//! Escape during a game asks Borne whether to quit, as Select + Start does: the emulator never
//! sees the key, so none of their own menus or exits open.
//!
//! Linux: while a game runs, Escape is grabbed on the X server (Xwayland under gamescope or a
//! Wayland desktop: the emulators are started as X11 clients, see `emulators::command`), so
//! the key goes to Borne whichever window has the focus. Released after the game, for Borne's own
//! use. macOS: the UI registers a hotkey (ui/launcher/main.cpp) and asks the core.
//!
//! Escape while the question is shown keeps playing (Enter or A quits, in Borne's window).

use crate::state::Shared;

#[cfg(target_os = "linux")]
pub fn spawn(app: Shared) {
    std::thread::Builder::new()
        .name("quitkey".into())
        .spawn(move || {
            if std::env::var_os("DISPLAY").is_none() {
                return;
            }
            // Reconnects if the X server goes away (a new gamescope session…).
            loop {
                if let Err(e) = run(&app) {
                    crate::logfile::write("quitkey", &format!("Escape not caught: {e}"));
                }
                std::thread::sleep(std::time::Duration::from_secs(10));
            }
        })
        .ok();
}

#[cfg(not(target_os = "linux"))]
pub fn spawn(_app: Shared) {}

#[cfg(target_os = "linux")]
fn run(app: &Shared) -> Result<(), Box<dyn std::error::Error>> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, GrabMode, ModMask};
    use x11rb::protocol::Event;
    const XK_ESCAPE: u32 = 0xff1b;

    let (conn, screen) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen].root;
    let (min, max) = (conn.setup().min_keycode, conn.setup().max_keycode);
    let map = conn.get_keyboard_mapping(min, max - min + 1)?.reply()?;
    let per = map.keysyms_per_keycode as usize;
    let codes: Vec<u8> =
        (0..=(max - min) as usize).filter(|i| map.keysyms[i * per..(i + 1) * per].contains(&XK_ESCAPE)).map(|i| min + i as u8).collect();
    if codes.is_empty() {
        return Err("no Escape key on this keyboard map".into());
    }
    let mut grabbed = false;
    loop {
        let playing = crate::emulators::playing();
        if playing != grabbed {
            for &k in &codes {
                if playing {
                    conn.grab_key(true, root, ModMask::ANY, k, GrabMode::ASYNC, GrabMode::ASYNC)?;
                } else {
                    conn.ungrab_key(k, root, ModMask::ANY)?;
                }
            }
            conn.flush()?;
            grabbed = playing;
        }
        while let Some(ev) = conn.poll_for_event()? {
            if let Event::KeyPress(k) = ev {
                if grabbed && codes.contains(&k.detail) {
                    pressed(app);
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(40));
    }
}

/// Escape pressed during a game: the question, or (when it is shown) back to the game.
pub fn pressed(app: &Shared) {
    if !crate::emulators::playing() {
        return;
    }
    if crate::emulators::paused() {
        crate::logfile::write("play", "Escape: back to the game");
        crate::emulators::resume(app);
    } else {
        crate::logfile::write("play", "Escape: asking whether to quit");
        crate::emulators::ask_quit(app);
    }
}
