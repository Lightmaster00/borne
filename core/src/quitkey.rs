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

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn spawn(_app: Shared) {}

#[cfg(target_os = "windows")]
pub fn spawn(app: Shared) {
    use std::sync::OnceLock;
    use windows_sys::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::VK_ESCAPE;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, KBDLLHOOKSTRUCT, MSG, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx,
        WH_KEYBOARD_LL, WM_KEYDOWN, WM_SYSKEYDOWN,
    };

    static TX: OnceLock<std::sync::mpsc::SyncSender<()>> = OnceLock::new();
    let (tx, rx) = std::sync::mpsc::sync_channel::<()>(4);
    let _ = TX.set(tx);
    let app_worker = app.clone();
    std::thread::Builder::new()
        .name("quitkey-worker".into())
        .spawn(move || {
            while rx.recv().is_ok() {
                pressed(&app_worker);
            }
        })
        .ok();

    unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 && (wparam == WM_KEYDOWN as usize || wparam == WM_SYSKEYDOWN as usize) {
            let kb = &*(lparam as *const KBDLLHOOKSTRUCT);
            if kb.vkCode == VK_ESCAPE as u32 && crate::emulators::playing() {
                if let Some(tx) = TX.get() {
                    let _ = tx.try_send(());
                }
                return 1;
            }
        }
        CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
    }

    std::thread::Builder::new()
        .name("quitkey".into())
        .spawn(move || unsafe {
            let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), std::ptr::null_mut(), 0);
            if hook.is_null() {
                crate::logfile::write("quitkey", "Escape hook could not be installed");
                return;
            }
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            UnhookWindowsHookEx(hook);
        })
        .ok();
}

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

// ---------- The game's windows out of the way of the quit question (Linux, X11) ----------
//
// Under gamescope (ChimeraOS, SteamOS) the window in front is the newest game's, whatever Borne
// asks: Borne's question would stay behind the paused game. Its windows are taken off the screen
// (unmapped: the X server does it, the paused emulator has nothing to do) while Borne asks, and
// put back when the game goes on.

#[cfg(target_os = "linux")]
static HIDDEN: std::sync::Mutex<Vec<u32>> = std::sync::Mutex::new(Vec::new());

/// The process group of a process (/proc/<pid>/stat, 5th field).
#[cfg(target_os = "linux")]
fn pgid_of(pid: u32) -> Option<i32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // The command name is in parentheses and may hold spaces: the fields after its ")".
    stat.rsplit_once(')')?.1.split_whitespace().nth(2)?.parse().ok()
}

/// Hides the visible top-level windows of the game's process group.
#[cfg(target_os = "linux")]
pub fn hide_game(pgid: i32) {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, MapState};
    if std::env::var_os("DISPLAY").is_none() {
        return;
    }
    let Ok((conn, screen)) = x11rb::connect(None) else { return };
    let root = conn.setup().roots[screen].root;
    let Some(pid_atom) = conn.intern_atom(false, b"_NET_WM_PID").ok().and_then(|c| c.reply().ok()) else { return };
    let mut hidden = vec![];
    // Top-level windows and their children (a window manager reparents them into frames).
    let mut stack = vec![(root, 0)];
    while let Some((w, depth)) = stack.pop() {
        let Ok(tree) = conn.query_tree(w).map(|c| c.reply()) else { continue };
        let Ok(tree) = tree else { continue };
        for child in tree.children {
            // Its process: as the window says (_NET_WM_PID), else as the X server knows its
            // client (X-Resource; Xwayland and Xorg have it).
            let pid = conn
                .get_property(false, child, pid_atom.atom, AtomEnum::CARDINAL, 0, 1)
                .ok()
                .and_then(|c| c.reply().ok())
                .and_then(|r| r.value32().and_then(|mut v| v.next()))
                .or_else(|| {
                    use x11rb::protocol::res::{self, ClientIdMask, ClientIdSpec};
                    let spec = ClientIdSpec { client: child, mask: ClientIdMask::LOCAL_CLIENT_PID };
                    res::query_client_ids(&conn, &[spec])
                        .ok()
                        .and_then(|c| c.reply().ok())
                        .and_then(|r| r.ids.into_iter().find_map(|v| v.value.first().copied()))
                });
            let viewable = conn.get_window_attributes(child).ok().and_then(|c| c.reply().ok()).map(|a| a.map_state == MapState::VIEWABLE);
            if let Some(pid) = pid {
                if pgid_of(pid) == Some(pgid) && viewable == Some(true) {
                    let _ = conn.unmap_window(child);
                    hidden.push(child);
                    continue;
                }
            }
            if depth < 2 {
                stack.push((child, depth + 1));
            }
        }
    }
    // Done by the server before returning (a round trip), so the question shows on an empty screen.
    let _ = conn.get_input_focus().ok().and_then(|c| c.reply().ok());
    *HIDDEN.lock().unwrap_or_else(|e| e.into_inner()) = hidden;
}

/// Puts the game's windows back.
#[cfg(target_os = "linux")]
pub fn show_game() {
    use x11rb::protocol::xproto::ConnectionExt;
    let hidden = std::mem::take(&mut *HIDDEN.lock().unwrap_or_else(|e| e.into_inner()));
    if hidden.is_empty() {
        return;
    }
    let Ok((conn, _)) = x11rb::connect(None) else { return };
    for w in hidden {
        let _ = conn.map_window(w);
        let _ = conn
            .configure_window(w, &x11rb::protocol::xproto::ConfigureWindowAux::new().stack_mode(x11rb::protocol::xproto::StackMode::ABOVE));
    }
    let _ = conn.get_input_focus().ok().and_then(|c| c.reply().ok());
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn hide_game(_pgid: i32) {}
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn show_game() {}

#[cfg(target_os = "windows")]
static HIDDEN_WIN: std::sync::Mutex<Vec<isize>> = std::sync::Mutex::new(Vec::new());

#[cfg(target_os = "windows")]
fn process_tree_pids(root_pid: u32) -> std::collections::HashSet<u32> {
    use std::collections::{HashMap, HashSet};
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
    };
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap != -1isize as _ {
            let mut pe: PROCESSENTRY32W = std::mem::zeroed();
            pe.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            if Process32FirstW(snap, &mut pe) != 0 {
                loop {
                    children.entry(pe.th32ParentProcessID).or_default().push(pe.th32ProcessID);
                    if Process32NextW(snap, &mut pe) == 0 {
                        break;
                    }
                }
            }
            CloseHandle(snap);
        }
    }
    let mut out = HashSet::from([root_pid]);
    let mut stack = vec![root_pid];
    while let Some(p) = stack.pop() {
        if let Some(cs) = children.get(&p) {
            for &c in cs {
                if out.insert(c) {
                    stack.push(c);
                }
            }
        }
    }
    out
}

#[cfg(target_os = "windows")]
pub fn hide_game(pgid: i32) {
    use std::collections::HashSet;
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{EnumWindows, GetWindowThreadProcessId, IsWindowVisible, SW_HIDE, ShowWindow};

    struct Ctx {
        pids: HashSet<u32>,
        hidden: Vec<isize>,
    }
    unsafe extern "system" fn enum_cb(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let ctx = &mut *(lparam as *mut Ctx);
        if IsWindowVisible(hwnd) != 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, &mut pid);
            if ctx.pids.contains(&pid) {
                ShowWindow(hwnd, SW_HIDE);
                ctx.hidden.push(hwnd as isize);
            }
        }
        1
    }
    let mut ctx = Ctx { pids: process_tree_pids(pgid as u32), hidden: vec![] };
    unsafe { EnumWindows(Some(enum_cb), &mut ctx as *mut Ctx as LPARAM) };
    *HIDDEN_WIN.lock().unwrap_or_else(|e| e.into_inner()) = ctx.hidden;
}

#[cfg(target_os = "windows")]
pub fn show_game() {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::WindowsAndMessaging::{SW_SHOW, SetForegroundWindow, ShowWindow};
    let hidden = std::mem::take(&mut *HIDDEN_WIN.lock().unwrap_or_else(|e| e.into_inner()));
    for h in hidden {
        let hwnd = h as HWND;
        unsafe {
            ShowWindow(hwnd, SW_SHOW);
            SetForegroundWindow(hwnd);
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    /// Needs an X server (DISPLAY) and xeyes: `cargo test -- --ignored game_windows`.
    #[test]
    #[ignore]
    fn game_windows_hidden_then_shown() {
        use std::os::unix::process::CommandExt;
        use x11rb::protocol::xproto::{ConnectionExt, MapState};
        let mut child = std::process::Command::new("xeyes").process_group(0).spawn().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1500));
        let state = |w: u32| {
            let (conn, _) = x11rb::connect(None).unwrap();
            conn.get_window_attributes(w).unwrap().reply().unwrap().map_state
        };
        super::hide_game(child.id() as i32);
        let hidden = super::HIDDEN.lock().unwrap().clone();
        assert!(!hidden.is_empty(), "the game's window found");
        assert!(hidden.iter().all(|w| state(*w) == MapState::UNMAPPED));
        super::show_game();
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(hidden.iter().all(|w| state(*w) == MapState::VIEWABLE));
        let _ = child.kill();
    }
}
