//! Emulators: finding them, starting a game, following the session.
//!
//! What Borne knows about each emulator (where to look, the systems it runs, its command line) is
//! declarative, in `emulators.json`. An emulator is found, in this order, at the path the user
//! chose, as a program on the PATH, as a Flatpak (Linux) or as an application in /Applications or
//! ~/Applications (macOS). RetroArch also needs a core for the system: the first one installed,
//! in RetroArch's own cores folder (native or Flatpak) or the system's libretro folder.
//!
//! One game runs at a time, as a child process of the core. RetroArch gets an extra configuration
//! file per profile (fullscreen; saves and states in the profile's folder), appended to the user's
//! own so their settings stay theirs. The session's output goes to `logs/emulator.log`; an
//! emulator that quits with an error within seconds is reported with the end of that log.

use crate::db::GameRow;
use crate::state::Shared;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Deserialize, Clone)]
pub struct Emulator {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub flatpak: Option<String>,
    #[serde(default)]
    pub binaries: Vec<String>,
    #[serde(default)]
    pub mac_apps: Vec<String>,
    pub args: Vec<String>,
    #[serde(default)]
    pub systems: Vec<String>,
    #[serde(default)]
    pub cores: std::collections::BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub user_provided: bool,
}

impl Emulator {
    fn runs(&self, system: &str) -> bool {
        self.systems.iter().any(|s| s == system) || self.cores.contains_key(system)
    }
    fn all_systems(&self) -> Vec<String> {
        let mut v: Vec<String> = self.systems.iter().cloned().chain(self.cores.keys().cloned()).collect();
        v.sort();
        v.dedup();
        v
    }
}

#[derive(Deserialize)]
struct Manifest {
    emulators: Vec<Emulator>,
}

pub fn all() -> Vec<Emulator> {
    serde_json::from_str::<Manifest>(include_str!("emulators.json"))
        .map(|m| m.emulators)
        .unwrap_or_default()
}

/// How an emulator was found.
#[derive(Clone, Debug, PartialEq)]
pub enum Found {
    Program(PathBuf),
    Flatpak(String),
}

impl Found {
    fn describe(&self) -> String {
        match self {
            Found::Program(p) => p.to_string_lossy().into_owned(),
            Found::Flatpak(id) => format!("Flatpak {id}"),
        }
    }
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

fn on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join(name))
        .find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    p.is_file() && p.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

fn flatpak_installed(id: &str) -> bool {
    let user = home().join(".local/share/flatpak/app").join(id);
    let system = Path::new("/var/lib/flatpak/app").join(id);
    user.join("current").exists() || system.join("current").exists()
}

fn user_path_key(id: &str) -> String {
    format!("emu_path.{id}")
}

/// Where an emulator is, if it is installed.
pub fn find(app: &Shared, e: &Emulator) -> Option<Found> {
    if let Some(p) = app.db.setting(&user_path_key(&e.id)).filter(|s| !s.is_empty()) {
        let p = PathBuf::from(p);
        // A macOS application chosen as a whole: its main program.
        if p.extension().map(|x| x == "app").unwrap_or(false) {
            let macos = p.join("Contents/MacOS");
            if let Some(exe) = std::fs::read_dir(&macos).ok()?.flatten().map(|f| f.path()).find(|f| is_executable(f)) {
                return Some(Found::Program(exe));
            }
        }
        return is_executable(&p).then_some(Found::Program(p));
    }
    for b in &e.binaries {
        if let Some(p) = on_path(b) {
            return Some(Found::Program(p));
        }
    }
    if cfg!(target_os = "linux") {
        if let Some(id) = &e.flatpak {
            if flatpak_installed(id) && on_path("flatpak").is_some() {
                return Some(Found::Flatpak(id.clone()));
            }
        }
    }
    if cfg!(target_os = "macos") {
        for dir in [PathBuf::from("/Applications"), home().join("Applications")] {
            for a in &e.mac_apps {
                let p = dir.join(a);
                if is_executable(&p) {
                    return Some(Found::Program(p));
                }
            }
        }
    }
    None
}

/// RetroArch's cores folders, native and Flatpak.
fn core_dirs(found: &Found) -> Vec<PathBuf> {
    let h = home();
    let mut v = vec![];
    if cfg!(target_os = "macos") {
        v.push(h.join("Library/Application Support/RetroArch/cores"));
    }
    if let Found::Flatpak(id) = found {
        v.push(h.join(".var/app").join(id).join("config/retroarch/cores"));
    }
    v.push(h.join(".config/retroarch/cores"));
    v.push(PathBuf::from("/usr/lib/x86_64-linux-gnu/libretro"));
    v.push(PathBuf::from("/usr/lib/libretro"));
    v.push(PathBuf::from("/usr/lib64/libretro"));
    v
}

fn find_core(found: &Found, names: &[String]) -> Option<PathBuf> {
    let ext = if cfg!(target_os = "macos") { "dylib" } else { "so" };
    for n in names {
        for d in core_dirs(found) {
            let p = d.join(format!("{n}_libretro.{ext}"));
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

/// Dolphin's GameCube language numbers.
fn dolphin_language(code: &str) -> Option<&'static str> {
    Some(match code {
        "en" => "0",
        "de" => "1",
        "fr" => "2",
        "es" => "3",
        "it" => "4",
        "nl" => "5",
        _ => return None,
    })
}

/// The emulator chosen for a system: the user's choice when it is installed, else the first one
/// installed, else the first one known (reported as missing).
fn choose(app: &Shared, system: &str) -> Option<(Emulator, Option<Found>)> {
    let list: Vec<Emulator> = all().into_iter().filter(|e| e.runs(system)).collect();
    if let Some(pref) = app.db.setting(&format!("emu_for.{system}")) {
        if let Some(e) = list.iter().find(|e| e.id == pref) {
            if let Some(f) = find(app, e) {
                return Some((e.clone(), Some(f)));
            }
        }
    }
    for e in &list {
        if let Some(f) = find(app, e) {
            if e.cores.is_empty() || find_core(&f, e.cores.get(system).map(|v| &v[..]).unwrap_or(&[])).is_some() {
                return Some((e.clone(), Some(f)));
            }
        }
    }
    list.into_iter().next().map(|e| {
        let f = find(app, &e);
        (e, f)
    })
}

/// Settings view: every emulator, where it was found, the systems it runs.
pub fn list(app: &Shared) -> Value {
    let flatpak = cfg!(target_os = "linux") && on_path("flatpak").is_some();
    let items: Vec<Value> = all()
        .iter()
        .map(|e| {
            let f = find(app, e);
            let cores: Vec<String> = match &f {
                Some(f) => e
                    .cores
                    .iter()
                    .filter_map(|(sys, names)| find_core(f, names).map(|_| sys.clone()))
                    .collect(),
                None => vec![],
            };
            json!({
                "id": e.id,
                "name": e.name,
                "found": f.as_ref().map(|f| f.describe()),
                "systems": e.all_systems(),
                "cores_for": cores,
                "needs_cores": !e.cores.is_empty(),
                "user_path": app.db.setting(&user_path_key(&e.id)).filter(|s| !s.is_empty()),
                "installable": flatpak && e.flatpak.is_some() && f.is_none(),
                "user_provided": e.user_provided,
            })
        })
        .collect();
    json!({ "emulators": items, "flatpak": flatpak, "install": install_state(), "session": session() })
}

pub fn set_path(app: &Shared, id: &str, path: &str) -> Result<(), String> {
    let e = all().into_iter().find(|e| e.id == id).ok_or("unknown emulator")?;
    let path = path.trim();
    if path.is_empty() {
        app.db.set_setting(&user_path_key(&e.id), "");
        return Ok(());
    }
    let p = Path::new(path);
    if !p.is_absolute() || !(is_executable(p) || (p.extension().map(|x| x == "app").unwrap_or(false) && p.is_dir())) {
        return Err("this path is not a program".into());
    }
    app.db.set_setting(&user_path_key(&e.id), path);
    Ok(())
}

// ---------- Flatpak installation ----------

static INSTALL: Mutex<Option<Value>> = Mutex::new(None);

fn install_state() -> Value {
    INSTALL.lock().unwrap().clone().unwrap_or(Value::Null)
}

pub fn install(app: &Shared, id: &str) -> Result<(), String> {
    let e = all().into_iter().find(|e| e.id == id).ok_or("unknown emulator")?;
    let fid = e.flatpak.clone().ok_or("no Flatpak for this emulator")?;
    if !(cfg!(target_os = "linux") && on_path("flatpak").is_some()) {
        return Err("Flatpak is not available on this system".into());
    }
    {
        let mut g = INSTALL.lock().unwrap();
        if g.as_ref().map(|v| v["running"] == true).unwrap_or(false) {
            return Err("an installation is already running".into());
        }
        *g = Some(json!({ "id": e.id, "running": true, "error": null }));
    }
    app.emit(json!({ "type": "emulators" }));
    let app = app.clone();
    std::thread::spawn(move || {
        let out = Command::new("flatpak")
            .args(["install", "--user", "--noninteractive", "-y", "flathub", &fid])
            .stdin(Stdio::null())
            .output();
        let error = match out {
            Ok(o) if o.status.success() => None,
            Ok(o) => Some(String::from_utf8_lossy(&o.stderr).lines().last().unwrap_or("installation failed").to_string()),
            Err(e) => Some(e.to_string()),
        };
        app.db.log("emulators", &format!("install {fid}: {}", error.as_deref().unwrap_or("ok")));
        *INSTALL.lock().unwrap() = Some(json!({ "id": e.id, "running": false, "error": error }));
        app.emit(json!({ "type": "emulators" }));
    });
    Ok(())
}

// ---------- sessions ----------

struct Session {
    rom_id: i64,
    name: String,
    emulator: String,
    started: Instant,
    child: Child,
    stopping: bool,
}

static SESSION: Mutex<Option<Session>> = Mutex::new(None);

pub fn playing() -> bool {
    SESSION.lock().unwrap().is_some()
}

pub fn session() -> Value {
    match SESSION.lock().unwrap().as_ref() {
        Some(s) => json!({ "running": true, "rom_id": s.rom_id, "name": s.name, "emulator": s.emulator, "seconds": s.started.elapsed().as_secs() }),
        None => json!({ "running": false }),
    }
}

/// The game's file on this device: downloaded, else linked through the virtual mount.
fn game_file(app: &Shared, g: &GameRow) -> Result<PathBuf, String> {
    if g.local_state == "local" {
        if let Some(m) = &g.local_main {
            let p = PathBuf::from(m);
            if p.is_file() {
                return Ok(p);
            }
        }
        return Err("the downloaded copy is missing: download the game again".into());
    }
    if g.linked {
        return crate::stream::link(app, g.rom_id);
    }
    Err("download the game or play it from the network first".into())
}

/// The command that starts `rom` with the emulator.
fn command(app: &Shared, e: &Emulator, found: &Found, system: &str, rom: &Path, lang: &str) -> Result<Command, String> {
    let mut core = None;
    if !e.cores.is_empty() {
        let names = e.cores.get(system).cloned().unwrap_or_default();
        core = Some(find_core(found, &names).ok_or_else(|| {
            format!("{} has no core for this console: install one of {} in RetroArch", e.name, names.join(", "))
        })?);
    }
    let config = if e.id == "retroarch" { Some(retroarch_config(app, system)?) } else { None };
    let lang_dolphin = if system == "ngc" { dolphin_language(lang).unwrap_or("") } else { "" };
    let mut args: Vec<String> = vec![];
    for a in &e.args {
        let v = a
            .replace("{rom}", &rom.to_string_lossy())
            .replace("{core}", &core.as_ref().map(|c| c.to_string_lossy().into_owned()).unwrap_or_default())
            .replace("{config}", &config.as_ref().map(|c| c.to_string_lossy().into_owned()).unwrap_or_default())
            .replace("{lang_dolphin}", lang_dolphin);
        // An option left without its value (no language chosen…) goes with its flag.
        if v.ends_with('=') || v.is_empty() {
            if args.last().map(|l| l.starts_with('-')).unwrap_or(false) {
                args.pop();
            }
            continue;
        }
        args.push(v);
    }
    let cmd = match found {
        Found::Program(p) => {
            let mut c = Command::new(p);
            c.args(&args);
            c
        }
        Found::Flatpak(id) => {
            let mut c = Command::new("flatpak");
            c.arg("run");
            // The sandbox sees the game's folder and Borne's per-profile folders, nothing more.
            if let Some(dir) = rom.parent() {
                c.arg(format!("--filesystem={}:ro", dir.to_string_lossy()));
            }
            c.arg(format!("--filesystem={}", app.paths.profiles().to_string_lossy()));
            c.arg(id).args(&args);
            c
        }
    };
    Ok(cmd)
}

/// RetroArch settings appended for Borne: fullscreen, the profile's saves and states.
fn retroarch_config(app: &Shared, system: &str) -> Result<PathBuf, String> {
    let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
    let base = app.paths.profiles().join(&profile);
    let saves = base.join("saves").join(system);
    let states = base.join("states").join(system);
    for d in [&saves, &states] {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let path = base.join("retroarch-borne.cfg");
    let text = format!(
        "video_fullscreen = \"true\"\nsavefile_directory = \"{}\"\nsavestate_directory = \"{}\"\nsort_savefiles_enable = \"false\"\nsort_savestates_enable = \"false\"\nconfig_save_on_exit = \"false\"\npause_nonactive = \"false\"\n",
        saves.to_string_lossy(),
        states.to_string_lossy()
    );
    std::fs::write(&path, text).map_err(|e| e.to_string())?;
    Ok(path)
}

fn emulator_log(app: &Shared) -> PathBuf {
    app.paths.reports().join("emulator.log")
}

fn log_tail(p: &Path) -> String {
    let t = std::fs::read_to_string(p).unwrap_or_default();
    let lines: Vec<&str> = t.lines().filter(|l| !l.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(3)..].join(" · ")
}

/// Starts the game. Returns when the emulator is running; the session is then followed in the
/// background and its end announced with a "session" event.
pub fn play(app: &Shared, rom_id: i64) -> Result<Value, String> {
    if SESSION.lock().unwrap().is_some() {
        return Err("a game is already running".into());
    }
    let g = app.db.game(rom_id).ok_or("unknown game")?;
    let system = g.platform_slug.clone();
    let (e, found) = choose(app, &system).ok_or_else(|| format!("Borne cannot run {} games yet", g.platform_name))?;
    let found = found.ok_or_else(|| {
        if e.user_provided {
            format!("{} is not installed: choose its program in Settings → Emulators", e.name)
        } else {
            format!("{} is not installed: install it from Settings → Emulators", e.name)
        }
    })?;
    let rom = game_file(app, &g)?;
    let lang = app
        .active_profile()
        .and_then(|p| app.db.game_prefs(&p.id).get(&g.group_key).and_then(|(_, l)| l.clone()))
        .unwrap_or_else(|| "auto".into());
    let mut cmd = command(app, &e, &found, &system, &rom, &lang)?;
    let log = emulator_log(app);
    let _ = std::fs::create_dir_all(log.parent().unwrap());
    let out = std::fs::File::create(&log).map_err(|e| e.to_string())?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    cmd.stdin(Stdio::null()).stdout(out).stderr(err);
    // Its own process group, so that stopping the game also stops what the emulator started
    // (Flatpak's sandbox, helper processes).
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let child = cmd.spawn().map_err(|err| format!("{} could not start: {err}", e.name))?;
    app.db.log("play", &format!("{} with {} ({})", g.name, e.name, found.describe()));
    *SESSION.lock().unwrap() = Some(Session { rom_id, name: g.name.clone(), emulator: e.name.clone(), started: Instant::now(), child, stopping: false });
    let s = session();
    app.emit(json!({ "type": "session", "session": s }));
    let app = app.clone();
    std::thread::spawn(move || follow(app, log));
    Ok(s)
}

fn follow(app: Shared, log: PathBuf) {
    loop {
        std::thread::sleep(Duration::from_millis(300));
        let mut g = SESSION.lock().unwrap();
        let Some(s) = g.as_mut() else { return };
        match s.child.try_wait() {
            Ok(None) => continue,
            Ok(Some(status)) => {
                let quick = s.started.elapsed() < Duration::from_secs(8) && !s.stopping;
                let error = (!status.success() && quick).then(|| {
                    let t = log_tail(&log);
                    if t.is_empty() { format!("{} stopped at once ({status})", s.emulator) } else { format!("{} stopped at once: {t}", s.emulator) }
                });
                let played = s.started.elapsed().as_secs();
                let (rom_id, name) = (s.rom_id, s.name.clone());
                *g = None;
                drop(g);
                app.db.log("play", &format!("{name}: session ended after {played} s ({status})"));
                app.emit(json!({ "type": "session", "session": { "running": false, "rom_id": rom_id, "seconds": played, "error": error } }));
                return;
            }
            Err(e) => {
                *g = None;
                drop(g);
                app.emit(json!({ "type": "session", "session": { "running": false, "error": e.to_string() } }));
                return;
            }
        }
    }
}

/// Ends the running game (the emulator is asked to quit, then stopped).
pub fn stop() -> bool {
    let mut g = SESSION.lock().unwrap();
    let Some(s) = g.as_mut() else { return false };
    s.stopping = true;
    let pid = s.child.id() as i32;
    unsafe {
        libc::kill(-pid, libc::SIGTERM);
    }
    drop(g);
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(5));
        if let Some(s) = SESSION.lock().unwrap().as_mut() {
            if s.child.id() as i32 == pid {
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
            }
        }
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_reads_and_covers_the_v1_systems() {
        let list = all();
        assert!(list.len() >= 4);
        for sys in ["nes", "genesis", "ngc", "ps2", "switch"] {
            assert!(list.iter().any(|e| e.runs(sys)), "{sys}");
        }
        for e in &list {
            assert!(e.args.iter().any(|a| a.contains("{rom}")), "{}", e.id);
        }
    }

    #[test]
    fn dolphin_language_numbers() {
        assert_eq!(dolphin_language("fr"), Some("2"));
        assert_eq!(dolphin_language("ja"), None);
    }
}
