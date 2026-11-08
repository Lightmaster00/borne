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
        .unwrap_or_else(|| "inconnu".into())
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
            let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else { continue };
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
    let mut dirs: Vec<PathBuf> = std::env::var("LIBVA_DRIVERS_PATH")
        .map(|v| v.split(':').map(PathBuf::from).collect())
        .unwrap_or_default();
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
    let env: Vec<(String, String)> = ENV_KEYS
        .iter()
        .map(|k| (k.to_string(), std::env::var(k).unwrap_or_else(|_| "—".into())))
        .collect();
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

