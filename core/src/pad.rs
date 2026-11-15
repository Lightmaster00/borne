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
}

pub type SharedPadState = Arc<Mutex<PadState>>;

const FIRST_REPEAT: Duration = Duration::from_millis(380);
const NEXT_REPEAT: Duration = Duration::from_millis(85);
const STICK_THRESHOLD: f32 = 0.6;
/// Select and Start pressed together, or one within this time of the other, quit the game.
const QUIT_CHORD: Duration = Duration::from_millis(700);

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
                    let mut s = state.lock().unwrap();
                    s.error = Some(e.to_string());
                    return;
                }
            };
            state.lock().unwrap().available = true;

            // held action -> (time of the next repeat, gamepad name)
            let mut held: HashMap<&'static str, (Instant, String)> = HashMap::new();
            let mut stick: HashMap<&'static str, bool> = HashMap::new();
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
                    let mut s = state.lock().unwrap();
                    s.pads = gilrs.gamepads().map(|(_, g)| g.name().to_string()).collect();
                    s.guids = gilrs.gamepads().map(|(_, g)| g.uuid().iter().map(|b| format!("{b:02x}")).collect()).collect();
                }
                while let Some(ev) = gilrs.next_event() {
                    let pad = gilrs.gamepad(ev.id).name().to_string();
                    match ev.event {
                        EventType::ButtonPressed(b, _) => {
                            let now = Instant::now();
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
                            if let Some(a) = map_button(b) {
                                emit(a, &pad, false);
                                if repeatable(a) {
                                    held.insert(a, (Instant::now() + FIRST_REPEAT, pad));
                                }
                            }
                        }
                        EventType::ButtonReleased(b, _) => {
                            if let Some(a) = map_button(b) {
                                held.remove(a);
                            }
                        }
                        EventType::AxisChanged(axis @ (Axis::RightStickX | Axis::RightStickY), v, _) => {
                            // Dead zone, then steps of 0.05 so small jitter sends nothing.
                            let q = if v.abs() < 0.18 { 0.0 } else { (v * 20.0).round() / 20.0 };
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
                                    let was = *stick.get(dir).unwrap_or(&false);
                                    if active && !was {
                                        emit(dir, &pad, false);
                                        held.insert(dir, (Instant::now() + FIRST_REPEAT, pad.clone()));
                                    } else if !active && was {
                                        held.remove(dir);
                                    }
                                    stick.insert(dir, active);
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
