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
use std::collections::BTreeMap;
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

pub fn engines(system: &str) -> Vec<Engine> {
    manifest().consoles.get(system).map(|v| v.iter().map(|(i, n)| engine(i, n)).collect()).unwrap_or_default()
}

/// The engine chosen for a console (the user's choice, else the first one).
pub fn chosen(app: &Shared, system: &str) -> Option<Engine> {
    let list = engines(system);
    let pref = app.db.setting(&format!("emu_for.{system}"));
    list.iter().find(|e| Some(&e.id) == pref.as_ref()).cloned().or_else(|| list.into_iter().next())
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
        "eden" => if mac_os { mac.join("eden") } else { xdg_data.join("eden") },
        "citron" => if mac_os { mac.join("citron") } else { xdg_data.join("citron") },
        "ryubing" => if mac_os { mac.join("Ryujinx") } else { xdg_config.join("Ryujinx") },
        "rpcs3" => if mac_os { mac.join("rpcs3") } else { xdg_config.join("rpcs3") },
        "pcsx2" => if mac_os { mac } else { xdg_config },
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
    let systems: Vec<(String, String)> = app.db.platforms().into_iter().map(|p| (p.slug.clone(), p.name.clone())).collect();
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
            json!({ "slug": slug, "name": name, "choices": choices, "chosen": chosen(app, slug).map(|e| e.id), "known": manifest().consoles.contains_key(slug), "available": available })
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

/// The command that starts `rom` with the chosen engine.
#[allow(clippy::too_many_arguments)]
fn command(app: &Shared, p: &Program, e: &Engine, found: &Found, system: &str, rom: &Path, lang: &str, rom_id: i64) -> Result<Command, String> {
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
    let config = if p.id == "retroarch" {
        let mut cheats = crate::cheats::retroarch_settings(app, rom_id, &e.name, rom);
        let crt = crate::emuinstall::crt_shader(app);
        cheats.extend(crate::gamesettings::retroarch(&display, crt.as_deref()));
        Some(retroarch_config(app, &profile, system, cheats)?)
    } else {
        None
    };
    let userdir = app.paths.profiles().join(&profile).join(&p.id);
    std::fs::create_dir_all(&userdir).map_err(|e| e.to_string())?;
    crate::gamesettings::apply(&p.id, &data_dir(app, &profile, &p.id), &userdir, &display)?;
    let pad = app.pads.lock().unwrap().pads.first().cloned();
    crate::gamesettings::controllers(&p.id, &data_dir(app, &profile, &p.id), &userdir, pad.as_deref())?;
    let lang_dolphin = if system == "ngc" { dolphin_language(lang).unwrap_or("") } else { "" };
    let mut args: Vec<String> = vec![];
    for a in &p.args {
        let v = a
            .replace("{rom}", &rom.to_string_lossy())
            .replace("{core}", &core.as_ref().map(|c| c.to_string_lossy().into_owned()).unwrap_or_default())
            .replace("{config}", &config.as_ref().map(|c| c.to_string_lossy().into_owned()).unwrap_or_default())
            .replace("{userdir}", &userdir.to_string_lossy())
            .replace("{lang_dolphin}", lang_dolphin)
            .replace("{upscale3}", &display.get("upscale").and_then(|v| v.as_str()).and_then(|v| v.parse::<u32>().ok()).unwrap_or(1).min(3).to_string());
        // An option left without its value (no language chosen…) goes with its flag.
        if v.ends_with('=') || v.is_empty() {
            if args.last().map(|l| l.starts_with('-')).unwrap_or(false) {
                args.pop();
            }
            continue;
        }
        args.push(v);
    }
    let mut cmd = match found {
        Found::Program(exe) => {
            let mut c = Command::new(exe);
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
    // AppImages extracted by Borne find their own libraries this way.
    cmd.env("APPIMAGE_EXTRACT_AND_RUN", "1");
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
        // No RetroArch interface: no menu, no on-screen messages, no hotkeys.
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
        ("input_exit_emulator".into(), "nul".into()),
        ("input_enable_hotkey".into(), "nul".into()),
        ("input_hotkey_block_delay".into(), "0".into()),
        ("quit_press_twice".into(), "false".into()),
        ("confirm_quit".into(), "false".into()),
        ("input_autodetect_enable".into(), "true".into()),
        ("auto_overrides_enable".into(), "false".into()),
        ("auto_remaps_enable".into(), "false".into()),
        ("game_specific_options".into(), "false".into()),
        ("network_cmd_enable".into(), "false".into()),
        ("check_firmware_before_loading".into(), "true".into()),
    ];
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

/// Settings for RetroArch set in Borne (none yet beyond the defaults above).
pub fn extra_retroarch(_app: &Shared, _system: &str) -> Vec<(String, String)> {
    vec![]
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
    let e = chosen(app, &system).ok_or_else(|| {
        if manifest().consoles.contains_key(&system) {
            format!("no emulator can run {} games yet", g.platform_name)
        } else {
            format!("Borne cannot run {} games yet", g.platform_name)
        }
    })?;
    let p = program(&e.program).ok_or("unknown emulator")?;
    crate::systemfiles::check(app, &system)?;
    let found = find(app, &p.id);
    let core_missing = e.core.as_ref().map(|c| !crate::emuinstall::core_path(app, c).is_file()).unwrap_or(false);
    if found.is_none() || core_missing {
        if found.is_none() && p.install_spec().is_none() {
            return Err(format!("{} is not available for this computer: choose its program in Settings → Emulators", p.name));
        }
        // Installed first; the game starts by itself once it is ready.
        game_file(app, &g)?;
        crate::emuinstall::play_after(rom_id);
        if !crate::emuinstall::busy() {
            crate::emuinstall::start(app, &p.id, e.core.clone().into_iter().collect())?;
        }
        return Ok(json!({ "running": false, "installing": p.name }));
    }
    let found = found.unwrap();
    let rom = game_file(app, &g)?;
    let lang = app
        .active_profile()
        .and_then(|p| app.db.game_prefs(&p.id).get(&g.group_key).and_then(|(_, l)| l.clone()))
        .unwrap_or_else(|| "auto".into());
    let mut cmd = command(app, &p, &e, &found, &system, &rom, &lang, rom_id)?;
    let log = emulator_log(app);
    let _ = std::fs::create_dir_all(log.parent().unwrap());
    let out = std::fs::File::create(&log).map_err(|e| e.to_string())?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    cmd.stdin(Stdio::null()).stdout(out).stderr(err);
    // Its own process group, so that stopping the game also stops what the emulator started
    // (Flatpak's sandbox, helper processes).
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let child = cmd.spawn().map_err(|err| format!("{} could not start: {err}", p.name))?;
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
        assert!(t.contains("Theme = dark") && t.contains("SetupWizardIncomplete = false") && t.contains("[Folders]\nBios = /x") && t.contains("A = 1"));
        let _ = std::fs::remove_file(p);
    }

    #[test]
    fn dolphin_language_numbers() {
        assert_eq!(dolphin_language("fr"), Some("2"));
        assert_eq!(dolphin_language("ja"), None);
    }
}
