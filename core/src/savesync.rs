//! Saves and save states kept in step with RomM, per profile (each profile is a RomM account).
//!
//! Before a game starts, what RomM has that is newer replaces the local copy; after the game, what
//! changed goes to RomM. When both sides changed since the last sync, the newest wins and the other
//! is archived (`profiles/<id>/archive/`): a local copy is always archived before it is replaced.
//!
//! What is synced, per emulator (each game has its own files, so nothing is shared between games):
//! - RetroArch: the battery save `<game>.srm` and the save states `<game>.state*`, sent with the
//!   core's name as the emulator, as RomM's own player (EmulatorJS) does;
//! - Dolphin: the game's own memory card (`GC/cards/<game>.raw`, set by Borne);
//! - DuckStation: the game's own memory card (`memcards/<game>_1.mcd`, cards per game file);
//! - PCSX2: a memory card per game (`memcards/<game>.ps2`, set by Borne);
//! - Eden and Citron: the game's save folder in the emulated console (by its title id), as a zip;
//! - RPCS3: the game's save folders (by the serial in its name), as zips.
//! Offline, the game starts with the local copy; sends are retried at the next start.

use crate::state::Shared;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn enabled(app: &Shared) -> bool {
    app.db.setting("save_sync").as_deref() != Some("off")
}

/// One thing kept in step: a file, or a folder sent as a zip.
#[derive(Clone, Debug)]
pub struct Item {
    pub kind: &'static str, // "saves" or "states"
    pub local: PathBuf,
    pub remote_name: String,
    pub folder: bool,
}

fn stem(rom: &Path) -> String {
    rom.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

/// The Switch title id in a file name ("Zelda [0100F2C0115B6000][v0].nsp").
pub fn title_id(rom: &Path) -> Option<String> {
    let n = rom.file_name()?.to_string_lossy().to_string();
    n.split('[')
        .skip(1)
        .filter_map(|p| p.split(']').next())
        .find(|t| t.len() == 16 && t.starts_with("01") && t.chars().all(|c| c.is_ascii_hexdigit()))
        .map(|t| t.to_uppercase())
}

/// The PS3 serial in a file or folder name ("Demon's Souls [BLES00932]").
pub fn ps3_serial(rom: &Path) -> Option<String> {
    let n = rom.to_string_lossy().to_uppercase();
    let b = n.as_bytes();
    (0..b.len().saturating_sub(8)).find_map(|i| {
        let w = &n[i..i + 9];
        let ok = w[..4].chars().all(|c| c.is_ascii_uppercase()) && w[4..].chars().all(|c| c.is_ascii_digit()) && matches!(&w[..2], "BL" | "BC" | "NP");
        ok.then(|| w.to_string())
    })
}

/// An Xbox 360 game's title id (8 hex digits), from its default.xex: a game folder, a .xex, or
/// an ISO (XDVDFS at any of the usual partition offsets).
pub fn xenia_title_id(rom: &Path) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let xex: Vec<u8> = if rom.is_dir() {
        std::fs::read(rom.join("default.xex")).ok()?
    } else if rom.extension().map(|e| e.eq_ignore_ascii_case("xex")).unwrap_or(false) {
        std::fs::read(rom).ok()?
    } else {
        let mut f = std::fs::File::open(rom).ok()?;
        let mut at = |o: u64, n: usize| -> Option<Vec<u8>> {
            let mut b = vec![0u8; n];
            f.seek(SeekFrom::Start(o)).ok()?;
            f.read_exact(&mut b).ok()?;
            Some(b)
        };
        let mut found = None;
        for base in [0u64, 0xFD90000, 0x2080000, 0x18300000] {
            let Some(vd) = at(base + 0x10000, 0x20) else { continue };
            if &vd[..20] != b"MICROSOFT*XBOX*MEDIA" {
                continue;
            }
            let le = |b: &[u8], o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as u64;
            let (sector, size) = (le(&vd, 0x14), le(&vd, 0x18) as usize);
            let dir = at(base + sector * 2048, size.min(1 << 20))?;
            let mut o = 0;
            while o + 14 <= dir.len() {
                if dir[o] == 0xFF && dir[o + 1] == 0xFF {
                    o = (o / 2048 + 1) * 2048;
                    continue;
                }
                let n = dir[o + 13] as usize;
                let name = String::from_utf8_lossy(dir.get(o + 14..o + 14 + n)?).to_lowercase();
                if name == "default.xex" {
                    let (s2, len) = (le(&dir, o + 4), le(&dir, o + 8) as usize);
                    found = at(base + s2 * 2048, len.min(1 << 20).max(0x1000));
                    break;
                }
                o = (o + 14 + n + 3) & !3;
            }
            if found.is_some() {
                break;
            }
        }
        found?
    };
    let be = |o: usize| xex.get(o..o + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]));
    if xex.get(0..4)? != b"XEX2" {
        return None;
    }
    let count = be(0x14)? as usize;
    for i in 0..count.min(64) {
        let (key, val) = (be(0x18 + i * 8)?, be(0x1C + i * 8)?);
        if key == 0x0004_0006 {
            return be(val as usize + 0xC).filter(|t| *t != 0).map(|t| format!("{t:08X}"));
        }
    }
    None
}

/// Ryujinx's save folder of a game: the numbered folder whose ExtraData0/1 starts with the
/// game's program id (the save's attribute, little endian), for an account save (type 1).
pub fn ryujinx_save_dir(root: &Path, program_id: u64) -> Option<PathBuf> {
    for e in std::fs::read_dir(root).ok()?.flatten() {
        let dir = e.path();
        for x in ["ExtraData0", "ExtraData1"] {
            let Ok(b) = std::fs::read(dir.join(x)) else { continue };
            if b.len() >= 0x21 && u64::from_le_bytes(b[0..8].try_into().unwrap()) == program_id && b[0x20] == 1 {
                return Some(dir);
            }
        }
    }
    None
}

/// A PS4 game's title id (CUSA…), from its param.sfo (the game folder, or the folder of its
/// eboot.bin).
pub fn ps4_title_id(rom: &Path) -> Option<String> {
    let root = if rom.is_dir() { rom.to_path_buf() } else { rom.parent()?.to_path_buf() };
    let sfo = std::fs::read(root.join("sce_sys/param.sfo")).ok()?;
    sfo_value(&sfo, "TITLE_ID")
}

/// A text value of a PlayStation SFO file.
pub fn sfo_value(sfo: &[u8], key: &str) -> Option<String> {
    let u32_at = |o: usize| sfo.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize);
    let u16_at = |o: usize| sfo.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]]) as usize);
    if sfo.get(0..4)? != b"\0PSF" {
        return None;
    }
    let (keys, data, count) = (u32_at(8)?, u32_at(12)?, u32_at(16)?);
    for i in 0..count.min(256) {
        let e = 20 + i * 16;
        let k = keys + u16_at(e)?;
        let name_end = sfo.get(k..)?.iter().position(|&b| b == 0)? + k;
        if &sfo[k..name_end] == key.as_bytes() {
            let len = u32_at(e + 4)?;
            let off = data + u32_at(e + 12)?;
            let raw = sfo.get(off..off + len)?;
            let text = String::from_utf8_lossy(raw).trim_end_matches('\0').trim().to_string();
            return (!text.is_empty()).then_some(text);
        }
    }
    None
}

/// The game's save folder in Eden / Citron's emulated console, once a console user exists.
fn switch_save_dir(data: &Path, tid: &str) -> Option<PathBuf> {
    let base = data.join("nand/user/save/0000000000000000");
    let users: Vec<PathBuf> = std::fs::read_dir(&base).ok()?.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
    let real = |u: &&PathBuf| !u.file_name().map(|n| n.to_string_lossy().chars().all(|c| c == '0')).unwrap_or(true);
    users.iter().find(|u| u.join(tid).is_dir()).or_else(|| users.iter().find(real)).map(|u| u.join(tid))
}

/// Dolphin's memory card for this game (Borne points slot A to it).
pub fn dolphin_card(app: &Shared, profile: &str, rom: &Path) -> PathBuf {
    app.paths.profiles().join(profile).join("dolphin/GC/cards").join(format!("{}.raw", stem(rom)))
}

/// What is synced for this game with this emulator (save states are listed apart).
pub fn items(app: &Shared, profile: &str, system: &str, program: &str, rom: &Path) -> Vec<Item> {
    let base = app.paths.profiles().join(profile);
    let data = crate::emulators::data_dir(app, profile, program);
    let st = stem(rom);
    match program {
        "retroarch" => vec![Item { kind: "saves", local: base.join("saves").join(system).join(format!("{st}.srm")), remote_name: format!("{st}.srm"), folder: false }],
        "dolphin" => vec![Item { kind: "saves", local: dolphin_card(app, profile, rom), remote_name: format!("{st}.raw"), folder: false }],
        "duckstation" => {
            let name = format!("{st}_1.mcd");
            vec![Item { kind: "saves", local: data.join("data/duckstation/memcards").join(&name), remote_name: name, folder: false }]
        }
        "pcsx2" => {
            let name = format!("{st}.ps2");
            vec![Item { kind: "saves", local: data.join("PCSX2/memcards").join(&name), remote_name: name, folder: false }]
        }
        // RPCS3: the game's save folders, named after its serial ("BLES01807…").
        "rpcs3" => match ps3_serial(rom) {
            Some(serial) => std::fs::read_dir(data.join("dev_hdd0/home/00000001/savedata"))
                .into_iter()
                .flatten()
                .flatten()
                .filter(|e| e.path().is_dir() && e.file_name().to_string_lossy().starts_with(&serial))
                .map(|e| Item { kind: "saves", local: e.path(), remote_name: format!("{}.zip", e.file_name().to_string_lossy()), folder: true })
                .collect(),
            None => vec![],
        },
        // Xenia: the game's saves (content/<profile>/<title id>/00000001), by the title id read
        // from its program; the game must have saved once on this computer.
        "xenia" => match xenia_title_id(rom) {
            Some(tid) => {
                let content = data.join("content");
                let mut found = content.join(&tid).join("00000001");
                for e in std::fs::read_dir(&content).into_iter().flatten().flatten() {
                    let d = e.path().join(&tid).join("00000001");
                    if d.is_dir() {
                        found = d;
                        break;
                    }
                }
                if found.is_dir() { vec![Item { kind: "saves", local: found, remote_name: format!("{tid}.zip"), folder: true }] } else { vec![] }
            }
            None => vec![],
        },
        // Ryujinx: the save folder whose extra data names the game's title id (folders are
        // numbered; the game must have made its save once on this computer).
        "ryubing" => match title_id(rom).and_then(|t| u64::from_str_radix(&t, 16).ok().map(|n| (t, n))) {
            Some((tid, n)) => ryujinx_save_dir(&data.join("bis/user/save"), n)
                .map(|dir| vec![Item { kind: "saves", local: dir, remote_name: format!("{tid}.zip"), folder: true }])
                .unwrap_or_default(),
            None => vec![],
        },
        // shadPS4: the game's save folder, named after its title id (CUSA…).
        "shadps4" => match ps4_title_id(rom) {
            Some(id) => {
                let dir = data.join("savedata/1").join(&id);
                vec![Item { kind: "saves", local: dir, remote_name: format!("{id}.zip"), folder: true }]
            }
            None => vec![],
        },
        "eden" | "citron" => match title_id(rom).and_then(|t| switch_save_dir(&data, &t).map(|d| (t, d))) {
            Some((tid, dir)) => vec![Item { kind: "saves", local: dir, remote_name: format!("{tid}.zip"), folder: true }],
            None => vec![],
        },
        _ => vec![],
    }
}

/// Where an emulator keeps every game's saves, relative to its data folder.
fn save_root(program: &str) -> Option<&'static str> {
    Some(match program {
        "pcsx2" => "PCSX2/memcards",
        "duckstation" => "data/duckstation/memcards",
        "rpcs3" => "dev_hdd0/home/00000001/savedata",
        "eden" | "citron" => "nand/user/save",
        "ryubing" => "bis/user/save",
        "shadps4" => "savedata",
        "xenia" => "content",
        _ => return None,
    })
}

/// Profiles never share saves. Most emulators keep theirs in each profile's own folder; on macOS,
/// Eden, Citron, Ryujinx, RPCS3 and PCSX2 keep theirs in one folder for the whole Mac. Before a
/// game, the saves there are set aside for the profile that last played (`profiles/<id>/stash/`)
/// and the playing profile's own are put back, so a profile never sees, nor sends to its RomM
/// account, another's saves.
pub fn claim(app: &Shared, profile: &str, program: &str) {
    let Some(rel) = save_root(program) else { return };
    let data = crate::emulators::data_dir(app, profile, program);
    if data.starts_with(app.paths.profiles()) {
        return; // already per profile
    }
    let root = data.join(rel);
    let key = format!("saveowner.{program}");
    let owner = app.db.setting(&key);
    if owner.as_deref() == Some(profile) {
        return;
    }
    let stash = |p: &str| app.paths.profiles().join(p).join("stash").join(program);
    let moved = |from: &Path, to: &Path| -> Result<(), String> {
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        if to.exists() {
            let _ = std::fs::remove_dir_all(to);
        }
        if std::fs::rename(from, to).is_ok() {
            return Ok(());
        }
        // Another volume: copy, then remove.
        copy_tree(from, to)?;
        std::fs::remove_dir_all(from).map_err(|e| e.to_string())
    };
    // Saves made before Borne knew whose they were belong to the profile playing now.
    if let Some(prev) = owner {
        if root.exists() {
            if let Err(e) = moved(&root, &stash(&prev).join("saves")) {
                app.db.log("saves", &format!("{program}: saves of another profile not set aside ({e}); not playing with them"));
                return;
            }
        }
        let mine = stash(profile).join("saves");
        if mine.exists() {
            if let Err(e) = moved(&mine, &root) {
                app.db.log("saves", &format!("{program}: this profile's saves not restored ({e})"));
            }
        }
    }
    let _ = std::fs::create_dir_all(&root);
    app.db.set_setting(&key, profile);
}

fn copy_tree(from: &Path, to: &Path) -> Result<(), String> {
    std::fs::create_dir_all(to).map_err(|e| e.to_string())?;
    for e in std::fs::read_dir(from).map_err(|e| e.to_string())?.flatten() {
        let (src, dst) = (e.path(), to.join(e.file_name()));
        if src.is_dir() {
            copy_tree(&src, &dst)?;
        } else {
            std::fs::copy(&src, &dst).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// RetroArch's save states of this game, on this device.
fn local_states(app: &Shared, profile: &str, system: &str, rom: &Path) -> Vec<Item> {
    let dir = app.paths.profiles().join(profile).join("states").join(system);
    let prefix = format!("{}.state", stem(rom));
    std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            (n.starts_with(&prefix) && !n.ends_with(".png")).then(|| Item { kind: "states", local: e.path(), remote_name: n, folder: false })
        })
        .collect()
}

fn state_key(profile: &str, rom_id: i64, item: &Item) -> String {
    format!("savesync.{profile}.{rom_id}.{}.{}", item.kind, item.remote_name)
}

fn last(app: &Shared, key: &str) -> Value {
    app.db.setting(key).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// A file's or a folder's content hash (paths and bytes), to tell a change.
fn hash(item: &Item) -> Option<String> {
    if !item.folder {
        return std::fs::read(&item.local).ok().map(|b| crate::emuinstall::sha256_bytes(&b));
    }
    if !item.local.is_dir() {
        return None;
    }
    let mut all = vec![];
    for f in walk(&item.local) {
        all.extend_from_slice(f.strip_prefix(&item.local).unwrap().to_string_lossy().as_bytes());
        all.extend(std::fs::read(&f).unwrap_or_default());
    }
    Some(crate::emuinstall::sha256_bytes(&all))
}

fn mtime(p: &Path) -> i64 {
    let files = if p.is_dir() { walk(p) } else { vec![p.to_path_buf()] };
    files
        .iter()
        .filter_map(|f| f.metadata().and_then(|m| m.modified()).ok())
        .filter_map(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .max()
        .unwrap_or(0)
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// RomM's time ("2026-11-11T21:07:11Z" or with an offset) in seconds.
fn parse_time(s: &str) -> i64 {
    let s = s.trim();
    let (date, time) = match s.split_once('T') {
        Some(x) => x,
        None => return 0,
    };
    let d: Vec<i64> = date.split('-').filter_map(|x| x.parse().ok()).collect();
    if d.len() != 3 {
        return 0;
    }
    let (clock, offset) = {
        let t = time.trim_end_matches('Z');
        match t.rfind(['+', '-']) {
            Some(i) if i > 0 => {
                let off = &t[i..];
                let sign = if off.starts_with('-') { -1 } else { 1 };
                let parts: Vec<i64> = off[1..].split(':').filter_map(|x| x.parse().ok()).collect();
                let secs = parts.first().copied().unwrap_or(0) * 3600 + parts.get(1).copied().unwrap_or(0) * 60;
                (&t[..i], sign * secs)
            }
            _ => (t, 0),
        }
    };
    let c: Vec<f64> = clock.split(':').filter_map(|x| x.parse().ok()).collect();
    if c.len() < 2 {
        return 0;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let (y, m, day) = (if d[1] <= 2 { d[0] - 1 } else { d[0] }, d[1], d[2]);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    days * 86400 + (c[0] as i64) * 3600 + (c[1] as i64) * 60 + c.get(2).copied().unwrap_or(0.0) as i64 - offset
}

/// Copies a local file or folder to the profile's archive before it is replaced.
fn archive(app: &Shared, profile: &str, item: &Item) {
    let dir = app.paths.profiles().join(profile).join("archive").join(item.kind);
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let dest = dir.join(format!("{}.{}", item.remote_name, now()));
    if item.folder {
        if let Ok(z) = zip_dir(&item.local) {
            let _ = std::fs::write(dest, z);
        }
    } else if item.local.is_file() {
        let _ = std::fs::copy(&item.local, dest);
    }
}

fn zip_dir(dir: &Path) -> Result<Vec<u8>, String> {
    let mut buf = std::io::Cursor::new(vec![]);
    {
        let mut z = zip::ZipWriter::new(&mut buf);
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for f in walk(dir) {
            let rel = f.strip_prefix(dir).unwrap().to_string_lossy().replace('\\', "/");
            z.start_file(rel, opts).map_err(|e| e.to_string())?;
            z.write_all(&std::fs::read(&f).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        }
        z.finish().map_err(|e| e.to_string())?;
    }
    Ok(buf.into_inner())
}

/// The newest copy on RomM of one file (by name, any emulator).
fn newest_remote(list: &[Value], name: &str) -> Option<Value> {
    list.iter()
        .filter(|s| s["file_name"].as_str().map(|n| n.eq_ignore_ascii_case(name)).unwrap_or(false) && s["missing_from_fs"] != true)
        .max_by_key(|s| parse_time(s["updated_at"].as_str().unwrap_or("")))
        .cloned()
}

/// Before a game: RomM's copies when they are newer. Returns notes for the log.
pub fn pull(app: &Shared, profile: &str, rom_id: i64, system: &str, program: &str, rom: &Path) -> Result<Vec<String>, String> {
    if !enabled(app) {
        return Ok(vec![]);
    }
    let client = app.client().ok_or("offline")?;
    let mut notes = vec![];
    let saves = client.assets("saves", rom_id).map_err(|e| e.to_string())?;
    let mut list: Vec<(Item, Value)> = vec![];
    for it in items(app, profile, system, program, rom) {
        if let Some(r) = newest_remote(&saves, &it.remote_name) {
            list.push((it, r));
        }
    }
    if program == "retroarch" {
        let states = client.assets("states", rom_id).unwrap_or_default();
        let prefix = format!("{}.state", stem(rom));
        let dir = app.paths.profiles().join(profile).join("states").join(system);
        let mut names: Vec<String> = states.iter().filter_map(|s| s["file_name"].as_str()).filter(|n| n.starts_with(&prefix)).map(String::from).collect();
        names.sort();
        names.dedup();
        for n in names {
            if let Some(r) = newest_remote(&states, &n) {
                list.push((Item { kind: "states", local: dir.join(&n), remote_name: n, folder: false }, r));
            }
        }
    }
    for (it, remote) in list {
        let key = state_key(profile, rom_id, &it);
        let prev = last(app, &key);
        let remote_time = parse_time(remote["updated_at"].as_str().unwrap_or(""));
        if remote_time <= prev["remote"].as_i64().unwrap_or(0) {
            continue;
        }
        let local_hash = hash(&it);
        let local_changed = local_hash.is_some() && local_hash.as_deref() != prev["hash"].as_str();
        if local_changed && mtime(&it.local) > remote_time {
            notes.push(format!("{}: the local copy is newer", it.remote_name));
            continue;
        }
        let id = remote["id"].as_i64().ok_or("asset without id")?;
        let safe: String = it.remote_name.chars().map(|c| if c == '/' || c == '\\' { '_' } else { c }).collect();
        let tmp = app.paths.profiles().join(profile).join(format!(".download-{safe}"));
        let _ = std::fs::create_dir_all(tmp.parent().unwrap());
        client.fetch_to_file(&format!("/api/{}/{id}/content", it.kind), &tmp, 512 << 20).map_err(|e| e.to_string())?;
        archive(app, profile, &it);
        if it.folder {
            let staging = it.local.with_extension("borne-new");
            let _ = std::fs::remove_dir_all(&staging);
            crate::downloads::extract_zip(&tmp, &staging, &std::sync::atomic::AtomicBool::new(false))?;
            let _ = std::fs::remove_dir_all(&it.local);
            std::fs::rename(&staging, &it.local).map_err(|e| e.to_string())?;
            let _ = std::fs::remove_file(&tmp);
        } else {
            std::fs::create_dir_all(it.local.parent().unwrap()).map_err(|e| e.to_string())?;
            std::fs::rename(&tmp, &it.local).map_err(|e| e.to_string())?;
        }
        app.db.set_setting(&key, &json!({ "hash": hash(&it), "remote": remote_time }).to_string());
        notes.push(format!("{}: taken from RomM", it.remote_name));
    }
    Ok(notes)
}

/// After a game: what changed goes to RomM (and what was still waiting). Returns how many files
/// were sent, or why some wait.
pub fn push(app: &Shared, profile: &str, rom_id: i64, system: &str, program: &str, rom: &Path, emulator: &str) -> Result<usize, String> {
    if !enabled(app) {
        return Ok(0);
    }
    let mut list = items(app, profile, system, program, rom);
    if program == "retroarch" {
        list.extend(local_states(app, profile, system, rom));
    }
    let mut sent = 0;
    let mut waiting: Option<String> = None;
    for it in list {
        let Some(h) = hash(&it) else { continue };
        let key = state_key(profile, rom_id, &it);
        let prev = last(app, &key);
        if prev["hash"].as_str() == Some(h.as_str()) && prev["pending"] != true {
            continue;
        }
        let mark_pending = || {
            app.db.set_setting(
                &key,
                &json!({ "hash": prev["hash"], "remote": prev["remote"], "pending": true, "system": system, "program": program, "rom": rom, "emulator": emulator }).to_string(),
            );
        };
        let Some(client) = app.client() else {
            mark_pending();
            waiting = Some("RomM unreachable".into());
            continue;
        };
        let data = if it.folder { zip_dir(&it.local)? } else { std::fs::read(&it.local).map_err(|e| e.to_string())? };
        match client.upload_asset(it.kind, rom_id, emulator, &it.remote_name, &data) {
            Ok(v) => {
                let t = parse_time(v["updated_at"].as_str().unwrap_or(""));
                app.db.set_setting(&key, &json!({ "hash": h, "remote": if t > 0 { t } else { now() } }).to_string());
                sent += 1;
            }
            Err(e) => {
                mark_pending();
                waiting = Some(e.to_string());
            }
        }
    }
    match waiting {
        Some(w) => Err(format!("sent later: {w}")),
        None => Ok(sent),
    }
}

/// Sends what is still waiting (RomM was unreachable), for the active profile.
pub fn retry_pending(app: &Shared) {
    let Some(p) = app.active_profile() else { return };
    let prefix = format!("savesync.{}.", p.id);
    let mut done = std::collections::HashSet::new();
    for (k, v) in app.db.settings_with_prefix(&prefix) {
        let Ok(v) = serde_json::from_str::<Value>(&v) else { continue };
        if v["pending"] != true {
            continue;
        }
        let Some(rom_id) = k.strip_prefix(&prefix).and_then(|r| r.split('.').next()).and_then(|r| r.parse::<i64>().ok()) else { continue };
        if !done.insert(rom_id) {
            continue;
        }
        let (Some(system), Some(program), Some(rom), Some(emu)) = (v["system"].as_str(), v["program"].as_str(), v["rom"].as_str(), v["emulator"].as_str()) else { continue };
        match push(app, &p.id, rom_id, system, program, Path::new(rom), emu) {
            Ok(n) if n > 0 => app.db.log("saves", &format!("game {rom_id}: {n} waiting file(s) sent")),
            Err(e) => app.db.log("saves", &format!("game {rom_id}: {e}")),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn romm_times() {
        assert_eq!(parse_time("1970-01-01T00:00:10Z"), 10);
        assert_eq!(parse_time("2026-11-11T21:07:11Z"), 1_794_431_231);
        assert_eq!(parse_time("2026-11-11T22:07:11+01:00"), 1_794_431_231);
        assert_eq!(parse_time("2026-11-11T21:07:11.123456"), 1_794_431_231);
        assert_eq!(parse_time("nonsense"), 0);
    }

    #[test]
    fn the_newest_copy_of_the_same_file_is_chosen() {
        let saves = vec![
            json!({ "id": 1, "file_name": "Game (World).srm", "updated_at": "2026-01-01T00:00:00Z" }),
            json!({ "id": 2, "file_name": "Game (World).srm", "updated_at": "2026-02-01T00:00:00Z" }),
            json!({ "id": 3, "file_name": "Other.srm", "updated_at": "2026-03-01T00:00:00Z" }),
        ];
        assert_eq!(newest_remote(&saves, "game (world).srm").unwrap()["id"], 2);
        assert!(newest_remote(&saves, "None.srm").is_none());
    }

    #[test]
    fn xbox360_title_id() {
        let mut xex = b"XEX2".to_vec();
        xex.resize(0x14, 0);
        xex.extend(1u32.to_be_bytes());
        xex.extend(0x0004_0006u32.to_be_bytes());
        xex.extend(0x40u32.to_be_bytes());
        xex.resize(0x40 + 0xC, 0);
        xex.extend(0x4D5307E6u32.to_be_bytes());
        xex.resize(0x100, 0);
        let p = std::env::temp_dir().join(format!("borne-xex-{}.xex", std::process::id()));
        std::fs::write(&p, &xex).unwrap();
        assert_eq!(super::xenia_title_id(&p).as_deref(), Some("4D5307E6"));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn ryujinx_saves_found_by_program_id() {
        let root = std::env::temp_dir().join(format!("borne-ryu-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for (dir, id, kind) in [("0000000000000001", 0x0100000000010000u64, 1u8), ("0000000000000002", 0x01007EF00011E000, 1), ("0000000000000003", 0x0100000000010000, 3)] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
            let mut b = id.to_le_bytes().to_vec();
            b.resize(0x40, 0);
            b[0x20] = kind;
            std::fs::write(root.join(dir).join("ExtraData0"), b).unwrap();
        }
        assert_eq!(super::ryujinx_save_dir(&root, 0x01007EF00011E000), Some(root.join("0000000000000002")));
        assert_eq!(super::ryujinx_save_dir(&root, 0x0100000000010000), Some(root.join("0000000000000001")));
        assert_eq!(super::ryujinx_save_dir(&root, 0x0100000000099000), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn sfo_title_id() {
        // A minimal SFO with one key, TITLE_ID = CUSA00001.
        let mut sfo = b"\0PSF".to_vec();
        sfo.extend(1u32.to_le_bytes()); // version
        sfo.extend(36u32.to_le_bytes()); // key table
        sfo.extend(48u32.to_le_bytes()); // data table
        sfo.extend(1u32.to_le_bytes()); // entries
        sfo.extend(0u16.to_le_bytes());
        sfo.extend(0x0204u16.to_le_bytes());
        sfo.extend(10u32.to_le_bytes());
        sfo.extend(12u32.to_le_bytes());
        sfo.extend(0u32.to_le_bytes());
        sfo.extend(b"TITLE_ID\0\0\0\0");
        sfo.extend(b"CUSA00001\0\0\0");
        assert_eq!(super::sfo_value(&sfo, "TITLE_ID").as_deref(), Some("CUSA00001"));
        assert_eq!(super::sfo_value(&sfo, "TITLE"), None);
    }

    #[test]
    fn ps3_serials() {
        assert_eq!(ps3_serial(Path::new("/g/Demon's Souls [BLES00932]/PS3_GAME")).as_deref(), Some("BLES00932"));
        assert_eq!(ps3_serial(Path::new("/g/Game.iso")), None);
    }

    #[test]
    fn switch_title_ids_and_save_folders() {
        assert_eq!(title_id(Path::new("/g/Zelda TotK [0100F2C0115B6000][v0].nsp")).as_deref(), Some("0100F2C0115B6000"));
        assert_eq!(title_id(Path::new("/g/Game.nsp")), None);
        let d = std::env::temp_dir().join(format!("borne-sw-{}", std::process::id()));
        let users = d.join("nand/user/save/0000000000000000");
        std::fs::create_dir_all(users.join("00000000000000000000000000000000")).unwrap();
        std::fs::create_dir_all(users.join("ABCDEF0123456789ABCDEF0123456789/0100F2C0115B6000")).unwrap();
        std::fs::write(users.join("ABCDEF0123456789ABCDEF0123456789/0100F2C0115B6000/save.bin"), b"x").unwrap();
        let dir = switch_save_dir(&d, "0100F2C0115B6000").unwrap();
        assert!(dir.ends_with("ABCDEF0123456789ABCDEF0123456789/0100F2C0115B6000"));
        let it = Item { kind: "saves", local: dir.clone(), remote_name: "x.zip".into(), folder: true };
        assert!(hash(&it).is_some());
        let z = zip::ZipArchive::new(std::io::Cursor::new(zip_dir(&dir).unwrap())).unwrap();
        assert_eq!(z.file_names().collect::<Vec<_>>(), vec!["save.bin"]);
        let _ = std::fs::remove_dir_all(d);
    }
}
