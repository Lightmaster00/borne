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

/// First start of an emulator: its controller set to the gamepad Borne sees (SDL), so it plays at
/// once. A mapping already there (changed by the user) is kept.
pub fn controllers(program: &str, data: &Path, userdir: &Path, pad: Option<&str>, guid: Option<&str>) -> Result<(), String> {
    let has_section =
        |p: &Path, sec: &str| std::fs::read_to_string(p).map(|t| t.lines().any(|l| l.trim() == format!("[{sec}]"))).unwrap_or(false);
    let ini = crate::emulators::ini_set;
    match program {
        "dolphin" => {
            let path = userdir.join("Config/GCPadNew.ini");
            let Some(pad) = pad else { return Ok(()) };
            if has_section(&path, "GCPad1") {
                return Ok(());
            }
            let device = format!("SDL/0/{pad}");
            let b = |x: &str| format!("`{x}`");
            let pairs: Vec<(String, String)> = vec![
                ("Device".into(), device),
                ("Buttons/A".into(), b("Button S")),
                ("Buttons/B".into(), b("Button W")),
                ("Buttons/X".into(), b("Button E")),
                ("Buttons/Y".into(), b("Button N")),
                ("Buttons/Z".into(), b("Shoulder R")),
                ("Buttons/Start".into(), "Start".into()),
                ("Main Stick/Up".into(), b("Left Y+")),
                ("Main Stick/Down".into(), b("Left Y-")),
                ("Main Stick/Left".into(), b("Left X-")),
                ("Main Stick/Right".into(), b("Left X+")),
                ("C-Stick/Up".into(), b("Right Y+")),
                ("C-Stick/Down".into(), b("Right Y-")),
                ("C-Stick/Left".into(), b("Right X-")),
                ("C-Stick/Right".into(), b("Right X+")),
                ("Triggers/L".into(), b("Trigger L")),
                ("Triggers/R".into(), b("Trigger R")),
                ("Triggers/L-Analog".into(), b("Trigger L")),
                ("Triggers/R-Analog".into(), b("Trigger R")),
                ("D-Pad/Up".into(), b("Pad N")),
                ("D-Pad/Down".into(), b("Pad S")),
                ("D-Pad/Left".into(), b("Pad W")),
                ("D-Pad/Right".into(), b("Pad E")),
            ];
            let v: Vec<(&str, &str, &str)> = pairs.iter().map(|(k, x)| ("GCPad1", k.as_str(), x.as_str())).collect();
            ini(&path, &v)
        }
        "pcsx2" | "duckstation" => {
            let path = if program == "pcsx2" { data.join("PCSX2/inis/PCSX2.ini") } else { data.join("data/duckstation/settings.ini") };
            if has_section(&path, "Pad1") {
                return Ok(());
            }
            let kind = if program == "pcsx2" { "DualShock2" } else { "AnalogController" };
            let map: [(&str, &str); 27] = [
                ("Type", kind),
                ("Up", "SDL-0/DPadUp"),
                ("Right", "SDL-0/DPadRight"),
                ("Down", "SDL-0/DPadDown"),
                ("Left", "SDL-0/DPadLeft"),
                ("Triangle", "SDL-0/FaceNorth"),
                ("Circle", "SDL-0/FaceEast"),
                ("Cross", "SDL-0/FaceSouth"),
                ("Square", "SDL-0/FaceWest"),
                ("Select", "SDL-0/Back"),
                ("Start", "SDL-0/Start"),
                ("L1", "SDL-0/LeftShoulder"),
                ("L2", "SDL-0/+LeftTrigger"),
                ("R1", "SDL-0/RightShoulder"),
                ("R2", "SDL-0/+RightTrigger"),
                ("L3", "SDL-0/LeftStick"),
                ("R3", "SDL-0/RightStick"),
                ("LUp", "SDL-0/-LeftY"),
                ("LRight", "SDL-0/+LeftX"),
                ("LDown", "SDL-0/+LeftY"),
                ("LLeft", "SDL-0/-LeftX"),
                ("RUp", "SDL-0/-RightY"),
                ("RRight", "SDL-0/+RightX"),
                ("RDown", "SDL-0/+RightY"),
                ("RLeft", "SDL-0/-RightX"),
                ("SmallMotor", "SDL-0/SmallMotor"),
                ("LargeMotor", "SDL-0/LargeMotor"),
            ];
            let mut v: Vec<(&str, &str, &str)> = map.iter().map(|(k, x)| ("Pad1", *k, *x)).collect();
            v.push(("InputSources", "SDL", "true"));
            ini(&path, &v)
        }
        // Eden / Citron: player 1 as a Pro Controller on the SDL gamepad (by its GUID), buttons by
        // position like the Switch (its A on the right).
        "eden" | "citron" => {
            let (Some(_), Some(guid)) = (pad, guid) else { return Ok(()) };
            let path = if cfg!(target_os = "macos") {
                data.join("config/qt-config.ini")
            } else {
                userdir.join("config").join(program).join("qt-config.ini")
            };
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            // Already on a gamepad (ours, or the user's own mapping): kept.
            if text
                .lines()
                .any(|l| l.split('=').next().map(|k| k.trim() == "player_0_button_a").unwrap_or(false) && l.contains("engine:sdl"))
            {
                return Ok(());
            }
            let p = |extra: &str| format!("\"{extra},guid:{guid},port:0,engine:sdl\"");
            let buttons: [(&str, &str); 16] = [
                ("a", "button:1"),
                ("b", "button:0"),
                ("x", "button:3"),
                ("y", "button:2"),
                ("lstick", "button:7"),
                ("rstick", "button:8"),
                ("l", "button:9"),
                ("r", "button:10"),
                ("zl", "axis:4,threshold:0.500000,invert:+"),
                ("zr", "axis:5,threshold:0.500000,invert:+"),
                ("plus", "button:6"),
                ("minus", "button:4"),
                ("dleft", "button:13"),
                ("dup", "button:11"),
                ("dright", "button:14"),
                ("ddown", "button:12"),
            ];
            let mut pairs: Vec<(String, String)> = buttons.iter().map(|(k, v)| (format!("player_0_button_{k}"), p(v))).collect();
            pairs.push(("player_0_lstick".into(), p("axis_x:0,axis_y:1,deadzone:0.150000,range:1.000000")));
            pairs.push(("player_0_rstick".into(), p("axis_x:2,axis_y:3,deadzone:0.150000,range:1.000000")));
            pairs.push(("player_0_type".into(), "0".into()));
            pairs.push(("player_0_connected".into(), "true".into()));
            let mut v: Vec<(String, String)> = vec![];
            for (k, x) in pairs {
                v.push((format!("{k}\\default"), "false".into()));
                v.push((k, x));
            }
            let refs: Vec<(&str, &str, &str)> = v.iter().map(|(k, x)| ("Controls", k.as_str(), x.as_str())).collect();
            ini(&path, &refs)
        }
        // Ryujinx: player 1 as a Pro Controller on the SDL pad, in the Config.json Ryujinx made on
        // its first start (kept if the user already set a gamepad).
        "ryubing" => {
            let (Some(_), Some(guid)) = (pad, guid) else { return Ok(()) };
            let path = data.join("Config.json");
            let Ok(text) = std::fs::read_to_string(&path) else { return Ok(()) };
            let Ok(mut cfg) = serde_json::from_str::<serde_json::Value>(&text) else { return Ok(()) };
            let list = cfg["input_config"].as_array().cloned().unwrap_or_default();
            if list.iter().any(|c| c["backend"].as_str() == Some("GamepadSDL2")) {
                return Ok(());
            }
            let Some(id) = dotnet_guid(guid) else { return Ok(()) };
            let pad_cfg = serde_json::json!({
                "left_joycon_stick": { "joystick": "Left", "invert_stick_x": false, "invert_stick_y": false, "rotate90_cw": false, "stick_button": "LeftStick" },
                "right_joycon_stick": { "joystick": "Right", "invert_stick_x": false, "invert_stick_y": false, "rotate90_cw": false, "stick_button": "RightStick" },
                "deadzone_left": 0.1, "deadzone_right": 0.1, "range_left": 1.0, "range_right": 1.0, "trigger_threshold": 0.5,
                "motion": { "motion_backend": "GamepadDriver", "sensitivity": 100, "gyro_deadzone": 1, "enable_motion": true },
                "rumble": { "strong_rumble": 1.0, "weak_rumble": 1.0, "enable_rumble": false },
                "left_joycon": { "button_minus": "Back", "button_l": "LeftShoulder", "button_zl": "LeftTrigger", "button_sl": "Unbound", "button_sr": "Unbound",
                                 "dpad_up": "DpadUp", "dpad_down": "DpadDown", "dpad_left": "DpadLeft", "dpad_right": "DpadRight" },
                "right_joycon": { "button_plus": "Start", "button_r": "RightShoulder", "button_zr": "RightTrigger", "button_sl": "Unbound", "button_sr": "Unbound",
                                  "button_x": "Y", "button_b": "A", "button_y": "X", "button_a": "B" },
                "version": 1, "backend": "GamepadSDL2", "id": format!("0-{id}"), "controller_type": "ProController", "player_index": "Player1"
            });
            let mut rest: Vec<serde_json::Value> = list.into_iter().filter(|c| c["player_index"].as_str() != Some("Player1")).collect();
            rest.insert(0, pad_cfg);
            cfg["input_config"] = serde_json::Value::Array(rest);
            std::fs::write(&path, serde_json::to_string_pretty(&cfg).unwrap_or_default()).map_err(|e| e.to_string())
        }
        // RPCS3: player 1 on the SDL handler, its default mapping for that pad.
        "rpcs3" => {
            let Some(pad) = pad else { return Ok(()) };
            let path = data.join("input_configs/global/Default.yml");
            if path.exists() {
                return Ok(());
            }
            let _ = std::fs::create_dir_all(path.parent().unwrap());
            let yml =
                format!("Player 1 Input:\n  Handler: SDL\n  Device: {pad} 1\n  Profile: Default\n  Config: {{}}\n  Buddy Device: \"\"\n");
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
        controllers("ryubing", &d, &d, Some("Pad"), Some("030000005e0400008e02000014010000")).unwrap();
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
        controllers("eden", &d, &d, Some("Pad"), Some("030000005e0400008e02000014010000")).unwrap();
        let ini = if cfg!(target_os = "macos") { d.join("config/qt-config.ini") } else { d.join("config/eden/qt-config.ini") };
        let t = std::fs::read_to_string(&ini).unwrap();
        assert!(t.contains("player_0_button_a = \"button:1,guid:030000005e0400008e02000014010000,port:0,engine:sdl\""));
        assert!(t.contains("player_0_button_a\\default = false"));
        controllers("rpcs3", &d, &d, Some("Pad"), None).unwrap();
        assert!(std::fs::read_to_string(d.join("input_configs/global/Default.yml")).unwrap().contains("Handler: SDL"));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn controllers_written_once() {
        let d = std::env::temp_dir().join(format!("borne-pad-{}", std::process::id()));
        controllers("dolphin", &d, &d, Some("Xbox Series X Controller"), None).unwrap();
        let t = std::fs::read_to_string(d.join("Config/GCPadNew.ini")).unwrap();
        assert!(t.contains("Device = SDL/0/Xbox Series X Controller") && t.contains("Buttons/A = `Button S`"));
        std::fs::write(d.join("Config/GCPadNew.ini"), "[GCPad1]\nDevice = mine\n").unwrap();
        controllers("dolphin", &d, &d, Some("Other"), None).unwrap();
        assert!(std::fs::read_to_string(d.join("Config/GCPadNew.ini")).unwrap().contains("Device = mine"));
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
}
