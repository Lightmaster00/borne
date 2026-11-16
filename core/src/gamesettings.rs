//! Display settings chosen in Borne, for all games and per game, and written into each
//! emulator's Borne-owned configuration before the game starts: the user never opens an emulator
//! to change them.
//!
//! - aspect: auto (the game's own), 4:3, 16:9, stretch
//! - upscale: 1–4 × the console's resolution (3D consoles: Dolphin, PCSX2, DuckStation, RPCS3)
//! - smooth: sharp pixels, smoothed, or an old CRT television look (2D consoles, RetroArch)
//! - integer: whole-number scaling, no uneven pixels (RetroArch)
//! - fps: show the frame rate
//!
//! A game's own value replaces its console's, which replaces the one for all games; "default"
//! removes a game's or a console's own value.

use crate::state::Shared;
use serde_json::{json, Map, Value};
use std::path::Path;

pub const KEYS: [(&str, &[&str], &str); 5] = [
    ("aspect", &["auto", "4:3", "16:9", "stretch"], "auto"),
    ("upscale", &["1", "2", "3", "4"], "2"),
    ("smooth", &["sharp", "smooth", "crt"], "sharp"),
    ("integer", &["off", "on"], "off"),
    ("fps", &["off", "on"], "off"),
];

fn default_of(key: &str) -> Option<&'static str> {
    KEYS.iter().find(|k| k.0 == key).map(|k| k.2)
}

fn valid(key: &str, value: &str) -> bool {
    KEYS.iter().any(|k| k.0 == key && k.1.contains(&value))
}

fn global_key(key: &str) -> String {
    format!("display.{key}")
}
fn console_key(console: &str, key: &str) -> String {
    format!("display.console.{console}.{key}")
}
fn game_key(group: &str, key: &str) -> String {
    format!("display.game.{group}.{key}")
}

/// Where a value is kept: for all games, a console, or one game.
pub enum Scope<'a> {
    All,
    Console(&'a str),
    Game(&'a str),
}

fn own(app: &Shared, scope: &Scope, key: &str) -> Option<String> {
    let k = match scope {
        Scope::All => global_key(key),
        Scope::Console(c) => console_key(c, key),
        Scope::Game(g) => game_key(g, key),
    };
    app.db.setting(&k).filter(|v| valid(key, v))
}

/// The values for a game (its own, else its console's, else for all games, else the default).
pub fn resolve(app: &Shared, console: &str, group: &str) -> Map<String, Value> {
    let mut m = Map::new();
    for (k, _, d) in KEYS {
        let v = own(app, &Scope::Game(group), k)
            .or_else(|| own(app, &Scope::Console(console), k))
            .or_else(|| own(app, &Scope::All, k))
            .unwrap_or_else(|| d.to_string());
        m.insert(k.to_string(), json!(v));
    }
    m
}

/// The values kept at a scope and those in effect there.
pub fn view(app: &Shared, scope: Scope, console: &str) -> Value {
    let owned: Map<String, Value> = KEYS.iter().filter_map(|(k, _, _)| own(app, &scope, k).map(|v| (k.to_string(), json!(v)))).collect();
    let effective = match scope {
        Scope::Game(g) => resolve(app, console, g),
        Scope::Console(c) => resolve(app, c, "\u{0}"),
        Scope::All => resolve(app, "\u{0}", "\u{0}"),
    };
    json!({
        "keys": KEYS.iter().map(|(k, vals, _)| json!({ "key": k, "values": vals })).collect::<Vec<_>>(),
        "own": owned,
        "effective": effective,
        "global": resolve(app, "\u{0}", "\u{0}"),
    })
}

pub fn set(app: &Shared, scope: Scope, key: &str, value: &str) -> Result<(), String> {
    default_of(key).ok_or("unknown setting")?;
    let k = match &scope {
        Scope::All => global_key(key),
        Scope::Console(c) => console_key(c, key),
        Scope::Game(g) => game_key(g, key),
    };
    if value == "default" && !matches!(scope, Scope::All) {
        app.db.set_setting(&k, "");
        return Ok(());
    }
    if !valid(key, value) {
        return Err("unknown value".into());
    }
    app.db.set_setting(&k, value);
    Ok(())
}

fn s<'a>(m: &'a Map<String, Value>, k: &str) -> &'a str {
    m.get(k).and_then(|v| v.as_str()).unwrap_or("")
}

/// RetroArch settings for these values. `crt`: the CRT shader preset, when it is installed.
pub fn retroarch(m: &Map<String, Value>, crt: Option<&Path>) -> Vec<(String, String)> {
    let aspect = match s(m, "aspect") {
        "4:3" => "0",
        "16:9" => "1",
        "stretch" => "24",
        _ => "22", // the core's own
    };
    let crt = crt.filter(|_| s(m, "smooth") == "crt");
    let mut v = vec![
        ("aspect_ratio_index".to_string(), aspect.to_string()),
        ("video_smooth".into(), (s(m, "smooth") != "sharp").to_string()),
        ("video_scale_integer".into(), (s(m, "integer") == "on").to_string()),
        ("fps_show".into(), (s(m, "fps") == "on").to_string()),
        ("video_font_enable".into(), (s(m, "fps") == "on").to_string()),
        ("video_shader_enable".into(), crt.is_some().to_string()),
        ("auto_shaders_enable".into(), "false".into()),
    ];
    if let Some(p) = crt {
        v.push(("video_shader".into(), p.to_string_lossy().into_owned()));
        // Slang shaders need a modern video driver (OpenGL core or Metal).
        if cfg!(target_os = "linux") {
            v.push(("video_driver".into(), "glcore".into()));
        }
    }
    v
}

/// Sets `Section:` / `  Key: value` lines in a YAML file such as RPCS3's config.yml.
pub fn yaml_set(path: &Path, values: &[(&str, &str, &str)]) -> Result<(), String> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut lines: Vec<String> = text.lines().map(String::from).collect();
    for (section, key, value) in values {
        let header = format!("{section}:");
        let start = match lines.iter().position(|l| l.trim_end() == header) {
            Some(i) => i,
            None => {
                lines.push(header.clone());
                lines.len() - 1
            }
        };
        let end = lines[start + 1..]
            .iter()
            .position(|l| !l.starts_with(' ') && !l.trim().is_empty())
            .map(|i| start + 1 + i)
            .unwrap_or(lines.len());
        let line = format!("  {key}: {value}");
        match lines[start + 1..end]
            .iter()
            .position(|l| l.starts_with("  ") && !l.starts_with("   ") && l.trim_start().starts_with(&format!("{key}:")))
        {
            Some(i) => lines[start + 1 + i] = line,
            None => lines.insert(end, line),
        }
    }
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    std::fs::write(path, lines.join("\n") + "\n").map_err(|e| e.to_string())
}

/// Sets keys of a JSON file that already exists (Ryubing's Config.json is created by Ryubing on
/// its first start; a partial file would be thrown away).
fn json_patch(path: &Path, values: &[(&str, Value)]) -> Result<(), String> {
    let Ok(text) = std::fs::read_to_string(path) else { return Ok(()) };
    let Ok(mut v) = serde_json::from_str::<Value>(&text) else { return Ok(()) };
    for (k, val) in values {
        v[*k] = val.clone();
    }
    std::fs::write(path, serde_json::to_string_pretty(&v).unwrap()).map_err(|e| e.to_string())
}

/// Writes the values into a standalone emulator's configuration (its Borne-owned folder).
pub fn apply(program: &str, data: &Path, userdir: &Path, m: &Map<String, Value>) -> Result<(), String> {
    let up = s(m, "upscale");
    let fps = s(m, "fps") == "on";
    let ini = crate::emulators::ini_set;
    match program {
        "dolphin" => {
            let aspect = match s(m, "aspect") {
                "16:9" => "1",
                "4:3" => "2",
                "stretch" => "3",
                _ => "0",
            };
            ini(&userdir.join("Config/GFX.ini"), &[("Settings", "InternalResolution", up), ("Settings", "AspectRatio", aspect)])?;
            ini(
                &userdir.join("Config/Dolphin.ini"),
                &[
                    ("Interface", "ShowFPS", if fps { "True" } else { "False" }),
                    ("Interface", "ConfirmStop", "False"),
                    ("Display", "Fullscreen", "True"),
                ],
            )
        }
        "pcsx2" => {
            let aspect = match s(m, "aspect") {
                "4:3" => "4:3",
                "16:9" => "16:9",
                "stretch" => "Stretch",
                _ => "Auto 4:3/3:2",
            };
            ini(
                &data.join("PCSX2/inis/PCSX2.ini"),
                &[
                    ("EmuCore/GS", "upscale_multiplier", up),
                    ("EmuCore/GS", "AspectRatio", aspect),
                    ("EmuCore/GS", "OsdShowFPS", if fps { "true" } else { "false" }),
                    ("UI", "ConfirmShutdown", "false"),
                    // Its first-run wizard never shows: the version must be there, or PCSX2
                    // takes the file for an old one and starts over with its wizard.
                    ("UI", "SettingsVersion", "1"),
                    ("UI", "SetupWizardIncomplete", "false"),
                    ("UI", "StartFullscreen", "true"),
                    ("UI", "HideMouseCursor", "true"),
                    ("AutoUpdater", "CheckAtStartup", "false"),
                ],
            )
        }
        "duckstation" => {
            let aspect = match s(m, "aspect") {
                "4:3" => "4:3",
                "16:9" => "16:9",
                "stretch" => "Stretch To Fill",
                _ => "Auto (Game Native)",
            };
            ini(
                &data.join("data/duckstation/settings.ini"),
                &[
                    ("GPU", "ResolutionScale", up),
                    ("Display", "AspectRatio", aspect),
                    ("Display", "ShowFPS", if fps { "true" } else { "false" }),
                    ("Main", "ConfirmPowerOff", "false"),
                    // No first-run wizard (the version kept, or DuckStation resets the file).
                    ("Main", "SettingsVersion", "3"),
                    ("Main", "SetupWizardIncomplete", "false"),
                    ("Main", "StartFullscreen", "true"),
                    ("Main", "HideCursorInFullscreen", "true"),
                    ("AutoUpdater", "CheckAtStartup", "false"),
                ],
            )
        }
        "eden" | "citron" => {
            // qt-config.ini: each value with its "\\default=false" line, or it is not used.
            let res = match up {
                "1" => "2",
                "3" => "5",
                "4" => "6",
                _ => "4",
            };
            let aspect = match s(m, "aspect") {
                "4:3" => "1",
                "stretch" => "4",
                _ => "0",
            };
            let path = if cfg!(target_os = "macos") {
                data.join("config/qt-config.ini")
            } else {
                userdir.join("config").join(program).join("qt-config.ini")
            };
            ini(
                &path,
                &[
                    ("Renderer", "resolution_setup\\default", "false"),
                    ("Renderer", "resolution_setup", res),
                    ("Renderer", "aspect_ratio\\default", "false"),
                    ("Renderer", "aspect_ratio", aspect),
                    ("UI", "fullscreen\\default", "false"),
                    ("UI", "fullscreen", "true"),
                    ("UI", "confirmClose\\default", "false"),
                    ("UI", "confirmClose", "false"),
                ],
            )
        }
        "ryubing" => {
            let aspect = match s(m, "aspect") {
                "4:3" => "Fixed4x3",
                "stretch" => "Stretched",
                _ => "Fixed16x9",
            };
            json_patch(
                &data.join("Config.json"),
                &[
                    ("res_scale", json!(up.parse::<i64>().unwrap_or(2))),
                    ("aspect_ratio", json!(aspect)),
                    ("start_fullscreen", json!(true)),
                    ("show_confirm_exit", json!(false)),
                ],
            )
        }
        "rpcs3" => {
            // No welcome window, no update check, no "really quit?" (GUI settings).
            ini(
                &data.join("GuiConfigs/CurrentSettings.ini"),
                &[
                    ("main_window", "infoBoxEnabledWelcome", "false"),
                    ("main_window", "confirmationBoxExitGame", "false"),
                    ("Meta", "checkUpdateStart", "false"),
                ],
            )?;
            let scale = (up.parse::<u32>().unwrap_or(1) * 100).to_string();
            let aspect = if s(m, "aspect") == "4:3" { "4:3" } else { "16:9" };
            yaml_set(
                &data.join("config.yml"),
                &[
                    ("Video", "Resolution Scale", &scale),
                    ("Video", "Aspect ratio", aspect),
                    ("Video", "Stretch To Display Area", if s(m, "aspect") == "stretch" { "true" } else { "false" }),
                ],
            )
        }
        _ => Ok(()),
    }
}

// ---------- Emulator options of one game ----------
//
// Settings of the emulator itself, chosen for one game (a widescreen hack, docked mode, rewind…):
// (program, key, values, default). Written before every game of that program, the default when
// the game has none, so one game's choice never leaks into the next.
pub const EMU_OPTIONS: &[(&str, &str, &[&str], &str)] = &[
    ("retroarch", "rewind", &["off", "on"], "off"),
    ("retroarch", "runahead", &["off", "1", "2"], "off"),
    ("dolphin", "widescreen", &["off", "on"], "off"),
    ("dolphin", "overclock", &["off", "150", "200"], "off"),
    ("pcsx2", "widescreen", &["off", "on"], "off"),
    ("pcsx2", "renderer", &["auto", "software"], "auto"),
    ("duckstation", "widescreen", &["off", "on"], "off"),
    ("duckstation", "pgxp", &["off", "on"], "off"),
    ("duckstation", "filtering", &["nearest", "bilinear"], "nearest"),
    ("eden", "docked", &["on", "off"], "on"),
    ("citron", "docked", &["on", "off"], "on"),
    ("ryubing", "docked", &["on", "off"], "on"),
    ("rpcs3", "colorbuffers", &["off", "on"], "off"),
    ("melonds", "console", &["ds", "dsi"], "ds"),
    ("melonds", "renderer", &["software", "opengl"], "software"),
    ("melonds", "jit", &["off", "on"], "off"),
    ("xenia", "license", &["trial", "full"], "trial"),
    ("xenia", "vsync", &["on", "off"], "on"),
    ("shadps4", "pro", &["off", "on"], "off"),
    ("shadps4", "trophies", &["on", "off"], "on"),
];

/// Command-line flags for a game's options (Xenia takes its settings on the command line).
pub fn emu_args(program: &str, m: &Map<String, Value>) -> Vec<String> {
    match program {
        "xenia" => {
            vec![format!("--license_mask={}", if s(m, "license") == "full" { 1 } else { 0 }), format!("--vsync={}", s(m, "vsync") != "off")]
        }
        _ => vec![],
    }
}

fn emu_key(group: &str, program: &str, key: &str) -> String {
    format!("emuopt.{group}.{program}.{key}")
}

fn emu_own(app: &Shared, group: &str, program: &str, key: &str, values: &[&str]) -> Option<String> {
    app.db.setting(&emu_key(group, program, key)).filter(|v| values.contains(&v.as_str()))
}

/// The emulator options in effect for a game run by `program`.
pub fn emu_options(app: &Shared, program: &str, group: &str) -> Map<String, Value> {
    EMU_OPTIONS
        .iter()
        .filter(|o| o.0 == program)
        .map(|(p, k, vals, d)| (k.to_string(), json!(emu_own(app, group, p, k, vals).unwrap_or_else(|| d.to_string()))))
        .collect()
}

/// The options offered for a game run by `program`: each with its values, the one in effect and
/// whether the game has its own.
pub fn emu_view(app: &Shared, program: &str, group: &str) -> Value {
    let list: Vec<Value> = EMU_OPTIONS
        .iter()
        .filter(|o| o.0 == program)
        .map(|(p, k, vals, d)| {
            let own = emu_own(app, group, p, k, vals);
            json!({ "key": k, "values": vals, "default": d, "value": own.clone().unwrap_or_else(|| d.to_string()), "own": own.is_some() })
        })
        .collect();
    json!({ "program": program, "options": list })
}

/// Sets a game's option ("default" removes it).
pub fn emu_set(app: &Shared, program: &str, group: &str, key: &str, value: &str) -> Result<(), String> {
    let (_, _, vals, _) = EMU_OPTIONS.iter().find(|o| o.0 == program && o.1 == key).ok_or("unknown option")?;
    if value == "default" {
        app.db.set_setting(&emu_key(group, program, key), "");
        return Ok(());
    }
    if !vals.contains(&value) {
        return Err("unknown value".into());
    }
    app.db.set_setting(&emu_key(group, program, key), value);
    Ok(())
}

/// RetroArch settings for a game's options.
pub fn emu_retroarch(m: &Map<String, Value>) -> Vec<(String, String)> {
    let ahead = s(m, "runahead");
    vec![
        ("rewind_enable".to_string(), (s(m, "rewind") == "on").to_string()),
        ("run_ahead_enabled".into(), (ahead != "off" && !ahead.is_empty()).to_string()),
        ("run_ahead_frames".into(), if ahead == "2" { "2".into() } else { "1".into() }),
    ]
}

/// Writes a game's options into a standalone emulator's configuration (its Borne-owned folder).
pub fn emu_apply(program: &str, data: &Path, userdir: &Path, m: &Map<String, Value>) -> Result<(), String> {
    let ini = crate::emulators::ini_set;
    let on = |k: &str| s(m, k) == "on";
    match program {
        "dolphin" => {
            let oc = s(m, "overclock");
            let ratio = match oc {
                "150" => "1.5",
                "200" => "2",
                _ => "1",
            };
            ini(&userdir.join("Config/GFX.ini"), &[("Settings", "wideScreenHack", if on("widescreen") { "True" } else { "False" })])?;
            ini(
                &userdir.join("Config/Dolphin.ini"),
                &[("Core", "OverclockEnable", if oc == "off" { "False" } else { "True" }), ("Core", "Overclock", ratio)],
            )
        }
        "pcsx2" => ini(
            &data.join("PCSX2/inis/PCSX2.ini"),
            &[
                ("EmuCore", "EnableWideScreenPatches", if on("widescreen") { "true" } else { "false" }),
                ("EmuCore/GS", "Renderer", if s(m, "renderer") == "software" { "13" } else { "-1" }),
            ],
        ),
        "duckstation" => ini(
            &data.join("data/duckstation/settings.ini"),
            &[
                ("GPU", "WidescreenHack", if on("widescreen") { "true" } else { "false" }),
                ("GPU", "PGXPEnable", if on("pgxp") { "true" } else { "false" }),
                ("GPU", "TextureFilter", if s(m, "filtering") == "bilinear" { "Bilinear" } else { "Nearest" }),
            ],
        ),
        "eden" | "citron" => {
            let path = if cfg!(target_os = "macos") {
                data.join("config/qt-config.ini")
            } else {
                userdir.join("config").join(program).join("qt-config.ini")
            };
            ini(
                &path,
                &[
                    ("System", "use_docked_mode\\default", "false"),
                    ("System", "use_docked_mode", if s(m, "docked") == "off" { "false" } else { "true" }),
                ],
            )
        }
        "ryubing" => json_patch(&data.join("Config.json"), &[("docked_mode", json!(s(m, "docked") != "off"))]),
        "rpcs3" => {
            yaml_set(&data.join("config.yml"), &[("Video", "Write Color Buffers", if on("colorbuffers") { "true" } else { "false" })])
        }
        // melonDS 1.x: melonDS.toml in its config folder (per profile on Linux).
        "melonds" => {
            let file =
                [data.join("config/melonDS/melonDS.toml"), data.join("melonDS.toml")].into_iter().find(|f| f.exists()).unwrap_or_else(
                    || if cfg!(target_os = "macos") { data.join("melonDS.toml") } else { data.join("config/melonDS/melonDS.toml") },
                );
            ini(
                &file,
                &[
                    ("Emu", "ConsoleType", if s(m, "console") == "dsi" { "1" } else { "0" }),
                    ("3D", "Renderer", if s(m, "renderer") == "opengl" { "1" } else { "0" }),
                    ("JIT", "Enable", if on("jit") { "true" } else { "false" }),
                ],
            )
        }
        "shadps4" => ini(
            &data.join("config.toml"),
            &[
                ("General", "isPS4Pro", if on("pro") { "true" } else { "false" }),
                ("General", "isTrophyPopupDisabled", if s(m, "trophies") == "off" { "true" } else { "false" }),
            ],
        ),
        _ => Ok(()),
    }
}

/// The controller of a standalone emulator, written before each game so that every emulator plays
/// on the gamepad without being set up: player 1 on the chosen pad (`index`, `pad`, `guid` as SDL
/// sees it), each console button on the pad button of the same place, as the game's controls say
/// (`src`: which pad button gives each pad-space button, None when none does; see controls.rs).
pub fn controllers(
    program: &str,
    data: &Path,
    userdir: &Path,
    index: usize,
    pad: Option<&str>,
    guid: Option<&str>,
    src: &dyn Fn(&str) -> Option<&'static str>,
) -> Result<(), String> {
    let ini = crate::emulators::ini_set;
    // A console button bound to the pad button that gives `logical`, in the emulator's own names
    // (`names`: pad-space name → its word); "" when no pad button does.
    let bind = |logical: &str, names: &dyn Fn(&str) -> String| src(logical).map(names).unwrap_or_default();
    match program {
        "dolphin" => {
            let Some(pad) = pad else { return Ok(()) };
            let path = userdir.join("Config/GCPadNew.ini");
            let n = |b: &str| {
                format!(
                    "`{}`",
                    match b {
                        "a" => "Button S",
                        "b" => "Button E",
                        "x" => "Button W",
                        "y" => "Button N",
                        "l" => "Shoulder L",
                        "r" => "Shoulder R",
                        "l2" => "Trigger L",
                        "r2" => "Trigger R",
                        "start" => "Start",
                        _ => "Back",
                    }
                )
            };
            let q = |x: &str| format!("`{x}`");
            let pairs: Vec<(String, String)> = vec![
                ("Device".into(), format!("SDL/{index}/{pad}")),
                ("Buttons/A".into(), bind("a", &n)),
                ("Buttons/B".into(), bind("x", &n)),
                ("Buttons/X".into(), bind("b", &n)),
                ("Buttons/Y".into(), bind("y", &n)),
                ("Buttons/Z".into(), bind("r", &n)),
                ("Buttons/Start".into(), bind("start", &n)),
                ("Main Stick/Up".into(), q("Left Y+")),
                ("Main Stick/Down".into(), q("Left Y-")),
                ("Main Stick/Left".into(), q("Left X-")),
                ("Main Stick/Right".into(), q("Left X+")),
                ("C-Stick/Up".into(), q("Right Y+")),
                ("C-Stick/Down".into(), q("Right Y-")),
                ("C-Stick/Left".into(), q("Right X-")),
                ("C-Stick/Right".into(), q("Right X+")),
                ("Triggers/L".into(), bind("l2", &n)),
                ("Triggers/R".into(), bind("r2", &n)),
                ("Triggers/L-Analog".into(), bind("l2", &n)),
                ("Triggers/R-Analog".into(), bind("r2", &n)),
                ("D-Pad/Up".into(), q("Pad N")),
                ("D-Pad/Down".into(), q("Pad S")),
                ("D-Pad/Left".into(), q("Pad W")),
                ("D-Pad/Right".into(), q("Pad E")),
            ];
            let v: Vec<(&str, &str, &str)> = pairs.iter().map(|(k, x)| ("GCPad1", k.as_str(), x.as_str())).collect();
            ini(&path, &v)?;
            // Wii: an emulated Wii Remote with its Nunchuk on the same pad, the pointer on the
            // right stick (most Wii games need both); the other three remotes off.
            let wii: Vec<(String, String)> = vec![
                ("Device".into(), format!("SDL/{index}/{pad}")),
                ("Source".into(), "1".into()),
                ("Extension".into(), "Nunchuk".into()),
                ("Buttons/A".into(), bind("a", &n)),
                ("Buttons/B".into(), bind("r2", &n)),
                ("Buttons/1".into(), bind("x", &n)),
                ("Buttons/2".into(), bind("y", &n)),
                ("Buttons/-".into(), bind("select", &n)),
                ("Buttons/+".into(), bind("start", &n)),
                ("Buttons/Home".into(), q("Guide")),
                ("D-Pad/Up".into(), q("Pad N")),
                ("D-Pad/Down".into(), q("Pad S")),
                ("D-Pad/Left".into(), q("Pad W")),
                ("D-Pad/Right".into(), q("Pad E")),
                ("IR/Up".into(), q("Right Y+")),
                ("IR/Down".into(), q("Right Y-")),
                ("IR/Left".into(), q("Right X-")),
                ("IR/Right".into(), q("Right X+")),
                ("Shake/X".into(), bind("b", &n)),
                ("Shake/Y".into(), bind("b", &n)),
                ("Shake/Z".into(), bind("b", &n)),
                ("Nunchuk/Buttons/C".into(), bind("l", &n)),
                ("Nunchuk/Buttons/Z".into(), bind("l2", &n)),
                ("Nunchuk/Stick/Up".into(), q("Left Y+")),
                ("Nunchuk/Stick/Down".into(), q("Left Y-")),
                ("Nunchuk/Stick/Left".into(), q("Left X-")),
                ("Nunchuk/Stick/Right".into(), q("Left X+")),
                ("Nunchuk/Shake/X".into(), bind("r", &n)),
                ("Nunchuk/Shake/Y".into(), bind("r", &n)),
                ("Nunchuk/Shake/Z".into(), bind("r", &n)),
            ];
            let mut v: Vec<(&str, &str, &str)> = wii.iter().map(|(k, x)| ("Wiimote1", k.as_str(), x.as_str())).collect();
            v.extend([("Wiimote2", "Source", "0"), ("Wiimote3", "Source", "0"), ("Wiimote4", "Source", "0")]);
            ini(&userdir.join("Config/WiimoteNew.ini"), &v)
        }
        "pcsx2" | "duckstation" => {
            let path = if program == "pcsx2" { data.join("PCSX2/inis/PCSX2.ini") } else { data.join("data/duckstation/settings.ini") };
            let dev = format!("SDL-{index}");
            let n = |b: &str| {
                let w = match b {
                    "a" => "FaceSouth",
                    "b" => "FaceEast",
                    "x" => "FaceWest",
                    "y" => "FaceNorth",
                    "l" => "LeftShoulder",
                    "r" => "RightShoulder",
                    "l2" => "+LeftTrigger",
                    "r2" => "+RightTrigger",
                    "start" => "Start",
                    _ => "Back",
                };
                format!("{dev}/{w}")
            };
            let fixed = |w: &str| format!("{dev}/{w}");
            let kind = if program == "pcsx2" { "DualShock2" } else { "AnalogController" };
            let map: Vec<(&str, String)> = vec![
                ("Type", kind.into()),
                ("Up", fixed("DPadUp")),
                ("Right", fixed("DPadRight")),
                ("Down", fixed("DPadDown")),
                ("Left", fixed("DPadLeft")),
                ("Triangle", bind("y", &n)),
                ("Circle", bind("b", &n)),
                ("Cross", bind("a", &n)),
                ("Square", bind("x", &n)),
                ("Select", bind("select", &n)),
                ("Start", bind("start", &n)),
                ("L1", bind("l", &n)),
                ("L2", bind("l2", &n)),
                ("R1", bind("r", &n)),
                ("R2", bind("r2", &n)),
                ("L3", fixed("LeftStick")),
                ("R3", fixed("RightStick")),
                ("LUp", fixed("-LeftY")),
                ("LRight", fixed("+LeftX")),
                ("LDown", fixed("+LeftY")),
                ("LLeft", fixed("-LeftX")),
                ("RUp", fixed("-RightY")),
                ("RRight", fixed("+RightX")),
                ("RDown", fixed("+RightY")),
                ("RLeft", fixed("-RightX")),
                ("SmallMotor", fixed("SmallMotor")),
                ("LargeMotor", fixed("LargeMotor")),
            ];
            let mut v: Vec<(&str, &str, &str)> = map.iter().map(|(k, x)| ("Pad1", *k, x.as_str())).collect();
            v.push(("InputSources", "SDL", "true"));
            ini(&path, &v)
        }
        // Eden / Citron (and Azahar, the same input code): player 1 on the SDL gamepad by its
        // GUID, buttons by position like Nintendo's (their A on the right).
        "eden" | "citron" | "azahar" => {
            let (Some(_), Some(guid)) = (pad, guid) else { return Ok(()) };
            let (path, prefix) = match program {
                "azahar" => (
                    if cfg!(target_os = "macos") {
                        data.join("config/qt-config.ini")
                    } else {
                        userdir.join("config/azahar-emu/qt-config.ini")
                    },
                    "profiles\\1\\",
                ),
                _ if cfg!(target_os = "macos") => (data.join("config/qt-config.ini"), "player_0_"),
                _ => (userdir.join("config").join(program).join("qt-config.ini"), "player_0_"),
            };
            let p = |extra: &str| format!("\"{extra},guid:{guid},port:{index},engine:sdl\"");
            let n = |b: &str| {
                p(match b {
                    "a" => "button:0",
                    "b" => "button:1",
                    "x" => "button:2",
                    "y" => "button:3",
                    "l" => "button:9",
                    "r" => "button:10",
                    "l2" => "axis:4,threshold:0.500000,invert:+",
                    "r2" => "axis:5,threshold:0.500000,invert:+",
                    "start" => "button:6",
                    _ => "button:4",
                })
            };
            let none = "\"[empty]\"".to_string();
            let b = |logical: &str| src(logical).map(n).unwrap_or_else(|| none.clone());
            let (start, select) = if program == "azahar" { ("start", "select") } else { ("plus", "minus") };
            let mut pairs: Vec<(String, String)> = vec![
                ("button_a".into(), b("b")),
                ("button_b".into(), b("a")),
                ("button_x".into(), b("y")),
                ("button_y".into(), b("x")),
                ("button_l".into(), b("l")),
                ("button_r".into(), b("r")),
                ("button_zl".into(), b("l2")),
                ("button_zr".into(), b("r2")),
                (format!("button_{start}"), b("start")),
                (format!("button_{select}"), b("select")),
                ("button_dleft".into(), p("button:13")),
                ("button_dup".into(), p("button:11")),
                ("button_dright".into(), p("button:14")),
                ("button_ddown".into(), p("button:12")),
            ];
            if program == "azahar" {
                for (k, _) in pairs.iter_mut() {
                    *k = k
                        .replace("button_dleft", "button_left")
                        .replace("button_dup", "button_up")
                        .replace("button_dright", "button_right")
                        .replace("button_ddown", "button_down");
                }
                pairs.push(("circle_pad".into(), p("axis_x:0,axis_y:1,deadzone:0.150000")));
                pairs.push(("c_stick".into(), p("axis_x:2,axis_y:3,deadzone:0.150000")));
            } else {
                pairs.push(("button_lstick".into(), p("button:7")));
                pairs.push(("button_rstick".into(), p("button:8")));
                pairs.push(("lstick".into(), p("axis_x:0,axis_y:1,deadzone:0.150000,range:1.000000")));
                pairs.push(("rstick".into(), p("axis_x:2,axis_y:3,deadzone:0.150000,range:1.000000")));
                pairs.push(("type".into(), "0".into()));
                pairs.push(("connected".into(), "true".into()));
            }
            let mut v: Vec<(String, String)> = vec![];
            for (k, x) in pairs {
                v.push((format!("{prefix}{k}\\default"), "false".into()));
                v.push((format!("{prefix}{k}"), x));
            }
            let refs: Vec<(&str, &str, &str)> = v.iter().map(|(k, x)| ("Controls", k.as_str(), x.as_str())).collect();
            ini(&path, &refs)
        }
        // Ryujinx: player 1 as a Pro Controller on the SDL pad, in the Config.json Ryujinx made on
        // its first start.
        "ryubing" => {
            let (Some(_), Some(guid)) = (pad, guid) else { return Ok(()) };
            let path = data.join("Config.json");
            let Ok(text) = std::fs::read_to_string(&path) else { return Ok(()) };
            let Ok(mut cfg) = serde_json::from_str::<serde_json::Value>(&text) else { return Ok(()) };
            let list = cfg["input_config"].as_array().cloned().unwrap_or_default();
            let Some(id) = dotnet_guid(guid) else { return Ok(()) };
            let n = |b: &str| {
                match b {
                    "a" => "A",
                    "b" => "B",
                    "x" => "X",
                    "y" => "Y",
                    "l" => "LeftShoulder",
                    "r" => "RightShoulder",
                    "l2" => "LeftTrigger",
                    "r2" => "RightTrigger",
                    "start" => "Start",
                    _ => "Back",
                }
                .to_string()
            };
            let b = |logical: &str| src(logical).map(n).unwrap_or_else(|| "Unbound".into());
            let pad_cfg = serde_json::json!({
                "left_joycon_stick": { "joystick": "Left", "invert_stick_x": false, "invert_stick_y": false, "rotate90_cw": false, "stick_button": "LeftStick" },
                "right_joycon_stick": { "joystick": "Right", "invert_stick_x": false, "invert_stick_y": false, "rotate90_cw": false, "stick_button": "RightStick" },
                "deadzone_left": 0.1, "deadzone_right": 0.1, "range_left": 1.0, "range_right": 1.0, "trigger_threshold": 0.5,
                "motion": { "motion_backend": "GamepadDriver", "sensitivity": 100, "gyro_deadzone": 1, "enable_motion": true },
                "rumble": { "strong_rumble": 1.0, "weak_rumble": 1.0, "enable_rumble": false },
                "left_joycon": { "button_minus": b("select"), "button_l": b("l"), "button_zl": b("l2"), "button_sl": "Unbound", "button_sr": "Unbound",
                                 "dpad_up": "DpadUp", "dpad_down": "DpadDown", "dpad_left": "DpadLeft", "dpad_right": "DpadRight" },
                "right_joycon": { "button_plus": b("start"), "button_r": b("r"), "button_zr": b("r2"), "button_sl": "Unbound", "button_sr": "Unbound",
                                  "button_x": b("y"), "button_b": b("a"), "button_y": b("x"), "button_a": b("b") },
                "version": 1, "backend": "GamepadSDL2", "id": format!("{index}-{id}"), "controller_type": "ProController", "player_index": "Player1"
            });
            let mut rest: Vec<serde_json::Value> = list.into_iter().filter(|c| c["player_index"].as_str() != Some("Player1")).collect();
            rest.insert(0, pad_cfg);
            cfg["input_config"] = serde_json::Value::Array(rest);
            std::fs::write(&path, serde_json::to_string_pretty(&cfg).unwrap_or_default()).map_err(|e| e.to_string())
        }
        // RPCS3: player 1 on the SDL handler, buttons by the game's controls.
        "rpcs3" => {
            let Some(pad) = pad else { return Ok(()) };
            let path = data.join("input_configs/global/Default.yml");
            let _ = std::fs::create_dir_all(path.parent().unwrap());
            let n = |b: &str| {
                match b {
                    "a" => "A",
                    "b" => "B",
                    "x" => "X",
                    "y" => "Y",
                    "l" => "LB",
                    "r" => "RB",
                    "l2" => "LT",
                    "r2" => "RT",
                    "start" => "Start",
                    _ => "Back",
                }
                .to_string()
            };
            let b = |logical: &str| format!("\"{}\"", src(logical).map(n).unwrap_or_default());
            let yml = format!(
                "Player 1 Input:\n  Handler: SDL\n  Device: {pad} {}\n  Profile: Default\n  Config:\n    Cross: {}\n    Circle: {}\n    Square: {}\n    Triangle: {}\n    L1: {}\n    R1: {}\n    L2: {}\n    R2: {}\n    Start: {}\n    Select: {}\n  Buddy Device: \"\"\n",
                index + 1,
                b("a"),
                b("b"),
                b("x"),
                b("y"),
                b("l"),
                b("r"),
                b("l2"),
                b("r2"),
                b("start"),
                b("select")
            );
            std::fs::write(&path, yml).map_err(|e| e.to_string())
        }
        _ => Ok(()),
    }
}

/// An SDL GUID (32 hex digits) as .NET writes a Guid made from those 16 bytes (the first three
/// groups little endian), the form Ryujinx names gamepads with.
fn dotnet_guid(sdl: &str) -> Option<String> {
    if sdl.len() != 32 || !sdl.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let b: Vec<u8> = (0..16).map(|i| u8::from_str_radix(&sdl[2 * i..2 * i + 2], 16).unwrap()).collect();
    let h = |r: &[u8]| r.iter().map(|x| format!("{x:02x}")).collect::<String>();
    let rev = |r: &[u8]| h(&r.iter().rev().cloned().collect::<Vec<u8>>());
    Some(format!("{}-{}-{}-{}-{}", rev(&b[0..4]), rev(&b[4..6]), rev(&b[6..8]), h(&b[8..10]), h(&b[10..16])))
}

#[cfg(test)]
mod tests {
    #[test]
    fn emu_options_for_retroarch() {
        let mut m = Map::new();
        m.insert("rewind".into(), json!("on"));
        m.insert("runahead".into(), json!("2"));
        let v = emu_retroarch(&m);
        assert!(v.contains(&("rewind_enable".into(), "true".into())));
        assert!(v.contains(&("run_ahead_enabled".into(), "true".into())));
        assert!(v.contains(&("run_ahead_frames".into(), "2".into())));
        assert!(EMU_OPTIONS.iter().all(|o| o.2.contains(&o.3)));
        let mut x = Map::new();
        x.insert("license".into(), json!("full"));
        x.insert("vsync".into(), json!("off"));
        assert_eq!(emu_args("xenia", &x), vec!["--license_mask=1".to_string(), "--vsync=false".to_string()]);
        assert!(emu_args("dolphin", &x).is_empty());
    }

    use super::*;

    #[test]
    fn values_are_checked() {
        assert!(valid("aspect", "16:9") && !valid("aspect", "21:9") && !valid("nope", "1"));
        assert_eq!(default_of("upscale"), Some("2"));
    }

    #[test]
    fn retroarch_values() {
        let mut m = Map::new();
        m.insert("aspect".into(), json!("4:3"));
        m.insert("smooth".into(), json!("smooth"));
        m.insert("integer".into(), json!("on"));
        m.insert("fps".into(), json!("off"));
        let r = retroarch(&m, None);
        assert!(r.contains(&("aspect_ratio_index".into(), "0".into())));
        assert!(r.contains(&("video_smooth".into(), "true".into())));
        assert!(r.contains(&("video_scale_integer".into(), "true".into())));
    }

    #[test]
    fn yaml_values_are_set_in_their_section() {
        let p = std::env::temp_dir().join(format!("borne-yaml-{}.yml", std::process::id()));
        std::fs::write(&p, "Core:\n  PPU Decoder: Recompiler\nVideo:\n  Renderer: Vulkan\n  Resolution Scale: 100\n  Vulkan:\n    Adapter: \"\"\nAudio:\n  Renderer: Cubeb\n").unwrap();
        yaml_set(&p, &[("Video", "Resolution Scale", "300"), ("Video", "Aspect ratio", "16:9")]).unwrap();
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(
            t.contains("  Resolution Scale: 300")
                && t.contains("  Aspect ratio: 16:9")
                && t.contains("    Adapter:")
                && t.contains("Audio:\n  Renderer: Cubeb")
        );
        let _ = std::fs::remove_file(p);
    }

    #[test]
    fn ryujinx_pad() {
        assert_eq!(dotnet_guid("030000005e0400008e02000014010000").as_deref(), Some("00000003-045e-0000-8e02-000014010000"));
        let d = std::env::temp_dir().join(format!("borne-ryu-pad-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("Config.json"),
            r#"{"version": 50, "input_config": [{"backend": "WindowKeyboard", "player_index": "Player1"}]}"#,
        )
        .unwrap();
        controllers("ryubing", &d, &d, 0, Some("Pad"), Some("030000005e0400008e02000014010000"), &same).unwrap();
        let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(d.join("Config.json")).unwrap()).unwrap();
        assert_eq!(v["input_config"][0]["id"], "0-00000003-045e-0000-8e02-000014010000");
        assert_eq!(v["input_config"].as_array().unwrap().len(), 1);
        assert_eq!(v["version"], 50);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn switch_and_ps3_pads() {
        let d = std::env::temp_dir().join(format!("borne-pads-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        controllers("eden", &d, &d, 0, Some("Pad"), Some("030000005e0400008e02000014010000"), &same).unwrap();
        let ini = if cfg!(target_os = "macos") { d.join("config/qt-config.ini") } else { d.join("config/eden/qt-config.ini") };
        let t = std::fs::read_to_string(&ini).unwrap();
        assert!(t.contains("player_0_button_a = \"button:1,guid:030000005e0400008e02000014010000,port:0,engine:sdl\""));
        assert!(t.contains("player_0_button_a\\default = false"));
        controllers("rpcs3", &d, &d, 0, Some("Pad"), None, &same).unwrap();
        assert!(std::fs::read_to_string(d.join("input_configs/global/Default.yml")).unwrap().contains("Handler: SDL"));
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The game's controls as they come: each button gives itself.
    fn same(b: &str) -> Option<&'static str> {
        crate::controls::BUTTONS.iter().find(|x| x.0 == b).map(|x| x.0)
    }

    #[test]
    fn controllers_follow_the_games_controls() {
        let d = std::env::temp_dir().join(format!("borne-pad-{}", std::process::id()));
        controllers("dolphin", &d, &d, 0, Some("Xbox Series X Controller"), None, &same).unwrap();
        let t = std::fs::read_to_string(d.join("Config/GCPadNew.ini")).unwrap();
        assert!(t.contains("Device = SDL/0/Xbox Series X Controller") && t.contains("Buttons/A = `Button S`"));
        let w = std::fs::read_to_string(d.join("Config/WiimoteNew.ini")).unwrap();
        assert!(
            w.contains("[Wiimote1]")
                && w.contains("Extension = Nunchuk")
                && w.contains("IR/Up = `Right Y+`")
                && w.contains("[Wiimote2]\nSource = 0")
        );
        // A and B swapped for a game; the second pad chosen.
        let swapped = |b: &str| match b {
            "a" => Some("b"),
            "b" => Some("a"),
            other => same(other),
        };
        controllers("dolphin", &d, &d, 1, Some("Other"), None, &swapped).unwrap();
        let t = std::fs::read_to_string(d.join("Config/GCPadNew.ini")).unwrap();
        assert!(t.contains("Device = SDL/1/Other") && t.contains("Buttons/A = `Button E`"));
        controllers("pcsx2", &d, &d, 0, Some("Pad"), None, &swapped).unwrap();
        let t = std::fs::read_to_string(d.join("PCSX2/inis/PCSX2.ini")).unwrap();
        assert!(t.contains("Cross = SDL-0/FaceEast") && t.contains("Circle = SDL-0/FaceSouth"));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn dolphin_values_go_to_its_ini() {
        let d = std::env::temp_dir().join(format!("borne-gs-{}", std::process::id()));
        let mut m = Map::new();
        for (k, v) in [("aspect", "16:9"), ("upscale", "3"), ("fps", "on"), ("smooth", "sharp"), ("integer", "off")] {
            m.insert(k.into(), json!(v));
        }
        apply("dolphin", &d, &d, &m).unwrap();
        let gfx = std::fs::read_to_string(d.join("Config/GFX.ini")).unwrap();
        assert!(gfx.contains("InternalResolution = 3") && gfx.contains("AspectRatio = 1"));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn first_run_windows_are_skipped() {
        let d = std::env::temp_dir().join(format!("borne-fr-{}", std::process::id()));
        let m = Map::new();
        apply("pcsx2", &d, &d, &m).unwrap();
        apply("duckstation", &d, &d, &m).unwrap();
        apply("rpcs3", &d, &d, &m).unwrap();
        let p = std::fs::read_to_string(d.join("PCSX2/inis/PCSX2.ini")).unwrap();
        assert!(p.contains("SettingsVersion = 1") && p.contains("SetupWizardIncomplete = false"));
        let ds = std::fs::read_to_string(d.join("data/duckstation/settings.ini")).unwrap();
        assert!(ds.contains("SettingsVersion = 3") && ds.contains("SetupWizardIncomplete = false"));
        let r = std::fs::read_to_string(d.join("GuiConfigs/CurrentSettings.ini")).unwrap();
        assert!(r.contains("infoBoxEnabledWelcome = false"));
        let _ = std::fs::remove_dir_all(d);
    }
}
