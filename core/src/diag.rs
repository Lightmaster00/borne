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
    let _ = writeln!(r, "sync: {}", serde_json::to_string(&*app.sync.lock().unwrap_or_else(|e| e.into_inner())).unwrap_or_default());
    let _ = writeln!(r, "free space: {:?} bytes", crate::paths::free_space(&app.paths.root));
    let _ = writeln!(r, "\n--- recent downloads ---");
    for d in app.db.downloads() {
        let _ =
            writeln!(r, "{} game {} '{}': {} {}/{} {}", d.id, d.rom_id, d.name, d.state, d.received, d.total, d.error.unwrap_or_default());
    }
    {
        let p = app.pads.lock().unwrap_or_else(|e| e.into_inner());
        let _ = writeln!(r, "\n--- pads ---");
        for i in 0..p.pads.len() {
            let ids = p.ids.get(i).copied().unwrap_or((0, 0));
            let _ = writeln!(
                r,
                "{i}: {} | system: {} | {:04x}:{:04x} | guid {}",
                p.pads[i],
                p.os_names.get(i).map(String::as_str).unwrap_or(""),
                ids.0,
                ids.1,
                p.guids.get(i).map(String::as_str).unwrap_or("")
            );
        }
        let _ = writeln!(r, "steam hides: {:?}", crate::pad::steam_hidden());
    }
    let _ = writeln!(r, "hardware: {}", crate::hardware::to_json(&crate::consoles::hardware(app)));
    r.push_str(&switch_report(app));
    let _ = writeln!(r, "\n--- log ---");
    r.push_str(&crate::logfile::tail(512 * 1024));
    // The last game's emulator output, and the emulators' own logs of the last two days.
    let tail = |path: &std::path::Path, max: usize| {
        let b = std::fs::read(path).unwrap_or_default();
        String::from_utf8_lossy(&b[b.len().saturating_sub(max)..]).to_string()
    };
    let _ = writeln!(r, "\n--- emulator output (last game) ---");
    r.push_str(&tail(&app.paths.reports().join("emulator.log"), 64 * 1024));
    let mut logs = vec![];
    let mut stack = vec![(app.paths.profiles(), 0)];
    while let Some((dir, depth)) = stack.pop() {
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let p = e.path();
            let Ok(m) = e.metadata() else { continue };
            if m.is_dir() && depth < 7 {
                stack.push((p, depth + 1));
            } else if m.is_file() {
                let n = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
                let recent = m.modified().ok().and_then(|t| t.elapsed().ok()).map(|a| a.as_secs() < 2 * 86400).unwrap_or(false);
                if recent && (n.ends_with(".log") || n.ends_with("log.txt")) {
                    logs.push((m.modified().ok(), p));
                }
            }
        }
    }
    // Each emulator's output from its last run.
    for e in std::fs::read_dir(app.paths.reports()).into_iter().flatten().flatten() {
        let p = e.path();
        let n = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if n.starts_with("emulator-") && n.ends_with(".log") {
            let t = e.metadata().ok().and_then(|m| m.modified().ok());
            if t.and_then(|t| t.elapsed().ok()).map(|a| a.as_secs() < 2 * 86400).unwrap_or(false) {
                logs.push((t, p));
            }
        }
    }
    // The emulators' own logs where they keep them outside Borne's folders (Cemu on macOS,
    // under ~/Library/Application Support/Cemu): a crash's stack trace is there.
    let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
    for prog in crate::emulators::programs() {
        let data = crate::emulators::data_dir(app, &profile, &prog.id);
        for l in &prog.logs {
            let path = data.join(l);
            let file = if path.is_dir() {
                std::fs::read_dir(&path)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .filter_map(|e| e.metadata().ok().filter(|m| m.is_file()).map(|m| (m.modified().ok(), e.path())))
                    .max_by_key(|x| x.0)
            } else {
                path.metadata().ok().filter(|m| m.is_file()).map(|m| (m.modified().ok(), path.clone()))
            };
            if let Some((t, p)) = file {
                let recent = t.and_then(|t| t.elapsed().ok()).map(|a| a.as_secs() < 2 * 86400).unwrap_or(false);
                if recent && !logs.iter().any(|(_, q)| *q == p) {
                    logs.push((t, p));
                }
            }
        }
    }
    logs.sort_by_key(|l| std::cmp::Reverse(l.0));
    for (_, p) in logs.into_iter().take(12) {
        let _ = writeln!(r, "\n--- {} ---", p.strip_prefix(&app.paths.root).unwrap_or(&p).display());
        r.push_str(&tail(&p, 48 * 1024));
    }

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

/// The Switch side of the report: the keys and firmware each Switch emulator has, and for each
/// Switch game on this device or played from the network, its files and what each package holds
/// (read from its header: base game, update or DLC, by its ticket's title ID).
fn switch_report(app: &crate::state::Shared) -> String {
    use std::fmt::Write;
    let mut r = String::new();
    let games: Vec<_> = app.db.games(Some("switch"), None, false).into_iter().filter(|g| g.local_state == "local" || g.linked).collect();
    let profile = app.active_profile().map(|p| p.id).unwrap_or_else(|| "default".into());
    let _ = writeln!(r, "\n--- switch ---");
    for emu in ["eden", "citron", "ryubing"] {
        let data = crate::emulators::data_dir(app, &profile, emu);
        if !data.is_dir() {
            continue;
        }
        let keys = data.join(if emu == "ryubing" { "system" } else { "keys" });
        let prod = std::fs::read_to_string(keys.join("prod.keys")).unwrap_or_default();
        // The newest master key says which firmware generations the keys open.
        let newest = prod
            .lines()
            .filter_map(|l| {
                l.trim().strip_prefix("master_key_").and_then(|x| x.split_whitespace().next()).and_then(|h| u32::from_str_radix(h, 16).ok())
            })
            .max();
        let reg = if emu == "ryubing" { "bis/system/Contents/registered" } else { "nand/system/Contents/registered" };
        let firmware = std::fs::read_dir(data.join(reg)).map(|d| d.count()).unwrap_or(0);
        let _ = writeln!(
            r,
            "{emu}: prod.keys {} ({} lines, newest master key {:?}), title.keys {}, firmware files {firmware}",
            if prod.is_empty() { "MISSING" } else { "present" },
            prod.lines().count(),
            newest,
            if keys.join("title.keys").is_file() { "present" } else { "absent" },
        );
    }
    // The keys the player gave Borne, and what each package holds when read with them.
    let given = crate::systemfiles::first_file(app, "switch", "prod-keys");
    let keys_text = given.as_deref().and_then(|p| std::fs::read_to_string(p).ok()).unwrap_or_default();
    let k = crate::switchcheck::keys(&keys_text);
    let _ = writeln!(
        r,
        "prod.keys given to Borne: {} · header_key {} · newest master key {:?}",
        given.as_deref().map(|p| p.display().to_string()).unwrap_or_else(|| "none".into()),
        if k.get("header_key").map(|v| v.len() == 32).unwrap_or(false) { "present" } else { "MISSING" },
        crate::switchcheck::newest_master_key(&k)
    );
    for g in games.iter().take(12) {
        let main = if g.local_state == "local" {
            g.local_main.clone().map(std::path::PathBuf::from)
        } else {
            crate::stream::link(app, g.rom_id).ok()
        };
        let _ = writeln!(
            r,
            "game {} ({}): {}",
            g.name,
            g.rom_id,
            main.as_deref().map(|p| p.display().to_string()).unwrap_or_else(|| "no file".into())
        );
        let Some(dir) = main.as_deref().and_then(|p| p.parent()) else { continue };
        let mut files: Vec<_> = std::fs::read_dir(dir).into_iter().flatten().flatten().map(|e| e.path()).collect();
        files.sort();
        for f in files.iter().take(20) {
            let size = f.metadata().map(|m| m.len()).unwrap_or(0);
            let inner = crate::downloads::pfs0_names(f);
            let tickets: Vec<String> =
                inner.iter().flatten().filter(|n| n.ends_with(".tik")).map(|n| n[..16.min(n.len())].to_string()).collect();
            let _ = writeln!(
                r,
                "  {} · {} MB · {} · {}",
                f.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
                size / 1_048_576,
                match &inner {
                    Some(n) => format!(
                        "PFS0 with {} files ({} .nca, {} .ncz)",
                        n.len(),
                        n.iter().filter(|x| x.ends_with(".nca")).count(),
                        n.iter().filter(|x| x.ends_with(".ncz")).count()
                    ),
                    None if f.is_dir() => "folder".to_string(),
                    None => "not a PFS0 package".to_string(),
                },
                match crate::downloads::switch_kind(f) {
                    Some(k) => format!("{k} (title {})", tickets.join(", ")),
                    None => "kind unknown (no ticket)".to_string(),
                }
            );
            if inner.is_some() && !keys_text.is_empty() {
                let _ = writeln!(r, "    read with the keys: {}", crate::switchcheck::describe(f, &keys_text));
                if let Some(p) = crate::switchcheck::problem(f, &keys_text) {
                    let _ = writeln!(r, "    problem: {p}");
                }
            }
        }
    }
    r
}
