//! Updates from GitHub releases.
//!
//! Two channels, chosen in the settings:
//!   stable  the latest published release (tag vX.Y.Z)        …/releases/latest/download/latest.json
//!   dev     rebuilt on every change of main (pre-release "dev") …/releases/download/dev/latest.json
//!
//! `latest.json` (written by CI) lists, per platform, the archive URL, its size and SHA-256.
//! Builds are ordered by their CI build number (`BORNE_BUILD`, set at compile time).
//!
//! Install: download next to the data, verify the SHA-256, extract next to the installed package,
//! then on "apply" swap the directories (the previous package is kept as `.borne-previous`) and
//! restart on the new core. Local builds (no build number) and read-only installs are not updated.
//! `BORNE_UPDATE_URL` replaces the GitHub address (tests).

use crate::state::Shared;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

const DEFAULT_BASE: &str = "https://github.com/Lightmaster00/borne/releases";

pub const VERSION: &str = match option_env!("BORNE_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};
pub const COMMIT: &str = match option_env!("BORNE_COMMIT") {
    Some(c) => c,
    None => "local",
};

/// CI build number; 0 for a local build.
pub fn build() -> u64 {
    option_env!("BORNE_BUILD").and_then(|b| b.parse().ok()).unwrap_or(0)
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct Asset {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct Manifest {
    pub version: String,
    pub build: u64,
    #[serde(default)]
    pub channel: String,
    #[serde(default)]
    pub commit: String,
    #[serde(default)]
    pub date: String,
    #[serde(default)]
    pub notes: String,
    pub assets: std::collections::HashMap<String, Asset>,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct UpdateState {
    /// idle | checking | uptodate | available | downloading | ready | error | unsupported
    pub state: String,
    pub available: Option<Manifest>,
    pub received: u64,
    pub total: u64,
    pub error: Option<String>,
    pub checked_at: Option<i64>,
}

static STATE: Mutex<Option<UpdateState>> = Mutex::new(None);
static BUSY: AtomicBool = AtomicBool::new(false);
/// Set when an update was applied: the supervisor restarts on the new core instead of exiting.
pub static RESTART: AtomicBool = AtomicBool::new(false);

fn get_state() -> UpdateState {
    STATE.lock().unwrap().clone().unwrap_or_else(|| UpdateState { state: "idle".into(), ..Default::default() })
}

fn set_state(app: &Shared, f: impl FnOnce(&mut UpdateState)) {
    let mut guard = STATE.lock().unwrap();
    let mut s = guard.clone().unwrap_or_else(|| UpdateState { state: "idle".into(), ..Default::default() });
    f(&mut s);
    *guard = Some(s.clone());
    drop(guard);
    app.emit(json!({ "type": "update", "update": s }));
}

pub fn channel(app: &Shared) -> String {
    app.db.setting("update_channel").unwrap_or_else(|| "stable".into())
}
pub fn auto_check(app: &Shared) -> bool {
    app.db.setting("update_auto").as_deref() != Some("0")
}

fn platform() -> String {
    format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH)
}

/// The installed package: Linux `<dir>/Borne` (bin/, ui/, lib/…), macOS `…/Borne.app`.
pub fn package_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let bin = exe.parent()?;
    if bin.file_name()? == "MacOS" {
        let app = bin.parent()?.parent()?;
        return app.extension().map(|e| e == "app").unwrap_or(false).then(|| app.to_path_buf());
    }
    let pkg = bin.parent()?;
    (bin.file_name()? == "bin" && pkg.join("ui").is_dir()).then(|| pkg.to_path_buf())
}

/// Why this installation cannot update itself, if it cannot.
pub fn unsupported_reason() -> Option<String> {
    if build() == 0 {
        return Some("this copy was built locally; updates come with the builds published on GitHub".into());
    }
    if std::env::var_os("FLATPAK_ID").is_some() {
        return Some("installed with Flatpak: update it with Flatpak".into());
    }
    let Some(pkg) = package_dir() else {
        return Some("installation folder not recognized".into());
    };
    let parent = pkg.parent()?;
    let probe = parent.join(".borne-write-test");
    match std::fs::write(&probe, b"") {
        Ok(()) => {
            let _ = std::fs::remove_file(probe);
            None
        }
        Err(_) => Some(format!("{} is not writable", parent.display())),
    }
}

pub fn status(app: &Shared) -> Value {
    json!({
        "current": { "version": VERSION, "build": build(), "commit": COMMIT, "platform": platform() },
        "channel": channel(app),
        "auto_check": auto_check(app),
        "unsupported": unsupported_reason(),
        "update": get_state(),
    })
}

fn base() -> String {
    std::env::var("BORNE_UPDATE_URL").unwrap_or_else(|_| DEFAULT_BASE.into()).trim_end_matches('/').to_string()
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .tls_config(crate::romm::tls())
        .timeout_connect(Some(Duration::from_secs(10)))
        .timeout_recv_response(Some(Duration::from_secs(20)))
        .user_agent(format!("Borne/{VERSION}"))
        .build()
        .into()
}

fn fetch_manifest(channel: &str) -> Result<Manifest, String> {
    let url = if channel == "dev" {
        format!("{}/download/dev/latest.json", base())
    } else {
        format!("{}/latest/download/latest.json", base())
    };
    let mut resp = agent().get(&url).call().map_err(|e| format!("update server unreachable ({e})"))?;
    if resp.status().as_u16() == 404 {
        return Err("no version published on this channel yet".into());
    }
    if !resp.status().is_success() {
        return Err(format!("update server answered {}", resp.status().as_u16()));
    }
    let body = resp.body_mut().with_config().limit(1 << 20).read_to_vec().map_err(|e| e.to_string())?;
    serde_json::from_slice(&body).map_err(|e| format!("unreadable update information ({e})"))
}

/// Looks for a newer build on the chosen channel (background thread).
pub fn check(app: &Shared) {
    if let Some(reason) = unsupported_reason() {
        set_state(app, |s| {
            s.state = "unsupported".into();
            s.error = Some(reason);
        });
        return;
    }
    if BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        set_state(&app, |s| {
            s.state = "checking".into();
            s.error = None;
        });
        let result = fetch_manifest(&channel(&app));
        set_state(&app, |s| {
            s.checked_at = Some(crate::db::now());
            match result {
                Ok(m) if m.build > build() && m.assets.contains_key(&platform()) => {
                    s.state = "available".into();
                    s.available = Some(m);
                }
                Ok(_) => {
                    s.state = "uptodate".into();
                    s.available = None;
                }
                Err(e) => {
                    s.state = "error".into();
                    s.error = Some(e);
                }
            }
        });
        BUSY.store(false, Ordering::SeqCst);
    });
}

fn staging_dir(pkg: &Path, build: u64) -> PathBuf {
    pkg.parent().unwrap_or(Path::new("/")).join(format!(".borne-update-{build}"))
}

/// Downloads, verifies and extracts the available build next to the installed package.
pub fn download(app: &Shared) -> Result<(), String> {
    let manifest = get_state().available.ok_or("no update available")?;
    let asset = manifest.assets.get(&platform()).cloned().ok_or("no build for this platform")?;
    let pkg = package_dir().ok_or("installation folder not recognized")?;
    if BUSY.swap(true, Ordering::SeqCst) {
        return Err("an update is already in progress".into());
    }
    let app = app.clone();
    std::thread::spawn(move || {
        let r = fetch_and_extract(&app, &manifest, &asset, &pkg);
        set_state(&app, |s| match r {
            Ok(()) => {
                s.state = "ready".into();
                s.error = None;
            }
            Err(e) => {
                s.state = "error".into();
                s.error = Some(e);
            }
        });
        BUSY.store(false, Ordering::SeqCst);
    });
    Ok(())
}

fn fetch_and_extract(app: &Shared, m: &Manifest, asset: &Asset, pkg: &Path) -> Result<(), String> {
    set_state(app, |s| {
        s.state = "downloading".into();
        s.received = 0;
        s.total = asset.size;
        s.error = None;
    });
    let dir = app.paths.root.join("updates");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let archive = dir.join(format!("borne-{}.{}", m.build, if asset.url.ends_with(".zip") { "zip" } else { "tar.gz" }));
    let resp = agent().get(&asset.url).call().map_err(|e| format!("download failed ({e})"))?;
    if !resp.status().is_success() {
        return Err(format!("download failed (HTTP {})", resp.status().as_u16()));
    }
    let mut reader = resp.into_body().into_reader();
    let mut out = std::fs::File::create(&archive).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    let mut received = 0u64;
    let mut last = std::time::Instant::now();
    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("download interrupted ({e})"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        received += n as u64;
        if last.elapsed() > Duration::from_millis(250) {
            last = std::time::Instant::now();
            set_state(app, |s| s.received = received);
        }
    }
    out.flush().map_err(|e| e.to_string())?;
    let digest: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if !digest.eq_ignore_ascii_case(asset.sha256.trim()) {
        let _ = std::fs::remove_file(&archive);
        return Err("the downloaded file is damaged (SHA-256 mismatch)".into());
    }
    set_state(app, |s| s.received = received);

    let staging = staging_dir(pkg, m.build);
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
    // System tools keep permissions and symbolic links (Qt frameworks on macOS) intact.
    let status = if cfg!(target_os = "macos") {
        std::process::Command::new("ditto").arg("-x").arg("-k").arg(&archive).arg(&staging).status()
    } else {
        std::process::Command::new("tar").arg("-xzf").arg(&archive).arg("-C").arg(&staging).status()
    };
    match status {
        Ok(s) if s.success() => {}
        _ => return Err("cannot extract the update".into()),
    }
    let new_pkg = staging.join(pkg.file_name().unwrap_or_default());
    let core = if cfg!(target_os = "macos") { new_pkg.join("Contents/MacOS/borne") } else { new_pkg.join("bin/borne") };
    if !core.is_file() {
        return Err("the update does not contain Borne".into());
    }
    let _ = std::fs::remove_file(&archive);
    app.db.log("update", &format!("build {} ({}) downloaded and verified", m.build, m.version));
    Ok(())
}

/// Swaps the installed package for the downloaded one. The restart happens when the UI quits.
pub fn apply(app: &Shared) -> Result<(), String> {
    let state = get_state();
    if state.state != "ready" {
        return Err("no update ready to install".into());
    }
    let m = state.available.ok_or("no update ready to install")?;
    let pkg = package_dir().ok_or("installation folder not recognized")?;
    let parent = pkg.parent().ok_or("installation folder not recognized")?.to_path_buf();
    let staging = staging_dir(&pkg, m.build);
    let new_pkg = staging.join(pkg.file_name().unwrap_or_default());
    let previous = parent.join(".borne-previous");
    let _ = std::fs::remove_dir_all(&previous);
    std::fs::rename(&pkg, &previous).map_err(|e| format!("cannot move the current version aside ({e})"))?;
    if let Err(e) = std::fs::rename(&new_pkg, &pkg) {
        // Put the current version back: Borne must never be left without a package.
        let _ = std::fs::rename(&previous, &pkg);
        return Err(format!("cannot install the update ({e})"));
    }
    let _ = std::fs::remove_dir_all(&staging);
    app.db.log("update", &format!("updated to build {} ({}); restarting", m.build, m.version));
    RESTART.store(true, Ordering::SeqCst);
    Ok(())
}

/// Path of the new core after an update was applied.
pub fn restart_exe() -> Option<PathBuf> {
    let pkg = package_dir_after_swap()?;
    Some(if cfg!(target_os = "macos") { pkg.join("Contents/MacOS/borne") } else { pkg.join("bin/borne") })
}

fn package_dir_after_swap() -> Option<PathBuf> {
    // current_exe() may now point into .borne-previous: rebuild the original path.
    let exe = std::env::current_exe().ok()?;
    let exe = exe.canonicalize().unwrap_or(exe);
    let mut p = exe.parent()?.to_path_buf();
    if p.file_name()? == "MacOS" {
        p = p.parent()?.parent()?.to_path_buf();
    } else {
        p = p.parent()?.to_path_buf();
    }
    let parent = p.parent()?;
    let name = if p.file_name()? == ".borne-previous" {
        if cfg!(target_os = "macos") { "Borne.app".to_string() } else { "Borne".to_string() }
    } else {
        p.file_name()?.to_string_lossy().into_owned()
    };
    Some(parent.join(name))
}

/// Replaces this process with the new core (Unix exec), keeping the arguments.
pub fn exec_new_core() -> ! {
    use std::os::unix::process::CommandExt;
    let exe = restart_exe().unwrap_or_else(|| PathBuf::from("borne"));
    let args: Vec<String> = std::env::args().skip(1).collect();
    eprintln!("[borne] restarting on {}", exe.display());
    let err = std::process::Command::new(&exe).args(args).exec();
    eprintln!("[borne] cannot restart: {err}");
    std::process::exit(1);
}

/// Checks at startup, then every 6 hours, when automatic checks are on.
pub fn start(app: &Shared) {
    if unsupported_reason().is_some() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(20));
        if auto_check(&app) && matches!(get_state().state.as_str(), "idle" | "uptodate" | "error" | "available") {
            check(&app);
        }
        std::thread::sleep(Duration::from_secs(6 * 3600));
    });
}
