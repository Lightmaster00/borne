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
//!   --ui <binary>     path to the UI (default: <package>/bin/borne-ui)
//!   --version         prints the version, build and commit
//!   --part-hashes <package>   prints the hash of each part of a package (updates; CI checks)
//! Variables: BORNE_DATA_DIR (data root), BORNE_DEBUG_INPUT=1 (test route).

mod api;
mod catalog;
mod cheats;
mod db;
mod diag;
mod downloads;
mod emuinstall;
mod emulators;
mod events;
mod gamesettings;
mod library;
mod logfile;
mod media;
mod pad;
mod pairing;
mod paths;
mod romm;
mod savesync;
mod screenscraper;
mod secrets;
mod state;
mod stream;
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
    use rand::Rng;
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
    let ui_bin =
        args.iter().position(|a| a == "--ui").and_then(|i| args.get(i + 1)).map(PathBuf::from).unwrap_or_else(|| layout.ui_bin.clone());

    let paths = paths::Paths::from_env();
    if let Err(e) = paths.ensure() {
        crate::logfile::write("main", &format!("cannot create {}: {e}", paths.root.display()));
        std::process::exit(1);
    }
    logfile::init(paths.root.join("logs"));
    logfile::write(
        "start",
        &format!("Borne {} (build {}) on {} {}", update::VERSION, update::build(), std::env::consts::OS, std::env::consts::ARCH),
    );
    let db = db::Db::open(&paths.db()).unwrap_or_else(|e| {
        crate::logfile::write("main", &format!("unreadable local database: {e}"));
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
        pad::spawn(move |json| hub.send(json), app.pads.clone());
    }

    // Pick up the state left by the previous session.
    downloads::verify_local(&app);
    let requeued = app.db.requeue_interrupted();
    if requeued > 0 {
        app.db.log("download", &format!("{requeued} interrupted download(s) resumed"));
    }
    downloads::spawn_worker(app.clone());
    stream::start(&app);
    update::start(&app);
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
            .status();
        match status {
            Ok(s) if s.success() => {
                stream::stop();
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
