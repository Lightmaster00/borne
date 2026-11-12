//! Diagnostics: graphics session, GPU, video decoding, memory, bench reports.

use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Serialize)]
pub struct Diagnostics {
    pub env: Vec<(String, String)>,
    pub cpu: String,
    pub gpus: Vec<String>,
    pub render_node: bool,
    pub rss_mb: f64,
    pub processes: usize,
    pub in_gamescope: bool,
    pub in_steam: bool,
    /// Used / total VRAM (MB), read from sysfs (amdgpu).
    pub vram_used_mb: Option<u64>,
    pub vram_total_mb: Option<u64>,
    /// VA-API drivers found (e.g. radeonsi_drv_video.so).
    pub va_drivers: Vec<String>,
}

const ENV_KEYS: [&str; 12] = [
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "GAMESCOPE_WAYLAND_DISPLAY",
    "SteamGameId",
    "SteamAppId",
    "WEBKIT_DISABLE_DMABUF_RENDERER",
    "WEBKIT_DISABLE_COMPOSITING_MODE",
    "LIBVA_DRIVER_NAME",
    "QT_QPA_PLATFORM",
    "QT_FFMPEG_DECODING_HW_DEVICE_TYPES",
];

fn read(p: &str) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

fn cpu_model() -> String {
    read("/proc/cpuinfo")
        .lines()
        .find(|l| l.starts_with("model name"))
        .and_then(|l| l.split(':').nth(1))
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".into())
}

fn gpus() -> Vec<String> {
    let mut out = vec![];
    if let Ok(rd) = std::fs::read_dir("/sys/class/drm") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.starts_with("card") || name.contains('-') {
                continue;
            }
            let dev = e.path().join("device");
            let vendor = read(&dev.join("vendor").to_string_lossy()).trim().to_string();
            let device = read(&dev.join("device").to_string_lossy()).trim().to_string();
            let driver = std::fs::read_link(dev.join("driver"))
                .ok()
                .and_then(|p| p.file_name().map(|f| f.to_string_lossy().into_owned()))
                .unwrap_or_default();
            let vendor_name = match vendor.as_str() {
                "0x1002" => "AMD",
                "0x10de" => "NVIDIA",
                "0x8086" => "Intel",
                _ => "?",
            };
            out.push(format!("{name}: {vendor_name} {device} (driver {driver})"));
        }
    }
    out.sort();
    out
}

/// Resident memory of the process and all its descendants (QML UI included).
fn rss_tree() -> (f64, usize) {
    let me = std::process::id();
    let mut parent: HashMap<u32, u32> = HashMap::new();
    let mut rss: HashMap<u32, u64> = HashMap::new();
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else {
                continue;
            };
            let status = read(&format!("/proc/{pid}/status"));
            let mut ppid = 0;
            let mut kb = 0;
            for l in status.lines() {
                if let Some(v) = l.strip_prefix("PPid:") {
                    ppid = v.trim().parse().unwrap_or(0);
                } else if let Some(v) = l.strip_prefix("VmRSS:") {
                    kb = v.trim().trim_end_matches("kB").trim().parse().unwrap_or(0);
                }
            }
            parent.insert(pid, ppid);
            rss.insert(pid, kb);
        }
    }
    let is_descendant = |mut p: u32| {
        for _ in 0..64 {
            if p == me {
                return true;
            }
            match parent.get(&p) {
                Some(&pp) if pp != 0 => p = pp,
                _ => return false,
            }
        }
        false
    };
    let pids: Vec<u32> = rss.keys().copied().filter(|&p| is_descendant(p)).collect();
    let total: u64 = pids.iter().map(|p| rss[p]).sum();
    (total as f64 / 1024.0, pids.len())
}

fn vram() -> (Option<u64>, Option<u64>) {
    let mut best: (Option<u64>, Option<u64>) = (None, None);
    if let Ok(rd) = std::fs::read_dir("/sys/class/drm") {
        for e in rd.flatten() {
            let dev = e.path().join("device");
            let used = read(&dev.join("mem_info_vram_used").to_string_lossy()).trim().parse::<u64>().ok();
            let total = read(&dev.join("mem_info_vram_total").to_string_lossy()).trim().parse::<u64>().ok();
            if let (Some(u), Some(t)) = (used, total) {
                if best.1.map(|bt| t > bt * 1024 * 1024).unwrap_or(true) {
                    best = (Some(u / 1024 / 1024), Some(t / 1024 / 1024));
                }
            }
        }
    }
    best
}

fn va_drivers() -> Vec<String> {
    let mut dirs: Vec<PathBuf> = std::env::var("LIBVA_DRIVERS_PATH").map(|v| v.split(':').map(PathBuf::from).collect()).unwrap_or_default();
    dirs.extend(["/usr/lib/dri", "/usr/lib64/dri", "/usr/lib/x86_64-linux-gnu/dri"].iter().map(PathBuf::from));
    let mut out = vec![];
    for d in dirs {
        if let Ok(rd) = std::fs::read_dir(&d) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().into_owned();
                if n.ends_with("_drv_video.so") && !out.contains(&n) {
                    out.push(n);
                }
            }
        }
    }
    out.sort();
    out
}

pub fn diagnostics() -> Diagnostics {
    let env: Vec<(String, String)> = ENV_KEYS.iter().map(|k| (k.to_string(), std::env::var(k).unwrap_or_else(|_| "—".into()))).collect();
    let (rss_mb, processes) = rss_tree();
    Diagnostics {
        in_gamescope: std::env::var("GAMESCOPE_WAYLAND_DISPLAY").is_ok()
            || std::env::var("XDG_CURRENT_DESKTOP").map(|d| d.contains("gamescope")).unwrap_or(false),
        in_steam: std::env::var("SteamGameId").is_ok() || std::env::var("SteamAppId").is_ok(),
        env,
        cpu: cpu_model(),
        gpus: gpus(),
        render_node: std::path::Path::new("/dev/dri/renderD128").exists(),
        rss_mb,
        processes,
        vram_used_mb: vram().0,
        vram_total_mb: vram().1,
        va_drivers: va_drivers(),
    }
}

/// Removes credentials typed into a server address (`https://user:pass@host`).
pub fn redact_url(url: &str) -> String {
    match url.split_once("://") {
        Some((scheme, rest)) => {
            let (authority, path) = rest.split_once('/').map(|(a, p)| (a, format!("/{p}"))).unwrap_or((rest, String::new()));
            let host = authority.rsplit_once('@').map(|(_, h)| h).unwrap_or(authority);
            format!("{scheme}://{host}{path}")
        }
        None => url.to_string(),
    }
}

/// Writes a plain-text report the user can attach to a bug report: versions, settings,
/// server state, recent downloads and the log. Never contains tokens.
/// Returns the paths written (data folder, and a copy in Downloads when there is one).
pub fn export_report(app: &crate::state::Shared) -> Result<Vec<PathBuf>, String> {
    use std::fmt::Write as _;
    let mut r = String::new();
    let _ = writeln!(r, "Borne diagnostic report");
    let _ = writeln!(r, "generated: {}", crate::db::now());
    let _ = writeln!(r, "version: {} (build {}, commit {})", crate::update::VERSION, crate::update::build(), crate::update::COMMIT);
    let _ = writeln!(r, "system: {} {}", std::env::consts::OS, std::env::consts::ARCH);
    let server = app.server_url().unwrap_or_default();
    let _ = writeln!(r, "server: {}", redact_url(&server));
    if !server.is_empty() {
        match crate::romm::Client::new(&server, None).heartbeat() {
            Ok(v) => {
                let _ = writeln!(r, "server version: RomM {v}");
            }
            Err(e) => {
                let _ = writeln!(r, "server check: {e}");
            }
        }
    }
    let profiles = app.db.profiles();
    let _ = writeln!(r, "profiles: {} ({} paired)", profiles.len(), profiles.iter().filter(|p| p.paired).count());
    let _ = writeln!(r, "active profile paired: {}", app.active_profile().map(|p| p.paired).unwrap_or(false));
    for key in ["install_mode", "stream_cache_mb", "update_channel", "update_auto"] {
        let _ = writeln!(r, "setting {key}: {}", app.db.setting(key).unwrap_or_else(|| "default".into()));
    }
    let _ = writeln!(r, "mount: {}", crate::stream::status(app));
    let _ = writeln!(r, "sync: {}", serde_json::to_string(&*app.sync.lock().unwrap()).unwrap_or_default());
    let _ = writeln!(r, "free space: {:?} bytes", crate::paths::free_space(&app.paths.root));
    let _ = writeln!(r, "\n--- recent downloads ---");
    for d in app.db.downloads() {
        let _ =
            writeln!(r, "{} game {} '{}': {} {}/{} {}", d.id, d.rom_id, d.name, d.state, d.received, d.total, d.error.unwrap_or_default());
    }
    let _ = writeln!(r, "\n--- log ---");
    r.push_str(&crate::logfile::tail(512 * 1024));

    let name = format!("borne-report-{}.txt", crate::db::now());
    let main = app.paths.reports().join(&name);
    std::fs::write(&main, &r).map_err(|e| e.to_string())?;
    let mut out = vec![main];
    if let Some(dl) = dirs::download_dir().filter(|d| d.is_dir()) {
        let copy = dl.join(&name);
        if std::fs::write(&copy, &r).is_ok() {
            out.push(copy);
        }
    }
    crate::logfile::write("report", "diagnostic report exported");
    Ok(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn redacts_credentials() {
        assert_eq!(super::redact_url("https://bob:secret@romm.lan:8443/romm"), "https://romm.lan:8443/romm");
        assert_eq!(super::redact_url("http://romm.lan"), "http://romm.lan");
    }
}
