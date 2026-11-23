//! The consoles shown in Borne, chosen by the player among those of the RomM library (a console
//! left out has no tab and no emulator installed), and what each one's games need that this
//! machine may not have: a touch screen, motion sensors, a Wii Remote, power.
//! Warned about when choosing the consoles, on their page in Settings and on a game's page,
//! so that no game turns out unplayable by surprise.

use crate::hardware::Hardware;
use crate::state::Shared;
use serde_json::{json, Value};

const HIDDEN: &str = "consoles.hidden";
const CHOSEN: &str = "consoles.chosen";
/// Consoles whose missing needs the player has seen before playing (asked once per console).
const SEEN: &str = "consoles.needs_seen";

pub fn hidden(app: &Shared) -> Vec<String> {
    app.db.setting(HIDDEN).unwrap_or_default().split(',').filter(|s| !s.is_empty()).map(String::from).collect()
}

pub fn is_hidden(app: &Shared, slug: &str) -> bool {
    hidden(app).iter().any(|h| h == slug)
}

pub fn set_shown(app: &Shared, slug: &str, shown: bool) {
    let mut h = hidden(app);
    h.retain(|x| x != slug);
    if !shown {
        h.push(slug.to_string());
    }
    app.db.set_setting(HIDDEN, &h.join(","));
    app.db.set_setting(CHOSEN, "1");
}

/// The player has chosen their consoles (asked once, after the first sync).
pub fn chosen(app: &Shared) -> bool {
    app.db.setting(CHOSEN).as_deref() == Some("1")
}

pub fn mark_chosen(app: &Shared) {
    app.db.set_setting(CHOSEN, "1");
}

/// What a console's games need, each with when it is missing: (code, missing on this machine).
/// The interface words them (consoles.js on the page side, CoreText).
fn needs(slug: &str, hw: &Hardware) -> Vec<(&'static str, bool)> {
    let heavy = |threads: usize, ram: u64| hw.threads < threads || hw.ram_gb < ram;
    match slug {
        // Lower screen: touched in many games (the right stick moves a pointer otherwise).
        "nds" => vec![("touch", !hw.touchscreen), ("two_screens", false)],
        "3ds" | "n3ds" => vec![("touch", !hw.touchscreen), ("two_screens", false), ("motion_some", !hw.motion_pad)],
        // The Wii Remote pointed at the screen, and shaken.
        "wii" => vec![("wiimote", !hw.wiimote), ("motion", !hw.motion_pad && !hw.wiimote)],
        // The GamePad's touch screen and its motion; a strong machine.
        "wiiu" => vec![("touch_gamepad", !hw.touchscreen), ("motion_some", !hw.motion_pad), ("power", heavy(4, 8))],
        // Some games only with Joy-Con (motion, separate halves) or the touch screen.
        "switch" => vec![("joycon_some", !hw.motion_pad), ("touch_some", !hw.touchscreen), ("power", heavy(4, 8))],
        // Front touch screen and rear pad.
        "psvita" => vec![("touch_vita", !hw.touchscreen)],
        "ps3" => vec![("power", heavy(6, 8))],
        "ps4" => vec![("power", heavy(8, 16))],
        "xbox360" => vec![("power", heavy(6, 8))],
        "ps2" | "ngc" => vec![("power", heavy(4, 4))],
        _ => vec![],
    }
}

/// The warnings of a console on this machine: [{code, missing}], those missing first.
pub fn warnings(slug: &str, hw: &Hardware) -> Vec<Value> {
    let mut v = needs(slug, hw);
    v.sort_by_key(|(_, missing)| !missing);
    v.into_iter()
        .map(|(code, missing)| {
            let mut w = json!({ "code": code, "missing": missing });
            if code == "power" {
                w["threads"] = json!(hw.threads);
                w["ram_gb"] = json!(hw.ram_gb);
            }
            w
        })
        .collect()
}

/// Before a game: what it is made for (an accessory, equipment.rs) and what its console's games
/// need, when this machine lacks them and the player has not answered yet ({running: false,
/// needs: [...], console, game}); None to play. Power is told on the game's page, not asked: a
/// game may run well enough. Never a lock: {anyway} records the answer and the game starts.
pub fn before_play(app: &Shared, rom_id: i64, anyway: bool) -> Option<Value> {
    let g = app.db.game(rom_id)?;
    let slug = g.platform_slug.clone();
    let hw = hardware(app);
    let mut needs: Vec<Value> = vec![];
    if let Some(n) = crate::equipment::before_play(app, &g.group_key, &slug, &g.name, &hw, anyway) {
        needs.push(n);
    }
    let mut seen: Vec<String> = app.db.setting(SEEN).unwrap_or_default().split(',').filter(|s| !s.is_empty()).map(String::from).collect();
    if !seen.contains(&slug) {
        let missing: Vec<Value> = warnings(&slug, &hw).into_iter().filter(|w| w["missing"] == true && w["code"] != "power").collect();
        if !missing.is_empty() {
            if anyway {
                seen.push(slug.clone());
                app.db.set_setting(SEEN, &seen.join(","));
            } else {
                needs.extend(missing);
            }
        }
    }
    if needs.is_empty() {
        return None;
    }
    Some(json!({ "running": false, "needs": needs, "console": g.platform_name, "game": g.name, "rom_id": rom_id }))
}

/// Forgets which consoles' needs were answered (asked again before their next game).
pub fn forget_seen(app: &Shared) {
    app.db.set_setting(SEEN, "");
}

pub fn hardware(app: &Shared) -> Hardware {
    let (ids, names) = {
        let p = app.pads.lock().unwrap_or_else(|e| e.into_inner());
        (p.ids.clone(), p.pads.iter().chain(p.os_names.iter()).cloned().collect::<Vec<_>>())
    };
    crate::hardware::detect(&ids, &names)
}

/// Every console of the RomM library: shown or not, its games, whether Borne plays it, and its
/// warnings on this machine.
pub fn list(app: &Shared) -> Value {
    let hw = hardware(app);
    let hidden = hidden(app);
    let known = crate::emulators::known_consoles();
    let consoles: Vec<Value> = app
        .db
        .platforms()
        .into_iter()
        .map(|p| {
            json!({
                "slug": p.slug, "name": p.name, "games": p.rom_count,
                "shown": !hidden.contains(&p.slug),
                "supported": known.contains(&p.slug),
                "warnings": warnings(&p.slug, &hw),
            })
        })
        .collect();
    json!({ "consoles": consoles, "chosen": chosen(app), "hardware": crate::hardware::to_json(&hw) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warnings_follow_the_machine() {
        let desktop = Hardware { mouse: true, machine: "desktop".into(), threads: 8, ram_gb: 16, ..Default::default() };
        let w = warnings("nds", &desktop);
        assert_eq!(w[0]["code"], "touch");
        assert_eq!(w[0]["missing"], true, "no touch screen on a desktop");
        let deck = Hardware {
            touchscreen: true,
            motion_pad: true,
            mouse: true,
            machine: "steamdeck".into(),
            threads: 8,
            ram_gb: 16,
            ..Default::default()
        };
        assert!(warnings("3ds", &deck).iter().all(|w| w["missing"] == false));
        let small = Hardware { threads: 2, ram_gb: 4, ..Default::default() };
        assert!(warnings("ps3", &small).iter().any(|w| w["code"] == "power" && w["missing"] == true));
        assert!(warnings("wii", &desktop).iter().any(|w| w["code"] == "wiimote" && w["missing"] == true));
        assert!(warnings("gba", &desktop).is_empty());
    }
}
