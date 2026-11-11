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
    p.metadata()
        .and_then(|m| m.modified())
        .map(|t| t.elapsed().map(|e| e.as_secs() < 7 * 86400).unwrap_or(true))
        .unwrap_or(false)
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
                let xml = walk(&out).into_iter().find(|p| p.file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case("cheats.xml")).unwrap_or(false));
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
        for e in &errors {
            app.db.log("cheats", e);
        }
        *STATE.lock().unwrap() = Some(json!({ "running": false, "error": if errors.is_empty() { Value::Null } else { json!(errors.join("; ")) } }));
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
    map.into_values().filter(|(_, c)| !c.is_empty()).map(|(n, c)| Cheat { name: if n.is_empty() { "?".into() } else { n }, code: c }).collect()
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
                let n = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
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
            Ok(Event::Text(t)) => text.push_str(&t.unescape().unwrap_or_default()),
            Ok(Event::CData(t)) => text.push_str(&String::from_utf8_lossy(&t)),
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
                            let name = if folder.is_empty() || parent != "folder" { cheat_name.clone() } else { format!("{folder} — {cheat_name}") };
                            out.push(Cheat { name, code: code.join("+") });
                        }
                    }
                    ("folder", _) => folder.clear(),
                    ("game", _) => {
                        if ids.iter().any(|i| *i == game_id) {
                            return Some(out);
                        }
                    }
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
        let rom = g.local_main.clone().filter(|m| Path::new(m).is_file()).ok_or("download the game first: its exact version is read from the file")?;
        let (code, crc) = ds_id(Path::new(&rom)).ok_or("this file is not a DS game")?;
        let xml = std::fs::read_to_string(root(app).join("nds-cheats.xml")).map_err(|_| "the DS cheat database is not here yet".to_string())?;
        return Ok((ds_cheats(&xml, &code, crc).unwrap_or_default(), "ds"));
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
    let on: Vec<String> = app
        .db
        .setting(&enabled_key(&profile(app), rom_id))
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
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
    let on: Vec<String> = app.db.setting(&enabled_key(&profile(app), rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
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
        text += &format!("cheat{i}_desc = \"{}\"\ncheat{i}_code = \"{}\"\ncheat{i}_enable = true\n", c.name.replace('"', "'"), c.code.replace('"', ""));
    }
    if std::fs::create_dir_all(file.parent().unwrap()).is_ok() && std::fs::write(&file, text).is_ok() {
        out.push(("apply_cheats_after_load".into(), "true".into()));
        out.push(("cheat_settings_path".into(), dir.to_string_lossy().into_owned()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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
