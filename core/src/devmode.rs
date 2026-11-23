//! Developer mode: the emulators opened on their own interface (Borne's setup for the profile, no
//! game), extra command-line arguments per emulator, emulators of one's own for any console, and
//! RetroArch settings of one's own. Off by default (Settings → Help).
//!
//! Nothing it does is lost or breaks Borne's setup for good:
//! - before an emulator is opened, its configuration files are copied aside (the five last
//!   copies kept); "Undo my changes" puts the last copy back;
//! - RetroArch's configuration stays Borne's: what is changed in its menu is kept apart
//!   (retroarch-user.cfg, only the keys that changed, never Borne's folders) and added on top;
//! - turned off, Borne plays as without it: extra arguments, one's own emulators and RetroArch
//!   changes are put aside (kept, back when it is turned on again).

use crate::state::Shared;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

const ON: &str = "dev.on";
const CUSTOM: &str = "dev.custom";

static DEV_ON: AtomicBool = AtomicBool::new(false);
static OWN: Mutex<Vec<Own>> = Mutex::new(Vec::new());

/// An emulator of the player's own: a program, its arguments ({rom} for the game), the consoles
/// it plays.
#[derive(Clone, Debug, PartialEq)]
pub struct Own {
    pub id: String,
    pub name: String,
    pub exe: String,
    pub args: String,
    pub consoles: Vec<String>,
}

fn own_json(o: &Own) -> Value {
    json!({ "id": o.id, "name": o.name, "exe": o.exe, "args": o.args, "consoles": o.consoles })
}

fn own_from(v: &Value) -> Option<Own> {
    Some(Own {
        id: v["id"].as_str()?.to_string(),
        name: v["name"].as_str().unwrap_or("").to_string(),
        exe: v["exe"].as_str().unwrap_or("").to_string(),
        args: v["args"].as_str().unwrap_or("{rom}").to_string(),
        consoles: v["consoles"].as_array().map(|a| a.iter().filter_map(|c| c.as_str().map(String::from)).collect()).unwrap_or_default(),
    })
}

/// Reads the settings into memory (at start, and after each change).
pub fn load(app: &Shared) {
    DEV_ON.store(app.db.setting(ON).as_deref() == Some("1"), Ordering::SeqCst);
    let list: Vec<Own> = app
        .db
        .setting(CUSTOM)
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.as_array().map(|a| a.iter().filter_map(own_from).collect()))
        .unwrap_or_default();
    *OWN.lock().unwrap_or_else(|e| e.into_inner()) = list;
}

pub fn on() -> bool {
    DEV_ON.load(Ordering::SeqCst)
}

pub fn set_on(app: &Shared, on: bool) {
    app.db.set_setting(ON, if on { "1" } else { "" });
    load(app);
}

/// The player's own emulators, in effect only while developer mode is on.
pub fn own() -> Vec<Own> {
    if !on() {
        return vec![];
    }
    OWN.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn own_program(id: &str) -> Option<Own> {
    own().into_iter().find(|o| o.id == id)
}

fn save_own(app: &Shared, list: &[Own]) {
    app.db.set_setting(CUSTOM, &Value::Array(list.iter().map(own_json).collect()).to_string());
    load(app);
}

/// Adds or changes one of the player's emulators ({id} to change one; a new one gets its id).
pub fn put_own(app: &Shared, v: &Value) -> Result<Value, String> {
    let mut list = OWN.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let id = v["id"].as_str().filter(|s| !s.is_empty()).map(String::from).unwrap_or_else(|| {
        let n = (1..).find(|n| !list.iter().any(|o| o.id == format!("own-{n}"))).unwrap_or(1);
        format!("own-{n}")
    });
    let mut o = list.iter().find(|o| o.id == id).cloned().unwrap_or(Own {
        id: id.clone(),
        name: String::new(),
        exe: String::new(),
        args: "{rom}".into(),
        consoles: vec![],
    });
    if let Some(n) = v["name"].as_str() {
        let n = n.trim();
        if n.is_empty() {
            return Err("give the emulator a name".into());
        }
        o.name = n.to_string();
    }
    if let Some(e) = v["exe"].as_str() {
        let e = e.trim();
        let p = Path::new(e);
        let app_bundle = p.extension().map(|x| x == "app").unwrap_or(false) && p.is_dir();
        if !p.is_absolute() || !(crate::emulators::is_program(p) || app_bundle) {
            return Err("this path is not a program".into());
        }
        o.exe = e.to_string();
    }
    if let Some(a) = v["args"].as_str() {
        split_args(a)?;
        o.args = a.trim().to_string();
    }
    if let Some(c) = v["consoles"].as_array() {
        o.consoles = c.iter().filter_map(|x| x.as_str().map(String::from)).collect();
    }
    if o.name.is_empty() {
        o.name = Path::new(&o.exe).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "My emulator".into());
    }
    list.retain(|x| x.id != id);
    list.push(o.clone());
    save_own(app, &list);
    Ok(own_json(&o))
}

pub fn remove_own(app: &Shared, id: &str) {
    let mut list = OWN.lock().unwrap_or_else(|e| e.into_inner()).clone();
    list.retain(|o| o.id != id);
    save_own(app, &list);
    // A console or game left on it goes back to Borne's choice.
    for (k, v) in app.db.settings_with_prefix("emu_for") {
        if v == format!("!{id}") {
            app.db.delete_setting(&k);
        }
    }
}

/// Command-line arguments as a shell splits them: spaces, "double" or 'single' quotes.
pub fn split_args(s: &str) -> Result<Vec<String>, String> {
    let (mut out, mut cur, mut quote, mut any) = (vec![], String::new(), None::<char>, false);
    for c in s.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => cur.push(c),
            (None, '"' | '\'') => {
                quote = Some(c);
                any = true;
            }
            (None, c) if c.is_whitespace() => {
                if any || !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                    any = false;
                }
            }
            (None, c) => cur.push(c),
        }
    }
    if quote.is_some() {
        return Err("a quote is not closed".into());
    }
    if any || !cur.is_empty() {
        out.push(cur);
    }
    Ok(out)
}

// ---------- extra arguments ----------

fn args_key(program: &str) -> String {
    format!("dev.args.{program}")
}

/// The extra arguments given to an emulator before the game (developer mode on only).
pub fn extra_args(app: &Shared, program: &str) -> Vec<String> {
    if !on() {
        return vec![];
    }
    app.db.setting(&args_key(program)).and_then(|s| split_args(&s).ok()).unwrap_or_default()
}

pub fn set_args(app: &Shared, program: &str, args: &str) -> Result<(), String> {
    split_args(args)?;
    app.db.set_setting(&args_key(program), args.trim());
    Ok(())
}

// ---------- copies of the configuration ----------

/// Folders that hold games, saves or caches rather than settings: not copied.
const SKIP_DIRS: &[&str] = &[
    "saves",
    "states",
    "memcards",
    "nand",
    "sdmc",
    "mlc01",
    "shader",
    "shaders",
    "cache",
    "shadercache",
    "logs",
    "log",
    "games",
    "ux0",
    "vs0",
    "dev_hdd0",
    "dev_flash",
    "content",
    "sysdata",
    "gamesaves",
    "screenshots",
    "load",
    "dump",
    "textures",
    "covers",
    "bios",
    "firmware",
    "keys",
    "registered",
    "wfs",
    "pipelinecache",
    "gamecache",
    "savedata",
];
const CONFIG_EXT: &[&str] = &["ini", "cfg", "json", "yml", "yaml", "toml", "xml", "conf", "opt"];
const MAX_FILE: u64 = 1 << 20;
const KEEP: usize = 5;

fn profile(app: &Shared) -> String {
    app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into())
}

/// Where an emulator's settings are, for the active profile: Borne's folder for it, and its own
/// data folder when that is elsewhere (macOS).
fn config_roots(app: &Shared, program: &str) -> Vec<PathBuf> {
    let p = profile(app);
    let base = app.paths.profiles().join(&p).join(program);
    let data = crate::emulators::data_dir(app, &p, program);
    // PCSX2 on macOS: its folder in Application Support (data_dir gives the whole of it).
    let data = if program == "pcsx2" && cfg!(target_os = "macos") { data.join("PCSX2") } else { data };
    let mut v = vec![base.clone()];
    if !data.starts_with(&base) && !data.ends_with("Application Support") {
        v.push(data);
    }
    v
}

fn config_files(root: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > 6 || out.len() > 2000 {
        return;
    }
    for e in std::fs::read_dir(root).into_iter().flatten().flatten() {
        let path = e.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        let name = e.file_name().to_string_lossy().to_lowercase();
        if meta.is_dir() {
            if !SKIP_DIRS.contains(&name.as_str()) && !name.starts_with('.') {
                config_files(&path, depth + 1, out);
            }
        } else if meta.is_file() && meta.len() <= MAX_FILE {
            let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
            if CONFIG_EXT.contains(&ext.as_str()) {
                out.push(path);
            }
        }
    }
}

fn backups_dir(app: &Shared, program: &str) -> PathBuf {
    app.paths.root.join("dev-backups").join(profile(app)).join(program)
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Copies an emulator's settings aside (before it is opened); the oldest copies beyond five go.
pub fn snapshot(app: &Shared, program: &str) -> Result<(), String> {
    let mut files = vec![];
    for r in config_roots(app, program) {
        config_files(&r, 0, &mut files);
    }
    let dir = backups_dir(app, program).join(now_secs().to_string());
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut manifest = vec![];
    for (i, f) in files.iter().enumerate() {
        let name = format!("{i}.{}", f.extension().map(|x| x.to_string_lossy().into_owned()).unwrap_or_default());
        if std::fs::copy(f, dir.join(&name)).is_ok() {
            manifest.push(json!({ "file": name, "path": f.to_string_lossy() }));
        }
    }
    // RetroArch: the changes of one's own too.
    let user = retroarch_user(app);
    if program == "retroarch" && user.is_file() {
        let _ = std::fs::copy(&user, dir.join("retroarch-user.cfg"));
        manifest.push(json!({ "file": "retroarch-user.cfg", "path": user.to_string_lossy() }));
    }
    std::fs::write(dir.join("manifest.json"), Value::Array(manifest).to_string()).map_err(|e| e.to_string())?;
    let mut all = copies(app, program);
    while all.len() > KEEP {
        let old = all.remove(0);
        let _ = std::fs::remove_dir_all(backups_dir(app, program).join(old.to_string()));
    }
    Ok(())
}

/// The copies kept, oldest first (their times, in seconds).
fn copies(app: &Shared, program: &str) -> Vec<u64> {
    let mut v: Vec<u64> = std::fs::read_dir(backups_dir(app, program))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_string_lossy().parse().ok())
        .filter(|t: &u64| backups_dir(app, program).join(t.to_string()).join("manifest.json").is_file())
        .collect();
    v.sort();
    v
}

/// Puts back the settings as they were before the emulator was last opened (that copy is then
/// used up: the one before it is next).
pub fn undo(app: &Shared, program: &str) -> Result<usize, String> {
    let Some(last) = copies(app, program).pop() else { return Err("no copy of this emulator's settings yet".into()) };
    if crate::emulators::playing() {
        return Err("a game is running: quit it first".into());
    }
    let dir = backups_dir(app, program).join(last.to_string());
    let manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let mut n = 0;
    let mut had_user = false;
    for m in manifest.as_array().cloned().unwrap_or_default() {
        let (Some(file), Some(path)) = (m["file"].as_str(), m["path"].as_str()) else { continue };
        had_user |= file == "retroarch-user.cfg";
        let to = PathBuf::from(path);
        if let Some(p) = to.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        if std::fs::copy(dir.join(file), &to).is_ok() {
            n += 1;
        }
    }
    if program == "retroarch" && !had_user {
        let _ = std::fs::remove_file(retroarch_user(app));
    }
    let _ = std::fs::remove_dir_all(&dir);
    app.db.log("developer", &format!("{program}: {n} settings file(s) put back"));
    Ok(n)
}

// ---------- RetroArch ----------

/// Keys RetroArch's own changes never override: Borne's folders and how it watches games.
const RA_KEPT: &[&str] = &[
    "libretro_directory",
    "system_directory",
    "savefile_directory",
    "savestate_directory",
    "joypad_autoconfig_dir",
    "config_save_on_exit",
    "log_verbosity",
    "frontend_log_level",
    "libretro_log_level",
    "network_cmd_enable",
    "check_firmware_before_loading",
];

/// What is set only to open RetroArch on its menu (not kept as a change of one's own).
pub const RA_OPEN: &[(&str, &str)] = &[
    ("config_save_on_exit", "true"),
    ("menu_enable_widgets", "true"),
    ("input_menu_toggle_gamepad_combo", "2"),
    ("quit_press_twice", "false"),
    ("video_font_enable", "true"),
];

pub fn retroarch_user(app: &Shared) -> PathBuf {
    app.paths.profiles().join(profile(app)).join("retroarch-user.cfg")
}
pub fn retroarch_open_cfg(app: &Shared) -> PathBuf {
    app.paths.profiles().join(profile(app)).join("retroarch-dev.cfg")
}
fn retroarch_open_base(app: &Shared) -> PathBuf {
    app.paths.profiles().join(profile(app)).join("retroarch-dev.base")
}

fn parse_cfg(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let (k, v) = l.split_once('=')?;
            let k = k.trim();
            if k.is_empty() || k.starts_with('#') {
                return None;
            }
            Some((k.to_string(), v.trim().trim_matches('"').to_string()))
        })
        .collect()
}

/// The configuration RetroArch opens on: the one a game gets, with its menu; a copy of it is
/// kept to see afterwards what was changed.
pub fn retroarch_prepare_open(app: &Shared, game_cfg: &Path) -> Result<PathBuf, String> {
    let text = std::fs::read_to_string(game_cfg).map_err(|e| e.to_string())?;
    let mut lines = parse_cfg(&text);
    // One's own changes so far, then what opening needs.
    if let Ok(t) = std::fs::read_to_string(retroarch_user(app)) {
        for (k, v) in parse_cfg(&t) {
            lines.retain(|(key, _)| key != &k);
            lines.push((k, v));
        }
    }
    for (k, v) in RA_OPEN {
        lines.retain(|(key, _)| key != k);
        lines.push((k.to_string(), v.to_string()));
    }
    let out: String = lines.iter().map(|(k, v)| format!("{k} = \"{v}\"\n")).collect();
    std::fs::write(retroarch_open_base(app), &out).map_err(|e| e.to_string())?;
    let cfg = retroarch_open_cfg(app);
    std::fs::write(&cfg, &out).map_err(|e| e.to_string())?;
    Ok(cfg)
}

/// After RetroArch closed: what was changed in its menu joins one's own changes.
pub fn retroarch_collect(app: &Shared) -> usize {
    let (Ok(before), Ok(after)) = (std::fs::read_to_string(retroarch_open_base(app)), std::fs::read_to_string(retroarch_open_cfg(app)))
    else {
        return 0;
    };
    let before = parse_cfg(&before);
    let changed: Vec<(String, String)> = parse_cfg(&after)
        .into_iter()
        .filter(|(k, _)| !RA_KEPT.contains(&k.as_str()) && !RA_OPEN.iter().any(|(o, _)| o == k))
        .filter(|(k, v)| before.iter().find(|(b, _)| b == k).map(|(_, bv)| bv != v).unwrap_or(true))
        .collect();
    if changed.is_empty() {
        return 0;
    }
    let mut user = std::fs::read_to_string(retroarch_user(app)).map(|t| parse_cfg(&t)).unwrap_or_default();
    for (k, v) in &changed {
        user.retain(|(key, _)| key != k);
        user.push((k.clone(), v.clone()));
    }
    let out: String = user.iter().map(|(k, v)| format!("{k} = \"{v}\"\n")).collect();
    let _ = std::fs::write(retroarch_user(app), out);
    app.db.log("developer", &format!("RetroArch: {} setting(s) of your own kept", changed.len()));
    changed.len()
}

/// RetroArch's changes of one's own, added on top of Borne's configuration before a game.
pub fn retroarch_append(app: &Shared) -> Option<PathBuf> {
    let p = retroarch_user(app);
    (on() && p.is_file()).then_some(p)
}

fn retroarch_own_count(app: &Shared) -> usize {
    std::fs::read_to_string(retroarch_user(app)).map(|t| parse_cfg(&t).len()).unwrap_or(0)
}

// ---------- what the settings show ----------

pub fn view(app: &Shared) -> Value {
    let programs: Vec<Value> = crate::emulators::programs()
        .iter()
        .filter(|p| crate::emulators::find(app, &p.id).is_some())
        .map(|p| {
            let roots = config_roots(app, &p.id);
            json!({
                "id": p.id, "name": p.name,
                "folder": roots.last().map(|r| r.to_string_lossy().into_owned()),
                "args": app.db.setting(&args_key(&p.id)).unwrap_or_default(),
                "copies": copies(app, &p.id),
                "own_settings": if p.id == "retroarch" { retroarch_own_count(app) } else { 0 },
            })
        })
        .collect();
    let own: Vec<Value> = OWN
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .map(|o| {
            let mut v = own_json(o);
            v["found"] = json!(crate::emulators::is_program(Path::new(&o.exe)) || Path::new(&o.exe).is_dir());
            v["copies"] = json!(copies(app, &o.id));
            v
        })
        .collect();
    json!({ "on": on(), "programs": programs, "own": own })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_split_like_a_shell() {
        assert_eq!(split_args("-f  --x=1").unwrap(), vec!["-f", "--x=1"]);
        assert_eq!(split_args(r#"--name "a b" '' {rom}"#).unwrap(), vec!["--name", "a b", "", "{rom}"]);
        assert!(split_args("\"open").is_err());
        assert!(split_args("   ").unwrap().is_empty());
    }

    #[test]
    fn retroarch_cfg_is_read() {
        let v = parse_cfg("a = \"1\"\n# c\nb=\"x y\"\n");
        assert_eq!(v, vec![("a".to_string(), "1".to_string()), ("b".to_string(), "x y".to_string())]);
    }
}
