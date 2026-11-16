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
const APPLIES: [&str; 10] = ["retroarch", "dolphin", "pcsx2", "duckstation", "eden", "citron", "ryubing", "rpcs3", "azahar", "shadps4"];

/// For each pad-space button (a, b, x, y, l, r, l2, r2, start, select), the pad button that gives
/// it in this game, or None when the game's controls leave it on no button.
pub fn sources(app: &Shared, group: &str) -> Vec<(&'static str, Option<&'static str>)> {
    let m = mapping(app, group);
    BUTTONS.iter().map(|(logical, id)| (*logical, m.iter().find(|(_, target)| target == id).map(|(pad, _)| *pad))).collect()
}

/// Player 1's controller for this game, among the `pads` connected now (with their GUIDs): the
/// pad chosen for it, found again by name and GUID wherever it is plugged now; the pad last used
/// in Borne when none was chosen (the one in the player's hands); else the first.
pub fn pad_index(app: &Shared, group: &str, pads: &[String], guids: &[String], last: Option<usize>) -> usize {
    let count = pads.len();
    let chosen = get(app, group, "pad").0.parse::<usize>().ok().and_then(|n| n.checked_sub(1));
    let id = app.db.setting(&key(group, "pad.id")).unwrap_or_default();
    if chosen.is_some() && !id.is_empty() {
        let at = |i: usize| format!("{}|{}", pads[i], guids.get(i).map(String::as_str).unwrap_or(""));
        // The same pad at the place chosen, else the first of its kind.
        if let Some(i) = chosen.filter(|i| *i < count && at(*i) == id).or_else(|| (0..count).find(|i| at(*i) == id)) {
            return i;
        }
    }
    chosen.filter(|i| *i < count).or_else(|| last.filter(|i| *i < count)).unwrap_or(0)
}

/// The players of a game: player 1's pad first, then the other connected pads in order (local
/// multiplayer), up to four.
pub fn players(app: &Shared, group: &str) -> Vec<crate::gamesettings::PadRef> {
    let (all, all_guids, ids, last) = {
        let s = app.pads.lock().unwrap_or_else(|e| e.into_inner());
        (s.pads.clone(), s.guids.clone(), s.ids.clone(), s.last)
    };
    // Started from Steam, the emulators do not see the pads Steam hides (they play through its
    // virtual pad): those are left out, and the numbering is that of the pads they see.
    let hidden = crate::pad::steam_hidden();
    let visible: Vec<usize> = (0..all.len()).filter(|i| !hidden.contains(ids.get(*i).unwrap_or(&(0, 0)))).collect();
    let pads: Vec<String> = visible.iter().map(|i| all[*i].clone()).collect();
    let guids: Vec<String> = visible.iter().filter_map(|i| all_guids.get(*i).cloned()).collect();
    if pads.is_empty() {
        return vec![];
    }
    // The pad in the player's hands (among those seen); when Steam hides it, Steam's virtual pad
    // (vendor 0x28de) stands for it.
    let last = last
        .and_then(|l| visible.iter().position(|i| *i == l))
        .or_else(|| last.and(visible.iter().position(|i| ids.get(*i).map(|x| x.0 == 0x28de).unwrap_or(false))));
    let first = pad_index(app, group, &pads, &guids, last);
    let order = std::iter::once(first).chain((0..pads.len()).filter(|i| *i != first));
    order
        .take(4)
        .map(|i| crate::gamesettings::PadRef {
            index: i,
            name: pads[i].clone(),
            guid: guids.get(i).cloned(),
            rank: pads[..=i].iter().filter(|n| **n == pads[i]).count(),
        })
        .collect()
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

/// The group under which the controls for every game are kept.
pub const ALL_GAMES: &str = "@all";

fn own(app: &Shared, group: &str, k: &str) -> Option<String> {
    let vals = values(k);
    app.db.setting(&key(group, k)).filter(|v| vals.contains(v))
}

/// What a game gets without a value of its own: the one for all games (the pad is always
/// chosen per game), else the default.
fn inherited(app: &Shared, group: &str, k: &str) -> String {
    let global = if group == ALL_GAMES || k == "pad" { None } else { own(app, ALL_GAMES, k) };
    global.unwrap_or_else(|| values(k)[0].clone())
}

fn get(app: &Shared, group: &str, k: &str) -> (String, bool) {
    match own(app, group, k) {
        Some(v) => (v, true),
        None => (inherited(app, group, k), false),
    }
}

/// The game's controls: each setting with its values and whether the game has its own, the
/// connected controllers, and whether the game's emulator takes them (RetroArch).
pub fn view(app: &Shared, group: &str, program: &str) -> Value {
    let pads = app.pads.lock().unwrap_or_else(|e| e.into_inner()).pads.clone();
    let options: Vec<Value> = keys()
        .iter()
        .filter(|k| group != ALL_GAMES || k.as_str() != "pad")
        .map(|k| {
            let (value, own) = get(app, group, k);
            json!({ "key": k, "value": value, "own": own, "inherited": inherited(app, group, k), "values": values(k) })
        })
        .collect();
    json!({ "applies": APPLIES.contains(&program), "stick": program == "retroarch", "program": program, "pads": pads, "options": options })
}

pub fn set(app: &Shared, group: &str, k: &str, value: &str) -> Result<(), String> {
    let vals = values(k);
    if vals.is_empty() || (group == ALL_GAMES && k == "pad") {
        return Err("unknown setting".into());
    }
    // A game set back to what it would get anyway keeps nothing of its own.
    if value == "default" || (value == vals[0] && group == ALL_GAMES) || (group != ALL_GAMES && value == inherited(app, group, k)) {
        app.db.set_setting(&key(group, k), "");
        if k == "pad" {
            app.db.set_setting(&key(group, "pad.id"), "");
        }
        return Ok(());
    }
    if !vals.iter().any(|v| v == value) {
        return Err("unknown value".into());
    }
    app.db.set_setting(&key(group, k), value);
    if k == "pad" {
        // The pad itself is remembered (name and GUID), not only its place.
        let s = app.pads.lock().unwrap_or_else(|e| e.into_inner());
        let i = value.parse::<usize>().unwrap_or(1).saturating_sub(1);
        let id = s.pads.get(i).map(|n| format!("{n}|{}", s.guids.get(i).map(String::as_str).unwrap_or(""))).unwrap_or_default();
        app.db.set_setting(&key(group, "pad.id"), &id);
    }
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
    if get(app, group, "pad").0.parse::<u32>().is_ok() {
        let first = players(app, group).first().map(|p| p.index).unwrap_or(0);
        v.push(("input_player1_joypad_index".into(), first.to_string()));
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
