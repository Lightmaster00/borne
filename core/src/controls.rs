//! A game's controls, chosen in its settings: which controller is player 1, the face buttons as
//! they are or swapped (A↔B, X↔Y), the left stick also as the D-pad (RetroArch), and which
//! button each pad button acts as. Applied to every emulator Borne sets up: RetroArch through a
//! remap file for the game, the standalone ones through their controller settings, written before
//! each game (gamesettings::controllers).

use crate::state::Shared;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// The pad's buttons, as RetroArch's RetroPad names them, with their RetroPad ids.
pub const BUTTONS: [(&str, u8); 10] =
    [("a", 8), ("b", 0), ("x", 9), ("y", 1), ("l", 10), ("r", 11), ("l2", 12), ("r2", 13), ("start", 3), ("select", 2)];
/// The other RetroPad buttons, kept as they are in the remap file.
const OTHERS: [(&str, u8); 6] = [("up", 4), ("down", 5), ("left", 6), ("right", 7), ("l3", 14), ("r3", 15)];

/// The programs whose controller Borne writes (the others read the pad as they find it).
const APPLIES: [&str; 9] = ["retroarch", "dolphin", "pcsx2", "duckstation", "eden", "citron", "ryubing", "rpcs3", "azahar"];

/// For each pad-space button (a, b, x, y, l, r, l2, r2, start, select), the pad button that gives
/// it in this game, or None when the game's controls leave it on no button.
pub fn sources(app: &Shared, group: &str) -> Vec<(&'static str, Option<&'static str>)> {
    let m = mapping(app, group);
    BUTTONS.iter().map(|(logical, id)| (*logical, m.iter().find(|(_, target)| target == id).map(|(pad, _)| *pad))).collect()
}

/// Player 1's controller for this game: its index among the connected pads (0 when automatic).
pub fn pad_index(app: &Shared, group: &str, count: usize) -> usize {
    get(app, group, "pad").0.parse::<usize>().ok().map(|n| n - 1).filter(|i| *i < count).unwrap_or(0)
}

/// RetroArch's names of a core's library: its remaps live in a folder of that name. The display
/// name is tried too, for a core missing here.
fn library_names(core: &str, display: &str) -> Vec<String> {
    let known = match core {
        "nestopia" => "Nestopia",
        "mednafen_wswan" => "Beetle WonderSwan",
        "mednafen_ngp" => "Beetle NeoPop",
        "stella" => "Stella",
        "fbneo" => "FinalBurn Neo",
        "vecx" => "VecX",
        _ => display,
    };
    let mut v = vec![known.to_string()];
    if known != display {
        v.push(display.to_string());
    }
    v
}

fn key(group: &str, k: &str) -> String {
    format!("controls.game.{group}.{k}")
}

/// The values a setting takes; the first is the default.
fn values(k: &str) -> Vec<String> {
    match k {
        "pad" => ["auto", "1", "2", "3", "4"].iter().map(|s| s.to_string()).collect(),
        "face" => vec!["same".into(), "swap".into()],
        "stick" => vec!["stick".into(), "dpad".into()],
        _ if k.starts_with("map.") => std::iter::once("same".to_string()).chain(BUTTONS.iter().map(|b| b.0.to_string())).collect(),
        _ => vec![],
    }
}

fn keys() -> Vec<String> {
    let mut k: Vec<String> = vec!["pad".into(), "face".into(), "stick".into()];
    k.extend(BUTTONS.iter().map(|b| format!("map.{}", b.0)));
    k
}

fn get(app: &Shared, group: &str, k: &str) -> (String, bool) {
    let vals = values(k);
    match app.db.setting(&key(group, k)).filter(|v| vals.contains(v)) {
        Some(v) => (v, true),
        None => (vals[0].clone(), false),
    }
}

/// The game's controls: each setting with its values and whether the game has its own, the
/// connected controllers, and whether the game's emulator takes them (RetroArch).
pub fn view(app: &Shared, group: &str, program: &str) -> Value {
    let pads = app.pads.lock().unwrap_or_else(|e| e.into_inner()).pads.clone();
    let options: Vec<Value> = keys()
        .iter()
        .map(|k| {
            let (value, own) = get(app, group, k);
            json!({ "key": k, "value": value, "own": own, "values": values(k) })
        })
        .collect();
    json!({ "applies": APPLIES.contains(&program), "stick": program == "retroarch", "program": program, "pads": pads, "options": options })
}

pub fn set(app: &Shared, group: &str, k: &str, value: &str) -> Result<(), String> {
    let vals = values(k);
    if vals.is_empty() {
        return Err("unknown setting".into());
    }
    if value == "default" || value == vals[0] {
        app.db.set_setting(&key(group, k), "");
        return Ok(());
    }
    if !vals.iter().any(|v| v == value) {
        return Err("unknown value".into());
    }
    app.db.set_setting(&key(group, k), value);
    Ok(())
}

/// Which RetroPad button each pad button presses for this game (by RetroPad id).
fn mapping(app: &Shared, group: &str) -> Vec<(&'static str, u8)> {
    let id = |name: &str| BUTTONS.iter().find(|b| b.0 == name).map(|b| b.1);
    let swap = get(app, group, "face").0 == "swap";
    BUTTONS
        .iter()
        .map(|(name, own)| {
            let swapped = match (*name, swap) {
                ("a", true) => id("b").unwrap(),
                ("b", true) => id("a").unwrap(),
                ("x", true) => id("y").unwrap(),
                ("y", true) => id("x").unwrap(),
                _ => *own,
            };
            let chosen = get(app, group, &format!("map.{name}")).0;
            (*name, if chosen == "same" { swapped } else { id(&chosen).unwrap_or(*own) })
        })
        .collect()
}

/// RetroArch: the settings for the main configuration, and the game's remap file written under
/// `remaps` for the core (`core`, `display`: its id and name), named after the game file.
pub fn retroarch(app: &Shared, group: &str, remaps: &Path, core: &str, display: &str, rom: &Path) -> Vec<(String, String)> {
    let mut v = vec![
        ("auto_remaps_enable".to_string(), "true".to_string()),
        ("input_remap_binds_enable".into(), "true".into()),
        ("input_remapping_directory".into(), remaps.to_string_lossy().replace('"', "")),
        ("input_player1_analog_dpad_mode".into(), if get(app, group, "stick").0 == "dpad" { "1" } else { "0" }.into()),
    ];
    let pad = get(app, group, "pad").0;
    if let Ok(n) = pad.parse::<u32>() {
        v.push(("input_player1_joypad_index".into(), (n - 1).to_string()));
    }
    let stem = rom.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let mut text = String::from("input_remap_port_p1 = \"0\"\n");
    for (name, target) in mapping(app, group) {
        text.push_str(&format!("input_player1_btn_{name} = \"{target}\"\n"));
    }
    for (name, id) in OTHERS {
        text.push_str(&format!("input_player1_btn_{name} = \"{id}\"\n"));
    }
    for lib in library_names(core, display) {
        let file: PathBuf = remaps.join(&lib).join(format!("{stem}.rmp"));
        if std::fs::create_dir_all(file.parent().unwrap()).is_ok() {
            let _ = std::fs::write(&file, &text);
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_and_keys() {
        assert_eq!(values("face"), vec!["same", "swap"]);
        assert_eq!(values("map.a")[0], "same");
        assert!(values("map.a").contains(&"select".to_string()));
        assert_eq!(keys().len(), 13);
        assert!(values("nope").is_empty());
    }

    #[test]
    fn library_folders() {
        assert_eq!(library_names("mgba", "mGBA"), vec!["mGBA"]);
        assert_eq!(library_names("nestopia", "Nestopia UE"), vec!["Nestopia", "Nestopia UE"]);
    }
}
