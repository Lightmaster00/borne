//! Borne — core.
//!
//! Single entry point: the core opens its database, starts its local API (HTTP + WebSocket)
//! and its background tasks (gamepads, downloads, sync), then launches the QML UI
//! as a separate process and supervises it:
//!   - normal UI exit (code 0) -> the core stops;
//!   - crash -> restart; 2 crashes within a minute -> safe mode; 4 -> give up.
//!
//! Options:
//!   --no-ui           core only (prints the addresses; development and tests)
//!   --add-to-steam    adds Borne to Steam as a non-Steam game (steam.rs) and exits
//!   --ui <binary>     path to the UI (default: <package>/bin/borne-ui)
//!   --version         prints the version, build and commit
//!   --part-hashes <package>   prints the hash of each part of a package (updates; CI checks)
//! Variables: BORNE_DATA_DIR (data root), BORNE_DEBUG_INPUT=1 (test route).

mod api;
mod catalog;
mod cheats;
mod consoles;
mod controls;
mod db;
mod diag;
mod discover;
mod downloads;
mod emuinstall;
mod emulators;
mod events;
mod gamesettings;
mod hardware;
mod library;
mod logfile;
mod media;
mod nsz;
mod pad;
mod pairing;
mod paths;
mod quitkey;
mod romm;
mod savesync;
mod screenscraper;
mod sdldb;
mod secrets;
mod state;
mod steam;
mod stream;
mod switchcheck;
mod systemfiles;
mod update;

use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Locations inside the package.
///   Linux: <package>/bin/{borne,borne-ui}, <package>/resources
///   macOS: Borne.app/Contents/MacOS/{borne,borne-ui}, Contents/Resources/resources
struct Layout {
    ui_bin: PathBuf,
    resources: PathBuf,
}

fn layout() -> Layout {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.canonicalize().ok())
        .and_then(|p| p.parent().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."));
    if exe_dir.file_name().map(|n| n == "MacOS").unwrap_or(false) {
        let res = exe_dir.parent().unwrap_or(&exe_dir).join("Resources");
        return Layout { ui_bin: exe_dir.join("borne-ui"), resources: res.join("resources") };
    }
    let root = exe_dir.parent().map(PathBuf::from).unwrap_or_else(|| exe_dir.clone());
    Layout { ui_bin: root.join("bin").join("borne-ui"), resources: root.join("resources") }
}

fn random_token() -> String {
    use rand::RngExt;
    let mut rng = rand::rng();
    (0..32).map(|_| format!("{:x}", rng.random_range(0..16u8))).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version") {
        println!("Borne {} (build {}, {})", update::VERSION, update::build(), update::COMMIT);
        return;
    }
    if let Some(pkg) = args.iter().position(|a| a == "--part-hashes").and_then(|i| args.get(i + 1)) {
        match update::tree_hashes(std::path::Path::new(pkg)) {
            Ok(h) => println!("{}", serde_json::to_string(&h).unwrap_or_default()),
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let no_ui = args.iter().any(|a| a == "--no-ui");
    let layout = layout();
    // Adds Borne to Steam as a non-Steam game (install.sh runs it).
    if args.iter().any(|a| a == "--add-to-steam") {
        match steam::add(&layout.resources) {
            Ok(how) if how == "chimera" => {
                println!("Borne is added to Steam through Chimera: it shows after the next Steam session start.")
            }
            Ok(_) => println!("Borne is added to Steam: it shows the next time Steam starts."),
            Err(e) => {
                eprintln!("Borne was not added to Steam: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let ui_bin =
        args.iter().position(|a| a == "--ui").and_then(|i| args.get(i + 1)).map(PathBuf::from).unwrap_or_else(|| layout.ui_bin.clone());

    let paths = paths::Paths::from_env();
    if let Err(e) = paths.ensure() {
        crate::logfile::write("main", &format!("cannot create {}: {e}", paths.root.display()));
        std::process::exit(1);
    }
    logfile::init(paths.root.join("logs"));
    // A panic anywhere (an API request, a background task) goes to the log file too, so that a
    // diagnostic report says what failed instead of only "core unreachable".
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        logfile::write("panic", &format!("thread {thread}: {info}"));
        default_hook(info);
    }));
    logfile::write(
        "start",
        &format!("Borne {} (build {}) on {} {}", update::VERSION, update::build(), std::env::consts::OS, std::env::consts::ARCH),
    );
    // A damaged database must not keep Borne from starting: it is set aside (kept for a bug
    // report) and a new one is made; the catalog comes back with the next sync.
    let db = db::Db::open(&paths.db()).or_else(|e| {
        crate::logfile::write("main", &format!("unreadable local database: {e}; starting a new one"));
        let aside = paths.db().with_extension(format!("broken-{}", db::now()));
        std::fs::rename(paths.db(), &aside)?;
        for ext in ["db-wal", "db-shm"] {
            let _ = std::fs::remove_file(paths.db().with_extension(ext));
        }
        db::Db::open(&paths.db()).map_err(|e| std::io::Error::other(e.to_string()))
    });
    let db = db.unwrap_or_else(|e| {
        crate::logfile::write("main", &format!("no local database: {e}"));
        std::process::exit(1);
    });

    let app: state::Shared = Arc::new(state::App {
        paths,
        db,
        hub: events::Broadcaster::default(),
        pads: Arc::new(Mutex::new(pad::PadState::default())),
        resources: layout.resources.clone(),
        pairing: Mutex::new(None),
        pairing_gen: AtomicU64::new(0),
        sync: Mutex::new(state::SyncState::default()),
        dl_cancel: Mutex::new(Default::default()),
        dl_pause: Mutex::new(Default::default()),
        dl_wake: (Mutex::new(false), Condvar::new()),
        online: AtomicBool::new(false),
        debug_input: std::env::var("BORNE_DEBUG_INPUT").as_deref() == Ok("1"),
    });

    {
        let hub = app.hub.clone();
        let on_quit = app.clone();
        pad::spawn(
            move |json| hub.send(json),
            app.pads.clone(),
            move || {
                if emulators::playing() {
                    logfile::write("play", "quit chord: asking whether to quit");
                    emulators::ask_quit(&on_quit);
                }
            },
        );
    }

    // Escape during a game: Borne's question, not the emulator's menu.
    quitkey::spawn(app.clone());

    // Profiles named before names took a capital: given one.
    for p in app.db.profiles() {
        let c = api::capitalized(&p.name);
        if c != p.name {
            app.db.rename_profile(&p.id, &c);
        }
    }

    // ChimeraOS: Borne's Steam shortcut kept pointing at this copy.
    steam::keep_up_to_date(&app, &layout.resources);

    // Pick up the state left by the previous session.
    downloads::verify_local(&app);
    let requeued = app.db.requeue_interrupted();
    if requeued > 0 {
        app.db.log("download", &format!("{requeued} interrupted download(s) resumed"));
    }
    downloads::spawn_worker(app.clone());
    stream::start(&app);
    update::start(&app);
    {
        let app = app.clone();
        std::thread::spawn(move || {
            screenscraper::cut_stored_hinges(&app);
            screenscraper::trim_stored_spines(&app);
        });
    }
    emuinstall::set_http_cache(app.paths.root.join("cache/releases"));
    emuinstall::start_updates(&app);
    if app.client().is_some() {
        catalog::start_sync(&app);
    }

    let token = random_token();
    let http_port = api::start(app.clone(), token.clone()).expect("starting the HTTP API");
    let ws_port = events::start(token.clone(), app.hub.clone()).expect("starting the WebSocket");
    let api_url = format!("http://127.0.0.1:{http_port}/{token}");
    let ws_url = format!("ws://127.0.0.1:{ws_port}/{token}");
    crate::logfile::write("main", &format!("data {}", app.paths.root.display()));
    // The URLs carry the session token: they go to stderr (read by whoever launched the core,
    // e.g. tests) but never to the log file.
    eprintln!("[borne] API {api_url}");
    eprintln!("[borne] events {ws_url}");
    logfile::write("start", &format!("API on port {http_port}, events on port {ws_port}"));

    if no_ui {
        loop {
            std::thread::sleep(Duration::from_millis(500));
            if update::RESTART.load(std::sync::atomic::Ordering::SeqCst) {
                stream::stop();
                update::exec_new_core();
            }
        }
    }

    let mut crashes: Vec<Instant> = vec![];
    loop {
        let safe_mode = crashes.iter().filter(|t| t.elapsed() < Duration::from_secs(60)).count() >= 2;
        if safe_mode {
            logfile::write("main", "safe mode: default theme");
        }
        let status = Command::new(&ui_bin)
            .env("BORNE_API", &api_url)
            .env("BORNE_WS", &ws_url)
            .env("BORNE_SAFE_MODE", if safe_mode { "1" } else { "0" })
            .env("BORNE_UI_RESTARTS", crashes.len().to_string())
            .spawn()
            .and_then(|mut ui| wait_ui(&mut ui));
        match status {
            // Closed by the system (Steam's "Exit game", a log-out): Borne quits with it, never
            // starting its interface again behind the one closing it.
            Ok(s) if s.success() || stopped_by_system(&s) => {
                if !s.success() {
                    logfile::write("main", &format!("closed by the system ({s})"));
                }
                emulators::stop();
                stop_stream_quickly();
                if update::RESTART.load(std::sync::atomic::Ordering::SeqCst) {
                    update::exec_new_core();
                }
                break;
            }
            Ok(s) => {
                logfile::write("ui", &format!("the UI stopped ({s}): restarting"));
                crashes.push(Instant::now());
            }
            Err(e) => {
                logfile::write("ui", &format!("cannot launch the UI {}: {e}", ui_bin.display()));
                std::process::exit(1);
            }
        }
        crashes.retain(|t| t.elapsed() < Duration::from_secs(60));
        if crashes.len() >= 4 {
            logfile::write("ui", "too many UI crashes: giving up");
            stream::stop();
            std::process::exit(1);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Set when the system asks Borne to quit (SIGTERM, SIGINT, SIGHUP).
static QUIT_ASKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn on_quit_signal(_: libc::c_int) {
    QUIT_ASKED.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// Waits for the interface; when the system asks Borne to quit meanwhile, the interface is closed
/// (it is given two seconds, then stopped) and its end returned.
fn wait_ui(ui: &mut std::process::Child) -> std::io::Result<std::process::ExitStatus> {
    static HANDLERS: std::sync::Once = std::sync::Once::new();
    HANDLERS.call_once(|| unsafe {
        for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::signal(sig, on_quit_signal as *const () as libc::sighandler_t);
        }
    });
    let mut asked_at: Option<Instant> = None;
    loop {
        if let Some(s) = ui.try_wait()? {
            return Ok(s);
        }
        if QUIT_ASKED.load(std::sync::atomic::Ordering::SeqCst) {
            match asked_at {
                None => {
                    asked_at = Some(Instant::now());
                    unsafe { libc::kill(ui.id() as i32, libc::SIGTERM) };
                }
                Some(t) if t.elapsed() > Duration::from_secs(2) => {
                    let _ = ui.kill();
                }
                _ => {}
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The interface ended by the system's request (a signal to quit), not by a crash.
fn stopped_by_system(s: &std::process::ExitStatus) -> bool {
    use std::os::unix::process::ExitStatusExt;
    QUIT_ASKED.load(std::sync::atomic::Ordering::SeqCst)
        || matches!(s.signal(), Some(libc::SIGTERM) | Some(libc::SIGINT) | Some(libc::SIGHUP) | Some(libc::SIGKILL))
}

/// The virtual mount stopped, without waiting more than two seconds for a read still under way
/// (a busy mount is left to the system, which drops it with the process).
fn stop_stream_quickly() {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        stream::stop();
        let _ = tx.send(());
    });
    let _ = rx.recv_timeout(Duration::from_secs(2));
}
