//! Games made for an accessory: a guitar, a Balance Board, PlayStation VR, Kinect, Joy-Con shaken…
//! Found by the game's name (equipment.json), checked against what is plugged in (hardware.rs).
//!
//! Never a lock: before the first game of such a title, when what it needs is not found here,
//! Borne says so and the player chooses (Not now / Play anyway). Play anyway is remembered for
//! the game, so a wrong match (or an accessory Borne cannot see) costs one question, once.

use crate::hardware::Hardware;
use crate::state::Shared;
use serde_json::{json, Value};
use std::sync::OnceLock;

/// What a need is: (code, kind, found here). kind: "made_for" (it plays with a pad, awkwardly),
/// "required" (not without it), "unsupported" (the emulator cannot give it: not playable here).
fn kind(code: &str) -> &'static str {
    match code {
        "guitar" | "turntable" | "bongos" | "buzzers" => "made_for",
        "psvr" | "kinect" | "ring_con" | "labo" | "camera" | "rocksmith" => "unsupported",
        _ => "required",
    }
}

/// Whether what a game needs is here. A Balance Board, a PlayStation Move… talk to the emulator
/// directly (Bluetooth): Borne cannot see them, so they always count as not found.
fn found(code: &str, hw: &Hardware) -> bool {
    match code {
        "guitar" => hw.guitar,
        "turntable" => hw.turntable,
        "microphone" => hw.microphone,
        "wii_motion" | "motionplus" => hw.motion_pad || hw.wiimote,
        "joycon_motion" => hw.motion_pad,
        _ => false,
    }
}

struct Rule {
    consoles: Vec<String>,
    has: Vec<String>,
    start: Vec<String>,
    end: Vec<String>,
    is: Vec<String>,
    except: Vec<String>,
    needs: String,
}

fn rules() -> &'static Vec<Rule> {
    static R: OnceLock<Vec<Rule>> = OnceLock::new();
    R.get_or_init(|| {
        let v: Value = serde_json::from_str(include_str!("equipment.json")).unwrap_or(Value::Null);
        let list = |r: &Value, k: &str| -> Vec<String> {
            r[k].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
        };
        v["rules"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|r| Rule {
                        consoles: list(r, "consoles"),
                        has: list(r, "has"),
                        start: list(r, "start"),
                        end: list(r, "end"),
                        is: list(r, "is"),
                        except: list(r, "except"),
                        needs: r["needs"].as_str().unwrap_or("").to_string(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    })
}

/// A name as the rules see it: lower case, letters and digits only, accents dropped. Region and
/// version tags in brackets or parentheses are left out ("Wii Fit (Europe) (Rev 1)" → "wiifit").
pub fn squeeze(name: &str) -> String {
    let mut out = String::new();
    let mut depth = 0;
    for c in name.chars() {
        match c {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = (depth - 1).max(0),
            _ if depth > 0 => {}
            _ => {
                for l in c.to_lowercase() {
                    let l = match l {
                        'à' | 'á' | 'â' | 'ä' | 'ã' => 'a',
                        'é' | 'è' | 'ê' | 'ë' => 'e',
                        'í' | 'ì' | 'î' | 'ï' => 'i',
                        'ó' | 'ò' | 'ô' | 'ö' | 'õ' => 'o',
                        'ú' | 'ù' | 'û' | 'ü' => 'u',
                        x => x,
                    };
                    if l.is_ascii_alphanumeric() {
                        out.push(l);
                    }
                }
            }
        }
    }
    out
}

/// What a game is made for ("" when nothing): the code of the first rule matching its console and
/// name.
pub fn need_of(console: &str, name: &str) -> Option<String> {
    let n = squeeze(name);
    if n.is_empty() {
        return None;
    }
    rules()
        .iter()
        .find(|r| {
            r.consoles.iter().any(|c| c == console)
                && !r.except.iter().any(|x| n.contains(x.as_str()))
                && (r.has.iter().any(|x| n.contains(x.as_str()))
                    || r.start.iter().any(|x| n.starts_with(x.as_str()))
                    || r.end.iter().any(|x| n.ends_with(x.as_str()))
                    || r.is.iter().any(|x| &n == x))
        })
        .map(|r| r.needs.clone())
}

/// A game's need as the page and the question show it: {code, kind, missing, game: true}.
pub fn view(console: &str, name: &str, hw: &Hardware) -> Option<Value> {
    let code = need_of(console, name)?;
    Some(json!({ "code": code, "kind": kind(&code), "missing": !found(&code, hw), "game": true }))
}

const SEEN: &str = "equipment.seen";

fn seen(app: &Shared) -> Vec<String> {
    app.db.setting(SEEN).unwrap_or_default().split('\n').filter(|s| !s.is_empty()).map(String::from).collect()
}

/// Before a game: its need when missing here and not yet answered for this game; None to play.
/// `anyway` records the answer (the game's group, all its versions).
pub fn before_play(app: &Shared, group: &str, console: &str, name: &str, hw: &Hardware, anyway: bool) -> Option<Value> {
    let need = view(console, name, hw).filter(|v| v["missing"] == true)?;
    let mut s = seen(app);
    if s.iter().any(|g| g == group) {
        return None;
    }
    if anyway {
        s.push(group.to_string());
        app.db.set_setting(SEEN, &s.join("\n"));
        return None;
    }
    Some(need)
}

/// Forgets the answers (Settings: ask again before games made for an accessory).
pub fn forget(app: &Shared) {
    app.db.set_setting(SEEN, "");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn games_are_matched_by_their_name() {
        assert_eq!(need_of("wii", "Wii Fit Plus (Europe)").as_deref(), Some("balance_board"));
        assert_eq!(need_of("wii", "Wii Sports Resort").as_deref(), Some("motionplus"));
        assert_eq!(need_of("wii", "Wii Sports").as_deref(), Some("wii_motion"));
        assert_eq!(need_of("ps2", "Guitar Hero III: Legends of Rock").as_deref(), Some("guitar"));
        assert_eq!(need_of("ps3", "DJ Hero 2").as_deref(), Some("turntable"));
        assert_eq!(need_of("ps4", "Astro Bot Rescue Mission").as_deref(), Some("psvr"));
        assert_eq!(need_of("ps4", "Moss").as_deref(), Some("psvr"));
        assert_eq!(need_of("ps4", "Mossy Hollow"), None);
        assert_eq!(need_of("ps4", "Batman: Arkham Knight"), None);
        assert_eq!(need_of("switch", "Super Mario Party").as_deref(), Some("joycon_motion"));
        assert_eq!(need_of("switch", "Super Mario Party Jamboree"), None);
        assert_eq!(need_of("switch", "Mario Party Superstars"), None);
        assert_eq!(need_of("switch", "1-2-Switch").as_deref(), Some("joycon_motion"));
        assert_eq!(need_of("switch", "Ring Fit Adventure").as_deref(), Some("ring_con"));
        assert_eq!(need_of("xbox360", "Kinect Adventures!").as_deref(), Some("kinect"));
        assert_eq!(need_of("ps2", "SingStar Pop").as_deref(), Some("microphone"));
        assert_eq!(need_of("ps2", "Buzz! The Music Quiz").as_deref(), Some("buzzers"));
        assert_eq!(need_of("ngc", "Donkey Konga 2").as_deref(), Some("bongos"));
        // Another console, or a game that only shares a word.
        assert_eq!(need_of("nds", "Guitar Hero: On Tour"), None);
        assert_eq!(need_of("snes", "Wii Fit"), None);
        assert_eq!(need_of("wii", "Super Mario Galaxy"), None);
        assert_eq!(need_of("ps4", "Rock Band 4").as_deref(), Some("guitar"));
    }

    #[test]
    fn found_follows_the_hardware() {
        let mut hw = Hardware::default();
        assert_eq!(view("ps2", "Guitar Hero II", &hw).unwrap()["missing"], true);
        hw.guitar = true;
        assert_eq!(view("ps2", "Guitar Hero II", &hw).unwrap()["missing"], false);
        hw.motion_pad = true;
        assert_eq!(view("switch", "1-2-Switch", &hw).unwrap()["missing"], false);
        assert_eq!(view("ps4", "Farpoint", &hw).unwrap()["kind"], "unsupported");
    }
}
