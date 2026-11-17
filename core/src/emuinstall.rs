//! Emulators installed and kept up to date by Borne itself, in `emulators/<id>/<version>/` of the
//! data folder: the user never installs, configures or updates an emulator by hand.
//!
//! Where each program comes from is in `emulators.json`, per system:
//! - `github`: the latest release of a GitHub repository, the asset found by words in its name
//!   (checked against the SHA-256 GitHub publishes for it, when there is one);
//! - `buildbot`: RetroArch's latest stable build from buildbot.libretro.com; its cores come from
//!   the buildbot's nightly folder, one by one, as the consoles need them;
//! - `page`: a download page listing the latest release (Dolphin on macOS);
//! - `flatpak`: Flathub, for programs only distributed that way on Linux (`--user`).
//!
//! Archives (.zip, .7z, .tar.xz), disk images (.dmg, macOS) and AppImages (extracted once, so no
//! FUSE is needed) are unpacked; the new version replaces the old one only once it is complete.
//! Updates are checked every 6 hours and installed when no game is running.
//! BORNE_EMU_MIRROR redirects every address to a local stand-in (tests).

use crate::state::Shared;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

pub fn os() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

fn net(url: &str) -> String {
    match std::env::var("BORNE_EMU_MIRROR") {
        Ok(m) if !m.is_empty() => format!("{}/{}", m.trim_end_matches('/'), url.trim_start_matches("https://")),
        _ => url.to_string(),
    }
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .tls_config(crate::romm::tls())
        .timeout_connect(Some(Duration::from_secs(15)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .user_agent(format!("Borne/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .into()
}

/// Where release lists are kept with their ETag (set at start): asking again with it costs
/// nothing against GitHub's limit of 60 requests an hour, and a refusal for that limit falls back
/// on the copy kept.
static HTTP_CACHE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

pub fn set_http_cache(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    let _ = HTTP_CACHE.set(dir);
}

fn get_text(url: &str) -> Result<String, String> {
    let file = HTTP_CACHE.get().map(|d| {
        let h = <sha2::Sha256 as sha2::Digest>::digest(url.as_bytes());
        d.join(h.iter().take(12).map(|b| format!("{b:02x}")).collect::<String>())
    });
    let kept: Option<(String, String)> = file
        .as_ref()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|t| t.split_once('\n').map(|(e, b)| (e.to_string(), b.to_string())));
    let mut req = agent().get(net(url)).header("Accept", "application/vnd.github+json");
    if let Some((etag, _)) = &kept {
        req = req.header("If-None-Match", etag.as_str());
    }
    let mut r = match req.call() {
        Ok(r) => r,
        Err(e) => return kept.map(|(_, b)| b).ok_or(format!("{url}: {e}")),
    };
    match r.status().as_u16() {
        200 => {}
        304 => return kept.map(|(_, b)| b).ok_or(format!("{url} answered 304")),
        // Rate-limited: the copy kept, however old, rather than nothing.
        403 | 429 if kept.is_some() => return Ok(kept.unwrap().1),
        s => return Err(format!("{url} answered {s}")),
    }
    let etag = r.headers().get("etag").and_then(|v| v.to_str().ok()).map(String::from);
    let body = r.body_mut().with_config().limit(16 << 20).read_to_string().map_err(|e| e.to_string())?;
    if let (Some(f), Some(etag)) = (file, etag) {
        let _ = std::fs::write(f, format!("{etag}\n{body}"));
    }
    Ok(body)
}

/// The latest version offered for this system: (version, download address, sha256).
pub fn latest(spec: &Value) -> Result<(String, String, Option<String>), String> {
    match spec["type"].as_str() {
        Some("github") => {
            let repo = spec["repo"].as_str().ok_or("no repository")?;
            let fits = |name: &str| asset_fits(spec, name);
            let mut releases: Vec<Value> = vec![];
            if let Ok(t) = get_text(&format!("https://api.github.com/repos/{repo}/releases/latest")) {
                releases.extend(serde_json::from_str::<Value>(&t).ok());
            }
            if spec["prerelease"].as_bool().unwrap_or(false) || releases.is_empty() {
                let t = get_text(&format!("https://api.github.com/repos/{repo}/releases?per_page=10"))?;
                releases.extend(serde_json::from_str::<Value>(&t).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default());
            }
            for r in releases {
                if let Some(a) = r["assets"].as_array().into_iter().flatten().find(|a| a["name"].as_str().map(fits).unwrap_or(false)) {
                    let version = r["tag_name"].as_str().unwrap_or("?").to_string();
                    // A rolling tag ("latest"): the asset's date tells versions apart.
                    let version = if version == "latest" || version == "preview" || version == "continuous" {
                        format!("{version}-{}", a["updated_at"].as_str().unwrap_or(""))
                    } else {
                        version
                    };
                    let url = a["browser_download_url"].as_str().ok_or("no download address")?.to_string();
                    let digest = a["digest"].as_str().and_then(|d| d.strip_prefix("sha256:")).map(String::from);
                    return Ok((version, url, digest));
                }
            }
            Err(format!("no build for this system in {repo}'s releases"))
        }
        // Forgejo / Gitea (Eden): same shape as GitHub's API.
        Some("gitea") => {
            let base = spec["base"].as_str().ok_or("no server")?;
            let repo = spec["repo"].as_str().ok_or("no repository")?;
            let t = get_text(&format!("{base}/api/v1/repos/{repo}/releases?limit=10"))?;
            let releases: Vec<Value> = serde_json::from_str::<Value>(&t).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
            for r in releases.iter().filter(|r| spec["prerelease"].as_bool().unwrap_or(false) || r["prerelease"] != true) {
                if let Some(a) =
                    r["assets"].as_array().into_iter().flatten().find(|a| a["name"].as_str().map(|n| asset_fits(spec, n)).unwrap_or(false))
                {
                    let url = a["browser_download_url"].as_str().ok_or("no download address")?.to_string();
                    return Ok((r["tag_name"].as_str().unwrap_or("?").to_string(), url, None));
                }
            }
            Err(format!("no build for this system in {repo}'s releases"))
        }
        // GitLab (Ryubing): the latest release's links.
        Some("gitlab") => {
            let base = spec["base"].as_str().ok_or("no server")?;
            let project = spec["project"].as_str().ok_or("no project")?.replace('/', "%2F");
            let t = get_text(&format!("{base}/api/v4/projects/{project}/releases?per_page=10"))?;
            let releases: Vec<Value> = serde_json::from_str::<Value>(&t).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
            for r in releases.iter().filter(|r| r["upcoming_release"] != true) {
                if let Some(l) = r["assets"]["links"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|l| l["name"].as_str().map(|n| asset_fits(spec, n)).unwrap_or(false))
                {
                    let url = l["direct_asset_url"].as_str().or(l["url"].as_str()).ok_or("no download address")?.to_string();
                    return Ok((r["tag_name"].as_str().unwrap_or("?").to_string(), url, None));
                }
            }
            Err(format!("no build for this system in {project}'s releases"))
        }
        Some("buildbot") => {
            let html = get_text("https://buildbot.libretro.com/stable/")?;
            let mut versions: Vec<Vec<u32>> = html
                .split("href=\"")
                .skip(1)
                .filter_map(|s| s.split('"').next())
                .filter_map(|h| h.trim_end_matches('/').rsplit('/').next().map(String::from))
                .filter_map(|v| {
                    let parts: Option<Vec<u32>> = v.split('.').map(|p| p.parse().ok()).collect();
                    parts.filter(|p| p.len() >= 2)
                })
                .collect();
            versions.sort();
            versions.dedup();
            let file = spec["file"].as_str().ok_or("no file")?;
            let (dir, name) = file.rsplit_once('/').unwrap_or(("", file));
            // The newest version whose folder holds this system's build: a version is listed
            // before every build of it is uploaded (the newest had no macOS build: 404).
            for v in versions.iter().rev().take(5) {
                let v = v.iter().map(|n| n.to_string()).collect::<Vec<_>>().join(".");
                let listing = get_text(&format!("https://buildbot.libretro.com/stable/{v}/{dir}/")).unwrap_or_default();
                if listing.contains(&format!("{name}\"")) || listing.contains(&format!("/{name}")) {
                    return Ok((v.clone(), format!("https://buildbot.libretro.com/stable/{v}/{file}"), None));
                }
            }
            Err("no RetroArch build for this computer on the buildbot".into())
        }
        Some("page") => {
            let html = get_text(spec["url"].as_str().ok_or("no page")?)?;
            let link = spec["link"].as_str().ok_or("no link")?;
            let ends = spec["ends"].as_str().unwrap_or("");
            let start = html.find(link).ok_or("no download link on the page")?;
            let rest = &html[start..];
            let end = rest.find(ends).ok_or("no download link on the page")? + ends.len();
            let url = rest[..end].to_string();
            if url.contains(['"', '<', ' ']) {
                return Err("unexpected download link".into());
            }
            let version = url[link.len()..].split('/').next().unwrap_or("?").to_string();
            Ok((version, url, None))
        }
        Some("flatpak") => Ok(("flatpak".into(), String::new(), None)),
        _ => Err("no installation source for this system".into()),
    }
}

/// Whether a release file is the build for this system: every word of `has` in its name, none of
/// `not`, and one of the endings in `ends` (case ignored).
fn asset_fits(spec: &Value, name: &str) -> bool {
    let n = name.to_lowercase();
    let list = |k: &str| -> Vec<String> {
        match &spec[k] {
            Value::String(s) => vec![s.to_lowercase()],
            Value::Array(a) => a.iter().filter_map(|v| v.as_str()).map(|s| s.to_lowercase()).collect(),
            _ => vec![],
        }
    };
    let ends = list("ends");
    (ends.is_empty() || ends.iter().any(|e| n.ends_with(e)))
        && list("has").iter().all(|h| n.contains(h))
        && !list("not").iter().any(|x| n.contains(x))
        && !n.ends_with(".zsync")
        && !n.ends_with(".sha256")
}

// ---------- state ----------

/// What is installed for a program: {version, exe} or {flatpak}.
pub fn installed(app: &Shared, id: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(&app.db.setting(&format!("emu_install.{id}"))?).ok()?;
    if let Some(exe) = v["exe"].as_str() {
        // A library picked by an earlier Borne (Azahar's libretro build) is no program:
        // installed again.
        if !Path::new(exe).exists() || is_library(Path::new(exe)) {
            return None;
        }
    }
    Some(v)
}

static TASK: Mutex<Option<Value>> = Mutex::new(None);

pub fn task() -> Value {
    TASK.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or(Value::Null)
}
fn set_task(app: &Shared, v: Value) {
    *TASK.lock().unwrap_or_else(|e| e.into_inner()) = Some(v);
    app.emit(json!({ "type": "emulators" }));
}
/// The failed installation's notice put away by the player.
pub fn dismiss(app: &Shared) {
    let mut t = TASK.lock().unwrap_or_else(|e| e.into_inner());
    if t.as_ref().map(|t| t["running"] != true).unwrap_or(false) {
        *t = None;
    }
    drop(t);
    app.emit(json!({ "type": "emulators" }));
}

pub fn busy() -> bool {
    TASK.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|t| t["running"] == true).unwrap_or(false)
}

fn root(app: &Shared) -> PathBuf {
    app.paths.root.join("emulators")
}

/// Where Borne installs a program (each version in a folder of its own).
pub fn program_dir(app: &Shared, program: &str) -> PathBuf {
    root(app).join(program)
}

pub fn cores_dir(app: &Shared) -> PathBuf {
    root(app).join("retroarch-cores")
}

pub fn core_path(app: &Shared, core: &str) -> PathBuf {
    let ext = if os() == "macos" { "dylib" } else { "so" };
    cores_dir(app).join(format!("{core}_libretro.{ext}"))
}

/// RetroArch's CRT look (the slang shader preset), once the shaders are here; fetched in the
/// background the first time it is asked for.
pub fn crt_shader(app: &Shared) -> Option<PathBuf> {
    let dir = root(app).join("retroarch-shaders");
    let preset = dir.join("crt/crt-easymode.slangp");
    if preset.is_file() {
        return Some(preset);
    }
    static FETCHING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if !FETCHING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        let app = app.clone();
        std::thread::spawn(move || {
            let zip = root(&app).join("shaders_slang.zip.part");
            let out = root(&app).join("retroarch-shaders.part");
            let r = fetch_file("https://buildbot.libretro.com/assets/frontend/shaders_slang.zip", &zip).and_then(|_| {
                let _ = std::fs::remove_dir_all(&out);
                unzip(&zip, &out)?;
                // The archive holds the shaders either at its root or in a shaders_slang folder.
                let inner = if out.join("shaders_slang").is_dir() { out.join("shaders_slang") } else { out.clone() };
                let dest = root(&app).join("retroarch-shaders");
                let _ = std::fs::remove_dir_all(&dest);
                std::fs::rename(&inner, &dest).map_err(|e| e.to_string())
            });
            let _ = std::fs::remove_file(&zip);
            let _ = std::fs::remove_dir_all(&out);
            if let Err(e) = r {
                app.db.log("emulators", &format!("CRT shaders: {e}"));
            }
            FETCHING.store(false, std::sync::atomic::Ordering::SeqCst);
        });
    }
    None
}

/// Installs (or updates) a program, and the RetroArch cores in `cores`, in the background.
/// The emulator the game waiting to start needs (set by `play` when it waits on an installation).
static WANTED: Mutex<Option<String>> = Mutex::new(None);

pub fn want(program: Option<&str>) {
    *WANTED.lock().unwrap_or_else(|e| e.into_inner()) = program.map(String::from);
}

pub fn start(app: &Shared, program: &str, cores: Vec<String>) -> Result<(), String> {
    let p = crate::emulators::program(program).ok_or("unknown emulator")?;
    if p.install_spec().is_none() && cores.is_empty() {
        return Err(format!("{} cannot be installed by Borne: choose its program", p.name));
    }
    // Its files are replaced: never under a running game.
    if crate::emulators::playing() {
        return Err("a game is running: quit it first".into());
    }
    {
        let mut t = TASK.lock().unwrap_or_else(|e| e.into_inner());
        if t.as_ref().map(|t| t["running"] == true).unwrap_or(false) {
            return Err("an installation is already running".into());
        }
        *t = Some(json!({ "id": program, "running": true, "step": "check", "received": 0, "total": 0, "error": null }));
    }
    app.emit(json!({ "type": "emulators" }));
    let app = app.clone();
    let program = program.to_string();
    std::thread::spawn(move || {
        let r = run(&app, &program, &cores);
        let error = r.err();
        if let Some(e) = &error {
            app.db.log("emulators", &format!("{program}: {e}"));
        }
        let name = crate::emulators::program(&program).map(|p| p.name).unwrap_or_else(|| program.clone());
        set_task(&app, json!({ "id": program, "name": name, "running": false, "error": error }));
        // The game waiting for this emulator starts now; after a failure it is forgotten (the
        // error is shown with the installation).
        // A game waiting for another emulator (this one was installed for the library) is not
        // the one that failed: its own emulator's installation starts now.
        let wanted = WANTED.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if error.is_none() || wanted.as_deref().is_some_and(|w| w != program) {
            crate::emulators::play_waiting(&app, None);
        } else {
            crate::emulators::forget_waiting();
        }
    });
    Ok(())
}

fn run(app: &Shared, program: &str, cores: &[String]) -> Result<(), String> {
    let p = crate::emulators::program(program).ok_or("unknown emulator")?;
    if let Some(spec) = p.install_spec() {
        let (version, url, digest) = latest(&spec)?;
        let current = installed(app, program).and_then(|v| v["version"].as_str().map(String::from));
        if spec["type"] == "flatpak" {
            flatpak(app, program, spec["id"].as_str().unwrap_or(""))?;
        } else if current.as_deref() != Some(version.as_str()) {
            unpack_release(app, program, &version, &url, digest.as_deref())?;
        }
    }
    if !cores.is_empty() {
        let pattern = p.cores_url().ok_or("this emulator has no cores")?;
        // Each core on its own: one missing on the server leaves the others installed.
        let mut failed = vec![];
        for c in cores {
            let dest = core_path(app, c);
            if dest.is_file() {
                continue;
            }
            set_task(app, json!({ "id": program, "running": true, "step": "core", "core": c, "received": 0, "total": 0 }));
            let r = (|| {
                let tmp = root(app).join(format!("{c}.zip.part"));
                download(app, program, &pattern.replace("{core}", c), &tmp, None)?;
                let out = root(app).join(format!("{c}.unpack"));
                let _ = std::fs::remove_dir_all(&out);
                unzip(&tmp, &out)?;
                let _ = std::fs::remove_file(&tmp);
                let name = dest.file_name().unwrap().to_owned();
                let found = walk(&out).into_iter().find(|f| f.file_name() == Some(&name)).ok_or("no core in the archive")?;
                std::fs::create_dir_all(cores_dir(app)).map_err(|e| e.to_string())?;
                std::fs::rename(&found, &dest).map_err(|e| e.to_string())?;
                let _ = std::fs::remove_dir_all(&out);
                Ok::<(), String>(())
            })();
            if let Err(e) = r {
                app.db.log("emulators", &format!("core {c}: {e}"));
                failed.push(format!("{c} ({e})"));
            }
        }
        if !failed.is_empty() {
            return Err(format!("RetroArch core not installed: {}", failed.join(", ")));
        }
    }
    Ok(())
}

fn flatpak(app: &Shared, program: &str, id: &str) -> Result<(), String> {
    if crate::emulators::which("flatpak").is_none() {
        return Err("Flatpak is not available on this system".into());
    }
    set_task(app, json!({ "id": program, "running": true, "step": "install", "received": 0, "total": 0 }));
    let action = if installed(app, program).is_some() { "update" } else { "install" };
    let mut args = vec![action, "--user", "--noninteractive", "-y"];
    if action == "install" {
        args.push("flathub");
    }
    args.push(id);
    let out = std::process::Command::new("flatpak").args(&args).stdin(std::process::Stdio::null()).output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("Flatpak failed").to_string());
    }
    app.db.set_setting(&format!("emu_install.{program}"), &json!({ "version": "flatpak", "flatpak": id }).to_string());
    Ok(())
}

fn download(app: &Shared, program: &str, url: &str, dest: &Path, sha256: Option<&str>) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err("refused: not an https address".into());
    }
    let mut r = agent()
        .get(net(url))
        .config()
        .timeout_recv_body(Some(Duration::from_secs(1800)))
        .build()
        .call()
        .map_err(|e| format!("download failed: {e}"))?;
    if r.status().as_u16() != 200 {
        let file = url.rsplit('/').next().unwrap_or(url);
        return Err(if r.status().as_u16() == 404 {
            format!("{file} is not on the download server (404)")
        } else {
            format!("the download of {file} answered {}", r.status().as_u16())
        });
    }
    let total: u64 = r.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok()).unwrap_or(0);
    if let Some(p) = dest.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
        // The archive and what it unpacks to (about three times its size), with a margin.
        let needed = total.saturating_mul(4) + 64 * 1024 * 1024;
        if let Some(free) = crate::paths::free_space(p) {
            if free < needed {
                return Err(format!("not enough disk space: {} MB needed, {} MB free", needed / 1_048_576, free / 1_048_576));
            }
        }
    }
    let mut out = std::fs::File::create(dest).map_err(|e| e.to_string())?;
    let mut reader = r.body_mut().with_config().limit(2 << 30).reader();
    let mut buf = vec![0u8; 1 << 16];
    let mut received: u64 = 0;
    let mut hasher = <sha2::Sha256 as sha2::Digest>::new();
    let mut last = std::time::Instant::now();
    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("download interrupted: {e}"))?;
        if n == 0 {
            break;
        }
        sha2::Digest::update(&mut hasher, &buf[..n]);
        std::io::Write::write_all(&mut out, &buf[..n]).map_err(|e| e.to_string())?;
        received += n as u64;
        if last.elapsed() > Duration::from_millis(400) {
            last = std::time::Instant::now();
            let mut t = task();
            t["received"] = json!(received);
            t["total"] = json!(total);
            t["id"] = json!(program);
            t["running"] = json!(true);
            set_task(app, t);
        }
    }
    if let Some(want) = sha256 {
        let got: String = sha2::Digest::finalize(hasher).iter().map(|b| format!("{b:02x}")).collect();
        if !got.eq_ignore_ascii_case(want) {
            let _ = std::fs::remove_file(dest);
            return Err("the download does not match its published checksum".into());
        }
    }
    Ok(())
}

/// A plain download (databases): https only, at most 512 MB.
pub fn fetch_file(url: &str, dest: &Path) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err("refused: not an https address".into());
    }
    let mut r = agent()
        .get(net(url))
        .config()
        .timeout_recv_body(Some(Duration::from_secs(600)))
        .build()
        .call()
        .map_err(|e| format!("download failed: {e}"))?;
    if r.status().as_u16() != 200 {
        return Err(format!("download answered {}", r.status().as_u16()));
    }
    if let Some(p) = dest.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    let mut out = std::fs::File::create(dest).map_err(|e| e.to_string())?;
    std::io::copy(&mut r.body_mut().with_config().limit(512 << 20).reader(), &mut out).map_err(|e| format!("download interrupted: {e}"))?;
    Ok(())
}

pub fn sha256_bytes(b: &[u8]) -> String {
    let mut h = <sha2::Sha256 as sha2::Digest>::new();
    sha2::Digest::update(&mut h, b);
    sha2::Digest::finalize(h).iter().map(|b| format!("{b:02x}")).collect()
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            let ft = match e.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            if ft.is_dir() && !ft.is_symlink() {
                // An application bundle counts as one item.
                if p.extension().map(|x| x == "app").unwrap_or(false) {
                    out.push(p);
                } else {
                    stack.push(p);
                }
            } else {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

fn set_exec(p: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755));
}

/// A zip, with Unix modes and symbolic links kept (application bundles need both); entries that
/// would land outside the target are refused.
fn unzip(zip_path: &Path, out: &Path) -> Result<(), String> {
    if os() == "macos" {
        let st = std::process::Command::new("ditto").arg("-x").arg("-k").arg(zip_path).arg(out).status().map_err(|e| e.to_string())?;
        return if st.success() { Ok(()) } else { Err("the archive could not be extracted".into()) };
    }
    use std::os::unix::fs::PermissionsExt;
    let f = std::fs::File::open(zip_path).map_err(|e| e.to_string())?;
    let mut a = zip::ZipArchive::new(f).map_err(|e| format!("unreadable archive: {e}"))?;
    std::fs::create_dir_all(out).map_err(|e| e.to_string())?;
    for i in 0..a.len() {
        let mut e = a.by_index(i).map_err(|e| e.to_string())?;
        let rel = e
            .enclosed_name()
            .and_then(|p| crate::downloads::safe_relative(&p.to_string_lossy()))
            .ok_or_else(|| format!("archive entry refused: {}", e.name().unwrap_or_default()))?;
        let dest = out.join(rel);
        if e.is_dir() {
            std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
            continue;
        }
        if let Some(p) = dest.parent() {
            std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
        }
        let mode = e.unix_mode().unwrap_or(0o644);
        if mode & 0o170000 == 0o120000 {
            let mut target = String::new();
            e.read_to_string(&mut target).map_err(|e| e.to_string())?;
            if target.starts_with('/') || target.split('/').any(|c| c == "..") {
                return Err(format!("archive link refused: {}", e.name().unwrap_or_default()));
            }
            let _ = std::os::unix::fs::symlink(&target, &dest);
            continue;
        }
        let mut w = std::fs::File::create(&dest).map_err(|e| e.to_string())?;
        std::io::copy(&mut e, &mut w).map_err(|e| e.to_string())?;
        let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(mode & 0o777 | 0o600));
    }
    Ok(())
}

/// Downloads a release and unpacks it into `emulators/<id>/<version>`, then finds its program.
fn unpack_release(app: &Shared, program: &str, version: &str, url: &str, sha256: Option<&str>) -> Result<(), String> {
    let base = root(app).join(program);
    let safe_version: String = version.chars().map(|c| if c.is_ascii_alphanumeric() || ".-_".contains(c) { c } else { '_' }).collect();
    let dir = base.join(&safe_version);
    let staging = base.join(format!("{safe_version}.part"));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
    let name = url.rsplit('/').next().unwrap_or("download").to_lowercase();
    let file = staging.join(".download");
    set_task(app, json!({ "id": program, "running": true, "step": "download", "version": version, "received": 0, "total": 0 }));
    download(app, program, url, &file, sha256)?;
    set_task(app, json!({ "id": program, "running": true, "step": "unpack", "version": version }));
    let out = staging.join("files");
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
    if name.ends_with(".zip") {
        unzip(&file, &out)?;
    } else if name.ends_with(".7z") {
        sevenz_rust2::decompress_file(&file, &out).map_err(|e| format!("the archive could not be extracted: {e}"))?;
    } else if name.ends_with(".tar.xz") || name.ends_with(".tar.gz") {
        let st = std::process::Command::new("tar").arg("-xf").arg(&file).arg("-C").arg(&out).status().map_err(|e| e.to_string())?;
        if !st.success() {
            return Err("the archive could not be extracted".into());
        }
    } else if name.ends_with(".dmg") {
        undmg(&file, &out)?;
    } else if name.ends_with(".appimage") {
        std::fs::rename(&file, out.join("program.AppImage")).map_err(|e| e.to_string())?;
    } else {
        return Err(format!("unknown kind of download: {name}"));
    }
    let _ = std::fs::remove_file(&file);
    let hint = crate::emulators::program(program).and_then(|p| p.install_spec()).and_then(|s| s["exe"].as_str().map(String::from));
    let exe = find_program(&out, hint.as_deref())?;
    // Move into place: the old version stays until the new one is complete.
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::rename(&staging, &dir).map_err(|e| e.to_string())?;
    // macOS: no "downloaded from the Internet" mark, so Gatekeeper does not stop the emulator
    // with a window asking whether to open it (Borne fetched it from its official source).
    if cfg!(target_os = "macos") {
        let _ = std::process::Command::new("xattr").args(["-dr", "com.apple.quarantine"]).arg(&dir).status();
    }
    let exe = dir.join(exe.strip_prefix(&staging).map_err(|_| "unexpected program path")?);
    app.db.set_setting(&format!("emu_install.{program}"), &json!({ "version": version, "exe": exe }).to_string());
    for e in std::fs::read_dir(&base).into_iter().flatten().flatten() {
        if e.path() != dir {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
    app.db.log("emulators", &format!("{program} {version} installed"));
    Ok(())
}

#[cfg(target_os = "macos")]
fn undmg(file: &Path, out: &Path) -> Result<(), String> {
    let mnt = out.join(".mnt");
    std::fs::create_dir_all(&mnt).map_err(|e| e.to_string())?;
    let st = std::process::Command::new("hdiutil")
        .args(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint"])
        .arg(&mnt)
        .arg(file)
        .stdout(std::process::Stdio::null())
        .status()
        .map_err(|e| e.to_string())?;
    if !st.success() {
        return Err("the disk image could not be opened".into());
    }
    let mut r = Err("no application in the disk image".to_string());
    for e in std::fs::read_dir(&mnt).into_iter().flatten().flatten() {
        let p = e.path();
        if p.extension().map(|x| x == "app").unwrap_or(false) {
            let ok =
                std::process::Command::new("ditto").arg(&p).arg(out.join(e.file_name())).status().map(|s| s.success()).unwrap_or(false);
            r = if ok { Ok(()) } else { Err("the application could not be copied".into()) };
            break;
        }
    }
    let _ = std::process::Command::new("hdiutil").args(["detach", "-quiet"]).arg(&mnt).status();
    let _ = std::fs::remove_dir(&mnt);
    r
}
#[cfg(not(target_os = "macos"))]
fn undmg(_file: &Path, _out: &Path) -> Result<(), String> {
    Err("disk images only open on macOS".into())
}

/// The program to start in an unpacked release: an application bundle's executable (macOS), or
/// an AppImage, extracted once so it runs without FUSE.
/// A shared library (.dylib, .so, .so.1…), never a program to start.
fn is_library(p: &Path) -> bool {
    let n = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    n.ends_with(".dylib") || n.ends_with(".so") || n.contains(".so.") || n.ends_with(".dll")
}

fn find_program(out: &Path, hint: Option<&str>) -> Result<PathBuf, String> {
    let items: Vec<PathBuf> = walk(out).into_iter().filter(|p| !is_library(p)).collect();
    if os() == "macos" {
        let Some(app) = items.iter().find(|p| p.extension().map(|x| x == "app").unwrap_or(false)) else {
            use std::os::unix::fs::PermissionsExt;
            return items
                .iter()
                .filter(|p| p.is_file() && p.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false))
                .max_by_key(|p| p.metadata().map(|m| m.len()).unwrap_or(0))
                .cloned()
                .ok_or_else(|| "no application in the download".to_string());
        };
        let plist = std::fs::read_to_string(app.join("Contents/Info.plist")).unwrap_or_default();
        let exe_name = plist
            .split("<key>CFBundleExecutable</key>")
            .nth(1)
            .and_then(|s| s.split("<string>").nth(1))
            .and_then(|s| s.split("</string>").next())
            .map(|s| s.trim().to_string());
        let macos = app.join("Contents/MacOS");
        let exe = match exe_name {
            Some(n) if macos.join(&n).is_file() => macos.join(n),
            _ => std::fs::read_dir(&macos)
                .map_err(|e| e.to_string())?
                .flatten()
                .map(|e| e.path())
                .find(|p| p.is_file())
                .ok_or("no program in the application")?,
        };
        set_exec(&exe);
        return Ok(exe);
    }
    let Some(appimage) = items.iter().find(|p| p.to_string_lossy().to_lowercase().ends_with(".appimage")) else {
        // A plain build (Xenia, Ryubing…): the program named in the manifest, else the largest
        // executable file.
        use std::os::unix::fs::PermissionsExt;
        let exec: Vec<&PathBuf> =
            items.iter().filter(|p| p.is_file() && p.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false)).collect();
        let pick = hint
            .and_then(|h| exec.iter().find(|p| p.file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case(h)).unwrap_or(false)))
            .or_else(|| exec.iter().max_by_key(|p| p.metadata().map(|m| m.len()).unwrap_or(0)))
            .ok_or("no program in the download")?;
        return Ok((*pick).clone());
    };
    set_exec(appimage);
    let dir = appimage.parent().unwrap().to_path_buf();
    let st = std::process::Command::new(appimage)
        .arg("--appimage-extract")
        .current_dir(&dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("the AppImage could not be opened: {e}"))?;
    let run = dir.join("squashfs-root/AppRun");
    if st.success() && run.exists() {
        let _ = std::fs::remove_file(appimage);
        return Ok(run);
    }
    // Some AppImages cannot be extracted: started as they are (FUSE needed).
    Ok(appimage.clone())
}

// ---------- the library's emulators ----------

static PREPARING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Every console of the library gets its emulator (and RetroArch core) installed ahead, so a new
/// console is ready before its first game: one at a time, in the background, never during a game.
/// Run after each sync.
pub fn install_for_library(app: &Shared) {
    // The same switch as updates: "Borne installs and updates the emulators by itself".
    if app.db.setting("emu_auto_update").as_deref() == Some("off") {
        return;
    }
    if PREPARING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    struct Done;
    impl Drop for Done {
        fn drop(&mut self) {
            PREPARING.store(false, std::sync::atomic::Ordering::SeqCst);
        }
    }
    let _done = Done;
    // What is missing, per program: (program, cores to add).
    let mut todo: Vec<(String, Vec<String>)> = vec![];
    for slug in app.db.platforms().into_iter().map(|p| p.slug).filter(|s| !crate::consoles::is_hidden(app, s)) {
        let Some(e) = crate::emulators::chosen(app, &slug) else { continue };
        let Some(p) = crate::emulators::program(&e.program) else { continue };
        let have = crate::emulators::find(app, &p.id).is_some();
        if !have && p.install_spec().is_none() {
            continue; // a program the player points to by hand
        }
        let core = e.core.filter(|c| !core_path(app, c).is_file());
        if have && core.is_none() {
            continue;
        }
        match todo.iter_mut().find(|(id, _)| *id == p.id) {
            Some((_, cores)) => {
                if let Some(c) = core.filter(|c| !cores.contains(c)) {
                    cores.push(c);
                }
            }
            None => todo.push((p.id.clone(), core.into_iter().collect())),
        }
    }
    for (program, cores) in todo {
        // One that failed (server down, no network) is tried again an hour later, not at each sync.
        if FAILED_AT
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&program)
            .map(|t| t.elapsed() < Duration::from_secs(3600))
            .unwrap_or(false)
        {
            continue;
        }
        // Never while a game runs or another installation goes on.
        while crate::emulators::playing() || busy() {
            std::thread::sleep(Duration::from_secs(5));
        }
        app.db.log("emulators", &format!("installing {program} {cores:?} for the library"));
        if let Err(e) = start(app, &program, cores) {
            app.db.log("emulators", &format!("{program}: {e}"));
            continue;
        }
        while busy() {
            std::thread::sleep(Duration::from_secs(2));
        }
        if task()["error"].is_string() {
            FAILED_AT.lock().unwrap_or_else(|e| e.into_inner()).insert(program, std::time::Instant::now());
        }
    }
}

static FAILED_AT: Mutex<BTreeMap<String, std::time::Instant>> = Mutex::new(BTreeMap::new());

// ---------- updates ----------

/// Every 6 hours: newer versions of the installed programs are installed, never during a game.
pub fn start_updates(app: &Shared) {
    let app = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(90));
        if app.db.setting("emu_auto_update").as_deref() != Some("off") {
            for p in crate::emulators::programs() {
                if crate::emulators::playing() || busy() {
                    break;
                }
                let Some(cur) = installed(&app, &p.id) else { continue };
                let Some(spec) = p.install_spec() else { continue };
                match latest(&spec) {
                    Ok((v, _, _)) if cur["version"].as_str() != Some(v.as_str()) || spec["type"] == "flatpak" => {
                        if start(&app, &p.id, vec![]).is_ok() {
                            while busy() {
                                std::thread::sleep(Duration::from_secs(2));
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) => app.db.log("emulators", &format!("update check for {}: {e}", p.id)),
                }
            }
        }
        std::thread::sleep(Duration::from_secs(6 * 3600));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_files_are_matched_by_words() {
        let citron = json!({ "ends": "-linux-x86_64.appimage" });
        assert!(asset_fits(&citron, "citron_nightly-0237a9b88-linux-x86_64.AppImage"));
        assert!(!asset_fits(&citron, "citron_nightly-0237a9b88-linux-x86_64_v3.AppImage"));
        assert!(!asset_fits(&citron, "citron_nightly-0237a9b88-linux-x86_64.AppImage.zsync"));
        let pcsx2 = json!({ "has": ["linux", "appimage", "x64"], "ends": ".appimage" });
        assert!(asset_fits(&pcsx2, "pcsx2-v2.8.2-linux-appimage-x64-Qt.AppImage"));
        let eden = json!({ "has": ["linux"], "not": ["aarch64", "arm64"], "ends": [".appimage"] });
        assert!(!asset_fits(&eden, "Eden-Linux-aarch64.AppImage"));
        assert!(asset_fits(&eden, "Eden-Linux-amd64.AppImage"));
    }

    #[test]
    fn mirror_rewrites_addresses() {
        std::env::set_var("BORNE_EMU_MIRROR", "http://127.0.0.1:1");
        assert_eq!(net("https://api.github.com/repos/x"), "http://127.0.0.1:1/api.github.com/repos/x");
        std::env::remove_var("BORNE_EMU_MIRROR");
    }
}
