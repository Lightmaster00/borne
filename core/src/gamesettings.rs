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
        let end = lines[start + 1..].iter().position(|l| !l.starts_with(' ') && !l.trim().is_empty()).map(|i| start + 1 + i).unwrap_or(lines.len());
        let line = format!("  {key}: {value}");
        match lines[start + 1..end].iter().position(|l| l.starts_with("  ") && !l.starts_with("   ") && l.trim_start().starts_with(&format!("{key}:"))) {
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
            ini(&userdir.join("Config/Dolphin.ini"), &[("Interface", "ShowFPS", if fps { "True" } else { "False" }), ("Interface", "ConfirmStop", "False"), ("Display", "Fullscreen", "True")])
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
                &[("EmuCore/GS", "upscale_multiplier", up), ("EmuCore/GS", "AspectRatio", aspect), ("EmuCore/GS", "OsdShowFPS", if fps { "true" } else { "false" }), ("UI", "ConfirmShutdown", "false")],
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
                &[("GPU", "ResolutionScale", up), ("Display", "AspectRatio", aspect), ("Display", "ShowFPS", if fps { "true" } else { "false" }), ("Main", "ConfirmPowerOff", "false")],
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
            let path = if cfg!(target_os = "macos") { data.join("config/qt-config.ini") } else { userdir.join("config").join(program).join("qt-config.ini") };
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
                &[("res_scale", json!(up.parse::<i64>().unwrap_or(2))), ("aspect_ratio", json!(aspect)), ("start_fullscreen", json!(true)), ("show_confirm_exit", json!(false))],
            )
        }
        "rpcs3" => {
            let scale = (up.parse::<u32>().unwrap_or(1) * 100).to_string();
            let aspect = if s(m, "aspect") == "4:3" { "4:3" } else { "16:9" };
            yaml_set(
                &data.join("config.yml"),
                &[("Video", "Resolution Scale", &scale), ("Video", "Aspect ratio", aspect), ("Video", "Stretch To Display Area", if s(m, "aspect") == "stretch" { "true" } else { "false" })],
            )
        }
        _ => Ok(()),
    }
}

/// First start of an emulator: its controller set to the gamepad Borne sees (SDL), so it plays at
/// once. A mapping already there (changed by the user) is kept.
pub fn controllers(program: &str, data: &Path, userdir: &Path, pad: Option<&str>, guid: Option<&str>) -> Result<(), String> {
    let has_section = |p: &Path, sec: &str| std::fs::read_to_string(p).map(|t| t.lines().any(|l| l.trim() == format!("[{sec}]"))).unwrap_or(false);
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
            let path = if cfg!(target_os = "macos") { data.join("config/qt-config.ini") } else { userdir.join("config").join(program).join("qt-config.ini") };
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            // Already on a gamepad (ours, or the user's own mapping): kept.
            if text.lines().any(|l| l.split('=').next().map(|k| k.trim() == "player_0_button_a").unwrap_or(false) && l.contains("engine:sdl")) {
                return Ok(());
            }
            let p = |extra: &str| format!("\"{extra},guid:{guid},port:0,engine:sdl\"");
            let buttons: [(&str, &str); 16] = [
                ("a", "button:1"), ("b", "button:0"), ("x", "button:3"), ("y", "button:2"),
                ("lstick", "button:7"), ("rstick", "button:8"), ("l", "button:9"), ("r", "button:10"),
                ("zl", "axis:4,threshold:0.500000,invert:+"), ("zr", "axis:5,threshold:0.500000,invert:+"),
                ("plus", "button:6"), ("minus", "button:4"),
                ("dleft", "button:13"), ("dup", "button:11"), ("dright", "button:14"), ("ddown", "button:12"),
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
        // RPCS3: player 1 on the SDL handler, its default mapping for that pad.
        "rpcs3" => {
            let Some(pad) = pad else { return Ok(()) };
            let path = data.join("input_configs/global/Default.yml");
            if path.exists() {
                return Ok(());
            }
            let _ = std::fs::create_dir_all(path.parent().unwrap());
            let yml = format!("Player 1 Input:\n  Handler: SDL\n  Device: {pad} 1\n  Profile: Default\n  Config: {{}}\n  Buddy Device: \"\"\n");
            std::fs::write(&path, yml).map_err(|e| e.to_string())
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
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
        assert!(t.contains("  Resolution Scale: 300") && t.contains("  Aspect ratio: 16:9") && t.contains("    Adapter:") && t.contains("Audio:\n  Renderer: Cubeb"));
        let _ = std::fs::remove_file(p);
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
