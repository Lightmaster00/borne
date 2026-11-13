//! Cheat codes, from public databases, matched to the exact version of each game.
//!
//! - Consoles run by RetroArch: the libretro cheat database (`cheats.zip` from the libretro
//!   buildbot, one `.cht` file per game, named after the No-Intro name of the dump). A game gets
//!   the file whose name is its own file name (title, region and revision included); a file for
//!   another region or revision is never used.
//! - Nintendo DS: DeadSkullzJr's NDS(i) cheat database (`cheats.xml` from its GitHub releases).
//!   Each entry carries the game ID read from the cartridge header: the 4-letter game code and the
//!   CRC32 of the 512-byte header, so each version (Europe, USA, Japan, revisions) has its own
//!   codes. Borne reads the same ID from the game file.
//!
//! - GameCube and Wii: the Action Replay and Gecko codes Dolphin ships with (its own
//!   `Sys/GameSettings/<game ID>.ini`), matched by the disc's 6-character game ID read from the
//!   game file (ISO, GCM, RVZ, WIA, CISO, WBFS).
//!
//! The databases are downloaded the first time cheats are asked for, then refreshed weekly. The
//! cheats chosen are kept per profile and per version, and written for the emulator before each
//! game (RetroArch: a `.cht` file loaded with the game).

use crate::state::Shared;
use serde_json::{json, Value};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const LIBRETRO_ZIP: &str = "https://buildbot.libretro.com/assets/frontend/cheats.zip";
const DS_REPO: &str = "DeadSkullzJr/NDS-i-Cheat-Databases";
/// Switch: HamletDuFromage's database in Atmosphère's layout (contents/<title id>/cheats/<build id>.txt).
const SWITCH_ZIP: &str = "https://github.com/HamletDuFromage/switch-cheats-db/releases/latest/download/contents.zip";

/// libretro database folders per console.
fn libretro_folder(slug: &str) -> Option<&'static str> {
    Some(match slug {
        "nes" | "famicom" => "Nintendo - Nintendo Entertainment System",
        "fds" => "Nintendo - Family Computer Disk System",
        "snes" | "sfam" => "Nintendo - Super Nintendo Entertainment System",
        "n64" => "Nintendo - Nintendo 64",
        "gb" => "Nintendo - Game Boy",
        "gbc" => "Nintendo - Game Boy Color",
        "gba" => "Nintendo - Game Boy Advance",
        "nds" => "Nintendo - Nintendo DS",
        "genesis" => "Sega - Mega Drive - Genesis",
        "sms" => "Sega - Master System - Mark III",
        "gamegear" => "Sega - Game Gear",
        "segacd" => "Sega - Mega-CD - Sega CD",
        "sega32" => "Sega - 32X",
        "saturn" => "Sega - Saturn",
        "psx" => "Sony - PlayStation",
        "tg16" => "NEC - PC Engine - TurboGrafx 16",
        "atari2600" => "Atari - 2600",
        "ngp" => "SNK - Neo Geo Pocket",
        "ngpc" => "SNK - Neo Geo Pocket Color",
        "wonderswan" => "Bandai - WonderSwan",
        "wonderswan-color" => "Bandai - WonderSwan Color",
        "virtualboy" => "Nintendo - Virtual Boy",
        "lynx" => "Atari - Lynx",
        _ => return None,
    })
}

fn root(app: &Shared) -> PathBuf {
    app.paths.root.join("cheats")
}

static STATE: Mutex<Option<Value>> = Mutex::new(None);

fn state() -> Value {
    STATE.lock().unwrap().clone().unwrap_or(Value::Null)
}

fn fresh(p: &Path) -> bool {
    p.metadata().and_then(|m| m.modified()).map(|t| t.elapsed().map(|e| e.as_secs() < 7 * 86400).unwrap_or(true)).unwrap_or(false)
}

/// Downloads (or refreshes) the databases in the background.
fn refresh(app: &Shared) {
    {
        let mut s = STATE.lock().unwrap();
        if s.as_ref().map(|v| v["running"] == true).unwrap_or(false) {
            return;
        }
        *s = Some(json!({ "running": true, "error": null }));
    }
    let app = app.clone();
    std::thread::spawn(move || {
        let mut errors = vec![];
        let dir = root(&app);
        let _ = std::fs::create_dir_all(&dir);
        if !fresh(&dir.join("libretro.stamp")) {
            match crate::emuinstall::fetch_file(LIBRETRO_ZIP, &dir.join("cheats.zip.part")).and_then(|_| {
                let out = dir.join("libretro.part");
                let _ = std::fs::remove_dir_all(&out);
                crate::downloads::extract_zip(&dir.join("cheats.zip.part"), &out, &std::sync::atomic::AtomicBool::new(false))?;
                let _ = std::fs::remove_dir_all(dir.join("libretro"));
                std::fs::rename(&out, dir.join("libretro")).map_err(|e| e.to_string())
            }) {
                Ok(()) => {
                    let _ = std::fs::write(dir.join("libretro.stamp"), "");
                }
                Err(e) => errors.push(format!("libretro: {e}")),
            }
            let _ = std::fs::remove_file(dir.join("cheats.zip.part"));
        }
        if !fresh(&dir.join("nds.stamp")) {
            let spec = json!({ "type": "github", "repo": DS_REPO, "ends": [".7z", ".zip"] });
            match crate::emuinstall::latest(&spec).and_then(|(_, url, sha)| {
                let file = dir.join("nds.download");
                crate::emuinstall::fetch_file(&url, &file)?;
                if let Some(want) = sha {
                    if !crate::emuinstall::sha256_file(&file).eq_ignore_ascii_case(&want) {
                        return Err("the DS database does not match its checksum".into());
                    }
                }
                let out = dir.join("nds.part");
                let _ = std::fs::remove_dir_all(&out);
                if url.to_lowercase().ends_with(".7z") {
                    sevenz_rust2::decompress_file(&file, &out).map_err(|e| e.to_string())?;
                } else {
                    crate::downloads::extract_zip(&file, &out, &std::sync::atomic::AtomicBool::new(false))?;
                }
                let _ = std::fs::remove_file(&file);
                let xml = walk(&out)
                    .into_iter()
                    .find(|p| p.file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case("cheats.xml")).unwrap_or(false));
                let xml = xml.ok_or("no cheats.xml in the DS database")?;
                std::fs::rename(&xml, dir.join("nds-cheats.xml")).map_err(|e| e.to_string())?;
                let _ = std::fs::remove_dir_all(&out);
                Ok(())
            }) {
                Ok(()) => {
                    let _ = std::fs::write(dir.join("nds.stamp"), "");
                }
                Err(e) => errors.push(format!("DS: {e}")),
            }
        }
        // The Switch database is large: only with Switch games in the library.
        let has_switch = app.db.platforms().iter().any(|p| p.slug == "switch");
        if has_switch && !fresh(&dir.join("switch.stamp")) {
            let part = dir.join("switch-contents.zip.part");
            match crate::emuinstall::fetch_file(SWITCH_ZIP, &part)
                .and_then(|_| std::fs::rename(&part, dir.join("switch-contents.zip")).map_err(|e| e.to_string()))
            {
                Ok(()) => {
                    let _ = std::fs::write(dir.join("switch.stamp"), "");
                }
                Err(e) => errors.push(format!("Switch: {e}")),
            }
            let _ = std::fs::remove_file(&part);
        }
        for e in &errors {
            app.db.log("cheats", e);
        }
        *STATE.lock().unwrap() =
            Some(json!({ "running": false, "error": if errors.is_empty() { Value::Null } else { json!(errors.join("; ")) } }));
        app.emit(json!({ "type": "cheats" }));
    });
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
    out
}

/// One cheat: a name (with its folder), and its codes.
#[derive(Clone, Debug, PartialEq)]
pub struct Cheat {
    pub name: String,
    pub code: String,
}

// ---------- libretro .cht ----------

fn stem(name: &str) -> String {
    let n = name.rsplit('/').next().unwrap_or(name);
    match n.rsplit_once('.') {
        Some((s, ext)) if ext.len() <= 4 => s.to_string(),
        _ => n.to_string(),
    }
}

/// The game's .cht: the one named exactly after its file (case and spacing ignored).
fn libretro_file(app: &Shared, slug: &str, fs_name: &str) -> Option<PathBuf> {
    let folder = root(app).join("libretro").join(libretro_folder(slug)?);
    let want = norm(&stem(fs_name));
    let dir = std::fs::read_dir(&folder).ok()?;
    dir.flatten().map(|e| e.path()).find(|p| norm(&stem(&p.file_name().unwrap_or_default().to_string_lossy())) == want)
}

fn norm(s: &str) -> String {
    s.to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn parse_cht(text: &str) -> Vec<Cheat> {
    let mut map = std::collections::BTreeMap::<usize, (String, String)>::new();
    for line in text.lines() {
        let Some((k, v)) = line.split_once('=') else { continue };
        let (k, v) = (k.trim(), v.trim().trim_matches('"'));
        let Some(rest) = k.strip_prefix("cheat") else { continue };
        let Some((n, field)) = rest.split_once('_') else { continue };
        let Ok(n) = n.parse::<usize>() else { continue };
        let e = map.entry(n).or_default();
        match field {
            "desc" => e.0 = v.to_string(),
            "code" => e.1 = v.to_string(),
            _ => {}
        }
    }
    map.into_values()
        .filter(|(_, c)| !c.is_empty())
        .map(|(n, c)| Cheat { name: if n.is_empty() { "?".into() } else { n }, code: c })
        .collect()
}

// ---------- DS ----------

/// The DS game ID: game code (header 0x0C) and the CRC32 of the 512-byte header.
pub fn ds_id(rom: &Path) -> Option<(String, u32)> {
    let mut f = std::fs::File::open(rom).ok()?;
    let mut h = [0u8; 512];
    f.read_exact(&mut h).ok()?;
    let code = std::str::from_utf8(&h[0x0C..0x10]).ok()?.to_string();
    if !code.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some((code, crc32fast::hash(&h)))
}

/// The cheats of one DS game in cheats.xml: the entry whose game ID is the game's (the CRC as
/// stored, or its complement, which some tools write).
pub fn ds_cheats(xml: &str, code: &str, crc: u32) -> Option<Vec<Cheat>> {
    use quick_xml::events::Event;
    let ids = [format!("{code} {crc:08X}"), format!("{code} {:08X}", !crc)];
    let mut r = quick_xml::Reader::from_str(xml);
    let mut path: Vec<String> = vec![];
    let mut text = String::new();
    let mut game_id = String::new();
    let mut folder = String::new();
    let mut cheat_name = String::new();
    let mut cheat_codes = String::new();
    let mut out: Vec<Cheat> = vec![];
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) => {
                let n = e.name().as_ref().to_lowercase();
                if n == "game" {
                    game_id.clear();
                    out.clear();
                    folder.clear();
                }
                if n == "cheat" {
                    cheat_name.clear();
                    cheat_codes.clear();
                }
                path.push(n);
                text.clear();
            }
            Ok(Event::Text(t)) => text.push_str(&t.xml10_content()),
            Ok(Event::GeneralRef(r)) => match r.resolve_char_ref() {
                Ok(Some(c)) => text.push(c),
                _ => text.push_str(quick_xml::escape::resolve_predefined_entity(&r).unwrap_or("")),
            },
            Ok(Event::CData(t)) => text.push_str(&t),
            Ok(Event::End(_)) => {
                let n = path.pop().unwrap_or_default();
                let parent = path.last().cloned().unwrap_or_default();
                match (n.as_str(), parent.as_str()) {
                    ("gameid", "game") => game_id = text.trim().to_uppercase(),
                    ("name", "folder") => folder = text.trim().to_string(),
                    ("name", "cheat") => cheat_name = text.trim().to_string(),
                    ("codes", "cheat") => cheat_codes = text.trim().to_string(),
                    ("cheat", _) => {
                        let words: Vec<&str> = cheat_codes.split_whitespace().collect();
                        let code: Vec<String> = words.chunks(2).filter(|c| c.len() == 2).map(|c| format!("{} {}", c[0], c[1])).collect();
                        if !code.is_empty() {
                            let name = if folder.is_empty() || parent != "folder" {
                                cheat_name.clone()
                            } else {
                                format!("{folder} — {cheat_name}")
                            };
                            out.push(Cheat { name, code: code.join("+") });
                        }
                    }
                    ("folder", _) => folder.clear(),
                    ("game", _) if ids.contains(&game_id) => return Some(out),
                    _ => {}
                }
                text.clear();
            }
            Ok(Event::Eof) | Err(_) => return None,
            _ => {}
        }
    }
}

// ---------- per game ----------

fn enabled_key(profile: &str, rom_id: i64) -> String {
    format!("cheats.{profile}.{rom_id}")
}

fn profile(app: &Shared) -> String {
    app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into())
}

/// The cheats of this version of the game, and which are on.
fn game_cheats(app: &Shared, rom_id: i64) -> Result<(Vec<Cheat>, &'static str), String> {
    let g = app.db.game(rom_id).ok_or("unknown game")?;
    if g.platform_slug == "nds" {
        let rom = g
            .local_main
            .clone()
            .filter(|m| Path::new(m).is_file())
            .ok_or("download the game first: its exact version is read from the file")?;
        let (code, crc) = ds_id(Path::new(&rom)).ok_or("this file is not a DS game")?;
        let xml =
            std::fs::read_to_string(root(app).join("nds-cheats.xml")).map_err(|_| "the DS cheat database is not here yet".to_string())?;
        return Ok((ds_cheats(&xml, &code, crc).unwrap_or_default(), "ds"));
    }
    if g.platform_slug == "ps2" {
        let file = ps2_file(app, &g.group_key);
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        return Ok((parse_pnach(&text), "pnach"));
    }
    if g.platform_slug == "switch" {
        let name = g.local_main.clone().unwrap_or_else(|| g.fs_name.clone());
        let tid = crate::savesync::title_id(Path::new(&name)).ok_or("the game's title id is not in its file name ([0100…])")?;
        let files = switch_cheat_files(app, &tid);
        let mut list: Vec<Cheat> = vec![];
        for (_, text) in &files {
            for c in parse_atmosphere(text) {
                if !c.name.is_empty() && !list.iter().any(|x| x.name == c.name) {
                    list.push(c);
                }
            }
        }
        return Ok((list, "switch-cheats-db"));
    }
    if g.platform_slug == "ngc" || g.platform_slug == "wii" {
        let rom = g
            .local_main
            .clone()
            .filter(|m| Path::new(m).is_file())
            .ok_or("download the game first: its exact version is read from the file")?;
        let id = disc_id(Path::new(&rom)).ok_or("the game ID could not be read from this file")?;
        let dir = dolphin_codes_dir(app).ok_or("install Dolphin first (Settings → Emulators): its own code list is used")?;
        return Ok((dolphin_cheats(&dir, &id), "dolphin"));
    }
    let Some(f) = libretro_file(app, &g.platform_slug, &g.fs_name) else { return Ok((vec![], "libretro")) };
    Ok((parse_cht(&std::fs::read_to_string(f).unwrap_or_default()), "libretro"))
}

pub fn list(app: &Shared, rom_id: i64) -> Value {
    let dir = root(app);
    let ready = dir.join("libretro.stamp").exists() || dir.join("nds.stamp").exists();
    if !fresh(&dir.join("libretro.stamp")) || !fresh(&dir.join("nds.stamp")) {
        refresh(app);
    }
    let on: Vec<String> =
        app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    match game_cheats(app, rom_id) {
        Ok((list, source)) => json!({
            "ready": ready,
            "source": source,
            "updating": state()["running"] == true,
            "error": state()["error"],
            "cheats": list.iter().map(|c| json!({ "name": c.name, "on": on.contains(&c.name) })).collect::<Vec<_>>(),
        }),
        Err(e) => json!({ "ready": ready, "updating": state()["running"] == true, "cheats": [], "error": e }),
    }
}

pub fn set(app: &Shared, rom_id: i64, on: &[String]) -> Value {
    app.db.set_setting(&enabled_key(&profile(app), rom_id), &serde_json::to_string(on).unwrap());
    list(app, rom_id)
}

/// RetroArch: the enabled cheats as a .cht file and the settings that load it with the game.
pub fn retroarch_settings(app: &Shared, rom_id: i64, core_name: &str, rom: &Path) -> Vec<(String, String)> {
    let on: Vec<String> =
        app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let dir = app.paths.profiles().join(profile(app)).join("cheats");
    let file = dir.join(core_name).join(format!("{}.cht", stem(&rom.to_string_lossy())));
    let _ = std::fs::remove_file(&file);
    let cheats: Vec<Cheat> = if on.is_empty() { vec![] } else { game_cheats(app, rom_id).map(|c| c.0).unwrap_or_default() };
    let chosen: Vec<&Cheat> = cheats.iter().filter(|c| on.contains(&c.name)).collect();
    let mut out = vec![("cheat_database_path".to_string(), dir.to_string_lossy().into_owned())];
    if chosen.is_empty() {
        return out;
    }
    let mut text = format!("cheats = {}\n", chosen.len());
    for (i, c) in chosen.iter().enumerate() {
        text += &format!(
            "cheat{i}_desc = \"{}\"\ncheat{i}_code = \"{}\"\ncheat{i}_enable = true\n",
            c.name.replace('"', "'"),
            c.code.replace('"', "")
        );
    }
    if std::fs::create_dir_all(file.parent().unwrap()).is_ok() && std::fs::write(&file, text).is_ok() {
        out.push(("apply_cheats_after_load".into(), "true".into()));
        out.push(("cheat_settings_path".into(), dir.to_string_lossy().into_owned()));
    }
    out
}

/// Standalone melonDS: the chosen DS cheats in "<game>.mch" next to the game file (melonDS's own
/// cheat file), and cheats turned on in its settings when they exist.
pub fn melonds_settings(app: &Shared, rom_id: i64, data: &Path, rom: &Path) -> Result<(), String> {
    let on: Vec<String> =
        app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let mch = rom.with_extension("mch");
    // melonDS 1.x keeps its settings in melonDS.toml (its config folder, per profile on Linux).
    for file in [data.join("config/melonDS/melonDS.toml"), data.join("melonDS.toml")] {
        if file.exists() {
            let _ = crate::emulators::ini_set(&file, &[("Instance0", "EnableCheats", if on.is_empty() { "false" } else { "true" })]);
        }
    }
    // Only a file Borne wrote is replaced or removed; one the player put there stays.
    let ours = |p: &Path| !p.exists() || std::fs::read(p).map(|t| t.starts_with(b"CAT Borne")).unwrap_or(false);
    if !ours(&mch) {
        return Ok(());
    }
    if on.is_empty() {
        let _ = std::fs::remove_file(&mch);
        return Ok(());
    }
    let cheats = game_cheats(app, rom_id).map(|c| c.0).unwrap_or_default();
    let mut text = String::from("CAT Borne\n\n");
    for c in cheats.iter().filter(|c| on.contains(&c.name)) {
        text += &format!("CHEAT {}\nON\n{}\n\n", c.name, c.code.split('+').collect::<Vec<_>>().join("\n"));
    }
    std::fs::write(&mch, text).map_err(|e| e.to_string())
}

// ---------- PlayStation 2 ----------
// No public cheat database is maintained for PCSX2: the user gives a .pnach for the game (a file
// or a link); Borne lists its cheats and writes the chosen ones under the game's CRC.

fn ps2_file(app: &Shared, group_key: &str) -> PathBuf {
    let safe: String = group_key.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    root(app).join("ps2").join(format!("{safe}.pnach"))
}

/// Keeps the .pnach given for this game (a path on the computer, or a link).
pub fn add_ps2_file(app: &Shared, group_key: &str, path: Option<&str>, url: Option<&str>) -> Result<usize, String> {
    let dst = ps2_file(app, group_key);
    std::fs::create_dir_all(dst.parent().unwrap()).map_err(|e| e.to_string())?;
    let tmp = dst.with_extension("part");
    match (path, url) {
        (Some(p), _) => {
            std::fs::copy(p, &tmp).map_err(|e| format!("{p}: {e}"))?;
        }
        (None, Some(u)) => crate::emuinstall::fetch_file(u, &tmp)?,
        _ => return Err("a file or a link expected".into()),
    }
    let small = std::fs::metadata(&tmp).map(|m| m.len() <= 4 << 20).unwrap_or(false);
    let text = match std::fs::read_to_string(&tmp) {
        Ok(t) if small => t,
        _ => {
            let _ = std::fs::remove_file(&tmp);
            return Err("not a text file".into());
        }
    };
    let n = parse_pnach(&text).len();
    if n == 0 {
        let _ = std::fs::remove_file(&tmp);
        return Err("no cheat (patch= line) in this file".into());
    }
    std::fs::rename(&tmp, &dst).map_err(|e| e.to_string())?;
    Ok(n)
}

/// Cheats of a .pnach: each "[Name]" section (pnach 2), else each run of patch lines under its
/// comment ("// Name" or "comment=Name").
pub fn parse_pnach(text: &str) -> Vec<Cheat> {
    let mut out: Vec<Cheat> = vec![];
    let mut name = String::new();
    let mut open = false;
    for line in text.lines() {
        let l = line.trim();
        if l.starts_with('[') && l.ends_with(']') {
            name = l[1..l.len() - 1].trim().to_string();
            open = false;
        } else if let Some(c) = l.strip_prefix("//").or_else(|| l.strip_prefix("comment=")) {
            if !c.trim().is_empty() {
                name = c.trim().to_string();
                open = false;
            }
        } else if l.starts_with("patch=") || l.starts_with("patch =") {
            if !open || out.is_empty() {
                let n = if name.is_empty() { format!("Cheat {}", out.len() + 1) } else { name.clone() };
                out.push(Cheat { name: n, code: String::new() });
                open = true;
            }
            let c = out.last_mut().unwrap();
            c.code += l;
            c.code.push('\n');
        }
    }
    out
}

/// PCSX2: the chosen cheats in `cheats/<CRC>.pnach` (unnamed, so PCSX2 applies them all) and
/// cheats turned on; the CRC is read from the game's main program on the disc (ISO only).
pub fn ps2_settings(app: &Shared, rom_id: i64, data: &Path, rom: &Path, group_key: &str) -> Result<(), String> {
    let on: Vec<String> =
        app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let ini = data.join("PCSX2/inis/PCSX2.ini");
    crate::emulators::ini_set(&ini, &[("EmuCore", "EnableCheats", if on.is_empty() { "false" } else { "true" })])?;
    if on.is_empty() {
        return Ok(());
    }
    let crc = ps2_crc(rom).ok_or("the game's CRC could not be read (cheats need an .iso)")?;
    let text = std::fs::read_to_string(ps2_file(app, group_key)).unwrap_or_default();
    let mut out = String::from("// Cheats chosen in Borne\n");
    for c in parse_pnach(&text).into_iter().filter(|c| on.contains(&c.name)) {
        out += &format!("// {}\n{}", c.name, c.code);
    }
    let dir = data.join("PCSX2/cheats");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(dir.join(format!("{crc:08X}.pnach")), out).map_err(|e| e.to_string())
}

/// PCSX2's CRC of a PS2 disc image: the XOR of the 32-bit words of the program SYSTEM.CNF boots.
pub fn ps2_crc(iso: &Path) -> Option<u32> {
    use std::io::{Seek, SeekFrom};
    let mut f = std::fs::File::open(iso).ok()?;
    let mut read = |lba: u64, len: usize| -> Option<Vec<u8>> {
        let mut b = vec![0u8; len];
        f.seek(SeekFrom::Start(lba * 2048)).ok()?;
        f.read_exact(&mut b).ok()?;
        Some(b)
    };
    let pvd = read(16, 2048)?;
    if &pvd[1..6] != b"CD001" {
        return None;
    }
    let le = |b: &[u8], o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
    let (root_lba, root_len) = (le(&pvd, 156 + 2) as u64, le(&pvd, 156 + 10) as usize);
    let root = read(root_lba, root_len.min(1 << 20))?;
    let find = |dir: &[u8], want: &str| -> Option<(u64, usize)> {
        let mut o = 0;
        while o < dir.len() {
            let n = dir[o] as usize;
            if n == 0 {
                o = (o / 2048 + 1) * 2048; // records do not cross sectors
                continue;
            }
            let name_len = *dir.get(o + 32)? as usize;
            let name = String::from_utf8_lossy(dir.get(o + 33..o + 33 + name_len)?).to_uppercase();
            if name.split(';').next() == Some(want) {
                return Some((le(dir, o + 2) as u64, le(dir, o + 10) as usize));
            }
            o += n;
        }
        None
    };
    let (cnf_lba, cnf_len) = find(&root, "SYSTEM.CNF")?;
    let cnf = String::from_utf8_lossy(&read(cnf_lba, cnf_len.min(4096))?).to_string();
    let boot = cnf.lines().find(|l| l.trim_start().starts_with("BOOT2"))?.split('=').nth(1)?.trim().to_string();
    let elf_name = boot.rsplit(['\\', ':']).next()?.split(';').next()?.to_uppercase();
    let (elf_lba, elf_len) = find(&root, &elf_name)?;
    let elf = read(elf_lba, elf_len.min(64 << 20))?;
    Some(elf.chunks(4).fold(0u32, |acc, w| {
        let mut b = [0u8; 4];
        b[..w.len()].copy_from_slice(w);
        acc ^ u32::from_le_bytes(b)
    }))
}

// ---------- Switch ----------

/// The database's cheat files for this title: (build id, text), one per version of the game.
fn switch_cheat_files(app: &Shared, tid: &str) -> Vec<(String, String)> {
    let zip_path = root(app).join("switch-contents.zip");
    let Ok(f) = std::fs::File::open(&zip_path) else { return vec![] };
    let Ok(mut z) = zip::ZipArchive::new(f) else { return vec![] };
    let want = format!("/{}/cheats/", tid.to_lowercase());
    let names: Vec<String> = z
        .file_names()
        .filter_map(|n| n.ok())
        .filter(|n| format!("/{}", n.to_lowercase()).contains(&want) && n.to_lowercase().ends_with(".txt"))
        .map(|n| n.into_owned())
        .collect();
    let mut out = vec![];
    for n in names {
        let Ok(mut e) = z.by_name(&n) else { continue };
        let mut text = String::new();
        if e.read_to_string(&mut text).is_ok() {
            let bid = Path::new(&n).file_stem().map(|s| s.to_string_lossy().to_uppercase()).unwrap_or_default();
            out.push((bid, text));
        }
    }
    out
}

/// Atmosphère cheat text: "[Name]" then its code lines; "{Master}" codes are always kept with
/// any cheat (their code holds "{master}").
pub fn parse_atmosphere(text: &str) -> Vec<Cheat> {
    let mut out: Vec<Cheat> = vec![];
    for line in text.lines() {
        let l = line.trim();
        if l.starts_with('[') && l.ends_with(']') {
            out.push(Cheat { name: l[1..l.len() - 1].trim().to_string(), code: String::new() });
        } else if l.starts_with('{') && l.ends_with('}') {
            out.push(Cheat { name: String::new(), code: "{master}\n".into() });
        } else if !l.is_empty() {
            if let Some(c) = out.last_mut() {
                c.code += l;
                c.code.push('\n');
            }
        }
    }
    out
}

/// Eden, Citron, Ryujinx: the chosen cheats written for every version of the game in the
/// emulator's mod folder (Borne cannot read the game's build id, so each version gets its file).
pub fn switch_settings(app: &Shared, rom_id: i64, program: &str, data: &Path, rom: &Path) -> Result<(), String> {
    let Some(tid) = crate::savesync::title_id(rom) else { return Ok(()) };
    let on: Vec<String> =
        app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let dir = match program {
        "ryubing" => data.join("mods/contents").join(tid.to_lowercase()).join("Borne").join("cheats"),
        _ => data.join("load").join(&tid).join("Borne").join("cheats"),
    };
    let _ = std::fs::remove_dir_all(&dir);
    if on.is_empty() {
        return Ok(());
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut enabled = String::new();
    for (bid, text) in switch_cheat_files(app, &tid) {
        let mut out = String::new();
        for c in parse_atmosphere(&text) {
            if c.name.is_empty() {
                out += "{Master Code}\n";
                out += &c.code.replace("{master}\n", "");
            } else if on.contains(&c.name) {
                out += &format!("[{}]\n{}\n", c.name, c.code);
                enabled += &format!("{bid}-{}\n", c.name);
            }
        }
        std::fs::write(dir.join(format!("{bid}.txt")), out).map_err(|e| e.to_string())?;
    }
    // Ryujinx turns on only the cheats listed in enabled.txt.
    if program == "ryubing" {
        std::fs::write(dir.join("enabled.txt"), enabled).map_err(|e| e.to_string())?;
    }
    Ok(())
}

// ---------- Dolphin ----------

/// The 6-character game ID of a GameCube or Wii disc image.
pub fn disc_id(rom: &Path) -> Option<String> {
    let mut f = std::fs::File::open(rom).ok()?;
    let mut head = vec![0u8; 0x8008];
    let n = f.read(&mut head).ok()?;
    head.truncate(n);
    let at = match head.get(0..4)? {
        b"RVZ\x01" | b"WIA\x01" => 0x58,
        b"CISO" => 0x8000,
        b"WBFS" => 0x200,
        _ => 0,
    };
    let id = head.get(at..at + 6)?;
    id.iter().all(|c| c.is_ascii_alphanumeric()).then(|| String::from_utf8_lossy(id).into_owned())
}

/// Where the installed Dolphin keeps its game settings and codes.
fn dolphin_codes_dir(app: &Shared) -> Option<PathBuf> {
    let exe = PathBuf::from(crate::emuinstall::installed(app, "dolphin")?["exe"].as_str()?);
    for base in exe.ancestors().take(5) {
        for rel in ["Sys/GameSettings", "Resources/Sys/GameSettings", "usr/share/dolphin-emu/sys/GameSettings", "sys/GameSettings"] {
            let d = base.join(rel);
            if d.is_dir() {
                return Some(d);
            }
        }
    }
    None
}

/// The codes in Dolphin's files for this game: the 6-character ID's, then the 3-character
/// one's (all regions). Each cheat's code says its kind ("ActionReplay" or "Gecko").
pub fn dolphin_cheats(dir: &Path, id: &str) -> Vec<Cheat> {
    let mut out: Vec<Cheat> = vec![];
    for file in [format!("{id}.ini"), format!("{}.ini", &id[..3.min(id.len())])] {
        let text = std::fs::read_to_string(dir.join(&file)).unwrap_or_default();
        let mut section = String::new();
        for line in text.lines() {
            let l = line.trim();
            if l.starts_with('[') && l.ends_with(']') {
                section = l[1..l.len() - 1].to_string();
            } else if (section == "ActionReplay" || section == "Gecko") && l.starts_with('$') {
                let name = l[1..].trim().to_string();
                if !name.is_empty() && !out.iter().any(|c| c.name == name) {
                    out.push(Cheat { name, code: section.clone() });
                }
            }
        }
    }
    out
}

/// Dolphin: the chosen codes enabled in the game's settings of Borne's Dolphin folder, and
/// cheats turned on (or off when none is chosen).
pub fn dolphin_settings(app: &Shared, rom_id: i64, userdir: &Path, rom: &Path) -> Result<(), String> {
    let on: Vec<String> =
        app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    crate::emulators::ini_set(
        &userdir.join("Config/Dolphin.ini"),
        &[("Core", "EnableCheats", if on.is_empty() { "False" } else { "True" })],
    )?;
    let Some(id) = disc_id(rom) else { return Ok(()) };
    let list = dolphin_codes_dir(app).map(|d| dolphin_cheats(&d, &id)).unwrap_or_default();
    let file = userdir.join("GameSettings").join(format!("{id}.ini"));
    let mut text = String::new();
    for section in ["ActionReplay", "Gecko"] {
        let names: Vec<&Cheat> = list.iter().filter(|c| c.code == section && on.contains(&c.name)).collect();
        text += &format!("[{section}_Enabled]\n");
        for c in names {
            text += &format!("${}\n", c.name);
        }
    }
    std::fs::create_dir_all(file.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(&file, text).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pnach_cheats_and_crc() {
        let c = parse_pnach("gametitle=Test\n[Infinite HP]\npatch=1,EE,00100000,word,00000001\n// Max money\npatch=1,EE,00200000,word,00000002\npatch=1,EE,00200004,word,00000003\n");
        assert_eq!(c.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), vec!["Infinite HP", "Max money"]);
        assert_eq!(c[1].code.lines().count(), 2);
        // A tiny ISO: PVD at sector 16, root at sector 18 holding SYSTEM.CNF (sector 19) and the ELF (sector 20).
        let mut iso = vec![0u8; 2048 * 21];
        let pvd = 16 * 2048;
        iso[pvd] = 1;
        iso[pvd + 1..pvd + 6].copy_from_slice(b"CD001");
        iso[pvd + 158..pvd + 162].copy_from_slice(&18u32.to_le_bytes());
        iso[pvd + 166..pvd + 170].copy_from_slice(&2048u32.to_le_bytes());
        let cnf = b"BOOT2 = cdrom0:\\SLUS_123.45;1\r\nVER = 1.00\r\n";
        iso[19 * 2048..19 * 2048 + cnf.len()].copy_from_slice(cnf);
        let elf: Vec<u8> = [0x11111111u32, 0x22222222, 0x44444444].iter().flat_map(|w| w.to_le_bytes()).collect();
        iso[20 * 2048..20 * 2048 + elf.len()].copy_from_slice(&elf);
        let mut o = 18 * 2048;
        for (name, lba, len) in [("SYSTEM.CNF;1", 19u32, cnf.len() as u32), ("SLUS_123.45;1", 20, elf.len() as u32)] {
            let rec = 33 + name.len() + (name.len() + 1) % 2;
            iso[o] = rec as u8;
            iso[o + 2..o + 6].copy_from_slice(&lba.to_le_bytes());
            iso[o + 10..o + 14].copy_from_slice(&len.to_le_bytes());
            iso[o + 32] = name.len() as u8;
            iso[o + 33..o + 33 + name.len()].copy_from_slice(name.as_bytes());
            o += rec;
        }
        let p = std::env::temp_dir().join(format!("borne-ps2-{}.iso", std::process::id()));
        std::fs::write(&p, &iso).unwrap();
        assert_eq!(ps2_crc(&p), Some(0x77777777));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn ds_cheats_from_the_xml_database() {
        let xml = "<codelist><game><name>Test</name><gameid>ABCD 1234ABCD</gameid>\
            <folder><name>Items &amp; money</name><cheat><name>Max caf&#233;</name><codes>02000000 0000FFFF</codes></cheat></folder>\
            <cheat><name><![CDATA[Walk <through> walls]]></name><codes>12000000 00000001 22000000 00000002</codes></cheat>\
            </game></codelist>";
        let c = ds_cheats(xml, "ABCD", 0x1234ABCD).unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].name, "Items & money — Max café");
        assert_eq!(c[0].code, "02000000 0000FFFF");
        assert_eq!(c[1].name, "Walk <through> walls");
        assert_eq!(c[1].code, "12000000 00000001+22000000 00000002");
        assert!(ds_cheats(xml, "WXYZ", 1).is_none());
    }

    #[test]
    fn atmosphere_cheats() {
        let c = parse_atmosphere("{Master Code}\n04000000 00000000\n\n[Infinite HP]\n04000000 11111111\n[Max money]\n04000000 22222222\n");
        assert_eq!(c.len(), 3);
        assert_eq!(c[0].name, "");
        assert_eq!(c[1].name, "Infinite HP");
        assert_eq!(c[1].code, "04000000 11111111\n");
    }

    #[test]
    fn dolphin_codes_and_disc_ids() {
        let d = std::env::temp_dir().join(format!("borne-dolphin-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("GALE01.ini"),
            "[OnFrame]\n[ActionReplay]\n$Infinite health\n0000 0000\n[Gecko]\n$Moon jump [someone]\nC2000000 00000000\n",
        )
        .unwrap();
        std::fs::write(d.join("GAL.ini"), "[ActionReplay]\n$Infinite health\n$All trophies\n").unwrap();
        let c = dolphin_cheats(&d, "GALE01");
        assert_eq!(
            c.iter().map(|c| (c.name.as_str(), c.code.as_str())).collect::<Vec<_>>(),
            vec![("Infinite health", "ActionReplay"), ("Moon jump [someone]", "Gecko"), ("All trophies", "ActionReplay")]
        );
        let mut iso = b"GALE01".to_vec();
        iso.resize(0x100, 0);
        std::fs::write(d.join("g.iso"), &iso).unwrap();
        assert_eq!(disc_id(&d.join("g.iso")).as_deref(), Some("GALE01"));
        let mut rvz = b"RVZ\x01".to_vec();
        rvz.resize(0x58, 0);
        rvz.extend(b"RMCP01");
        rvz.resize(0x200, 0);
        std::fs::write(d.join("g.rvz"), &rvz).unwrap();
        assert_eq!(disc_id(&d.join("g.rvz")).as_deref(), Some("RMCP01"));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn reads_libretro_cheat_files() {
        let t = "cheats = 2\n\ncheat0_desc = \"Infinite Lives\"\ncheat0_code = \"SXIOPO\"\ncheat0_enable = false\ncheat1_desc = \"Start on World 8\"\ncheat1_code = \"AAAA+BBBB\"\n";
        let c = parse_cht(t);
        assert_eq!(c.len(), 2);
        assert_eq!(c[1], Cheat { name: "Start on World 8".into(), code: "AAAA+BBBB".into() });
    }

    #[test]
    fn ds_cheats_follow_the_exact_version() {
        let xml = r#"<codelist>
          <game><name>Pokemon (Europe)</name><gameid>IRBF 11111111</gameid>
            <cheat><name>Money</name><codes>02000000 0000FFFF</codes></cheat></game>
          <game><name>Pokemon (Europe) (Rev 1)</name><gameid>IRBF 22222222</gameid>
            <folder><name>Items</name><cheat><name>All items</name><codes>94000130 FCFF0000 02000004 00000001</codes></cheat></folder></game>
        </codelist>"#;
        let rev1 = ds_cheats(xml, "IRBF", 0x22222222).unwrap();
        assert_eq!(rev1, vec![Cheat { name: "Items — All items".into(), code: "94000130 FCFF0000+02000004 00000001".into() }]);
        assert_eq!(ds_cheats(xml, "IRBF", 0x11111111).unwrap()[0].name, "Money");
        assert!(ds_cheats(xml, "IRBF", 0x33333333).is_none());
    }

    #[test]
    fn ds_id_reads_the_header() {
        let dir = std::env::temp_dir().join(format!("borne-ds-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut h = vec![0u8; 600];
        h[0x0C..0x10].copy_from_slice(b"IRBF");
        let p = dir.join("g.nds");
        std::fs::write(&p, &h).unwrap();
        let (code, crc) = ds_id(&p).unwrap();
        assert_eq!(code, "IRBF");
        assert_eq!(crc, crc32fast::hash(&h[..512]));
        let _ = std::fs::remove_dir_all(dir);
    }
}
