//! Display settings chosen in Borne, for all games and per game, and written into each
//! emulator's Borne-owned configuration before the game starts: the user never opens an emulator
//! to change them.
//!
//! - aspect: auto (the game's own), 4:3, 16:9, stretch
//! - upscale: 1–4 × the console's resolution (3D consoles: Dolphin, PCSX2, DuckStation, RPCS3)
//! - smooth: smooth or sharp pixels (2D consoles, RetroArch)
//! - integer: whole-number scaling, no uneven pixels (RetroArch)
//! - fps: show the frame rate
//!
//! A game's own value replaces the one for all games; "default" removes it.

use crate::state::Shared;
use serde_json::{json, Map, Value};
use std::path::Path;

pub const KEYS: [(&str, &[&str], &str); 5] = [
    ("aspect", &["auto", "4:3", "16:9", "stretch"], "auto"),
    ("upscale", &["1", "2", "3", "4"], "2"),
    ("smooth", &["sharp", "smooth"], "sharp"),
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
fn game_key(group: &str, key: &str) -> String {
    format!("display.game.{group}.{key}")
}

/// The values for a game (its own, else for all games, else the default).
pub fn resolve(app: &Shared, group: &str) -> Map<String, Value> {
    let mut m = Map::new();
    for (k, _, d) in KEYS {
        let v = app
            .db
            .setting(&game_key(group, k))
            .filter(|v| valid(k, v))
            .or_else(|| app.db.setting(&global_key(k)).filter(|v| valid(k, v)))
            .unwrap_or_else(|| d.to_string());
        m.insert(k.to_string(), json!(v));
    }
    m
}

pub fn view(app: &Shared, group: Option<&str>) -> Value {
    let global: Map<String, Value> = KEYS
        .iter()
        .map(|(k, _, d)| (k.to_string(), json!(app.db.setting(&global_key(k)).filter(|v| valid(k, v)).unwrap_or_else(|| d.to_string()))))
        .collect();
    let mut out = json!({ "keys": KEYS.iter().map(|(k, vals, _)| json!({ "key": k, "values": vals })).collect::<Vec<_>>(), "global": global });
    if let Some(g) = group {
        let own: Map<String, Value> = KEYS.iter().filter_map(|(k, _, _)| app.db.setting(&game_key(g, k)).filter(|v| valid(k, v)).map(|v| (k.to_string(), json!(v)))).collect();
        out["game"] = Value::Object(own);
        out["effective"] = Value::Object(resolve(app, g));
    }
    out
}

pub fn set(app: &Shared, group: Option<&str>, key: &str, value: &str) -> Result<(), String> {
    default_of(key).ok_or("unknown setting")?;
    match group {
        Some(g) if value == "default" => {
            app.db.set_setting(&game_key(g, key), "");
            Ok(())
        }
        Some(g) if valid(key, value) => {
            app.db.set_setting(&game_key(g, key), value);
            Ok(())
        }
        None if valid(key, value) => {
            app.db.set_setting(&global_key(key), value);
            Ok(())
        }
        _ => Err("unknown value".into()),
    }
}

fn s<'a>(m: &'a Map<String, Value>, k: &str) -> &'a str {
    m.get(k).and_then(|v| v.as_str()).unwrap_or("")
}

/// RetroArch settings for these values.
pub fn retroarch(m: &Map<String, Value>) -> Vec<(String, String)> {
    let aspect = match s(m, "aspect") {
        "4:3" => "0",
        "16:9" => "1",
        "stretch" => "24",
        _ => "22", // the core's own
    };
    vec![
        ("aspect_ratio_index".into(), aspect.into()),
        ("video_smooth".into(), (s(m, "smooth") == "smooth").to_string()),
        ("video_scale_integer".into(), (s(m, "integer") == "on").to_string()),
        ("fps_show".into(), (s(m, "fps") == "on").to_string()),
        ("video_font_enable".into(), (s(m, "fps") == "on").to_string()),
    ]
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
        let r = retroarch(&m);
        assert!(r.contains(&("aspect_ratio_index".into(), "0".into())));
        assert!(r.contains(&("video_smooth".into(), "true".into())));
        assert!(r.contains(&("video_scale_integer".into(), "true".into())));
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
