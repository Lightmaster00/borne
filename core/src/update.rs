//! Updates from GitHub releases.
//!
//! Two channels, chosen in the settings:
//!   stable  the latest published release (tag vX.Y.Z)        …/releases/latest/download/latest.json
//!   dev     rebuilt on every change of main (pre-release "dev") …/releases/download/dev/latest.json
//!
//! `latest.json` (written by CI, `scripts/release/manifest.py`) lists, per platform, the full
//! archive (URL, size, SHA-256) and the package split in parts (`parts`): `core` (the programs),
//! `ui` (views, sounds, fonts, translations) and `runtime` (Qt), each with its archive and the
//! hash of its files (`tree`, see `tree_hash`). Builds are ordered by their CI build number
//! (`BORNE_BUILD`, set at compile time).
//!
//! Install: only the parts whose files differ from the installed ones are downloaded (a usual
//! update: a few MB instead of the whole package), verified (SHA-256), and laid over a copy of the
//! installed package next to it; the copy must then match every part's hash exactly, else the full
//! archive is fetched instead. On "apply" the directories are swapped (the previous package is
//! kept as `.borne-previous`) and the new core restarts. Local builds (no build number) and
//! read-only installs are not updated. `BORNE_UPDATE_URL` replaces the GitHub address (tests).

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
    /// The package's parts (core, ui, runtime); absent in manifests of older builds.
    #[serde(default)]
    pub parts: std::collections::BTreeMap<String, Part>,
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct Part {
    pub url: String,
    pub sha256: String,
    pub size: u64,
    /// `tree_hash` of the part's files in the package.
    pub tree: String,
}

/// The part a package file belongs to, by its path in the package (`/` separators). Same rules
/// as `scripts/release/parts.py`.
pub fn part_of(rel: &str) -> &'static str {
    let (runtime, ui): (&[&str], &[&str]) = if cfg!(target_os = "macos") {
        (
            &["Contents/Frameworks/", "Contents/PlugIns/", "Contents/Resources/qml/"],
            &["Contents/Resources/ui/", "Contents/Resources/resources/"],
        )
    } else {
        (&["lib/", "plugins/", "qml/"], &["ui/", "resources/"])
    };
    if runtime.iter().any(|p| rel.starts_with(p)) {
        "runtime"
    } else if ui.iter().any(|p| rel.starts_with(p)) {
        "ui"
    } else {
        "core"
    }
}

/// Every file and symbolic link of a package, with its path relative to it (sorted).
fn package_entries(root: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    let mut out = vec![];
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for e in std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))? {
            let p = e.map_err(|e| e.to_string())?.path();
            let meta = std::fs::symlink_metadata(&p).map_err(|e| e.to_string())?;
            if meta.is_dir() {
                stack.push(p);
            } else {
                let rel = p.strip_prefix(root).map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
                out.push((rel, p));
            }
        }
    }
    out.sort();
    Ok(out)
}

/// The hash of each part of a package: SHA-256 over its files, sorted by path, one line each:
/// `path \0 f \0 sha256(content) x|-` (executable or not) or `path \0 l \0 link target`.
/// Same computation as `scripts/release/parts.py`.
pub fn tree_hashes(root: &Path) -> Result<std::collections::BTreeMap<String, String>, String> {
    use std::os::unix::fs::PermissionsExt;
    let mut hashers: std::collections::BTreeMap<String, Sha256> =
        ["core", "ui", "runtime"].iter().map(|p| (p.to_string(), Sha256::new())).collect();
    for (rel, path) in package_entries(root)? {
        let meta = std::fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        let line = if meta.file_type().is_symlink() {
            let target = std::fs::read_link(&path).map_err(|e| e.to_string())?;
            format!("{rel}\0l\0{}\n", target.to_string_lossy())
        } else {
            let mut f = std::fs::File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let mut h = Sha256::new();
            let mut buf = vec![0u8; 1 << 16];
            loop {
                let n = std::io::Read::read(&mut f, &mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                h.update(&buf[..n]);
            }
            let exec = if meta.permissions().mode() & 0o111 != 0 { "x" } else { "-" };
            format!("{rel}\0f\0{}{exec}\n", hex(&h.finalize()))
        };
        hashers.get_mut(part_of(&rel)).unwrap().update(line.as_bytes());
    }
    Ok(hashers.into_iter().map(|(k, h)| (k, hex(&h.finalize()))).collect())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
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
    /// What the available build costs to download here: the parts that differ from the installed
    /// ones (`parts`), or the whole archive when they cannot be used (`parts` empty).
    pub size: u64,
    pub parts: Vec<String>,
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
    if std::env::current_exe().map(|p| p.to_string_lossy().contains("/AppTranslocation/")).unwrap_or(false) {
        return Some("macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again".into());
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
        "release_page": release_page(app),
        "update": get_state(),
    })
}

fn base() -> String {
    std::env::var("BORNE_UPDATE_URL").unwrap_or_else(|_| DEFAULT_BASE.into()).trim_end_matches('/').to_string()
}

/// Packages are only fetched from where the manifest lives (GitHub releases of this project,
/// or the test server given in BORNE_UPDATE_URL), over HTTPS for the real one.
fn asset_url_allowed(url: &str) -> bool {
    if std::env::var("BORNE_UPDATE_URL").is_ok() {
        return url.starts_with(&format!("{}/", base()));
    }
    url.starts_with("https://github.com/Lightmaster00/borne/releases/download/")
        || url.starts_with("https://objects.githubusercontent.com/")
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
    let url =
        if channel == "dev" { format!("{}/download/dev/latest.json", base()) } else { format!("{}/latest/download/latest.json", base()) };
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

/// The page to download a build by hand: the channel's release on GitHub.
pub fn release_page(app: &Shared) -> String {
    if channel(app) == "dev" {
        format!("{DEFAULT_BASE}/tag/dev")
    } else {
        format!("{DEFAULT_BASE}/latest")
    }
}

/// Looks for a newer build on the chosen channel (background thread). `force` offers the
/// channel's latest build even when it is not newer (reinstall, or move from dev to stable).
/// Works even where Borne cannot install itself: the build is then offered as a manual download.
pub fn check(app: &Shared, force: bool) {
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
                Ok(m) if (force || m.build > build()) && m.assets.contains_key(&platform()) => {
                    let (size, parts) = download_size(&m.assets[&platform()]);
                    s.state = "available".into();
                    s.available = Some(m);
                    s.size = size;
                    s.parts = parts;
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

/// The bytes an update will download: the parts whose hash differs from the installed package's,
/// else the whole archive (no parts published, or the installed package cannot be read).
fn download_size(asset: &Asset) -> (u64, Vec<String>) {
    if asset.parts.is_empty() {
        return (asset.size, vec![]);
    }
    match package_dir().map(|p| tree_hashes(&p)) {
        Some(Ok(local)) => {
            let changed: Vec<(&String, &Part)> = asset.parts.iter().filter(|(name, p)| local.get(*name) != Some(&p.tree)).collect();
            (changed.iter().map(|(_, p)| p.size).sum(), changed.iter().map(|(n, _)| n.to_string()).collect())
        }
        _ => (asset.size, vec![]),
    }
}

fn staging_dir(pkg: &Path, build: u64) -> PathBuf {
    pkg.parent().unwrap_or(Path::new("/")).join(format!(".borne-update-{build}"))
}

/// Downloads, verifies and extracts the available build next to the installed package.
pub fn download(app: &Shared) -> Result<(), String> {
    if let Some(reason) = unsupported_reason() {
        return Err(reason);
    }
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

/// Downloads `url` to `dest`, refusing more bytes than announced and a SHA-256 mismatch;
/// progress is counted from `offset` (several files of one update).
fn fetch_file(app: &Shared, url: &str, size: u64, sha256: &str, dest: &Path, offset: u64) -> Result<u64, String> {
    if !asset_url_allowed(url) {
        return Err("the update points to an unexpected address: refused".into());
    }
    let resp = agent().get(url).call().map_err(|e| format!("download failed ({e})"))?;
    if !resp.status().is_success() {
        return Err(format!("download failed (HTTP {})", resp.status().as_u16()));
    }
    let mut reader = resp.into_body().into_reader();
    let mut out = std::fs::File::create(dest).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    let mut received = 0u64;
    let mut last = std::time::Instant::now();
    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("download interrupted ({e})"))?;
        if n == 0 {
            break;
        }
        received += n as u64;
        if size > 0 && received > size {
            drop(out);
            let _ = std::fs::remove_file(dest);
            return Err("the downloaded file is larger than announced: refused".into());
        }
        hasher.update(&buf[..n]);
        out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        if last.elapsed() > Duration::from_millis(250) {
            last = std::time::Instant::now();
            set_state(app, |s| s.received = offset + received);
        }
    }
    out.flush().map_err(|e| e.to_string())?;
    if !hex(&hasher.finalize()).eq_ignore_ascii_case(sha256.trim()) {
        let _ = std::fs::remove_file(dest);
        return Err("the downloaded file is damaged (SHA-256 mismatch)".into());
    }
    set_state(app, |s| s.received = offset + received);
    Ok(received)
}

/// Extracts an archive into `dir` with the system's tools, which keep permissions and symbolic
/// links (Qt frameworks on macOS) intact.
fn extract(archive: &Path, dir: &Path) -> Result<(), String> {
    let zip = archive.extension().map(|e| e == "zip").unwrap_or(false);
    let status = if zip {
        std::process::Command::new("ditto").arg("-x").arg("-k").arg(archive).arg(dir).status()
    } else {
        std::process::Command::new("tar").arg("--no-same-owner").arg("-xzf").arg(archive).arg("-C").arg(dir).status()
    };
    match status {
        Ok(s) if s.success() => Ok(()),
        _ => Err("cannot extract the update".into()),
    }
}

/// Copies the installed package (symbolic links and permissions kept).
fn copy_package(from: &Path, to: &Path) -> Result<(), String> {
    let status = if cfg!(target_os = "macos") {
        std::process::Command::new("ditto").arg(from).arg(to).status()
    } else {
        std::process::Command::new("cp").arg("-a").arg(from).arg(to).status()
    };
    match status {
        Ok(s) if s.success() => Ok(()),
        _ => Err("cannot copy the installed version".into()),
    }
}

fn fetch_and_extract(app: &Shared, m: &Manifest, asset: &Asset, pkg: &Path) -> Result<(), String> {
    let dir = app.paths.root.join("updates");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let staging = staging_dir(pkg, m.build);
    if !asset.parts.is_empty() {
        match fetch_parts(app, m, asset, pkg, &dir, &staging) {
            Ok(()) => return Ok(()),
            Err(e) => app.db.log("update", &format!("update by parts not possible ({e}): downloading the whole version")),
        }
    }
    set_state(app, |s| {
        s.state = "downloading".into();
        s.received = 0;
        s.total = asset.size;
        s.error = None;
    });
    let archive = dir.join(format!("borne-{}.{}", m.build, if asset.url.ends_with(".zip") { "zip" } else { "tar.gz" }));
    fetch_file(app, &asset.url, asset.size, &asset.sha256, &archive, 0)?;
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
    extract(&archive, &staging)?;
    if find_package(&staging).is_none() {
        let found: Vec<String> = std::fs::read_dir(&staging)
            .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        app.db.log("update", &format!("no Borne package in the archive (found: {})", found.join(", ")));
        return Err("the update does not contain Borne".into());
    }
    let _ = std::fs::remove_file(&archive);
    app.db.log("update", &format!("build {} ({}) downloaded and verified", m.build, m.version));
    Ok(())
}

/// The update by parts: a copy of the installed package, the changed parts replaced, checked
/// against every part's hash.
fn fetch_parts(app: &Shared, m: &Manifest, asset: &Asset, pkg: &Path, dir: &Path, staging: &Path) -> Result<(), String> {
    let local = tree_hashes(pkg)?;
    let changed: Vec<(&String, &Part)> = asset.parts.iter().filter(|(name, p)| local.get(*name) != Some(&p.tree)).collect();
    let total: u64 = changed.iter().map(|(_, p)| p.size).sum();
    set_state(app, |s| {
        s.state = "downloading".into();
        s.received = 0;
        s.total = total;
        s.error = None;
    });
    let mut archives = vec![];
    let mut offset = 0;
    for (name, p) in &changed {
        let archive = dir.join(format!("borne-{}-{name}.tar.gz", m.build));
        offset += fetch_file(app, &p.url, p.size, &p.sha256, &archive, offset)?;
        archives.push((name.as_str(), archive));
    }
    let _ = std::fs::remove_dir_all(staging);
    std::fs::create_dir_all(staging).map_err(|e| e.to_string())?;
    let new_pkg = staging.join(pkg.file_name().ok_or("installation folder not recognized")?);
    copy_package(pkg, &new_pkg)?;
    for (name, archive) in &archives {
        // The part's old files go first: a file the new version no longer has must not stay.
        for (rel, path) in package_entries(&new_pkg)? {
            if part_of(&rel) == *name {
                std::fs::remove_file(&path).map_err(|e| e.to_string())?;
            }
        }
        extract(archive, &new_pkg)?;
    }
    let got = tree_hashes(&new_pkg)?;
    for (name, p) in &asset.parts {
        if got.get(name) != Some(&p.tree) {
            let _ = std::fs::remove_dir_all(staging);
            return Err(format!("the {name} part does not match after the update"));
        }
    }
    for (_, archive) in &archives {
        let _ = std::fs::remove_file(archive);
    }
    let names: Vec<&str> = archives.iter().map(|(n, _)| *n).collect();
    app.db.log(
        "update",
        &format!(
            "build {} ({}) assembled from {} ({:.1} MB instead of {:.1} MB) and verified",
            m.build,
            m.version,
            if names.is_empty() { "the installed files".to_string() } else { names.join(", ") },
            total as f64 / 1048576.0,
            asset.size as f64 / 1048576.0
        ),
    );
    Ok(())
}

/// The package inside an extracted archive, whatever its folder is called (the installed copy may
/// have been renamed, e.g. "Borne 2.app" or "Borne-dev"): the folder, at most two levels down,
/// that holds the core (macOS: `X.app/Contents/MacOS/borne`, Linux: `X/bin/borne`).
fn find_package(staging: &Path) -> Option<PathBuf> {
    let core_of = |p: &Path| {
        if cfg!(target_os = "macos") {
            p.join("Contents/MacOS/borne")
        } else {
            p.join("bin/borne")
        }
    };
    let entries = |d: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(d)
            .map(|r| {
                r.filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| p.is_dir() && !p.file_name().map(|n| n.to_string_lossy().starts_with("__MACOSX")).unwrap_or(false))
                    .collect()
            })
            .unwrap_or_default()
    };
    for a in entries(staging) {
        if core_of(&a).is_file() {
            return Some(a);
        }
        for b in entries(&a) {
            if core_of(&b).is_file() {
                return Some(b);
            }
        }
    }
    None
}

/// Swaps the installed package for the downloaded one. The restart happens when the UI quits.
pub fn apply(app: &Shared) -> Result<(), String> {
    if crate::emulators::playing() {
        return Err("a game is running: quit it first".into());
    }
    let state = get_state();
    if state.state != "ready" {
        return Err("no update ready to install".into());
    }
    let m = state.available.ok_or("no update ready to install")?;
    let pkg = package_dir().ok_or("installation folder not recognized")?;
    let parent = pkg.parent().ok_or("installation folder not recognized")?.to_path_buf();
    let staging = staging_dir(&pkg, m.build);
    let new_pkg = find_package(&staging).ok_or("the update does not contain Borne")?;
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
        if cfg!(target_os = "macos") {
            "Borne.app".to_string()
        } else {
            "Borne".to_string()
        }
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
    crate::logfile::write("update", &format!("restarting on {}", exe.display()));
    let err = std::process::Command::new(&exe).args(args).exec();
    crate::logfile::write("update", &format!("cannot restart: {err}"));
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
        if auto_check(&app)
            && !crate::emulators::playing()
            && matches!(get_state().state.as_str(), "idle" | "uptodate" | "error" | "available")
        {
            check(&app, false);
        }
        std::thread::sleep(Duration::from_secs(6 * 3600));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parts_and_their_hashes() {
        let root = std::env::temp_dir().join(format!("borne-parts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (core, ui, lib) = if cfg!(target_os = "macos") {
            ("Contents/MacOS/borne", "Contents/Resources/ui/Main.qml", "Contents/Frameworks/QtCore")
        } else {
            ("bin/borne", "ui/Main.qml", "lib/libQt6Core.so.6")
        };
        for (p, body) in [(core, "core"), (ui, "ui"), (lib, "qt")] {
            std::fs::create_dir_all(root.join(p).parent().unwrap()).unwrap();
            std::fs::write(root.join(p), body).unwrap();
        }
        assert_eq!(part_of(core), "core");
        assert_eq!(part_of(ui), "ui");
        assert_eq!(part_of(lib), "runtime");
        let a = tree_hashes(&root).unwrap();
        std::fs::write(root.join(ui), "ui 2").unwrap();
        let b = tree_hashes(&root).unwrap();
        assert_eq!(a["core"], b["core"]);
        assert_eq!(a["runtime"], b["runtime"]);
        assert_ne!(a["ui"], b["ui"]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn finds_the_package_whatever_its_name() {
        let root = std::env::temp_dir().join(format!("borne-upd-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let core = if cfg!(target_os = "macos") { "Borne.app/Contents/MacOS/borne" } else { "Borne/bin/borne" };
        let p = root.join("nested").join(core);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, b"").unwrap();
        let found = find_package(&root).unwrap();
        assert!(found.ends_with(if cfg!(target_os = "macos") { "Borne.app" } else { "Borne" }));
        assert!(find_package(&root.join("nested").join("missing")).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }
}
