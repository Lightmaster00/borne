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
    players_placed(app, group).into_iter().map(|(p, _)| p).collect()
}

/// The players, each with its pad's place among every pad connected (Steam's hidden ones too):
/// RetroArch reads the pads itself and numbers them all.
pub fn players_placed(app: &Shared, group: &str) -> Vec<(crate::gamesettings::PadRef, usize)> {
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
        .map(|i| {
            (
                crate::gamesettings::PadRef {
                    index: i,
                    name: pads[i].clone(),
                    guid: guids.get(i).cloned(),
                    rank: pads[..=i].iter().filter(|n| **n == pads[i]).count(),
                },
                visible[i],
            )
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

/// The group under which a console's controls are kept (between every game's and a game's own).
pub fn console_group(slug: &str) -> String {
    format!("@console:{slug}")
}

/// The console a game's group belongs to.
fn console_of(app: &Shared, group: &str) -> Option<String> {
    app.db.group(group).into_iter().next().map(|g| g.platform_slug)
}

fn own(app: &Shared, group: &str, k: &str) -> Option<String> {
    let vals = values(k);
    app.db.setting(&key(group, k)).filter(|v| vals.contains(v))
}

/// The level above this one: a game's console, then every game.
fn parent(app: &Shared, group: &str) -> Option<String> {
    if group == ALL_GAMES {
        None
    } else if group.starts_with("@console:") {
        Some(ALL_GAMES.to_string())
    } else {
        Some(console_of(app, group).map(|c| console_group(&c)).unwrap_or_else(|| ALL_GAMES.to_string()))
    }
}

/// What a level gets without a value of its own: its console's, else every game's (the pad is
/// always chosen per game), else the default.
fn inherited(app: &Shared, group: &str, k: &str) -> String {
    let mut up = if k == "pad" { None } else { parent(app, group) };
    while let Some(g) = up {
        if let Some(v) = own(app, &g, k) {
            return v;
        }
        up = parent(app, &g);
    }
    values(k)[0].clone()
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
    let (pads, ids) = {
        let p = app.pads.lock().unwrap_or_else(|e| e.into_inner());
        (p.pads.clone(), p.ids.clone())
    };
    // The kind of pad in the player's hands, to name its buttons as printed on it.
    let vendor = players(app, if group.starts_with('@') { "" } else { group })
        .first()
        .and_then(|p| pads.iter().position(|n| *n == p.name))
        .and_then(|i| ids.get(i))
        .map(|x| x.0)
        .unwrap_or(0);
    let family = match vendor {
        0x057e => "nintendo",
        0x054c => "playstation",
        _ => "xbox",
    };
    // Which pad button gives each of the console's buttons now.
    let buttons: Vec<Value> = sources(app, group).iter().map(|(l, p)| json!({ "button": l, "pad": p })).collect();
    let level = if group == ALL_GAMES {
        "all"
    } else if group.starts_with("@console:") {
        "console"
    } else {
        "game"
    };
    let console =
        if level == "console" { group.trim_start_matches("@console:").to_string() } else { console_of(app, group).unwrap_or_default() };
    let options: Vec<Value> = keys()
        .iter()
        .filter(|k| level == "game" || k.as_str() != "pad")
        .map(|k| {
            let (value, own) = get(app, group, k);
            json!({ "key": k, "value": value, "own": own, "inherited": inherited(app, group, k), "values": values(k) })
        })
        .collect();
    json!({
        "applies": level != "game" || APPLIES.contains(&program),
        "stick": level != "game" || program == "retroarch",
        "program": program,
        "pads": pads,
        "options": options,
        "level": level,
        "console": console,
        "family": family,
        "buttons": buttons,
    })
}

pub fn set(app: &Shared, group: &str, k: &str, value: &str) -> Result<(), String> {
    // Everything of this level back to the level above.
    if k == "*" {
        for k in keys() {
            app.db.set_setting(&key(group, &k), "");
        }
        app.db.set_setting(&key(group, "pad.id"), "");
        return Ok(());
    }
    // The buttons only (the layout and the stick kept).
    if k == "map.*" {
        for (b, _) in BUTTONS {
            app.db.set_setting(&key(group, &format!("map.{b}")), "");
        }
        return Ok(());
    }
    let vals = values(k);
    if vals.is_empty() || (group.starts_with('@') && k == "pad") {
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

/// "Press the button for…": the pad button `pad` now gives the console's button `button` (both in
/// the controls' names), at this level. The level's buttons are first written out as they are
/// now (so nothing else moves), then the two pad buttons concerned trade what they give.
pub fn assign(app: &Shared, group: &str, button: &str, pad: &str) -> Result<(), String> {
    let name = |id: u8| BUTTONS.iter().find(|b| b.1 == id).map(|b| b.0);
    if name_ok(button).is_none() || name_ok(pad).is_none() {
        return Err("unknown button".into());
    }
    let now: Vec<(&'static str, &'static str)> = mapping(app, group).into_iter().filter_map(|(p, id)| Some((p, name(id)?))).collect();
    let mut gives: std::collections::HashMap<&str, &str> = now.iter().copied().collect();
    let before = gives.get(pad).copied().unwrap_or(pad);
    // The pad button that gave `button` until now takes what `pad` gave.
    if let Some((other, _)) = now.iter().find(|(p, b)| *b == button && *p != pad) {
        gives.insert(other, before);
    }
    gives.insert(pad, button);
    for (p, b) in gives {
        app.db.set_setting(&key(group, &format!("map.{p}")), b);
    }
    Ok(())
}

fn name_ok(b: &str) -> Option<&'static str> {
    BUTTONS.iter().find(|x| x.0 == b).map(|x| x.0)
}

/// Which RetroPad button each pad button presses for this game (by RetroPad id).
fn mapping(app: &Shared, group: &str) -> Vec<(&'static str, u8)> {
    let id = |name: &str| BUTTONS.iter().find(|b| b.0 == name).map(|b| b.1);
    // Started from Steam with a Nintendo pad, the game plays on Steam's virtual pad, which Steam
    // lays out by the letters (its A where the Nintendo A is, on the right): its buttons are put
    // back in their places, as with the pad itself.
    let steam_nintendo = {
        let s = app.pads.lock().unwrap_or_else(|e| e.into_inner());
        s.ids.iter().any(|x| x.0 == 0x28de) && crate::pad::steam_hidden().iter().any(|x| x.0 == 0x057e)
    };
    let swap = (get(app, group, "face").0 == "swap") != steam_nintendo;
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

/// Cores of consoles whose pads had no analog stick: there the left stick also moves as the D-pad
/// unless chosen otherwise (the games read the D-pad only).
const DIGITAL_CORES: &[&str] = &[
    "snes9x",
    "bsnes",
    "nestopia",
    "fceumm",
    "mesen",
    "genesis_plus_gx",
    "picodrive",
    "blastem",
    "mgba",
    "gambatte",
    "sameboy",
    "gearboy",
    "mednafen_pce",
    "mednafen_pce_fast",
    "mednafen_supergrafx",
    "fbneo",
    "mame",
    "mame2003_plus",
    "stella",
    "mednafen_ngp",
    "mednafen_wswan",
    "mednafen_saturn",
    "yabause",
    "yabasanshiro",
    "kronos",
    "vecx",
    "prosystem",
    "handy",
    "bluemsx",
    "opera",
    "gearsystem",
    "smsplus",
    "virtualjaguar",
    "mednafen_vb",
    "pokemini",
    "atari800",
];

/// Whether the left stick also moves as the D-pad: as chosen for the game, else for every game,
/// else on consoles without analog stick.
fn stick_moves_dpad(app: &Shared, group: &str, core: &str) -> bool {
    let console = console_of(app, group).map(|c| console_group(&c)).unwrap_or_default();
    match own(app, group, "stick").or_else(|| own(app, &console, "stick")).or_else(|| own(app, ALL_GAMES, "stick")) {
        Some(v) => v == "dpad",
        None => DIGITAL_CORES.contains(&core),
    }
}

/// RetroArch: the settings for the main configuration, and the game's remap file written under
/// `remaps` for the core (`core`, `display`: its id and name), named after the game file.
pub fn retroarch(app: &Shared, group: &str, remaps: &Path, core: &str, display: &str, rom: &Path) -> Vec<(String, String)> {
    let mut v = vec![
        ("auto_remaps_enable".to_string(), "true".to_string()),
        ("input_remap_binds_enable".into(), "true".into()),
        ("input_remapping_directory".into(), remaps.to_string_lossy().replace('"', "")),
        ("input_player1_analog_dpad_mode".into(), if stick_moves_dpad(app, group, core) { "1" } else { "0" }.into()),
    ];
    // One player per pad in hands: a pad is never two players at once (with Steam Input, the
    // pad itself and Steam's virtual pad are both seen by RetroArch; only one of them plays).
    let placed = players_placed(app, group);
    v.push(("input_max_users".into(), placed.len().max(1).to_string()));
    for (n, (_, full)) in placed.iter().enumerate() {
        v.push((format!("input_player{}_joypad_index", n + 1), full.to_string()));
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
