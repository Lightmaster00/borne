//! Gamepad input on the Rust side (gilrs / evdev).
//!
//! Qt 6 no longer has a gamepad module, so the core is the single source:
//! events are relayed to the QML UI over the WebSocket.

use gilrs::{Axis, Button, EventType, Gilrs};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Serialize, Clone)]
struct PadEvent {
    #[serde(rename = "type")]
    kind: &'static str,
    action: &'static str,
    pad: String,
    repeat: bool,
}

#[derive(Default, Clone, Serialize)]
pub struct PadState {
    pub available: bool,
    pub error: Option<String>,
    pub pads: Vec<String>,
    /// SDL-style GUID of each pad (same order), for emulators that bind a device by it.
    pub guids: Vec<String>,
    /// USB vendor and product of each pad (same order; 0 when unknown).
    pub ids: Vec<(u16, u16)>,
    /// The name the system gives each pad (same order), which SDL 3 hashes into its GUID.
    pub os_names: Vec<String>,
    /// The pad that last pressed a button (its place in `pads`): the one in the player's hands,
    /// given to the game when no pad was chosen for it.
    pub last: Option<usize>,
}

pub type SharedPadState = Arc<Mutex<PadState>>;

const FIRST_REPEAT: Duration = Duration::from_millis(380);
const NEXT_REPEAT: Duration = Duration::from_millis(85);
const STICK_THRESHOLD: f32 = 0.6;
/// Select and Start pressed together, or one within this time of the other, quit the game.
const QUIT_CHORD: Duration = Duration::from_millis(700);

/// The pads Steam hides from the games it starts (Steam Input: SDL_GAMECONTROLLER_IGNORE_DEVICES,
/// "0x057e/0x2009,…"), which then play through Steam's virtual pad instead. Inherited by the
/// emulators when Borne is started from Steam.
pub fn steam_hidden() -> Vec<(u16, u16)> {
    let list = std::env::var("SDL_GAMECONTROLLER_IGNORE_DEVICES").unwrap_or_default();
    list.split(',')
        .filter_map(|e| {
            let (v, p) = e.trim().split_once('/')?;
            let hex = |x: &str| u16::from_str_radix(x.trim().trim_start_matches("0x").trim_start_matches("0X"), 16).ok();
            Some((hex(v)?, hex(p)?))
        })
        .collect()
}

/// A Nintendo pad's face buttons by their letters: A is on the right (East), B at the bottom,
/// X on top, Y on the left.
fn by_label(b: Button) -> Button {
    match b {
        Button::South => Button::East,
        Button::East => Button::South,
        Button::North => Button::West,
        Button::West => Button::North,
        other => other,
    }
}

fn map_button(b: Button) -> Option<&'static str> {
    Some(match b {
        Button::DPadUp => "up",
        Button::DPadDown => "down",
        Button::DPadLeft => "left",
        Button::DPadRight => "right",
        Button::South => "a",
        Button::East => "b",
        Button::West => "x",
        Button::North => "y",
        Button::Start => "start",
        Button::Select => "select",
        Button::LeftTrigger => "lb",
        Button::RightTrigger => "rb",
        Button::LeftTrigger2 => "lt",
        Button::RightTrigger2 => "rt",
        Button::RightThumb => "r3",
        _ => return None,
    })
}

fn repeatable(action: &str) -> bool {
    matches!(action, "up" | "down" | "left" | "right" | "lb" | "rb" | "lt" | "rt")
}

/// `emit` receives each event serialized as JSON (relayed to WebSocket clients).
/// Reads the gamepads. `on_quit` is called on the quit chord (Select and Start together), here in
/// the core so it works whatever the emulator does with the pad and whether the UI is awake.
pub fn spawn(emit_json: impl Fn(String) + Send + 'static, state: SharedPadState, on_quit: impl Fn() + Send + 'static) {
    std::thread::Builder::new()
        .name("borne-pad".into())
        .spawn(move || {
            let mut gilrs = match Gilrs::new() {
                Ok(g) => g,
                Err(e) => {
                    let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
                    s.error = Some(e.to_string());
                    return;
                }
            };
            state.lock().unwrap_or_else(|e| e.into_inner()).available = true;

            // held action -> (time of the next repeat, gamepad name)
            let mut held: HashMap<&'static str, (Instant, String)> = HashMap::new();
            // Each pad's stick directions (several pads must not undo each other's).
            let mut stick: HashMap<(usize, &'static str), bool> = HashMap::new();
            // Right stick: turns the selected game box (continuous, not actions).
            let (mut rx, mut ry) = (0.0f32, 0.0f32);
            // When Select and Start were last pressed, for the quit chord.
            let (mut select_at, mut start_at): (Option<Instant>, Option<Instant>) = (None, None);
            let emit_stick = |x: f32, y: f32| {
                emit_json(format!(r#"{{"type":"stick","x":{x:.2},"y":{y:.2}}}"#));
            };
            let emit = |action: &'static str, pad: &str, repeat: bool| {
                let ev = PadEvent { kind: "pad", action, pad: pad.to_string(), repeat };
                if let Ok(s) = serde_json::to_string(&ev) {
                    emit_json(s);
                }
            };

            loop {
                {
                    let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
                    s.pads = gilrs.gamepads().map(|(_, g)| g.name().to_string()).collect();
                    s.guids = gilrs.gamepads().map(|(_, g)| g.uuid().iter().map(|b| format!("{b:02x}")).collect()).collect();
                    s.ids = gilrs.gamepads().map(|(_, g)| (g.vendor_id().unwrap_or(0), g.product_id().unwrap_or(0))).collect();
                    s.os_names = gilrs.gamepads().map(|(_, g)| g.os_name().to_string()).collect();
                }
                // Started from Steam with Steam Input: the pads Steam hides from games also send
                // their presses here, besides Steam's virtual pad; only the virtual pad is heard,
                // or every press would count twice.
                let hidden = steam_hidden();
                let steam_pad = gilrs.gamepads().any(|(_, g)| g.vendor_id() == Some(0x28de));
                while let Some(ev) = gilrs.next_event() {
                    let gp = gilrs.gamepad(ev.id);
                    let ids = (gp.vendor_id().unwrap_or(0), gp.product_id().unwrap_or(0));
                    if steam_pad && hidden.contains(&ids) {
                        continue;
                    }
                    // A Nintendo pad (Switch Pro, Joy-Con) heard directly: its buttons by their
                    // letters, as its owner reads them (A on the right confirms), not by place.
                    let nintendo = ids.0 == 0x057e;
                    let pad = gp.name().to_string();
                    let pad_key = usize::from(ev.id);
                    match ev.event {
                        EventType::ButtonPressed(b, _) => {
                            let now = Instant::now();
                            let place = gilrs.gamepads().position(|(id, _)| id == ev.id);
                            state.lock().unwrap_or_else(|e| e.into_inner()).last = place;
                            match b {
                                Button::Select => select_at = Some(now),
                                Button::Start => start_at = Some(now),
                                _ => {}
                            }
                            if matches!(b, Button::Select | Button::Start) {
                                if let (Some(a), Some(b)) = (select_at, start_at) {
                                    let gap = if a > b { a - b } else { b - a };
                                    if gap <= QUIT_CHORD {
                                        select_at = None;
                                        start_at = None;
                                        on_quit();
                                    }
                                }
                            }
                            if let Some(a) = map_button(if nintendo { by_label(b) } else { b }) {
                                emit(a, &pad, false);
                                if repeatable(a) {
                                    held.insert(a, (Instant::now() + FIRST_REPEAT, pad));
                                }
                            }
                        }
                        EventType::ButtonReleased(b, _) => {
                            if let Some(a) = map_button(if nintendo { by_label(b) } else { b }) {
                                held.remove(a);
                            }
                        }
                        EventType::AxisChanged(axis @ (Axis::RightStickX | Axis::RightStickY), v, _) => {
                            // Dead zone, then the rest of the travel rescaled from 0 (no jump at its
                            // edge), in steps of 0.02 so small jitter sends nothing; the interface
                            // smooths the angle (Main.qml).
                            const DEAD: f32 = 0.15;
                            let q = if v.abs() < DEAD { 0.0 } else { (v.signum() * (v.abs() - DEAD) / (1.0 - DEAD) * 50.0).round() / 50.0 };
                            let (nx, ny) = if axis == Axis::RightStickX { (q, ry) } else { (rx, -q) };
                            if (nx, ny) != (rx, ry) {
                                rx = nx;
                                ry = ny;
                                emit_stick(rx, ry);
                            }
                        }
                        EventType::AxisChanged(axis, v, _) => {
                            let dirs: Option<(&'static str, &'static str)> = match axis {
                                Axis::LeftStickX => Some(("left", "right")),
                                // gilrs: positive Y = up
                                Axis::LeftStickY => Some(("down", "up")),
                                _ => None,
                            };
                            if let Some((neg, pos)) = dirs {
                                for (dir, active) in [(neg, v < -STICK_THRESHOLD), (pos, v > STICK_THRESHOLD)] {
                                    let was = *stick.get(&(pad_key, dir)).unwrap_or(&false);
                                    if active && !was {
                                        emit(dir, &pad, false);
                                        held.insert(dir, (Instant::now() + FIRST_REPEAT, pad.clone()));
                                    } else if !active && was {
                                        held.remove(dir);
                                    }
                                    stick.insert((pad_key, dir), active);
                                }
                            }
                        }
                        EventType::Disconnected => held.clear(),
                        _ => {}
                    }
                }
                let now = Instant::now();
                for (action, (next, pad)) in held.iter_mut() {
                    if now >= *next {
                        emit(action, pad, true);
                        *next = now + NEXT_REPEAT;
                    }
                }
                std::thread::sleep(Duration::from_millis(4));
            }
        })
        .expect("gamepad thread");
}
