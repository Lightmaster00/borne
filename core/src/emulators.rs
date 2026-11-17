//! Emulators: the choice per console, finding the program, starting a game, following the session.
//!
//! `emulators.json` lists the programs (where they come from, how they start) and, per console, the
//! choices offered in Settings → Emulators: a RetroArch core by name, or `!program` for a
//! standalone emulator. The user picks one per console; Borne installs it (emuinstall.rs),
//! configures it and starts it. A program is used, in this order: as installed by Borne, at the
//! path the user chose, on the PATH, as a Flatpak (Linux) or in /Applications (macOS).
//!
//! RetroArch runs with Borne's own configuration (`--config`), written from Borne's settings
//! before each game: fullscreen, no menu, no on-screen messages, no hotkeys, the profile's saves
//! and states. The user's own RetroArch settings are never read nor changed, and the user never
//! has to open RetroArch. Dolphin gets its own user folder per profile.
//!
//! One game runs at a time, as a child process of the core in its own process group. The session's
//! output goes to `reports/emulator.log`; an emulator that quits with an error within seconds is
//! reported with the end of that log.

use crate::db::GameRow;
use crate::state::Shared;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Deserialize, Clone)]
pub struct Program {
    pub id: String,
    pub name: String,
    pub args: Vec<String>,
    #[serde(default)]
    install: BTreeMap<String, Value>,
    #[serde(default)]
    cores: BTreeMap<String, String>,
    #[serde(default)]
    binaries: Vec<String>,
    #[serde(default)]
    mac_apps: Vec<String>,
    #[serde(default)]
    pub user_provided: bool,
    /// Lines in the emulator's output that mean the game did not start (case ignored): the
    /// emulator is then closed instead of staying on its own screen with no game.
    #[serde(default)]
    fails: Vec<String>,
    /// File extensions the program does not take, and the one to give it instead (Azahar reads
    /// a .3ds image only as .cci): the game is handed over through a link with that name.
    #[serde(default)]
    rename_ext: BTreeMap<String, String>,
    /// The emulator's own log files, inside its data folder (a folder: its newest file). Many
    /// write their errors there rather than to their output; watched like the output.
    #[serde(default)]
    pub logs: Vec<String>,
}

impl Program {
    pub fn install_spec(&self) -> Option<Value> {
        self.install.get(crate::emuinstall::os()).cloned()
    }
    pub fn cores_url(&self) -> Option<String> {
        self.cores.get(crate::emuinstall::os()).cloned()
    }
}

#[derive(Deserialize)]
struct Manifest {
    programs: Vec<Program>,
    consoles: BTreeMap<String, Vec<(String, String)>>,
}

fn manifest() -> Manifest {
    serde_json::from_str(include_str!("emulators.json")).expect("emulators.json")
}

pub fn programs() -> Vec<Program> {
    manifest().programs
}
pub fn program(id: &str) -> Option<Program> {
    programs().into_iter().find(|p| p.id == id)
}

/// One choice for a console: a RetroArch core, or a standalone program.
#[derive(Clone, Debug, PartialEq)]
pub struct Engine {
    pub id: String,
    pub name: String,
    pub program: String,
    pub core: Option<String>,
}

fn engine(id: &str, name: &str) -> Engine {
    match id.strip_prefix('!') {
        Some(p) => Engine { id: id.into(), name: name.into(), program: p.into(), core: None },
        None => Engine { id: id.into(), name: name.into(), program: "retroarch".into(), core: Some(id.into()) },
    }
}

/// The consoles Borne plays (an emulator in its list).
pub fn known_consoles() -> Vec<String> {
    manifest().consoles.into_iter().filter(|(_, v)| !v.is_empty()).map(|(k, _)| k).collect()
}

pub fn engines(system: &str) -> Vec<Engine> {
    let mut list: Vec<Engine> = manifest().consoles.get(system).map(|v| v.iter().map(|(i, n)| engine(i, n)).collect()).unwrap_or_default();
    // On a Mac, Ryujinx (Ryubing) comes first for the Switch: Eden's ARM64 recompiler crashes
    // there in the middle of games (Dynarmic, freed memory), Ryujinx runs natively.
    if system == "switch" && cfg!(target_os = "macos") {
        if let Some(i) = list.iter().position(|e| e.program == "ryubing") {
            let r = list.remove(i);
            list.insert(0, r);
        }
    }
    list
}

/// Changes made once to the player's choices when a default proved wrong.
pub fn migrate(app: &Shared) {
    // On a Mac, Eden crashes in the middle of Switch games (its ARM64 recompiler): a console
    // left on Eden moves to Ryujinx (Ryubing) once. A choice made after that stays.
    if cfg!(target_os = "macos") && app.db.setting("migrated.mac_switch_ryubing").is_none() {
        if app.db.setting("emu_for.switch").as_deref().is_some_and(|e| e == "!eden" || e == "!citron") {
            app.db.set_setting("emu_for.switch", "!ryubing");
            app.db.log("emulators", "Switch: Eden replaced by Ryubing on this Mac (Eden crashes there)");
        }
        app.db.set_setting("migrated.mac_switch_ryubing", "1");
    }
}

/// What is said when an emulator crashed (killed by a signal it raised).
fn crash_message(emulator: &str, program: &str, signal: i32) -> String {
    let hint = match program {
        "eden" | "citron" if cfg!(target_os = "macos") => {
            ": a known problem of this emulator on Mac. Choose Ryubing for this game or for the Switch (Game settings → Emulator)"
        }
        "cemu" => ": its log is in the diagnostic report (Settings → Diagnostics)",
        _ => "",
    };
    format!("{emulator} crashed (signal {signal}){hint}")
}

/// The engine chosen for a console (the user's choice, else the first one).
pub fn chosen(app: &Shared, system: &str) -> Option<Engine> {
    let list = engines(system);
    let pref = app.db.setting(&format!("emu_for.{system}"));
    list.iter().find(|e| Some(&e.id) == pref.as_ref()).cloned().or_else(|| list.into_iter().next())
}

/// The engine for one game: its own choice (game settings), else its console's.
pub fn chosen_for_game(app: &Shared, system: &str, group_key: &str) -> Option<Engine> {
    let own = app.db.setting(&format!("emu_for_game.{group_key}"));
    let mut first = engines(system).into_iter().find(|e| Some(&e.id) == own.as_ref()).or_else(|| chosen(app, system))?;
    // One Borne can neither find nor install any more (Citron, taken down): the console's next one.
    let usable = |e: &Engine| find(app, &e.program).is_some() || program(&e.program).map(|p| p.install_spec().is_some()).unwrap_or(false);
    if !usable(&first) {
        if let Some(other) = engines(system).into_iter().find(|e| usable(e)) {
            first = other;
        }
    }
    // A game that did not run on it goes to its partner (Eden ↔ Ryubing), without a word: the
    // player keeps the preferred one for every other game.
    if failed_on(app, group_key, &first.program) {
        if let Some(other) = partners(system, &first.program).into_iter().find(|o| !failed_on(app, group_key, &o.program)) {
            return Some(other);
        }
    }
    Some(first)
}

/// Emulators that can stand in for each other, per console: a game that crashes or does not start
/// on one is started on the other.
const PARTNERS: &[(&str, &[&str])] = &[("switch", &["eden", "ryubing"])];

/// The engines that stand in for `program` on `system` (available on this computer).
pub fn partners(system: &str, program: &str) -> Vec<Engine> {
    let Some((_, group)) = PARTNERS.iter().find(|(s, _)| *s == system) else { return vec![] };
    if !group.contains(&program) {
        return vec![];
    }
    engines(system)
        .into_iter()
        .filter(|e| e.program != program && group.contains(&e.program.as_str()))
        .filter(|e| self::program(&e.program).map(|p| p.install_spec().is_some()).unwrap_or(false))
        .collect()
}

fn failed_key(group_key: &str, program: &str) -> String {
    format!("emu_failed.{group_key}.{program}")
}

/// Whether this game already failed on this emulator (it crashed or did not start).
fn failed_on(app: &Shared, group_key: &str, program: &str) -> bool {
    app.db.setting(&failed_key(group_key, program)).is_some()
}

/// How long a game must run before a crash no longer counts as "this game does not run here".
const RUNS_AFTER: Duration = Duration::from_secs(180);

/// Sets (or, with None, clears) the engine of one game; installed at once like a console's.
pub fn choose_for_game(app: &Shared, system: &str, group_key: &str, engine_id: Option<&str>) -> Result<(), String> {
    let key = format!("emu_for_game.{group_key}");
    let Some(id) = engine_id else {
        app.db.delete_setting(&key);
        return Ok(());
    };
    let e = engines(system).into_iter().find(|e| e.id == id).ok_or("unknown emulator for this console")?;
    app.db.set_setting(&key, &e.id);
    if find(app, &e.program).is_none() || e.core.as_ref().map(|c| !crate::emuinstall::core_path(app, c).is_file()).unwrap_or(false) {
        let _ = crate::emuinstall::start(app, &e.program, e.core.into_iter().collect());
    }
    Ok(())
}

pub fn choose(app: &Shared, system: &str, engine_id: &str) -> Result<(), String> {
    let e = engines(system).into_iter().find(|e| e.id == engine_id).ok_or("unknown emulator for this console")?;
    app.db.set_setting(&format!("emu_for.{system}"), &e.id);
    // Installed at once, so the first game starts without waiting.
    if program(&e.program).map(|p| p.install_spec().is_some()).unwrap_or(false) || e.core.is_some() {
        let missing_program = find(app, &e.program).is_none();
        let missing_core = e.core.as_ref().map(|c| !crate::emuinstall::core_path(app, c).is_file()).unwrap_or(false);
        if missing_program || missing_core {
            let _ = crate::emuinstall::start(app, &e.program, e.core.into_iter().collect());
        }
    }
    Ok(())
}

/// How a program was found.
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

pub fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(name)).find(|p| is_executable(p))
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

/// Letters and digits only, lower case: "PCSX2-v2.2.0.AppImage" → "pcsx2v220appimage".
fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_lowercase()).collect()
}

/// Where AppImages are usually kept (EmuDeck and most AppImage managers use ~/Applications).
fn appimage_dirs() -> Vec<PathBuf> {
    let h = home();
    vec![h.join("Applications"), h.join("AppImages"), h.join(".local/bin"), h.join("Emulation/tools"), h.join("bin")]
}

/// The user's own AppImage of a program, if there is one in the usual folders: its file name
/// starts with the program's name or one of its other names (the newest file when several).
pub fn user_appimage_in(dirs: &[PathBuf], id: &str, names: &[String]) -> Option<PathBuf> {
    let mut want: Vec<String> =
        std::iter::once(id.to_string()).chain(names.iter().cloned()).map(|n| squash(&n)).filter(|n| n.len() >= 3).collect();
    // Other names the AppImages go by.
    match id {
        "ryubing" => want.push("ryujinx".into()),
        "dolphin" => want.push("dolphinemu".into()),
        "citron" => want.push("citron".into()),
        _ => {}
    }
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = vec![];
    for d in dirs {
        for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.to_lowercase().ends_with(".appimage") {
                continue;
            }
            let s = squash(&name);
            if want.iter().any(|w| s.starts_with(w.as_str())) && is_executable(&e.path()) {
                let t = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
                found.push((t, e.path()));
            }
        }
    }
    found.into_iter().max_by_key(|(t, _)| *t).map(|(_, p)| p)
}

fn user_appimage(p: &Program) -> Option<PathBuf> {
    let mut names = vec![p.name.clone()];
    names.extend(p.binaries.iter().cloned());
    // "Citron Neo", "Ryubing (Ryujinx)": the first word too.
    if let Some(first) = p.name.split([' ', '(']).next() {
        names.push(first.to_string());
    }
    user_appimage_in(&appimage_dirs(), &p.id, &names)
}

fn user_path_key(id: &str) -> String {
    format!("emu_path.{id}")
}

/// Where a program is, if it is available.
pub fn find(app: &Shared, id: &str) -> Option<Found> {
    let p = program(id)?;
    if let Some(v) = crate::emuinstall::installed(app, id) {
        if let Some(exe) = v["exe"].as_str() {
            return Some(Found::Program(PathBuf::from(exe)));
        }
        if let Some(f) = v["flatpak"].as_str() {
            if flatpak_installed(f) {
                return Some(Found::Flatpak(f.to_string()));
            }
        }
    }
    if let Some(path) = app.db.setting(&user_path_key(id)).filter(|s| !s.is_empty()) {
        let path = PathBuf::from(path);
        if path.extension().map(|x| x == "app").unwrap_or(false) {
            let macos = path.join("Contents/MacOS");
            return std::fs::read_dir(&macos).ok()?.flatten().map(|f| f.path()).find(|f| is_executable(f)).map(Found::Program);
        }
        return is_executable(&path).then_some(Found::Program(path));
    }
    for b in &p.binaries {
        if let Some(found) = which(b) {
            return Some(Found::Program(found));
        }
    }
    if cfg!(target_os = "linux") {
        if let Some(found) = user_appimage(&p) {
            return Some(Found::Program(found));
        }
    }
    if cfg!(target_os = "linux") {
        if let Some(f) = p.install_spec().filter(|s| s["type"] == "flatpak").and_then(|s| s["id"].as_str().map(String::from)) {
            if flatpak_installed(&f) && which("flatpak").is_some() {
                return Some(Found::Flatpak(f));
            }
        }
    }
    if cfg!(target_os = "macos") {
        for dir in [PathBuf::from("/Applications"), home().join("Applications")] {
            for a in &p.mac_apps {
                let f = dir.join(a);
                if is_executable(&f) {
                    return Some(Found::Program(f));
                }
            }
        }
    }
    None
}

/// Where an emulator keeps its configuration, saves and system files for a profile. On Linux it is
/// Borne's own per-profile folder (the XDG variables point there, see `xdg_env`); on macOS,
/// where those variables are not read, the emulator's usual folder.
pub fn data_dir(app: &Shared, profile: &str, program: &str) -> PathBuf {
    let base = app.paths.profiles().join(profile).join(program);
    let (xdg_data, xdg_config) = (base.join("data"), base.join("config"));
    let mac = home().join("Library/Application Support");
    let mac_os = cfg!(target_os = "macos");
    match program {
        "eden" => {
            if mac_os {
                mac.join("eden")
            } else {
                xdg_data.join("eden")
            }
        }
        "citron" => {
            if mac_os {
                mac.join("citron")
            } else {
                xdg_data.join("citron")
            }
        }
        "ryubing" => {
            if mac_os {
                mac.join("Ryujinx")
            } else {
                xdg_config.join("Ryujinx")
            }
        }
        "rpcs3" => {
            if mac_os {
                mac.join("rpcs3")
            } else {
                xdg_config.join("rpcs3")
            }
        }
        "pcsx2" => {
            if mac_os {
                mac
            } else {
                xdg_config
            }
        }
        "shadps4" => {
            if mac_os {
                mac.join("shadPS4")
            } else {
                xdg_data.join("shadPS4")
            }
        }
        "xenia" => xdg_data.join("Xenia"),
        // Cemu: its user data (keys.txt, mlc01); its settings are in the config folder next to it.
        "cemu" => {
            if mac_os {
                mac.join("Cemu")
            } else {
                xdg_data.join("Cemu")
            }
        }
        // Its PS Vita file system (ux0, vs0…).
        "vita3k" => {
            if mac_os {
                mac.join("Vita3K/Vita3K/fs")
            } else {
                xdg_data.join("Vita3K/Vita3K")
            }
        }
        "azahar" => {
            if mac_os {
                mac.join("Azahar")
            } else {
                xdg_data.join("azahar-emu")
            }
        }
        _ => base,
    }
}

/// Linux: the emulator's data and configuration in Borne's per-profile folder.
pub fn xdg_env(app: &Shared, profile: &str, program: &str) -> Vec<(String, String)> {
    if cfg!(target_os = "macos") || program == "retroarch" || program == "dolphin" {
        return vec![];
    }
    let base = app.paths.profiles().join(profile).join(program);
    vec![
        ("XDG_DATA_HOME".into(), base.join("data").to_string_lossy().into_owned()),
        ("XDG_CONFIG_HOME".into(), base.join("config").to_string_lossy().into_owned()),
        ("XDG_CACHE_HOME".into(), base.join("cache").to_string_lossy().into_owned()),
    ]
}

/// Sets keys in an INI file, keeping everything else (created when missing).
pub fn ini_set(path: &Path, values: &[(&str, &str, &str)]) -> Result<(), String> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut lines: Vec<String> = text.lines().map(String::from).collect();
    for (section, key, value) in values {
        let header = format!("[{section}]");
        let start = lines.iter().position(|l| l.trim() == header);
        let start = match start {
            Some(i) => i,
            None => {
                if !lines.is_empty() && !lines.last().map(|l| l.is_empty()).unwrap_or(true) {
                    lines.push(String::new());
                }
                lines.push(header.clone());
                lines.len() - 1
            }
        };
        let end = lines[start + 1..].iter().position(|l| l.trim_start().starts_with('[')).map(|i| start + 1 + i).unwrap_or(lines.len());
        let line = format!("{key} = {value}");
        match lines[start + 1..end].iter().position(|l| l.split('=').next().map(|k| k.trim() == *key).unwrap_or(false)) {
            Some(i) => lines[start + 1 + i] = line,
            None => lines.insert(end, line),
        }
    }
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    std::fs::write(path, lines.join("\n") + "\n").map_err(|e| e.to_string())
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

/// Settings view: per console of the library, the choices and the one chosen; per program, what
/// is installed.
pub fn list(app: &Shared) -> Value {
    let hw = crate::consoles::hardware(app);
    let systems: Vec<(String, String)> = app
        .db
        .platforms()
        .into_iter()
        .filter(|p| !crate::consoles::is_hidden(app, &p.slug))
        .map(|p| (p.slug.clone(), p.name.clone()))
        .collect();
    let consoles: Vec<Value> = systems
        .iter()
        .map(|(slug, name)| {
            let choices: Vec<Value> = engines(slug)
                .iter()
                .map(|e| {
                    let core_ok = e.core.as_ref().map(|c| crate::emuinstall::core_path(app, c).is_file()).unwrap_or(true);
                    json!({ "id": e.id, "name": e.name, "program": e.program, "ready": core_ok && find(app, &e.program).is_some() })
                })
                .collect();
            let available = !choices.is_empty() && engines(slug).iter().any(|e| program(&e.program).map(|p| p.install_spec().is_some() || find(app, &p.id).is_some()).unwrap_or(false));
            json!({ "slug": slug, "name": name, "choices": choices, "chosen": chosen(app, slug).map(|e| e.id), "known": manifest().consoles.contains_key(slug), "available": available,
                    "warnings": crate::consoles::warnings(slug, &hw) })
        })
        .collect();
    let programs: Vec<Value> = programs()
        .iter()
        .map(|p| {
            let found = find(app, &p.id);
            let inst = crate::emuinstall::installed(app, &p.id);
            json!({
                "id": p.id,
                "name": p.name,
                "found": found.as_ref().map(|f| f.describe()),
                "managed": inst.is_some(),
                "version": inst.as_ref().and_then(|v| v["version"].as_str().map(String::from)),
                "installable": p.install_spec().is_some(),
                "user_provided": p.user_provided,
                "user_path": app.db.setting(&user_path_key(&p.id)).filter(|s| !s.is_empty()),
            })
        })
        .collect();
    json!({
        "consoles": consoles,
        "programs": programs,
        "task": crate::emuinstall::task(),
        "auto_update": app.db.setting("emu_auto_update").as_deref() != Some("off"),
        "session": session(),
    })
}

pub fn set_path(app: &Shared, id: &str, path: &str) -> Result<(), String> {
    let p = program(id).ok_or("unknown emulator")?;
    let path = path.trim();
    if path.is_empty() {
        app.db.set_setting(&user_path_key(&p.id), "");
        return Ok(());
    }
    let f = Path::new(path);
    if !f.is_absolute() || !(is_executable(f) || (f.extension().map(|x| x == "app").unwrap_or(false) && f.is_dir())) {
        return Err("this path is not a program".into());
    }
    app.db.set_setting(&user_path_key(&p.id), path);
    Ok(())
}

// ---------- sessions ----------

struct Session {
    rom_id: i64,
    name: String,
    emulator: String,
    /// Its program's id (eden, cemu…).
    program: String,
    /// The game's group (its versions together) and console, for the emulator stand-in.
    group_key: String,
    system: String,
    /// What to send to RomM afterwards: (profile, console, program, game file, emulator name).
    sync: Option<(String, String, String, PathBuf, String)>,
    started: Instant,
    child: Child,
    stopping: bool,
    /// The line of the emulator's output that showed the game did not start, if any.
    failure: Option<String>,
    /// Paused while the player is asked whether to quit (the process group stopped).
    paused: bool,
    /// The emulator's .app on macOS, brought back to the front after that question.
    bundle: Option<PathBuf>,
    /// The Flatpak the emulator runs in: its sandbox lives apart from the process group.
    flatpak: Option<String>,
    /// Started by `open` (macOS): the emulator's processes are found by their bundle.
    via_open: bool,
}

/// Sends a signal to the game: its process group, and with `open`, the emulator's own processes.
fn signal_session(s: &Session, sig: i32) {
    unsafe {
        libc::kill(-(s.child.id() as i32), sig);
    }
    if s.via_open {
        if let Some(b) = &s.bundle {
            let exe_dir = b.join("Contents/MacOS");
            let out = Command::new("pgrep").arg("-f").arg(exe_dir.as_os_str()).output();
            for pid in out.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default().split_whitespace() {
                if let Ok(pid) = pid.parse::<i32>() {
                    unsafe {
                        libc::kill(pid, sig);
                    }
                }
            }
        }
    }
}

/// Ends every sandbox of this Flatpak application.
fn flatpak_kill(id: &str) {
    let _ = Command::new("flatpak").args(["kill", id]).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

/// Whether a sandbox of this Flatpak application runs.
fn flatpak_running(id: &str) -> bool {
    Command::new("flatpak")
        .args(["ps", "--columns=application"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().any(|l| l.trim() == id))
        .unwrap_or(false)
}

static SESSION: Mutex<Option<Session>> = Mutex::new(None);

pub fn playing() -> bool {
    SESSION.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

/// Whether the game is paused by the quit question.
pub fn paused() -> bool {
    SESSION.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|s| s.paused).unwrap_or(false)
}

/// The game being played, if any.
pub fn playing_rom() -> Option<i64> {
    SESSION.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|s| s.rom_id)
}

pub fn session() -> Value {
    match SESSION.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        Some(s) => {
            json!({ "running": true, "rom_id": s.rom_id, "name": s.name, "emulator": s.emulator, "seconds": s.started.elapsed().as_secs(), "paused": s.paused })
        }
        None => json!({ "running": false }),
    }
}

/// The game's file on this device: downloaded, else linked through the virtual mount.
fn game_file(app: &Shared, g: &GameRow) -> Result<PathBuf, String> {
    if g.local_state == "local" {
        if let Some(m) = &g.local_main {
            let p = PathBuf::from(m);
            // Downloaded compressed by an earlier Borne: downloaded again, now extracted.
            // Once only: an archive that is still there after the download again (several files,
            // extraction not needed) is given as it is rather than downloaded in a loop.
            let again = format!("redownloaded.{}", g.rom_id);
            if p.is_file()
                && crate::downloads::extractable(&p)
                && !crate::downloads::keeps_archive(&g.platform_slug, &p)
                && app.db.setting(&again).is_none()
            {
                app.db.set_setting(&again, "1");
                crate::downloads::delete_local(app, g.rom_id)?;
                return Err(crate::stream::COMPRESSED.into());
            }
            if p.is_file() {
                return Ok(p);
            }
        }
        return Err("the downloaded copy is missing: download the game again".into());
    }
    if g.linked {
        let path = crate::stream::link(app, g.rom_id)?;
        readable(&path)?;
        return Ok(path);
    }
    Err("download the game or play it from the network first".into())
}

/// A link to `rom` with the extension the program takes, when it does not take the file's own
/// (see `rename_ext`); None when the file can be given as it is.
fn renamed_rom(app: &Shared, p: &Program, rom: &Path) -> Result<Option<PathBuf>, String> {
    let ext = rom.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let Some(to) = p.rename_ext.get(&ext) else { return Ok(None) };
    let dir = app.paths.mount().with_file_name("links").join(&p.id);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let link = dir.join(rom.with_extension(to).file_name().unwrap_or_default());
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(rom, &link).map_err(|e| format!("could not prepare the game file: {e}"))?;
    Ok(Some(link))
}

/// Checks that a game played from the network can be read before the emulator starts: its first
/// bytes come through the mount from RomM, within a time limit.
fn readable(path: &Path) -> Result<(), String> {
    let p = path.to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let r = (|| {
            let mut f = std::fs::File::open(&p)?;
            let mut buf = [0u8; 16];
            std::io::Read::read(&mut f, &mut buf)
        })();
        let _ = tx.send(r);
    });
    match rx.recv_timeout(Duration::from_secs(30)) {
        Ok(Ok(n)) if n > 0 => Ok(()),
        Ok(Ok(_)) => Err("the game's file on RomM is empty".into()),
        Ok(Err(e)) => Err(format!("the game's file cannot be read from RomM ({e})")),
        Err(_) => Err("RomM does not answer: the game cannot be played from the network now".into()),
    }
}

/// The command that starts `rom` with the chosen engine.
#[allow(clippy::too_many_arguments)]
fn command(
    app: &Shared,
    p: &Program,
    e: &Engine,
    found: &Found,
    system: &str,
    rom: &Path,
    lang: &str,
    rom_id: i64,
) -> Result<Command, String> {
    let core = match &e.core {
        Some(c) => {
            let path = crate::emuinstall::core_path(app, c);
            if !path.is_file() {
                return Err(format!("the {} core is missing", e.name));
            }
            Some(path)
        }
        None => None,
    };
    let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
    let group = app.db.game(rom_id).map(|g| g.group_key).unwrap_or_default();
    let display = crate::gamesettings::resolve(app, system, &group);
    let options = crate::gamesettings::emu_options(app, &p.id, &group);
    // The console's language: the game's choice, else the interface's when the version has it.
    let language = {
        let chosen = app.active_profile().and_then(|pr| app.db.game_prefs(&pr.id).get(&group).and_then(|x| x.1.clone()));
        let ui = app.db.setting("ui.lang").filter(|l| !l.is_empty()).unwrap_or_else(|| "en".into());
        app.db.game(rom_id).map(|g| crate::library::play_language(&g, chosen.as_deref(), &ui)).unwrap_or(ui)
    };
    let config = if p.id == "retroarch" {
        let mut cheats = crate::cheats::retroarch_settings(app, rom_id, &e.name, rom);
        let crt = crate::emuinstall::crt_shader(app);
        cheats.extend(crate::gamesettings::retroarch(&display, crt.as_deref()));
        cheats.extend(crate::gamesettings::emu_retroarch(&options));
        cheats.extend(crate::gamesettings::retroarch_language(&language));
        let remaps = app.paths.profiles().join(&profile).join("remaps");
        cheats.extend(crate::controls::retroarch(app, &group, &remaps, e.core.as_deref().unwrap_or(""), &e.name, rom));
        Some(retroarch_config(app, &profile, system, cheats)?)
    } else {
        None
    };
    let userdir = app.paths.profiles().join(&profile).join(&p.id);
    std::fs::create_dir_all(&userdir).map_err(|e| e.to_string())?;
    crate::gamesettings::apply(&p.id, &data_dir(app, &profile, &p.id), &userdir, &display)?;
    crate::gamesettings::emu_apply(&p.id, &data_dir(app, &profile, &p.id), &userdir, &options)?;
    crate::gamesettings::language_apply(&p.id, &data_dir(app, &profile, &p.id), &userdir, &language)?;
    app.db.log("play", &format!("game {rom_id} played in {language}"));
    if system == "switch" {
        // The game's update and DLC, wherever they are: beside it, in its folders, or stored by
        // RomM as games of their own in its group. The base game is what starts; the emulator
        // reads the others from these folders without installing them.
        let dirs = switch_content_dirs(app, rom_id, rom);
        if !dirs.is_empty() {
            app.db.log("play", &format!("update and DLC read from {} folder(s)", dirs.len()));
        }
        crate::gamesettings::switch_content(&p.id, &data_dir(app, &profile, &p.id), &userdir, &dirs)?;
    }
    if p.id == "melonds" {
        if let Err(e) = crate::cheats::melonds_settings(app, rom_id, &data_dir(app, &profile, &p.id), rom) {
            app.db.log("cheats", &format!("melonDS: {e}"));
        }
    }
    // PCSX2: the chosen cheats from the .pnach given for the game.
    if p.id == "pcsx2" {
        if let Some(g) = app.db.game(rom_id) {
            if let Err(e) = crate::cheats::ps2_settings(app, rom_id, &data_dir(app, &profile, &p.id), rom, &g.group_key) {
                app.db.log("cheats", &format!("PCSX2: {e}"));
            }
        }
    }
    // Switch emulators: the chosen cheats in their mod folder.
    if matches!(p.id.as_str(), "eden" | "citron" | "ryubing") {
        if let Err(e) = crate::cheats::switch_settings(app, rom_id, &p.id, &data_dir(app, &profile, &p.id), rom) {
            app.db.log("cheats", &format!("{}: {e}", p.name));
        }
    }
    // Dolphin: the cheats chosen in Borne, from Dolphin's own code list.
    if p.id == "dolphin" {
        if let Err(e) = crate::cheats::dolphin_settings(app, rom_id, &userdir, rom) {
            app.db.log("cheats", &format!("Dolphin: {e}"));
        }
    }
    // Each game its own memory card, so its saves can follow it on RomM.
    if p.id == "dolphin" {
        let card = crate::savesync::dolphin_card(app, &profile, rom);
        let _ = std::fs::create_dir_all(card.parent().unwrap());
        ini_set(&userdir.join("Config/Dolphin.ini"), &[("Core", "SlotA", "1"), ("Core", "MemcardAPath", &card.to_string_lossy())])?;
    }
    if p.id == "pcsx2" {
        let name = format!("{}.ps2", rom.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
        let data = data_dir(app, &profile, &p.id);
        let _ = std::fs::create_dir_all(data.join("PCSX2/memcards"));
        ini_set(&data.join("PCSX2/inis/PCSX2.ini"), &[("MemoryCards", "Slot1_Enable", "true"), ("MemoryCards", "Slot1_Filename", &name)])?;
    }
    if p.id == "duckstation" {
        ini_set(
            &data_dir(app, &profile, &p.id).join("data/duckstation/settings.ini"),
            &[("MemoryCards", "Card1Type", "PerGameFileTitle")],
        )?;
    }
    let players = crate::controls::players(app, &group);
    // Which pad each player has, in the log (the diagnostic report shows it).
    let hidden = crate::pad::steam_hidden();
    app.db.log(
        "pads",
        &format!(
            "{}: {}{}",
            p.id,
            if players.is_empty() {
                "no pad".to_string()
            } else {
                players
                    .iter()
                    .enumerate()
                    .map(|(n, x)| format!("P{} {} #{} {}", n + 1, x.name, x.index, x.guid.as_deref().unwrap_or("?")))
                    .collect::<Vec<_>>()
                    .join(", ")
            },
            if hidden.is_empty() { String::new() } else { format!(" (Steam hides {} pad(s) from games)", hidden.len()) }
        ),
    );
    let sources = crate::controls::sources(app, &group);
    let src = |logical: &str| sources.iter().find(|(l, _)| *l == logical).and_then(|(_, p)| *p);
    // Cemu reads pads with SDL 3, whose GUIDs also carry the CRC of the pad's system name.
    let players: Vec<crate::gamesettings::PadRef> = if p.id == "cemu" {
        let st = app.pads.lock().unwrap_or_else(|e| e.into_inner()).clone();
        players
            .into_iter()
            .map(|mut x| {
                if let Some(g) = x.guid.clone() {
                    let i = (0..st.pads.len()).find(|i| st.pads[*i] == x.name && st.guids.get(*i) == Some(&g));
                    if let Some(os) = i.and_then(|i| st.os_names.get(i)) {
                        x.guid = Some(crate::gamesettings::sdl3_guid(&g, os));
                    }
                }
                x
            })
            .collect()
    } else {
        players
    };
    crate::gamesettings::controllers(&p.id, &data_dir(app, &profile, &p.id), &userdir, &players, &src)?;
    let _ = lang;
    let lang_dolphin = if system == "ngc" { dolphin_language(&language).unwrap_or("") } else { "" };
    let renamed = renamed_rom(app, p, rom)?;
    let rom = renamed.as_deref().unwrap_or(rom);
    let mut args: Vec<String> = vec![];
    // Vita3K installs a .vpk and starts it; once installed, the game starts by its title ID
    // (no second installation).
    // A game dumped as a folder (sce_sys/param.sfo, eboot.bin…) is given as that folder: Vita3K
    // installs a folder as it does a .vpk, not one of its files.
    let vita_dir = if p.id == "vita3k" { vita_content(rom) } else { None };
    let rom = vita_dir.as_deref().unwrap_or(rom);
    let vita = if p.id == "vita3k" { vita_installed(&data_dir(app, &profile, &p.id), rom) } else { None };
    for a in &p.args {
        // Cemu on macOS: no fullscreen at start (see gamesettings::cemu_settings's caller).
        if cfg!(target_os = "macos") && p.id == "cemu" && a == "-f" {
            continue;
        }
        if a == "{rom}" {
            if let Some(tid) = &vita {
                args.extend(["-r".to_string(), tid.clone()]);
                continue;
            }
        }
        let v = a
            .replace("{rom}", &rom.to_string_lossy())
            .replace("{core}", &core.as_ref().map(|c| c.to_string_lossy().into_owned()).unwrap_or_default())
            .replace("{config}", &config.as_ref().map(|c| c.to_string_lossy().into_owned()).unwrap_or_default())
            .replace("{userdir}", &userdir.to_string_lossy())
            .replace("{data}", &data_dir(app, &profile, &p.id).to_string_lossy())
            .replace("{lang_dolphin}", lang_dolphin)
            .replace(
                "{upscale3}",
                &display.get("upscale").and_then(|v| v.as_str()).and_then(|v| v.parse::<u32>().ok()).unwrap_or(1).min(3).to_string(),
            );
        // An option left without its value (no language chosen…) goes with its flag.
        if v.ends_with('=') || v.is_empty() {
            if args.last().map(|l| l.starts_with('-')).unwrap_or(false) {
                args.pop();
            }
            continue;
        }
        args.push(v);
    }
    // A game's own emulator options given as flags go before the game.
    let extra = crate::gamesettings::emu_args(&p.id, &options);
    if !extra.is_empty() {
        let at = args.len().saturating_sub(1);
        args.splice(at..at, extra);
    }
    let mut cmd = match found {
        Found::Program(exe) => {
            let mut c = Command::new(exe);
            c.args(&args);
            c
        }
        Found::Flatpak(id) => {
            // One of this emulator's sandboxes left from before (killing `flatpak run` does not
            // end its sandbox): ended, so that no old game plays on behind the new one.
            flatpak_kill(id);
            let mut c = Command::new("flatpak");
            c.arg("run");
            // The sandbox ends with the `flatpak run` Borne started and stops.
            c.arg("--die-with-parent");
            // The sandbox sees the game's folder and Borne's per-profile folders, nothing more.
            if let Some(dir) = rom.parent() {
                c.arg(format!("--filesystem={}:ro", dir.to_string_lossy()));
            }
            c.arg(format!("--filesystem={}", app.paths.profiles().to_string_lossy()));
            c.arg(id).args(&args);
            c
        }
    };
    // AppImages extracted by Borne find their own libraries this way.
    cmd.env("APPIMAGE_EXTRACT_AND_RUN", "1");
    // Linux: the pads as the kernel gives them (evdev), as Borne sees them, rather than SDL's own
    // drivers (HIDAPI) that name a Switch Pro or a DualSense pad differently: the pad Borne set up
    // is the one the emulator finds (same SDL GUID). Unless the user asked otherwise.
    if cfg!(target_os = "linux") && std::env::var_os("SDL_JOYSTICK_HIDAPI").is_none() {
        cmd.env("SDL_JOYSTICK_HIDAPI", "0");
    }
    // Under Steam, SDL shows Steam's virtual pad only when it can read Steam's note about it (a
    // file in /tmp), which a Flatpak's sandbox cannot: the emulator then saw no pad at all (the
    // real ones hidden by Steam). The virtual pad is shown whatever.
    if std::env::var_os("SteamVirtualGamepadInfo").is_some() || std::env::var_os("SDL_GAMECONTROLLER_IGNORE_DEVICES").is_some() {
        cmd.env("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD", "1");
        if let Found::Flatpak(_) = found {
            // The note itself, where the sandbox can read it (its /tmp is its own).
            if let Some(info) = std::env::var_os("SteamVirtualGamepadInfo") {
                let from = PathBuf::from(&info);
                let to = app.paths.profiles().join("steam-virtual-gamepads.txt");
                if std::fs::copy(&from, &to).is_ok() {
                    cmd.env("SteamVirtualGamepadInfo", &to);
                }
            }
        }
    }
    // Linux: the emulator as an X11 client (Xwayland on a Wayland desktop), where Borne catches
    // Escape before it (quitkey.rs). Under gamescope they already are.
    if cfg!(target_os = "linux") && std::env::var_os("DISPLAY").is_some() {
        cmd.env_remove("WAYLAND_DISPLAY");
        for var in ["QT_QPA_PLATFORM", "SDL_VIDEODRIVER", "GDK_BACKEND"] {
            if std::env::var(var).map(|v| v.to_lowercase().contains("wayland")).unwrap_or(false) {
                cmd.env_remove(var);
            }
        }
    }
    cmd.envs(xdg_env(app, &profile, &p.id));
    // BIOS, keys and firmware where this emulator reads them.
    let exe = match found {
        Found::Program(x) => Some(x.as_path()),
        Found::Flatpak(_) => None,
    };
    crate::systemfiles::prepare(app, system, &p.id, &data_dir(app, &profile, &p.id), exe, &xdg_env(app, &profile, &p.id))?;
    Ok(cmd)
}

/// RetroArch's whole configuration for Borne (given with --config, so the user's own is never
/// read): fullscreen, no menu, no messages, no hotkeys, the profile's saves and states, Borne's
/// cores and BIOS folders. Written before each game from Borne's settings.
fn retroarch_config(app: &Shared, profile: &str, system: &str, cheats: Vec<(String, String)>) -> Result<PathBuf, String> {
    let base = app.paths.profiles().join(profile);
    let saves = base.join("saves").join(system);
    let states = base.join("states").join(system);
    for d in [&saves, &states] {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let q = |p: &Path| p.to_string_lossy().replace('"', "");
    let mut lines: Vec<(String, String)> = vec![
        ("video_fullscreen".into(), "true".into()),
        ("video_windowed_fullscreen".into(), "true".into()),
        ("libretro_directory".into(), q(&crate::emuinstall::cores_dir(app))),
        ("system_directory".into(), q(&crate::systemfiles::bios_dir(app))),
        ("savefile_directory".into(), q(&saves)),
        ("savestate_directory".into(), q(&states)),
        ("sort_savefiles_enable".into(), "false".into()),
        ("sort_savestates_enable".into(), "false".into()),
        ("config_save_on_exit".into(), "false".into()),
        ("pause_nonactive".into(), "false".into()),
        // No RetroArch interface: no menu, no on-screen messages, no hotkeys but Escape pressed
        // twice on the keyboard; on the pad, Borne's own quit chord asks first (pad.rs).
        ("menu_enable_widgets".into(), "false".into()),
        ("video_font_enable".into(), "false".into()),
        ("notification_show_autoconfig".into(), "false".into()),
        ("notification_show_cheats_applied".into(), "false".into()),
        ("notification_show_config_override_load".into(), "false".into()),
        ("notification_show_remap_load".into(), "false".into()),
        ("notification_show_fast_forward".into(), "false".into()),
        ("notification_show_patch_applied".into(), "false".into()),
        ("notification_show_refresh_rate".into(), "false".into()),
        ("notification_show_set_initial_disk".into(), "false".into()),
        ("notification_show_save_state".into(), "false".into()),
        ("notification_show_screenshot".into(), "false".into()),
        ("menu_show_load_content_animation".into(), "false".into()),
        ("input_menu_toggle_gamepad_combo".into(), "0".into()),
        ("input_quit_gamepad_combo".into(), "0".into()),
        ("input_menu_toggle".into(), "nul".into()),
        ("input_exit_emulator".into(), "escape".into()),
        ("input_enable_hotkey".into(), "nul".into()),
        ("input_hotkey_block_delay".into(), "0".into()),
        ("quit_press_twice".into(), "true".into()),
        ("confirm_quit".into(), "false".into()),
        ("input_autodetect_enable".into(), "true".into()),
        ("auto_overrides_enable".into(), "false".into()),
        ("auto_remaps_enable".into(), "false".into()),
        ("game_specific_options".into(), "false".into()),
        ("network_cmd_enable".into(), "false".into()),
        ("check_firmware_before_loading".into(), "true".into()),
        // Errors in the output, so that a game that does not load closes RetroArch (fails).
        ("log_verbosity".into(), "true".into()),
        ("frontend_log_level".into(), "3".into()),
        ("libretro_log_level".into(), "3".into()),
    ];
    // Linux: the pads' profiles where RetroArch looks for them (an extracted RetroArch has none
    // of its own): one per connected pad, from SDL_GameControllerDB, and those it ships.
    if cfg!(target_os = "linux") {
        if let Ok(dir) = retroarch_autoconfig(app, &base) {
            lines.push(("joypad_autoconfig_dir".into(), q(&dir)));
            lines.push(("input_joypad_driver".into(), "udev".into()));
        }
    }
    // Per-console and per-game settings chosen in Borne come on top (see game_settings).
    for (k, v) in crate::emulators::extra_retroarch(app, system).into_iter().chain(cheats) {
        lines.retain(|(key, _)| key != &k);
        lines.push((k, v));
    }
    let text: String = lines.iter().map(|(k, v)| format!("{k} = \"{v}\"\n")).collect();
    let path = base.join("retroarch.cfg");
    std::fs::write(&path, text).map_err(|e| e.to_string())?;
    Ok(path)
}

/// RetroArch's profile of a pad (udev driver) from its SDL mapping: each RetroPad control on the
/// pad's raw button, axis or hat. None when SDL_GameControllerDB does not know the pad.
pub fn retroarch_pad_profile(name: &str, guid: &str, vendor: u16, product: u16) -> Option<String> {
    use crate::sdldb::{bind, Bind};
    bind(guid, "a")?;
    let mut out = format!(
        "input_driver = \"udev\"\ninput_device = \"{}\"\ninput_vendor_id = \"{vendor}\"\ninput_product_id = \"{product}\"\n",
        name.replace('"', "")
    );
    let hat = |m: u32| match m {
        1 => "up",
        2 => "right",
        4 => "down",
        _ => "left",
    };
    // (RetroArch's control, SDL's) — RetroArch's B is the bottom face button, as SDL's A.
    let pairs = [
        ("b", "a"),
        ("a", "b"),
        ("y", "x"),
        ("x", "y"),
        ("select", "back"),
        ("start", "start"),
        ("up", "dpup"),
        ("down", "dpdown"),
        ("left", "dpleft"),
        ("right", "dpright"),
        ("l", "leftshoulder"),
        ("r", "rightshoulder"),
        ("l2", "lefttrigger"),
        ("r2", "righttrigger"),
        ("l3", "leftstick"),
        ("r3", "rightstick"),
    ];
    for (ra, sdl) in pairs {
        match bind(guid, sdl) {
            Some(Bind::Button(n)) => out.push_str(&format!("input_{ra}_btn = \"{n}\"\n")),
            Some(Bind::Hat { index, mask }) => out.push_str(&format!("input_{ra}_btn = \"h{index}{}\"\n", hat(mask))),
            Some(Bind::Axis { index, positive }) => {
                out.push_str(&format!("input_{ra}_axis = \"{}{index}\"\n", if positive { '+' } else { '-' }))
            }
            None => {}
        }
    }
    for (ra, sdl) in [("l_x", "leftx"), ("l_y", "lefty"), ("r_x", "rightx"), ("r_y", "righty")] {
        if let Some(Bind::Axis { index, .. }) = bind(guid, sdl) {
            out.push_str(&format!("input_{ra}_plus_axis = \"+{index}\"\ninput_{ra}_minus_axis = \"-{index}\"\n"));
        }
    }
    Some(out)
}

/// The folder of RetroArch's pad profiles: those RetroArch ships (copied once), then one per
/// connected pad.
fn retroarch_autoconfig(app: &Shared, base: &Path) -> Result<PathBuf, String> {
    let dir = base.join("autoconfig");
    let udev = dir.join("udev");
    std::fs::create_dir_all(&udev).map_err(|e| e.to_string())?;
    if !dir.join(".shipped").exists() {
        let mut stack = vec![(crate::emuinstall::program_dir(app, "retroarch"), 0)];
        while let Some((d, depth)) = stack.pop() {
            for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = e.path();
                if !p.is_dir() {
                    continue;
                }
                if e.file_name() == "autoconfig" && p.join("udev").is_dir() {
                    for f in std::fs::read_dir(p.join("udev")).into_iter().flatten().flatten() {
                        let _ = std::fs::copy(f.path(), udev.join(f.file_name()));
                    }
                } else if depth < 6 {
                    stack.push((p, depth + 1));
                }
            }
        }
        let _ = std::fs::write(dir.join(".shipped"), "");
    }
    let s = app.pads.lock().unwrap_or_else(|e| e.into_inner()).clone();
    for (i, name) in s.pads.iter().enumerate() {
        let (Some(guid), Some((v, p))) = (s.guids.get(i), s.ids.get(i)) else { continue };
        if let Some(text) = retroarch_pad_profile(name, guid, *v, *p) {
            let file: String = name.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
            std::fs::write(udev.join(format!("borne-{file}.cfg")), text).map_err(|e| e.to_string())?;
        }
    }
    Ok(dir)
}

/// Settings for RetroArch set in Borne (none yet beyond the defaults above).
pub fn extra_retroarch(_app: &Shared, _system: &str) -> Vec<(String, String)> {
    vec![]
}

fn emulator_log(app: &Shared) -> PathBuf {
    app.paths.reports().join("emulator.log")
}

/// The last lines that say something: the error lines when there are some (in any language
/// RetroArch writes, they are tagged ERROR), without RetroArch's tags and banners.
fn log_tail(p: &Path) -> String {
    let t = std::fs::read_to_string(p).unwrap_or_default();
    let clean = |l: &str| {
        let mut l = l.trim();
        while let Some(rest) = l.strip_prefix('[').and_then(|r| r.split_once(']')).map(|(_, r)| r.trim_start()) {
            l = rest;
        }
        l.to_string()
    };
    let lines: Vec<&str> = t.lines().filter(|l| l.chars().any(|c| c.is_alphanumeric())).collect();
    let errors: Vec<&str> =
        lines.iter().copied().filter(|l| l.contains("ERROR") || l.contains("<Critical>") || l.contains("<Error>")).collect();
    let pick = if errors.is_empty() { &lines } else { &errors };
    let mut out: Vec<String> = pick[pick.len().saturating_sub(2)..].iter().map(|l| clean(l)).filter(|l| !l.is_empty()).collect();
    out.dedup();
    out.join(" · ").chars().take(300).collect()
}

/// The folder of a PS Vita game dumped as files (the one holding sce_sys/param.sfo), when the
/// file Borne picked is one of them: looked for above the file, then below its folder. None for
/// a .vpk or .zip, given as they are.
fn vita_content(rom: &Path) -> Option<PathBuf> {
    let ext = rom.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if rom.is_file() && ext == "vpk" {
        return None;
    }
    // A .zip with the game at its root goes as it is; another one (NoNpDrm's app/<TITLE ID>/…, a
    // folder inside) is extracted once next to it, and its game folder given.
    if rom.is_file() && ext == "zip" {
        let at_root =
            std::fs::File::open(rom).ok().and_then(|f| zip::ZipArchive::new(f).ok()).map(|mut z| z.by_name("sce_sys/param.sfo").is_ok());
        if at_root != Some(false) {
            return None;
        }
        let out = rom.with_extension("");
        if !out.is_dir() {
            let tmp = rom.with_extension("extracting");
            let _ = std::fs::remove_dir_all(&tmp);
            let ok = std::fs::File::open(rom)
                .ok()
                .and_then(|f| zip::ZipArchive::new(f).ok())
                .map(|mut z| z.extract(&tmp).is_ok())
                .unwrap_or(false);
            if !ok || std::fs::rename(&tmp, &out).is_err() {
                let _ = std::fs::remove_dir_all(&tmp);
                return None;
            }
        }
        return if out.join("sce_sys/param.sfo").is_file() { Some(out) } else { vita_content(&out) };
    }
    let has = |d: &Path| d.join("sce_sys/param.sfo").is_file();
    if rom.is_dir() && has(rom) {
        return None;
    }
    let start = if rom.is_dir() { rom } else { rom.parent()? };
    if let Some(d) = start.ancestors().take(4).find(|d| has(d)) {
        return Some(d.to_path_buf());
    }
    let mut stack = vec![(start.to_path_buf(), 0)];
    while let Some((d, depth)) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                if has(&p) {
                    return Some(p);
                }
                if depth < 3 {
                    stack.push((p, depth + 1));
                }
            }
        }
    }
    None
}

/// A zip holding a PS Vita .pkg (as the store sells games): the .pkg entry, the title ID in its
/// header (content ID "EP1024-PCSB01061_00-…"), and a license (zRIF) found beside it in the zip.
fn vita_pkg_of(zip_path: &Path) -> Option<(String, String, Option<String>)> {
    if !zip_path.extension().map(|e| e.eq_ignore_ascii_case("zip")).unwrap_or(false) {
        return None;
    }
    let f = std::fs::File::open(zip_path).ok()?;
    let mut z = zip::ZipArchive::new(f).ok()?;
    let names: Vec<String> = z.file_names().filter_map(|n| n.ok().map(|n| n.into_owned())).collect();
    if names.iter().any(|n| n.ends_with("sce_sys/param.sfo")) {
        return None; // a dumped game: installed by Vita3K as it is
    }
    let pkg = names.iter().find(|n| n.to_lowercase().ends_with(".pkg"))?.clone();
    let mut head = [0u8; 0x60];
    std::io::Read::read_exact(&mut z.by_name(&pkg).ok()?, &mut head).ok()?;
    if &head[..4] != b"\x7fPKG" {
        return None;
    }
    let content = String::from_utf8_lossy(&head[0x30..0x54]).to_string();
    let tid = content.get(7..16)?.to_string();
    if !(tid.len() == 9 && tid.chars().all(|c| c.is_ascii_alphanumeric())) {
        return None;
    }
    // A zRIF: base64 starting "KO5i", in a small text file of the zip (or the .zrif one).
    let mut zrif = None;
    for n in names.iter().filter(|n| {
        let l = n.to_lowercase();
        [".zrif", ".txt", ".tsv", ".json", ".nfo"].iter().any(|e| l.ends_with(e))
    }) {
        let Ok(mut e) = z.by_name(n) else { continue };
        if e.size() > 1 << 20 {
            continue;
        }
        let mut text = String::new();
        if std::io::Read::read_to_string(&mut e, &mut text).is_err() {
            continue;
        }
        zrif = text
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '='))
            .find(|w| w.starts_with("KO5i") && w.len() >= 40)
            .map(String::from);
        if zrif.is_some() {
            break;
        }
    }
    Some((pkg, tid, zrif))
}

/// A zip holding a dumped PS Vita game (sce_sys/param.sfo somewhere in it).
fn vita_zip_to_extract(rom: &Path) -> bool {
    if !rom.is_file() || !rom.extension().map(|e| e.eq_ignore_ascii_case("zip")).unwrap_or(false) {
        return false;
    }
    let Ok(f) = std::fs::File::open(rom) else { return false };
    let Ok(z) = zip::ZipArchive::new(f) else { return false };
    let has = z.file_names().any(|n| n.ok().map(|n| n.ends_with("sce_sys/param.sfo")).unwrap_or(false));
    has
}

/// Extracts a dumped PS Vita game's zip next to it, then keeps the folder only: the game's
/// file becomes its param.sfo (the folder holding it is what Vita3K installs).
fn vita_extract(app: &Shared, rom_id: i64, zip_path: &Path) -> Result<(), String> {
    let out = zip_path.with_extension("");
    let tmp = zip_path.with_extension("extracting");
    let _ = std::fs::remove_dir_all(&tmp);
    let flag = std::sync::atomic::AtomicBool::new(false);
    let started = Instant::now();
    if let Err(e) = crate::downloads::extract_zip(zip_path, &tmp, &flag) {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(format!("the PS Vita game could not be extracted: {e}"));
    }
    let _ = std::fs::remove_dir_all(&out);
    std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
    let game = vita_content(&out.join("x")).or_else(|| out.join("sce_sys/param.sfo").is_file().then(|| out.clone()));
    let Some(game) = game else {
        return Err("no PS Vita game (sce_sys/param.sfo) in this zip".into());
    };
    let _ = std::fs::remove_file(zip_path);
    if let Some(g) = app.db.game(rom_id) {
        let dir = g.local_dir.clone().unwrap_or_else(|| out.to_string_lossy().into_owned());
        let size = crate::downloads::dir_size(Path::new(&dir)) as i64;
        app.db.set_local(rom_id, &dir, &game.join("sce_sys/param.sfo").to_string_lossy(), size);
    }
    app.db.log("play", &format!("{}: extracted in {:.0} s", zip_path.display(), started.elapsed().as_secs_f64()));
    Ok(())
}

/// The installed folder of a PS Vita .pkg game (`ux0/app/<ID>`), installed first with its zRIF
/// (`--pkg … --zrif …`). None for another kind of file.
fn vita_pkg_installed(app: &Shared, found: &Found, rom: &Path) -> Result<Option<PathBuf>, String> {
    let Some((entry, tid, zrif)) = vita_pkg_of(rom) else { return Ok(None) };
    let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
    let installed = data_dir(app, &profile, "vita3k").join("ux0/app").join(&tid);
    if installed.join("sce_sys/param.sfo").is_file() {
        return Ok(Some(installed));
    }
    let Some(zrif) = zrif else {
        return Err("this PS Vita game is a .pkg without its license (zRIF): Vita3K cannot install it. Put on RomM a zip of the dumped game (NoNpDrm) or a .vpk, or add its zRIF in a text file inside the zip".into());
    };
    let Found::Program(exe) = found else { return Ok(None) };
    // The .pkg out of the zip, beside it, for the installation only.
    let pkg = rom.with_extension("pkg");
    let r = (|| {
        let f = std::fs::File::open(rom).map_err(|e| e.to_string())?;
        let mut z = zip::ZipArchive::new(f).map_err(|e| e.to_string())?;
        let mut src = z.by_name(&entry).map_err(|e| e.to_string())?;
        let mut out = std::fs::File::create(&pkg).map_err(|e| e.to_string())?;
        std::io::copy(&mut src, &mut out).map_err(|e| format!("the .pkg could not be taken out of the zip: {e}"))?;
        app.db.log("play", &format!("Vita3K: installing {tid} from its .pkg"));
        let out = Command::new(exe)
            .arg("--pkg")
            .arg(&pkg)
            .args(["--zrif", &zrif, "--frontend", "sdl"])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("Vita3K could not start: {e}"))?;
        let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
        crate::logfile::write("play", &format!("Vita3K --pkg: {}", text.lines().rev().take(15).collect::<Vec<_>>().join(" | ")));
        Ok::<(), String>(())
    })();
    let _ = std::fs::remove_file(&pkg);
    r?;
    if installed.join("sce_sys/param.sfo").is_file() {
        Ok(Some(installed))
    } else {
        Err("Vita3K could not install this .pkg with its license (zRIF): its log is in the diagnostic report".into())
    }
}

/// A PS Vita game's title ID (PCSE00001…), from the param.sfo of its .vpk (a zip), when Vita3K
/// has it installed already (`ux0/app/<ID>` in its file system).
fn vita_installed(data: &Path, vpk: &Path) -> Option<String> {
    let sfo = if vpk.is_dir() {
        std::fs::read(vpk.join("sce_sys/param.sfo")).ok()?
    } else {
        let f = std::fs::File::open(vpk).ok()?;
        let mut z = zip::ZipArchive::new(f).ok()?;
        let mut sfo = Vec::new();
        std::io::Read::read_to_end(&mut z.by_name("sce_sys/param.sfo").ok()?, &mut sfo).ok()?;
        sfo
    };
    let tid = crate::savesync::sfo_value(&sfo, "TITLE_ID")?;
    let ok = tid.len() == 9 && tid.chars().all(|c| c.is_ascii_alphanumeric());
    (ok && data.join("ux0/app").join(&tid).is_dir()).then_some(tid)
}

/// The title ID of a CIA, read from its TMD (CIA header, then certificate chain and ticket,
/// each aligned to 64 bytes; the TMD's signature block, then the ID at 0x4C past it).
fn cia_title_id(path: &Path) -> Option<u64> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).ok()?;
    let mut h = [0u8; 0x20];
    f.read_exact(&mut h).ok()?;
    let le = |o: usize| u32::from_le_bytes(h[o..o + 4].try_into().unwrap()) as u64;
    let align = |n: u64| n.div_ceil(64) * 64;
    let tmd = align(le(0)) + align(le(8)) + align(le(0x0c));
    f.seek(SeekFrom::Start(tmd)).ok()?;
    let mut t = [0u8; 4];
    f.read_exact(&mut t).ok()?;
    let sig = match u32::from_be_bytes(t) {
        0x10000 | 0x10003 => 0x200 + 0x3c,
        0x10001 | 0x10004 => 0x100 + 0x3c,
        0x10002 | 0x10005 => 0x3c + 0x40,
        _ => return None,
    };
    f.seek(SeekFrom::Start(tmd + 4 + sig + 0x4c)).ok()?;
    let mut id = [0u8; 8];
    f.read_exact(&mut id).ok()?;
    Some(u64::from_be_bytes(id))
}

/// The installed program of a CIA in Azahar's SD card, installed first if it is not there yet
/// (`azahar -i`, which prints its result and quits). Its largest content is the game.
fn cia_installed(app: &Shared, profile: &str, found: &Found, cia: &Path) -> Result<PathBuf, String> {
    let tid = cia_title_id(cia).ok_or("the .cia file is not readable")?;
    let content = data_dir(app, profile, "azahar")
        .join("sdmc/Nintendo 3DS/00000000000000000000000000000000/00000000000000000000000000000000/title")
        .join(format!("{:08x}", tid >> 32))
        .join(format!("{:08x}", tid & 0xffff_ffff))
        .join("content");
    let largest = || {
        std::fs::read_dir(&content)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x.eq_ignore_ascii_case("app")).unwrap_or(false))
            .max_by_key(|p| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0))
    };
    if let Some(app_file) = largest() {
        return Ok(app_file);
    }
    app.db.log("play", &format!("installing {} into Azahar", cia.display()));
    let mut cmd = match found {
        Found::Program(exe) => Command::new(exe),
        Found::Flatpak(id) => {
            let mut c = Command::new("flatpak");
            c.arg("run");
            if let Some(dir) = cia.parent() {
                c.arg(format!("--filesystem={}:ro", dir.to_string_lossy()));
            }
            c.arg(format!("--filesystem={}", app.paths.profiles().to_string_lossy())).arg(id);
            c
        }
    };
    cmd.arg("-i").arg(cia).env("APPIMAGE_EXTRACT_AND_RUN", "1").envs(xdg_env(app, profile, "azahar"));
    let out = cmd.stdin(Stdio::null()).output().map_err(|e| format!("Azahar could not start: {e}"))?;
    let said = String::from_utf8_lossy(&out.stdout);
    let said = said.lines().rev().find(|l| l.contains("CIA")).unwrap_or("").trim().to_string();
    largest().ok_or_else(|| {
        if said.contains("encrypted") {
            "the game file is encrypted: the emulator needs a decrypted copy".to_string()
        } else {
            format!("Azahar could not install the game: {}", if said.is_empty() { "no answer".into() } else { said })
        }
    })
}

/// The one game waiting to start once its file is downloaded or its emulator installed: the last
/// game the player pressed Play on. Any other Play, a game starting, or three hours, forget it, so
/// that a game never starts by itself long after it was asked, or instead of another.
static WAITING: Mutex<Option<(i64, Instant)>> = Mutex::new(None);
const WAIT_FOR: Duration = Duration::from_secs(3 * 3600);

fn wait_for(rom_id: i64) {
    *WAITING.lock().unwrap_or_else(|e| e.into_inner()) = Some((rom_id, Instant::now()));
}

/// The game waiting to start, when it is `rom_id` (or any, with None) and still wanted: taken.
pub fn take_waiting(rom_id: Option<i64>) -> Option<i64> {
    let mut w = WAITING.lock().unwrap_or_else(|e| e.into_inner());
    match *w {
        Some((id, at)) if rom_id.map(|r| r == id).unwrap_or(true) => {
            *w = None;
            (at.elapsed() < WAIT_FOR && !playing()).then_some(id)
        }
        _ => None,
    }
}

/// Forgets the game waiting to start (the player changed their mind: B on the launch screen).
pub fn forget_waiting() {
    *WAITING.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Starts the game that was waiting (its download or its emulator's installation over). Its
/// failure is told as a notice, never as the end of a session: a game may be running.
pub fn play_waiting(app: &Shared, rom_id: Option<i64>) {
    let Some(id) = take_waiting(rom_id) else { return };
    if let Err(e) = play(app, id) {
        app.emit(json!({ "type": "play_failed", "rom_id": id, "error": e }));
    }
}

/// A Switch package that holds an update or a DLC is not the game: the base game beside it is
/// started instead (an emulator given an update says "missing a program-type NCA"); with none
/// beside it, the player is told what is missing.
fn switch_base(rom: &Path) -> Result<PathBuf, String> {
    let is_pkg = |p: &Path| p.extension().map(|e| e.eq_ignore_ascii_case("nsp") || e.eq_ignore_ascii_case("nsz")).unwrap_or(false);
    if !is_pkg(rom) {
        return Ok(rom.to_path_buf());
    }
    let kind = crate::downloads::switch_kind(rom);
    if kind.is_none() || kind == Some("base") {
        return Ok(rom.to_path_buf());
    }
    if let Some(dir) = rom.parent() {
        if let Ok(rd) = std::fs::read_dir(dir) {
            for e in rd.flatten() {
                let p = e.path();
                if p != rom && is_pkg(&p) && crate::downloads::switch_kind(&p) == Some("base") {
                    return Ok(p);
                }
            }
        }
    }
    Err(if kind == Some("update") {
        "this file is an update of the game, not the game: add the base game to this game on RomM".to_string()
    } else {
        "this file is a DLC of the game, not the game: add the base game to this game on RomM".to_string()
    })
}

/// A note on a downloaded game's file, shown on its page: a 3DS dump said encrypted (Azahar
/// cannot play it) or decrypted.
pub fn file_note(g: &crate::db::GameRow) -> Option<Value> {
    if g.platform_slug != "3ds" || g.local_state != "local" {
        return None;
    }
    let rom = PathBuf::from(g.local_main.as_deref()?);
    let ext = rom.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if !["3ds", "cci", "cxi"].contains(&ext.as_str()) {
        return None;
    }
    Some(if n3ds_encrypted(&rom) {
        json!({ "ok": false, "text": "this copy is encrypted: Azahar cannot play it. Put a decrypted copy of the game on RomM" })
    } else {
        json!({ "ok": true, "text": "decrypted copy: Azahar can play it" })
    })
}

/// Whether a 3DS game file (.3ds/.cci: an NCSD image; .cxi: an NCCH) is encrypted: its first
/// partition's NCCH header lacks the NoCrypto flag (bit 2 of flags[7], at 0x18F).
fn n3ds_encrypted(rom: &Path) -> bool {
    use std::io::{Read, Seek, SeekFrom};
    let ext = rom.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if !["3ds", "cci", "cxi"].contains(&ext.as_str()) {
        return false;
    }
    let Ok(mut f) = std::fs::File::open(rom) else { return false };
    let mut head = [0u8; 0x200];
    if f.read_exact(&mut head).is_err() {
        return false;
    }
    let ncch = match &head[0x100..0x104] {
        b"NCSD" => u32::from_le_bytes(head[0x120..0x124].try_into().unwrap()) as u64 * 0x200,
        b"NCCH" => 0,
        _ => return false,
    };
    let mut h = [0u8; 0x200];
    if f.seek(SeekFrom::Start(ncch)).is_err() || f.read_exact(&mut h).is_err() || &h[0x100..0x104] != b"NCCH" {
        return false;
    }
    h[0x18F] & 0x04 == 0
}

/// A Wii U disc image (.wud, .wux) comes with its disc key beside it (a 16-byte .key file): Cemu
/// reads disc keys from its keys.txt only, where the key is added (once).
fn cemu_disc_keys(data: &Path, rom: &Path) {
    let disc = rom.extension().map(|e| e.eq_ignore_ascii_case("wud") || e.eq_ignore_ascii_case("wux")).unwrap_or(false);
    let Some(dir) = rom.parent().filter(|_| disc) else { return };
    let keys = data.join("keys.txt");
    let mut text = std::fs::read_to_string(&keys).unwrap_or_default();
    let before = text.len();
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = e.path();
        if !path.extension().map(|x| x.eq_ignore_ascii_case("key")).unwrap_or(false) {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else { continue };
        // Raw 16 bytes, or already written as 32 hex digits.
        let hex = if bytes.len() == 16 {
            bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
        } else {
            let t = String::from_utf8_lossy(&bytes).trim().to_lowercase();
            if t.len() == 32 && t.chars().all(|c| c.is_ascii_hexdigit()) {
                t
            } else {
                continue;
            }
        };
        if !text.to_lowercase().contains(&hex) {
            if !text.is_empty() && !text.ends_with('\n') {
                text.push('\n');
            }
            text.push_str(&format!("{hex} # {}\n", rom.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default()));
        }
    }
    if text.len() != before {
        let _ = std::fs::create_dir_all(data);
        let _ = std::fs::write(&keys, text);
    }
}

/// The folders holding a Switch game's update and DLC packages: its own folder and those below it
/// (RomM's update/ and dlc/), and the folders of the updates and DLC RomM keeps as games of their
/// own in the game's group (linked through the virtual mount, or downloaded).
fn switch_content_dirs(app: &Shared, rom_id: i64, rom: &Path) -> Vec<PathBuf> {
    switch_content_dirs_raw(app, rom_id, rom).iter().map(|d| switch_unpacked_dir(app, d)).collect()
}

/// Where the .nsp unpacked from the .nsz of a folder Borne cannot write (a game played from
/// RomM through the mount) are kept.
fn nsp_cache(app: &Shared, dir: &Path) -> PathBuf {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    dir.hash(&mut h);
    app.paths.root.join("cache").join("nsp").join(format!("{:016x}", h.finish()))
}

fn in_library(app: &Shared, p: &Path) -> bool {
    p.starts_with(app.paths.library())
}

fn top_nsz(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file() && p.extension().map(|e| e.eq_ignore_ascii_case("nsz")).unwrap_or(false))
        .collect()
}

/// A folder of packages as the emulator gets it: one Borne cannot write is given as its
/// unpacked copy once there is one.
fn switch_unpacked_dir(app: &Shared, dir: &Path) -> PathBuf {
    let cache = nsp_cache(app, dir);
    if !in_library(app, dir) && cache.is_dir() && !top_nsz(dir).is_empty() {
        cache
    } else {
        dir.to_path_buf()
    }
}

/// The game's package as the emulator gets it (its .nsp, for an .nsz played from RomM).
fn switch_unpacked(app: &Shared, rom: &Path) -> PathBuf {
    let is_nsz = rom.extension().map(|e| e.eq_ignore_ascii_case("nsz")).unwrap_or(false);
    let Some(dir) = rom.parent().filter(|_| is_nsz) else { return rom.to_path_buf() };
    let nsp = nsp_cache(app, dir).join(Path::new(rom.file_name().unwrap_or_default()).with_extension("nsp"));
    if nsp.is_file() {
        nsp
    } else {
        rom.to_path_buf()
    }
}

/// Whether a Switch game or its update/DLC folders still hold .nsz packages to unpack.
fn switch_needs_unpack(app: &Shared, rom: &Path, dirs: &[PathBuf]) -> bool {
    let mut all: Vec<PathBuf> = dirs.to_vec();
    if let Some(d) = rom.parent() {
        all.push(d.to_path_buf());
    }
    all.iter().any(|d| {
        if in_library(app, d) {
            !crate::nsz::found(d).is_empty()
        } else {
            let cache = nsp_cache(app, d);
            top_nsz(d).iter().any(|z| !cache.join(Path::new(z.file_name().unwrap_or_default()).with_extension("nsp")).is_file())
        }
    })
}

/// Unpacks a Switch game's .nsz packages: in place for downloaded games (their file in the
/// library updated), into the cache for those played from RomM.
fn switch_unpack(app: &Shared, rom: &Path, dirs: &[PathBuf]) -> Result<(), String> {
    let flag = std::sync::atomic::AtomicBool::new(false);
    let mut all: Vec<PathBuf> = vec![];
    if let Some(d) = rom.parent() {
        all.push(d.to_path_buf());
    }
    all.extend(dirs.iter().cloned());
    let mut seen: Vec<PathBuf> = vec![];
    for d in all {
        if seen.iter().any(|s| d.starts_with(s)) {
            continue;
        }
        let started = std::time::Instant::now();
        if in_library(app, &d) {
            for (from, to) in crate::nsz::unpack_in_place(&d, &flag)? {
                app.db
                    .log("play", &format!("{}: unpacked to {} in {:.0} s", from.display(), to.display(), started.elapsed().as_secs_f64()));
                // The game whose file it was (this one, or its update or DLC) now has the .nsp.
                for (id, dir, main, _) in app.db.local_games() {
                    if Path::new(&main) == from {
                        let size = crate::downloads::dir_size(Path::new(&dir)) as i64;
                        app.db.set_local(id, &dir, &to.to_string_lossy(), size);
                    }
                }
            }
            seen.push(d);
        } else {
            crate::nsz::unpack_into(&d, &nsp_cache(app, &d), &flag)?;
            app.db.log("play", &format!("{}: unpacked into the cache in {:.0} s", d.display(), started.elapsed().as_secs_f64()));
        }
    }
    Ok(())
}

fn switch_content_dirs_raw(app: &Shared, rom_id: i64, rom: &Path) -> Vec<PathBuf> {
    let is_pkg = |p: &Path| p.extension().map(|e| ["nsp", "nsz", "xci", "xcz"].iter().any(|x| e.eq_ignore_ascii_case(x))).unwrap_or(false);
    let holds_extra = |dir: &Path| {
        std::fs::read_dir(dir).into_iter().flatten().flatten().map(|e| e.path()).any(|p| {
            p != rom
                && is_pkg(&p)
                && crate::downloads::switch_kind(&p).map(|k| k != "base").unwrap_or_else(|| crate::downloads::is_extra(&p))
        })
    };
    let mut dirs: Vec<PathBuf> = vec![];
    let add = |d: PathBuf, dirs: &mut Vec<PathBuf>| {
        if !dirs.contains(&d) {
            dirs.push(d);
        }
    };
    if let Some(top) = rom.parent() {
        let mut stack = vec![(top.to_path_buf(), 0)];
        while let Some((d, depth)) = stack.pop() {
            if holds_extra(&d) {
                add(d.clone(), &mut dirs);
            }
            if depth < 2 {
                for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                    if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                        stack.push((e.path(), depth + 1));
                    }
                }
            }
        }
    }
    let group = app.db.game(rom_id).map(|g| g.group_key).unwrap_or_default();
    for g in app.db.group(&group) {
        if g.rom_id == rom_id || !crate::library::is_extra(&g) {
            continue;
        }
        let file = match (&g.local_main, g.local_state.as_str()) {
            (Some(m), "local") => Some(PathBuf::from(m)),
            _ => crate::stream::link(app, g.rom_id).ok(),
        };
        if let Some(d) = file.as_deref().and_then(Path::parent) {
            add(d.to_path_buf(), &mut dirs);
        }
    }
    dirs
}

/// A Switch update or DLC chosen as the game's version: the group's base game is played instead.
fn switch_base_version(app: &Shared, rom_id: i64) -> i64 {
    let Some(g) = app.db.game(rom_id) else { return rom_id };
    if g.platform_slug != "switch" || !crate::library::is_extra(&g) {
        return rom_id;
    }
    app.db
        .group(&g.group_key)
        .into_iter()
        .filter(|x| !crate::library::is_extra(x))
        .max_by_key(|x| (x.local_state == "local" || x.linked, -x.rom_id))
        .map(|x| x.rom_id)
        .unwrap_or(rom_id)
}

/// Held while a finished game's save is sent to RomM.
static SAVING: Mutex<()> = Mutex::new(());

/// A game is being started (saves pulled, emulator spawned): a second A press must not start
/// another one before the session exists.
static STARTING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Starts the game. Returns when the emulator is running; the session is then followed in the
/// background and its end announced with a "session" event.
pub fn play(app: &Shared, rom_id: i64) -> Result<Value, String> {
    if SESSION.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
        return Err("a game is already running".into());
    }
    if STARTING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return Err("a game is already running".into());
    }
    struct Started;
    impl Drop for Started {
        fn drop(&mut self) {
            STARTING.store(false, std::sync::atomic::Ordering::SeqCst);
        }
    }
    let _started = Started;
    forget_waiting();
    let rom_id = switch_base_version(app, rom_id);
    let g = app.db.game(rom_id).ok_or("unknown game")?;
    let system = g.platform_slug.clone();
    let e = chosen_for_game(app, &system, &g.group_key).ok_or_else(|| {
        if manifest().consoles.contains_key(&system) {
            format!("no emulator can run {} games yet", g.platform_name)
        } else {
            format!("Borne cannot run {} games yet", g.platform_name)
        }
    })?;
    let p = program(&e.program).ok_or("unknown emulator")?;
    crate::systemfiles::check(app, &system)?;
    // The game's file first. A game being downloaded, or compressed on RomM (downloaded and
    // extracted first), starts by itself once it is ready.
    let downloading = || {
        app.db
            .downloads()
            .iter()
            .any(|d| d.rom_id == rom_id && ["queued", "downloading", "verifying", "extracting"].contains(&d.state.as_str()))
    };
    let rom = match game_file(app, &g) {
        Err(e) if e == crate::stream::COMPRESSED || (g.local_state != "local" && downloading()) => {
            wait_for(rom_id);
            if !downloading() {
                crate::downloads::enqueue(app, rom_id)?;
            }
            return Ok(json!({ "running": false, "downloading": g.name }));
        }
        r => r,
    };
    if crate::stream::is_temporary(app, rom_id) {
        crate::stream::mark_temporary(app, rom_id); // used now: kept longest
    }
    let found = find(app, &p.id);
    let core_missing = e.core.as_ref().map(|c| !crate::emuinstall::core_path(app, c).is_file()).unwrap_or(false);
    if found.is_none() || core_missing {
        if found.is_none() && p.install_spec().is_none() {
            return Err(format!("{} is not available for this computer: choose its program in Settings → Emulators", p.name));
        }
        // Installed first; the game starts by itself once it is ready.
        rom?;
        wait_for(rom_id);
        crate::emuinstall::want(Some(&p.id));
        if !crate::emuinstall::busy() {
            crate::emuinstall::start(app, &p.id, e.core.clone().into_iter().collect())?;
        }
        // Another emulator being installed (for the library) goes first: said, so the player
        // knows why nothing seems to happen.
        let task = crate::emuinstall::task();
        let after = task["id"].as_str().filter(|id| task["running"] == true && *id != p.id).and_then(program).map(|o| o.name);
        return Ok(json!({ "running": false, "installing": p.name, "after": after }));
    }
    let found = found.unwrap();
    let mut rom = rom?;
    if system == "switch" {
        // Packages compressed with nsz are unpacked to .nsp first (once, in the background):
        // no emulator reads an .nsz's NCZ files.
        let dirs = switch_content_dirs_raw(app, rom_id, &rom);
        if switch_needs_unpack(app, &rom, &dirs) {
            wait_for(rom_id);
            let (app2, rom2) = (app.clone(), rom.clone());
            std::thread::spawn(move || match switch_unpack(&app2, &rom2, &dirs) {
                Ok(()) => play_waiting(&app2, Some(rom_id)),
                Err(e) => {
                    let _ = take_waiting(Some(rom_id));
                    app2.db.log("play", &format!("game {rom_id}: {e}"));
                    app2.emit(json!({ "type": "play_failed", "rom_id": rom_id, "error": e }));
                }
            });
            return Ok(json!({ "running": false, "preparing": g.name }));
        }
        rom = switch_unpacked(app, &rom);
        rom = switch_base(&rom)?;
        // The package read with the player's keys first: what the emulator would only call
        // "missing a Program-type NCA" is said here by its cause.
        if let Some(keys) = crate::systemfiles::first_file(app, "switch", "prod-keys").and_then(|k| std::fs::read_to_string(k).ok()) {
            app.db.log("play", &format!("{}: {}", g.name, crate::switchcheck::describe(&rom, &keys)));
            if let Some(problem) = crate::switchcheck::problem(&rom, &keys) {
                return Err(problem);
            }
        }
    }
    // Ryujinx writes its Config.json at its first start only: until then Borne has nowhere to
    // put the pad, fullscreen and the game folders, and the pad would do nothing. Started once
    // without a game, for that file, then closed.
    if p.id == "ryubing" {
        if let Found::Program(exe) = &found {
            let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
            let config = data_dir(app, &profile, "ryubing").join("Config.json");
            if !config.is_file() {
                app.db.log("play", "Ryujinx: first start, for its Config.json");
                if let Ok(mut child) = Command::new(exe).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
                    let t = Instant::now();
                    while !config.is_file() && t.elapsed() < Duration::from_secs(30) {
                        std::thread::sleep(Duration::from_millis(300));
                    }
                    std::thread::sleep(Duration::from_millis(800));
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
        }
    }
    // A PS Vita game sold on the store comes as a .pkg (in a zip): Vita3K installs it only with
    // its license (zRIF), then it starts as an installed game.
    if p.id == "vita3k" {
        // Vita3K's Discord presence crashes it on quitting (macOS shows "quit unexpectedly"):
        // turned off in its config.yml once it has one.
        let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
        let data = data_dir(app, &profile, "vita3k");
        for cfg in [data.join("config.yml"), data.parent().map(|d| d.join("config.yml")).unwrap_or_default()] {
            if let Ok(text) = std::fs::read_to_string(&cfg) {
                if text.contains("discord-rich-presence: true") {
                    let _ = std::fs::write(&cfg, text.replace("discord-rich-presence: true", "discord-rich-presence: false"));
                }
            }
        }
        if let Some(dir) = vita_pkg_installed(app, &found, &rom)? {
            rom = dir;
        } else if vita_zip_to_extract(&rom) && g.local_state == "local" {
            // A zip of the dumped game: Vita3K's own zip reader fails on large ones ("failed
            // finding central directory" past 4 GB): extracted once, in the background, and
            // the folder given from then on.
            wait_for(rom_id);
            let (app2, rom2) = (app.clone(), rom.clone());
            std::thread::spawn(move || match vita_extract(&app2, rom_id, &rom2) {
                Ok(()) => play_waiting(&app2, Some(rom_id)),
                Err(e) => {
                    let _ = take_waiting(Some(rom_id));
                    app2.db.log("play", &format!("game {rom_id}: {e}"));
                    app2.emit(json!({ "type": "play_failed", "rom_id": rom_id, "error": e }));
                }
            });
            return Ok(json!({ "running": false, "preparing": g.name }));
        }
    }
    if p.id == "cemu" {
        cemu_disc_keys(&data_dir(app, &app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into()), "cemu"), &rom);
    }
    // An encrypted 3DS dump stops Azahar at once on a "3DS error": said before, by its cause.
    if p.id == "azahar" && n3ds_encrypted(&rom) {
        return Err(
            "this 3DS game file is encrypted: Azahar plays decrypted game files only. Put a decrypted copy of the game on RomM".into()
        );
    }
    // A .cia is installed into Azahar once, then its installed program is what starts.
    if p.id == "azahar" && rom.extension().map(|x| x.eq_ignore_ascii_case("cia")).unwrap_or(false) {
        let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
        rom = cia_installed(app, &profile, &found, &rom)?;
    }
    let lang = app
        .active_profile()
        .and_then(|p| app.db.game_prefs(&p.id).get(&g.group_key).and_then(|(_, l)| l.clone()))
        .unwrap_or_else(|| "auto".into());
    // Saves and states from RomM when they are newer, and what is still waiting to go.
    let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
    let emu_name = e.core.clone().unwrap_or_else(|| p.id.clone());
    let sync = Some((profile.clone(), system.clone(), p.id.clone(), rom.clone(), emu_name));
    // The previous game's save on its way to RomM first (the same game may be played again).
    drop(SAVING.lock().unwrap_or_else(|e| e.into_inner()));
    crate::savesync::claim(app, &profile, &p.id);
    crate::savesync::retry_pending(app);
    match crate::savesync::pull(app, &profile, rom_id, &system, &p.id, &rom) {
        Ok(notes) => {
            for n in notes {
                app.db.log("saves", &format!("{}: {n}", g.name));
            }
        }
        Err(err) => app.db.log("saves", &format!("{}: no sync before playing ({err})", g.name)),
    }
    let mut cmd = command(app, &p, &e, &found, &system, &rom, &lang, rom_id)?;
    // Azahar on macOS warns with a window to close by hand (a mouse, no pad) when its parent is
    // not launchd: started through `open -W`, which waits for it to end. Its own processes are
    // then outside the group, so they are signalled by their bundle (`via_open`).
    let mut via_open = false;
    if cfg!(target_os = "macos") && p.id == "azahar" {
        if let Some(app_dir) = Path::new(cmd.get_program()).ancestors().find(|a| a.extension().map(|e| e == "app").unwrap_or(false)) {
            let mut o = Command::new("/usr/bin/open");
            o.args(["-W", "-n", "-a"]).arg(app_dir);
            for (k, v) in cmd.get_envs() {
                if let Some(v) = v {
                    o.arg("--env").arg(format!("{}={}", k.to_string_lossy(), v.to_string_lossy()));
                }
            }
            o.arg("--args").args(cmd.get_args());
            cmd = o;
            via_open = true;
        }
    }
    let log = emulator_log(app);
    let _ = std::fs::create_dir_all(log.parent().unwrap());
    let out = std::fs::File::create(&log).map_err(|e| e.to_string())?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    cmd.stdin(Stdio::null()).stdout(out).stderr(err);
    // Its own process group, so that stopping the game also stops what the emulator started
    // (Flatpak's sandbox, helper processes).
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let bundle = if via_open {
        cmd.get_args().nth(3).map(PathBuf::from)
    } else {
        Path::new(cmd.get_program()).ancestors().find(|a| a.extension().map(|e| e == "app").unwrap_or(false)).map(Path::to_path_buf)
    };
    let child = cmd.spawn().map_err(|err| format!("{} could not start: {err}", p.name))?;
    app.db.log("play", &format!("{} with {} ({})", g.name, e.name, found.describe()));
    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = Some(Session {
        rom_id,
        name: g.name.clone(),
        emulator: e.name.clone(),
        program: p.id.clone(),
        group_key: g.group_key.clone(),
        system: system.clone(),
        started: Instant::now(),
        child,
        stopping: false,
        sync,
        failure: None,
        paused: false,
        bundle,
        via_open,
        flatpak: match &found {
            Found::Flatpak(id) => Some(id.clone()),
            _ => None,
        },
    });
    let s = session();
    app.emit(json!({ "type": "session", "session": s }));
    let fails: Vec<String> = p.fails.iter().map(|f| f.to_lowercase()).collect();
    // Its log where Borne points it, and where it may write anyway: the usual folders of the
    // user, and a Flatpak's own (Flatpak sets the XDG variables itself).
    let data = data_dir(app, &profile, &p.id);
    let base = app.paths.profiles().join(&profile).join(&p.id);
    let mut dirs = vec![data.clone()];
    for (from, to) in [("data", ".local/share"), ("config", ".config")] {
        if let Ok(rel) = data.strip_prefix(base.join(from)) {
            dirs.push(home().join(to).join(rel));
            if let Found::Flatpak(id) = &found {
                dirs.push(home().join(".var/app").join(id).join(from).join(rel));
            }
        }
    }
    let own: Vec<PathBuf> = dirs.iter().flat_map(|d| p.logs.iter().map(move |l| d.join(l))).collect();
    let app = app.clone();
    std::thread::spawn(move || follow(app, log, own, fails));
    Ok(s)
}

/// How long after the start the emulator's output is watched for a game that did not start.
const WATCH_START: Duration = Duration::from_secs(90);

/// The first line of `text` that contains one of `fails` (lowercase).
fn failure_line(text: &str, fails: &[String]) -> Option<String> {
    text.lines()
        .find(|l| {
            let l = l.to_lowercase();
            fails.iter().any(|f| l.contains(f.as_str()))
        })
        .map(|l| {
            // Without the time stamp and tags ("[  0.67] Core <Critical> core/core.cpp:308:Load:").
            let l = l.trim();
            let l = match l.find('>') {
                Some(i) if l[..i].contains('<') => l[i..].split_once(": ").map(|(_, t)| t).unwrap_or(l),
                _ => l,
            };
            l.chars().take(200).collect()
        })
}

/// What an emulator's error line means for the player, when it is a known one.
fn explain(line: &str) -> String {
    let l = line.to_lowercase();
    let known = if l.contains("(error 52)") || l.contains("missing a program-type nca") {
        "the game cannot be read: the Switch keys (prod.keys) and firmware are older than the game; take them again from an up-to-date Switch"
    } else if l.contains("(error 13)") || l.contains("missing production key") {
        "the Switch keys (prod.keys) are missing"
    } else if l.contains("fatal error type") || l.contains("system archive not found") || l.contains("shared font") {
        "the game stopped on a 3DS error: it needs the 3DS system files (in Azahar: File → Set Up System Files, from a 3DS), or the game file is damaged or still encrypted"
    } else if l.contains("firmware is missing") {
        "the Switch firmware is missing: add it in Settings → Consoles → Switch"
    } else if l.contains("failed to obtain loader") {
        "the emulator does not take this file (a .cia must be installed first: a .3ds or .cci copy starts directly)"
    } else if (l.contains("crc") || l.contains("rom")) && (l.contains("required") || l.contains("missing") || l.contains("not found")) {
        "this arcade game is not in the version the emulator expects (a ROM is missing or different): use a set made for FinalBurn Neo"
    } else if l.contains("needs an installed app to run") {
        "Vita3K could not install the game from this file (its log is in the diagnostic report). A PS Vita game must be a .vpk, a zip of the dumped game, or a .pkg with its license"
    } else if l.contains("encrypted") {
        "the game file is encrypted: the emulator needs a decrypted copy"
    } else {
        return line.to_string();
    };
    known.to_string()
}

/// A log file as it is now; a folder stands for its newest file. Only what was written since
/// `since` counts (the emulator's log from an earlier game is not this game's).
fn current_log(path: &Path, since: std::time::SystemTime) -> Option<PathBuf> {
    let modified = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    let file = if path.is_dir() {
        std::fs::read_dir(path).ok()?.flatten().map(|e| e.path()).filter(|p| p.is_file()).max_by_key(|p| modified(p))?
    } else {
        path.to_path_buf()
    };
    (modified(&file)? >= since).then_some(file)
}

fn follow(app: Shared, log: PathBuf, own: Vec<PathBuf>, fails: Vec<String>) {
    let since = std::time::SystemTime::now() - Duration::from_secs(2);
    // Bytes already read, per file: the emulator's output, then its own logs.
    let mut read: HashMap<PathBuf, usize> = HashMap::new();
    loop {
        std::thread::sleep(Duration::from_millis(250));
        let mut g = SESSION.lock().unwrap_or_else(|e| e.into_inner());
        let Some(s) = g.as_mut() else { return };
        match s.child.try_wait() {
            Ok(None) => {
                // A game that did not start leaves the emulator on its own screen (an error
                // window waiting for a mouse): closed at once, the error shown by Borne.
                if !fails.is_empty() && !s.stopping && s.failure.is_none() && s.started.elapsed() < WATCH_START {
                    let files = std::iter::once(Some(log.clone())).chain(own.iter().map(|p| current_log(p, since))).flatten();
                    for file in files {
                        let bytes = std::fs::read(&file).unwrap_or_default();
                        let done = read.entry(file).or_insert(0);
                        if bytes.len() < *done {
                            *done = 0; // started again by the emulator
                        }
                        if bytes.len() > *done {
                            let start = done.saturating_sub(256);
                            *done = bytes.len();
                            if let Some(line) = failure_line(&String::from_utf8_lossy(&bytes[start..]), &fails) {
                                s.failure = Some(line);
                                break;
                            }
                        }
                    }
                    if s.failure.is_some() {
                        drop(g);
                        stop();
                    }
                }
                continue;
            }
            Ok(Some(status)) => {
                // The program started may hand the game to another process and leave (a launcher
                // script, an AppImage runtime): the game runs as long as its process group does.
                // Only then is the session over, so that a second game cannot start beside it.
                #[cfg(unix)]
                {
                    // Started by `open`: the emulator is gone with it, or made to go.
                    if s.via_open && s.stopping {
                        signal_session(s, libc::SIGKILL);
                    }
                    let pgid = s.child.id() as i32;
                    if unsafe { libc::kill(-pgid, 0) } == 0 {
                        if s.stopping {
                            unsafe { libc::kill(-pgid, libc::SIGKILL) };
                        }
                        continue;
                    }
                    // A Flatpak's sandbox outlives its `flatpak run`: the game runs as long as it.
                    if let Some(id) = s.flatpak.clone() {
                        if flatpak_running(&id) {
                            if s.stopping {
                                flatpak_kill(&id);
                            }
                            drop(g);
                            std::thread::sleep(Duration::from_millis(700));
                            continue;
                        }
                    }
                }
                let quick = s.started.elapsed() < Duration::from_secs(8) && !s.stopping;
                let failure = s.failure.take().or_else(|| {
                    // A last look, for an emulator that wrote its error and quit at once.
                    let text = std::fs::read_to_string(&log).unwrap_or_default();
                    (!s.stopping && s.started.elapsed() < WATCH_START).then(|| failure_line(&text, &fails)).flatten()
                });
                // Killed by a signal it raised itself (abort, segmentation fault): a crash of the
                // emulator, at any time, said as such rather than by its last log line.
                let crashed = {
                    use std::os::unix::process::ExitStatusExt;
                    status.signal().filter(|n| {
                        !s.stopping && [libc::SIGABRT, libc::SIGSEGV, libc::SIGBUS, libc::SIGILL, libc::SIGFPE, libc::SIGTRAP].contains(n)
                    })
                };
                let program_id = s.program.clone();
                let error = failure
                    .map(|l| format!("{} could not start the game: {}", s.emulator, explain(&l)))
                    .or_else(|| crashed.map(|n| crash_message(&s.emulator, &program_id, n)))
                    .or_else(|| {
                        (!status.success() && quick).then(|| {
                            let t = log_tail(&log);
                            if t.is_empty() {
                                format!("{} stopped at once ({status})", s.emulator)
                            } else {
                                format!("{} stopped at once: {}", s.emulator, explain(&t))
                            }
                        })
                    });
                // This emulator's output kept apart (the diagnostic report shows each emulator's
                // last run, not only the last game's).
                let _ = std::fs::copy(&log, log.with_file_name(format!("emulator-{}.log", s.program)));
                let played = s.started.elapsed().as_secs();
                let (rom_id, name, sync) = (s.rom_id, s.name.clone(), s.sync.clone());
                let (group_key, system) = (s.group_key.clone(), s.system.clone());
                // A game that does not run on this emulator (it crashed or refused it early)
                // goes on its partner at once, the player seeing only the game start; noted per
                // game, so the next time starts there directly. One that ran is noted as running.
                if error.is_some() && s.started.elapsed() < RUNS_AFTER {
                    app.db.set_setting(&failed_key(&group_key, &program_id), "1");
                } else if error.is_none() && s.started.elapsed() >= RUNS_AFTER {
                    app.db.delete_setting(&failed_key(&group_key, &program_id));
                }
                let switch_to = error
                    .as_ref()
                    .filter(|_| s.started.elapsed() < RUNS_AFTER)
                    .and_then(|_| partners(&system, &program_id).into_iter().find(|o| !failed_on(&app, &group_key, &o.program)));
                if let Some(other) = switch_to {
                    let _ = std::fs::copy(&log, log.with_file_name(format!("emulator-{}.log", s.program)));
                    let saving = SAVING.lock().unwrap_or_else(|e| e.into_inner());
                    *g = None;
                    drop(g);
                    app.db.log(
                        "play",
                        &format!(
                            "{name}: {} did not run it ({}); started on {} instead",
                            program_id,
                            error.as_deref().unwrap_or(""),
                            other.name
                        ),
                    );
                    drop(saving);
                    let app = app.clone();
                    std::thread::spawn(move || match play(&app, rom_id) {
                        Ok(r) if r["running"] == true => {}
                        Ok(r) => {
                            // Installing or preparing first: it starts by itself once ready.
                            app.emit(json!({ "type": "session", "session": { "running": false, "rom_id": rom_id, "seconds": played, "error": null, "waiting": r } }));
                        }
                        Err(e) => {
                            app.emit(json!({ "type": "session", "session": { "running": false, "rom_id": rom_id, "seconds": played, "error": e } }));
                        }
                    });
                    return;
                }
                // The save is sent while the player already moves on: held by SAVING until done,
                // so that a game started meanwhile waits for it before taking its saves.
                let saving = SAVING.lock().unwrap_or_else(|e| e.into_inner());
                *g = None;
                drop(g);
                app.db.log("play", &format!("{name}: session ended after {played} s ({status})"));
                // Recently played and time played, for the library's "Recent" tab and sorting.
                if error.is_none() {
                    if let (Some(p), Some(g)) = (app.active_profile(), app.db.game(rom_id)) {
                        app.db.record_play(&p.id, &g.group_key, played as i64);
                    }
                }
                app.emit(json!({ "type": "session", "session": { "running": false, "rom_id": rom_id, "seconds": played, "error": error, "saving": sync.is_some() } }));
                let saved = sync.map(|(profile, system, program, rom, emu)| {
                    crate::savesync::push(&app, &profile, rom_id, &system, &program, &rom, &emu)
                });
                drop(saving);
                let save_note = match &saved {
                    Some(Ok(n)) if *n > 0 => Some("save sent to RomM".to_string()),
                    Some(Err(e)) => Some(e.clone()),
                    _ => None,
                };
                if let Some(n) = &save_note {
                    app.db.log("saves", &format!("{name}: {n}"));
                }
                app.emit(json!({ "type": "saves", "rom_id": rom_id, "note": save_note }));
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

/// How long the quit question waits before the game goes on by itself (the question may be hidden
/// behind the emulator on some desktops).
const ASK_QUIT_FOR: Duration = Duration::from_secs(30);

/// The quit chord during a game: the game pauses (its processes stopped) and Borne asks whether
/// to quit; the chord again quits at once.
pub fn ask_quit(app: &Shared) {
    let mut g = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    let Some(s) = g.as_mut() else { return };
    if s.stopping {
        return;
    }
    if s.paused {
        drop(g);
        stop();
        return;
    }
    let pid = s.child.id() as i32;
    signal_session(s, libc::SIGSTOP);
    s.paused = true;
    drop(g);
    crate::quitkey::hide_game(pid);
    app.emit(json!({ "type": "session", "session": session() }));
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(ASK_QUIT_FOR);
        let still =
            SESSION.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|s| s.paused && s.child.id() as i32 == pid).unwrap_or(false);
        if still {
            resume(&app);
        }
    });
}

/// The game goes on after the quit question: its processes run again, and on macOS the emulator
/// comes back to the front.
pub fn resume(app: &Shared) {
    let mut g = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    let Some(s) = g.as_mut() else { return };
    if !s.paused {
        return;
    }
    signal_session(s, libc::SIGCONT);
    s.paused = false;
    let bundle = s.bundle.clone();
    drop(g);
    crate::quitkey::show_game();
    if let Some(b) = bundle {
        let _ = Command::new("open").arg("-a").arg(b).status();
    }
    app.emit(json!({ "type": "session", "session": session() }));
}

/// Ends the running game (the emulator is asked to quit, then stopped).
pub fn stop() -> bool {
    let mut g = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    let Some(s) = g.as_mut() else { return false };
    s.stopping = true;
    let pid = s.child.id() as i32;
    if let Some(id) = s.flatpak.clone() {
        std::thread::spawn(move || flatpak_kill(&id));
    }
    signal_session(s, libc::SIGTERM);
    // A game paused by the quit question runs again to receive it.
    if s.paused {
        signal_session(s, libc::SIGCONT);
    }
    drop(g);
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(5));
        if let Some(s) = SESSION.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            if s.child.id() as i32 == pid {
                signal_session(s, libc::SIGKILL);
            }
        }
    });
    true
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_wii_u_discs_key_goes_into_cemus_keys() {
        let d = tempfile::tempdir().unwrap();
        let game = d.path().join("game");
        std::fs::create_dir_all(&game).unwrap();
        std::fs::write(game.join("Game.wud"), b"x").unwrap();
        std::fs::write(game.join("Game.key"), [0xabu8; 16]).unwrap();
        let data = d.path().join("cemu");
        super::cemu_disc_keys(&data, &game.join("Game.wud"));
        super::cemu_disc_keys(&data, &game.join("Game.wud"));
        let t = std::fs::read_to_string(data.join("keys.txt")).unwrap();
        assert_eq!(t.matches("abababababababababababababababab").count(), 1, "{t}");
    }

    #[test]
    fn a_waiting_game_starts_once_and_only_itself() {
        super::wait_for(5);
        assert_eq!(super::take_waiting(Some(6)), None, "another game's download does not start it");
        assert_eq!(super::take_waiting(Some(5)), Some(5));
        assert_eq!(super::take_waiting(Some(5)), None, "started once");
        super::wait_for(7);
        super::forget_waiting();
        assert_eq!(super::take_waiting(None), None, "forgotten by another Play");
    }

    use super::*;

    #[test]
    fn retroarch_profile_of_a_pad_from_sdl() {
        if cfg!(target_os = "macos") {
            return;
        }
        // Xbox Series X over Bluetooth (SDL_GameControllerDB): X on button 3, triggers on axes.
        let t = retroarch_pad_profile("Xbox Wireless Controller", "050000005e040000130b000022050000", 0x045e, 0x0b13).unwrap();
        assert!(t.contains("input_device = \"Xbox Wireless Controller\""), "{t}");
        assert!(t.contains("input_vendor_id = \"1118\""));
        assert!(t.contains("input_b_btn = \"0\""), "RetroArch's B is SDL's A (bottom)");
        assert!(t.contains("input_y_btn = \"3\""), "{t}");
        assert!(t.contains("input_up_btn = \"h0up\""), "{t}");
        assert!(t.contains("input_r2_axis = \"+4\""), "{t}");
        assert!(t.contains("input_l_x_plus_axis = \"+0\""));
        assert!(retroarch_pad_profile("?", "0300000000000000ffff000000000000", 0, 0).is_none());
    }

    #[test]
    fn the_users_own_appimages_are_found() {
        use std::os::unix::fs::PermissionsExt;
        let d = std::env::temp_dir().join(format!("borne-appimg-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        for f in ["pcsx2-Qt.AppImage", "Ryujinx.AppImage", "rpcs3-v0.0.34.AppImage", "duckstation-notes.txt", "Cemu.AppImage"] {
            std::fs::write(d.join(f), b"x").unwrap();
            std::fs::set_permissions(d.join(f), std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let dirs = [d.clone()];
        let n = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(user_appimage_in(&dirs, "pcsx2", &n(&["PCSX2"])), Some(d.join("pcsx2-Qt.AppImage")));
        assert_eq!(user_appimage_in(&dirs, "ryubing", &n(&["Ryubing (Ryujinx)", "Ryubing"])), Some(d.join("Ryujinx.AppImage")));
        assert_eq!(user_appimage_in(&dirs, "rpcs3", &n(&["RPCS3"])), Some(d.join("rpcs3-v0.0.34.AppImage")));
        assert_eq!(user_appimage_in(&dirs, "duckstation", &n(&["DuckStation"])), None, "not an AppImage");
        assert_eq!(user_appimage_in(&dirs, "dolphin", &n(&["Dolphin"])), None);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn a_program_is_never_taken_for_a_retroarch_core() {
        // "vita3k" without its "!" made PS Vita games wait for a RetroArch core that does not
        // exist (404) instead of starting Vita3K.
        let programs: Vec<String> = programs().into_iter().map(|p| p.id).collect();
        for (console, list) in manifest().consoles {
            for (id, _) in list {
                assert!(!programs.contains(&id), "{console}: {id} is a program, written without its '!'");
            }
        }
    }

    #[test]
    fn a_vita_pkg_in_a_zip_is_found_with_its_license() {
        use std::io::Write;
        let d = std::env::temp_dir().join(format!("borne-vpkg-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let mut head = vec![0u8; 0x100];
        head[..4].copy_from_slice(b"\x7fPKG");
        head[0x30..0x54].copy_from_slice(b"EP1024-PCSB01061_00-COLLARMALICE0000");
        let make = |name: &str, zrif: Option<&str>| {
            let p = d.join(name);
            let mut z = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
            let o = zip::write::SimpleFileOptions::default();
            z.start_file("EP1024-PCSB01061_00-COLLARMALICE0000.pkg", o).unwrap();
            z.write_all(&head).unwrap();
            if let Some(k) = zrif {
                z.start_file("license.txt", o).unwrap();
                z.write_all(format!("zRIF: {k}\n").as_bytes()).unwrap();
            }
            z.finish().unwrap();
            p
        };
        let key = "KO5ifR1dQ+eHBlGnZWTTRRpeS0xIUnFj8tJRqlMaRgcdQY0lBXVNqTI2AAAA";
        let (pkg, tid, zrif) = vita_pkg_of(&make("a.zip", Some(key))).unwrap();
        assert_eq!((pkg.as_str(), tid.as_str(), zrif.as_deref()), ("EP1024-PCSB01061_00-COLLARMALICE0000.pkg", "PCSB01061", Some(key)));
        assert_eq!(vita_pkg_of(&make("b.zip", None)).unwrap().2, None);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn encrypted_3ds_files_are_told() {
        let d = std::env::temp_dir().join(format!("borne-3ds-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let image = |flags7: u8| {
            let mut v = vec![0u8; 0x4200];
            v[0x100..0x104].copy_from_slice(b"NCSD");
            v[0x120..0x124].copy_from_slice(&0x20u32.to_le_bytes()); // partition 0 at 0x4000
            v[0x4100..0x4104].copy_from_slice(b"NCCH");
            v[0x418F] = flags7;
            v
        };
        std::fs::write(d.join("enc.3ds"), image(0)).unwrap();
        std::fs::write(d.join("dec.cci"), image(4)).unwrap();
        assert!(n3ds_encrypted(&d.join("enc.3ds")));
        assert!(!n3ds_encrypted(&d.join("dec.cci")));
        assert!(!n3ds_encrypted(&d.join("missing.3ds")));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn vita_games_start_by_title_once_installed() {
        let d = std::env::temp_dir().join(format!("borne-vita-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let mut sfo = b"\0PSF".to_vec();
        for v in [1u32, 36, 48, 1] {
            sfo.extend(v.to_le_bytes());
        }
        sfo.extend(0u16.to_le_bytes());
        sfo.extend(0x0204u16.to_le_bytes());
        for v in [10u32, 12, 0] {
            sfo.extend(v.to_le_bytes());
        }
        sfo.extend(b"TITLE_ID\0\0\0\0PCSE00001\0\0\0");
        let vpk = d.join("Game.vpk");
        let mut z = zip::ZipWriter::new(std::fs::File::create(&vpk).unwrap());
        z.start_file("sce_sys/param.sfo", zip::write::SimpleFileOptions::default()).unwrap();
        std::io::Write::write_all(&mut z, &sfo).unwrap();
        z.finish().unwrap();
        assert_eq!(vita_installed(&d, &vpk), None); // not installed: the .vpk is given
        std::fs::create_dir_all(d.join("ux0/app/PCSE00001")).unwrap();
        assert_eq!(vita_installed(&d, &vpk).as_deref(), Some("PCSE00001"));
        // A folder dump: the folder, whichever of its files was picked.
        let dump = d.join("Game (Europe)/PCSE00001");
        std::fs::create_dir_all(dump.join("sce_sys")).unwrap();
        std::fs::create_dir_all(dump.join("sce_module")).unwrap();
        std::fs::write(dump.join("sce_sys/param.sfo"), &sfo).unwrap();
        std::fs::write(dump.join("eboot.bin"), b"x").unwrap();
        std::fs::write(dump.join("sce_module/libc.suprx"), b"x").unwrap();
        assert_eq!(vita_content(&dump.join("eboot.bin")).as_deref(), Some(dump.as_path()));
        assert_eq!(vita_content(&dump.join("sce_module/libc.suprx")).as_deref(), Some(dump.as_path()));
        assert_eq!(vita_content(&d.join("Game (Europe)/x.bin")).as_deref(), Some(dump.as_path()), "found below");
        assert_eq!(vita_content(&vpk), None);
        assert_eq!(vita_installed(&d, &dump).as_deref(), Some("PCSE00001"), "installed folder dump");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn cia_title_id_is_read_from_its_tmd() {
        let mut b = vec![0u8; 0x2040]; // header 0x2020, aligned
        b[0..4].copy_from_slice(&0x2020u32.to_le_bytes());
        b[8..12].copy_from_slice(&0xa00u32.to_le_bytes());
        b[0x0c..0x10].copy_from_slice(&0x350u32.to_le_bytes());
        b.extend(vec![0u8; 0xa00 + 0x380]); // certificates, ticket (aligned)
        let mut tmd = 0x10004u32.to_be_bytes().to_vec();
        tmd.extend(vec![0u8; 0x13c + 0x4c]);
        tmd.extend(0x0004_0000_0019_3a00u64.to_be_bytes());
        b.extend(tmd);
        let p = std::env::temp_dir().join(format!("borne-cia-{}.cia", std::process::id()));
        std::fs::write(&p, &b).unwrap();
        assert_eq!(cia_title_id(&p), Some(0x0004_0000_0019_3a00));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn switch_emulators_stand_in_for_each_other() {
        let names = |v: Vec<Engine>| v.into_iter().map(|e| e.program).collect::<Vec<_>>();
        assert_eq!(names(partners("switch", "eden")), ["ryubing"]);
        assert_eq!(names(partners("switch", "ryubing")), ["eden"]);
        assert!(partners("switch", "citron").is_empty());
        assert!(partners("gc", "dolphin").is_empty());
    }

    #[test]
    fn harmless_warnings_never_stop_a_game() {
        // Azahar loads its own replacements for these: the game goes on (stopping it there
        // killed Pokémon X a few seconds in).
        let fails: Vec<String> = program("azahar").unwrap().fails.iter().map(|f| f.to_lowercase()).collect();
        for line in [
            "[   2.700898] Service.FS <Warning> core/file_sys/archive_ncch.cpp:OpenFile:187: Shared Font file missing. Loading open source replacement from memory",
            "[   3.219994] Service.FS <Warning> core/file_sys/archive_ncch.cpp:OpenFile:200: Bad Word List file missing. Loading open source replacement from memory",
            "[   4.221461] Service.FS <Warning> core/file_sys/archive_ncch.cpp:OpenFile:181: Country list file missing. Loading open source replacement from memory",
        ] {
            assert_eq!(failure_line(line, &fails), None, "{line}");
        }
    }

    #[test]
    fn failure_lines_read_plainly() {
        let fails = vec!["failed to load rom".to_string()];
        let l = failure_line("[   0.679377] Core <Critical> core/core.cpp:308:Load: Failed to load ROM (Error 52)!\n", &fails);
        assert_eq!(l.as_deref(), Some("Failed to load ROM (Error 52)!"));
        let d = std::env::temp_dir().join(format!("borne-tail-{}", std::process::id()));
        std::fs::write(&d, "[INFO] =====\n[libretro ERROR] [BOOT] Unknown game\n[ERROR] [Content] Failed to load content.\n").unwrap();
        assert_eq!(log_tail(&d), "Unknown game · Failed to load content.");
        let _ = std::fs::remove_file(&d);
    }

    #[test]
    fn manifest_reads_and_offers_choices_for_the_v1_consoles() {
        for sys in ["nes", "genesis", "ngc", "ps2", "switch", "nds", "ps3", "ps4", "xbox360"] {
            let e = engines(sys);
            assert!(!e.is_empty(), "{sys}");
            for x in &e {
                assert!(program(&x.program).is_some(), "{sys}: {}", x.program);
            }
        }
        assert_eq!(engines("nes")[0].core.as_deref(), Some("mesen"));
        assert_eq!(engines("ps2")[0].program, "pcsx2");
        assert!(engines("xboxone").is_empty());
        assert!(program("eden").unwrap().install_spec().is_some());
        for p in programs() {
            assert!(p.args.iter().any(|a| a.contains("{rom}")), "{}", p.id);
        }
    }

    #[test]
    fn ini_values_are_set_in_place() {
        let p = std::env::temp_dir().join(format!("borne-ini-{}.ini", std::process::id()));
        std::fs::write(&p, "[UI]\nTheme = dark\nSetupWizardIncomplete = true\n\n[Other]\nA = 1\n").unwrap();
        ini_set(&p, &[("UI", "SetupWizardIncomplete", "false"), ("Folders", "Bios", "/x")]).unwrap();
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(
            t.contains("Theme = dark")
                && t.contains("SetupWizardIncomplete = false")
                && t.contains("[Folders]\nBios = /x")
                && t.contains("A = 1")
        );
        let _ = std::fs::remove_file(p);
    }

    #[test]
    fn dolphin_language_numbers() {
        assert_eq!(dolphin_language("fr"), Some("2"));
        assert_eq!(dolphin_language("ja"), None);
    }
}
