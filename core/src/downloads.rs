//! Game downloads: persistent queue, resume (Range), verification
//! (size + SHA-1), safe archive extraction, atomic install.
//!
//!   library/.staging/<rom_id>/…        files in progress (.part), kept for resuming
//!   library/<platform>/<rom_id>/…      installed game, moved in one go once complete
//!
//! A final file never exists half-written (NFR-03).

use crate::romm::{RomDetail, RomFile};
use crate::state::Shared;
use std::io::{BufWriter, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// "Main" file extensions in order of preference, to choose what to launch.
const MAIN_EXT: &[&str] = &[
    // Wii U first: a folder dump's game files include .bin data, its program is the .rpx.
    "wua", "wud", "wux", "rpx", "m3u", "cue", "gdi", "cdi", "chd", "iso", "rvz", "gcz", "wbfs", "ciso", "nsp", "xci", "nes", "fds", "md",
    "gen", "smd", "bin", "sfc", "smc", "gb", "gbc", "gba", "n64", "z64", "v64", "nds", "3ds", "cci", "cxi", "gg", "sms", "32x", "pce",
    "ws", "wsc", "ngp", "ngc", "a26", "lnx", "vb", "cso", "pbp", "a78", "j64", "col", "rom", "mx1", "mx2", "vec", "min", "cia", "vpk",
];
/// The size of a folder's files (links not followed).
pub fn dir_size(dir: &Path) -> u64 {
    walk_size(dir)
}

/// Consoles whose games are archives by nature (arcade sets read zipped by MAME and FinalBurn):
/// kept as they are. Every other console's zip or 7z is extracted, as the standalone emulators
/// (Azahar, Eden, Dolphin…) do not read archives.
pub fn keeps_archive(platform: &str, archive: &Path) -> bool {
    match platform {
        "arcade" | "neogeo" | "neogeoaes" | "neogeomvs" | "cps1" | "cps2" | "cps3" | "mame" | "fbneo" | "naomi" | "atomiswave" => true,
        // PS Vita: a .zip stays as it was downloaded. At launch Vita3K gets it as it is when the
        // game is at its root, else it is extracted once next to it (see `vita_content`); never
        // deleted and downloaded again.
        "psvita" => archive.extension().map(|e| e.eq_ignore_ascii_case("zip")).unwrap_or(false),
        _ => false,
    }
}

/// An archive Borne extracts (zip, 7z).
pub fn extractable(path: &Path) -> bool {
    path.extension().map(|e| ["zip", "7z", "rar"].iter().any(|x| e.eq_ignore_ascii_case(x))).unwrap_or(false)
}

/// A RAR archive, by the system's own tools (no RAR decoder may be bundled): bsdtar (libarchive,
/// on macOS and most Linux systems), else unrar, else 7z. None of them writes outside the folder
/// by default; links they made are removed all the same.
fn extract_rar(archive: &Path, out: &Path) -> Result<(), String> {
    extract_external(archive, out, "no tool to open RAR archives (bsdtar, unrar or 7z) on this system")
}

/// An archive by the system's own tools (bsdtar, unrar, 7z, unzip): for RAR, and for the zips the
/// built-in reader does not take (some large or unusual ones).
pub fn extract_external(archive: &Path, out: &Path, none: &str) -> Result<(), String> {
    std::fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let o = out.to_string_lossy().into_owned();
    let a = archive.to_string_lossy().into_owned();
    let rar = archive.extension().map(|e| e.eq_ignore_ascii_case("rar")).unwrap_or(false);
    let tries: Vec<(&str, Vec<String>)> = vec![
        ("bsdtar", vec!["-xf".into(), a.clone(), "-C".into(), o.clone()]),
        (
            if rar { "unrar" } else { "unzip" },
            if rar {
                vec!["x".into(), "-o+".into(), "-idq".into(), a.clone(), format!("{o}/")]
            } else {
                vec!["-o".into(), "-q".into(), a.clone(), "-d".into(), o.clone()]
            },
        ),
        ("7z", vec!["x".into(), "-y".into(), format!("-o{o}"), a.clone()]),
    ];
    let mut last = none.to_string();
    for (tool, args) in tries {
        match std::process::Command::new(tool).args(&args).stdin(std::process::Stdio::null()).output() {
            Ok(r) if r.status.success() => {
                let mut stack = vec![out.to_path_buf()];
                let mut files = 0;
                while let Some(d) = stack.pop() {
                    for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                        match e.file_type() {
                            Ok(t) if t.is_symlink() => {
                                let _ = std::fs::remove_file(e.path());
                            }
                            Ok(t) if t.is_dir() => stack.push(e.path()),
                            _ => files += 1,
                        }
                    }
                }
                // A damaged archive can be "extracted" into nothing (bsdtar reading a zip whose
                // end is missing): not a success.
                if files > 0 {
                    return Ok(());
                }
                last = none.to_string();
            }
            Ok(r) => last = format!("the archive could not be extracted: {}", String::from_utf8_lossy(&r.stderr).trim()),
            Err(_) => continue,
        }
    }
    Err(last)
}

enum Outcome {
    Done,
    Cancelled,
}

pub fn spawn_worker(app: Shared) {
    std::thread::Builder::new()
        .name("borne-downloads".into())
        .spawn(move || loop {
            match app.db.next_queued_download() {
                Some((id, rom_id)) => run(&app, id, rom_id),
                None => {
                    let (lock, cv) = &app.dl_wake;
                    let mut woken = lock.lock().unwrap_or_else(|e| e.into_inner());
                    while !*woken {
                        woken = cv.wait_timeout(woken, Duration::from_secs(30)).unwrap().0;
                        if app.db.next_queued_download().is_some() {
                            break;
                        }
                    }
                    *woken = false;
                }
            }
        })
        .expect("download thread");
}

pub fn enqueue(app: &Shared, rom_id: i64) -> Result<i64, String> {
    // Asked for itself: a kept copy, not a temporary one (the network route marks it after).
    crate::stream::clear_temporary(app, rom_id);
    let game = app.db.game(rom_id).ok_or("unknown game")?;
    if game.local_state == "local" {
        return Err("game already installed".into());
    }
    let id = app.db.enqueue_download(rom_id)?;
    emit(app, id, rom_id, "queued", 0, game.fs_size, None, 0.0);
    app.wake_downloads();
    Ok(id)
}

pub fn cancel(app: &Shared, id: i64) -> bool {
    app.dl_pause.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    if let Some(flag) = app.dl_cancel.lock().unwrap_or_else(|e| e.into_inner()).get(&id) {
        flag.store(true, Ordering::SeqCst);
        return true;
    }
    let state = app.db.download_state(id);
    if matches!(state.as_deref(), Some("queued" | "failed" | "paused")) {
        // Nothing will resume it: its partial files go.
        if let Some(rom_id) = app.db.download_rom(id) {
            let _ = std::fs::remove_dir_all(app.paths.library().join(".staging").join(rom_id.to_string()));
        }
        app.db.update_download(id, "cancelled", 0, 0, None);
        app.emit(serde_json::json!({ "type": "download", "id": id, "state": "cancelled" }));
        app.emit(serde_json::json!({ "type": "library" }));
        return true;
    }
    false
}

/// Pauses a download: a running one stops and keeps its partial files, a queued one waits.
pub fn pause(app: &Shared, id: i64) -> bool {
    if let Some(flag) = app.dl_cancel.lock().unwrap_or_else(|e| e.into_inner()).get(&id) {
        app.dl_pause.lock().unwrap_or_else(|e| e.into_inner()).insert(id);
        flag.store(true, Ordering::SeqCst);
        return true;
    }
    if app.db.download_state(id).as_deref() == Some("queued") {
        let (received, total) = app.db.download_progress(id);
        app.db.update_download(id, "paused", received, total, None);
        app.emit(serde_json::json!({ "type": "download", "id": id, "state": "paused" }));
        app.emit(serde_json::json!({ "type": "library" }));
        return true;
    }
    false
}

/// Puts a paused (or failed) download back in the queue; it resumes where it stopped (Range).
pub fn resume(app: &Shared, id: i64) -> bool {
    if !matches!(app.db.download_state(id).as_deref(), Some("paused" | "failed")) {
        return false;
    }
    let (received, total) = app.db.download_progress(id);
    app.db.update_download(id, "queued", received, total, None);
    app.emit(serde_json::json!({ "type": "download", "id": id, "state": "queued" }));
    app.emit(serde_json::json!({ "type": "library" }));
    app.wake_downloads();
    true
}

#[allow(clippy::too_many_arguments)]
fn emit(app: &Shared, id: i64, rom_id: i64, state: &str, received: i64, total: i64, error: Option<&str>, speed: f64) {
    app.emit(serde_json::json!({
        "type": "download", "id": id, "rom_id": rom_id, "state": state,
        "received": received, "total": total, "error": error, "speed": speed.round(),
    }));
}

fn run(app: &Shared, id: i64, rom_id: i64) {
    let flag = Arc::new(AtomicBool::new(false));
    app.dl_cancel.lock().unwrap_or_else(|e| e.into_inner()).insert(id, flag.clone());
    let result = download(app, id, rom_id, &flag);
    app.dl_cancel.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    let staging = app.paths.library().join(".staging").join(rom_id.to_string());
    match result {
        Ok(Outcome::Done) => {
            let _ = std::fs::remove_dir_all(&staging);
            if crate::stream::is_temporary(app, rom_id) {
                crate::stream::mark_temporary(app, rom_id);
                crate::stream::evict_temporary(app, rom_id);
            }
            // Started now if it was the game waiting for its file.
            crate::emulators::play_waiting(app, Some(rom_id));
        }
        Ok(Outcome::Cancelled) if app.dl_pause.lock().unwrap_or_else(|e| e.into_inner()).remove(&id) => {
            // Paused: the partial files stay for resuming.
            let (received, total) = app.db.download_progress(id);
            app.db.update_download(id, "paused", received, total, None);
            emit(app, id, rom_id, "paused", received, total, None, 0.0);
            app.db.log("download", &format!("game {rom_id}: paused"));
        }
        Ok(Outcome::Cancelled) => {
            let _ = std::fs::remove_dir_all(&staging);
            app.db.update_download(id, "cancelled", 0, 0, None);
            emit(app, id, rom_id, "cancelled", 0, 0, None, 0.0);
            app.db.log("download", &format!("game {rom_id}: cancelled"));
        }
        Err(e) => {
            // Partial files stay in place: retrying resumes where it stopped.
            if e.starts_with("RomM server unreachable") {
                app.set_online(false);
            }
            // The progress stays: a retry resumes from the partial files.
            let (received, total) = app.db.download_progress(id);
            app.db.update_download(id, "failed", received, total, Some(&e));
            emit(app, id, rom_id, "failed", received, total, Some(&e), 0.0);
            app.db.log("download", &format!("game {rom_id}: {e}"));
        }
    }
    app.emit(serde_json::json!({ "type": "library" }));
}

/// Safe relative path of a file inside the game directory (no parent traversal, no absolute path).
pub fn safe_relative(rel: &str) -> Option<PathBuf> {
    let p = Path::new(rel);
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            // Control characters (a newline) would break the playlists and configuration files
            // the path is written into.
            Component::Normal(s) if s.to_string_lossy().chars().any(char::is_control) => return None,
            Component::Normal(s) => out.push(s),
            Component::CurDir => {}
            _ => return None,
        }
    }
    (!out.as_os_str().is_empty()).then_some(out)
}

pub fn relative_path(detail: &RomDetail, f: &RomFile) -> Option<PathBuf> {
    if detail.files.len() <= 1 {
        return safe_relative(&f.file_name);
    }
    // Multi-file game: keep the tree below the game's directory in RomM.
    let prefix = format!("{}/{}/", detail.fs_path.trim_end_matches('/'), detail.fs_name);
    let rel = f.full_path.strip_prefix(&prefix).unwrap_or(&f.file_name);
    safe_relative(rel)
}

/// Archive formats whose RomM hash may describe the content rather than the archive itself.
fn is_archive_name(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    [".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".xz", ".bz2"].iter().any(|e| n.ends_with(e))
}

fn sha1_file(path: &Path, flag: &AtomicBool) -> std::io::Result<Option<String>> {
    let mut h = sha1_smol::Sha1::new();
    let mut f = std::fs::File::open(path)?;
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if flag.load(Ordering::SeqCst) {
            return Ok(None);
        }
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(Some(h.digest().to_string()))
}

fn download(app: &Shared, id: i64, rom_id: i64, flag: &AtomicBool) -> Result<Outcome, String> {
    let game = app.db.game(rom_id).ok_or("unknown game")?;
    let client = app.client().ok_or("no paired profile or server offline")?;
    let detail = client.rom(rom_id).map_err(|e| e.to_string())?;
    app.set_online(true);
    let files: Vec<RomFile> = detail.installable_files().into_iter().cloned().collect();
    if files.is_empty() {
        return Err("RomM lists no game file for this title".into());
    }
    let total: i64 = files.iter().map(|f| f.file_size_bytes).sum();

    let staging = app.paths.library().join(".staging").join(rom_id.to_string());
    std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
    // Margin: an extracted zip can double the space needed during the install.
    let already: u64 = walk_size(&staging);
    let needed = (total as u64).saturating_mul(2).saturating_sub(already) + 64 * 1024 * 1024;
    if let Some(free) = crate::paths::free_space(&staging) {
        if free < needed {
            return Err(format!("not enough disk space: {} MB needed, {} MB free", needed / 1_048_576, free / 1_048_576));
        }
    }

    // Rate limiting for tests (BORNE_DEBUG_DL_KBPS), no effect in normal use.
    let throttle_kbps: u64 = std::env::var("BORNE_DEBUG_DL_KBPS").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut received_before: i64 = 0;
    let started = Instant::now();
    let mut last_emit = Instant::now() - Duration::from_secs(1);
    let mut bytes_this_run: u64 = 0;
    app.db.update_download(id, "downloading", 0, total, None);

    for f in &files {
        let rel = relative_path(&detail, f).ok_or_else(|| format!("file path refused: {}", f.full_path))?;
        let final_path = staging.join(&rel);
        let part = PathBuf::from(format!("{}.part", final_path.display()));
        if let Some(parent) = final_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        // File already finished during a previous attempt.
        if final_path.exists() && std::fs::metadata(&final_path).map(|m| m.len() as i64 == f.file_size_bytes).unwrap_or(false) {
            received_before += f.file_size_bytes;
            continue;
        }
        let mut previous_mismatch: Option<String> = None;
        let len = loop {
            let mut retry = false;
            let mut from = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
            if f.file_size_bytes > 0 && from > f.file_size_bytes as u64 {
                from = 0;
            }
            let (mut reader, _total_file, resumed) = client.open_file(f, from).map_err(|e| e.to_string())?;
            let file = if resumed && from > 0 {
                std::fs::OpenOptions::new().append(true).open(&part)
            } else {
                from = 0;
                std::fs::File::create(&part)
            }
            .map_err(|e| e.to_string())?;
            let mut out = BufWriter::with_capacity(1 << 20, file);
            let mut buf = vec![0u8; 256 * 1024];
            let mut got = from as i64;
            loop {
                if flag.load(Ordering::SeqCst) {
                    return Ok(Outcome::Cancelled);
                }
                let n = reader.read(&mut buf).map_err(|e| format!("transfer interrupted: {e}"))?;
                if n == 0 {
                    break;
                }
                out.write_all(&buf[..n]).map_err(|e| format!("cannot write: {e}"))?;
                got += n as i64;
                bytes_this_run += n as u64;
                if throttle_kbps > 0 {
                    let expected = Duration::from_secs_f64(bytes_this_run as f64 / (throttle_kbps as f64 * 1024.0));
                    if let Some(wait) = expected.checked_sub(started.elapsed()) {
                        std::thread::sleep(wait);
                    }
                }
                if last_emit.elapsed() > Duration::from_millis(250) {
                    last_emit = Instant::now();
                    let speed = bytes_this_run as f64 / started.elapsed().as_secs_f64().max(0.001);
                    let received = received_before + got;
                    app.db.update_download(id, "downloading", received, total, None);
                    emit(app, id, rom_id, "downloading", received, total, None, speed);
                }
            }
            out.flush().map_err(|e| e.to_string())?;
            drop(out);

            // Verification: size, then the SHA-1 provided by RomM.
            app.db.update_download(id, "verifying", received_before + got, total, None);
            emit(app, id, rom_id, "verifying", received_before + got, total, None, 0.0);
            let len = std::fs::metadata(&part).map(|m| m.len() as i64).unwrap_or(-1);
            if f.file_size_bytes > 0 && len != f.file_size_bytes {
                let _ = std::fs::remove_file(&part);
                return Err(format!("wrong size for {} ({len} instead of {})", f.file_name, f.file_size_bytes));
            }
            // Archive: RomM's hash covers the content, checked after extraction. A zip without
            // the member list (older RomM) cannot be checked against the server's hash.
            let archive = f.is_archive() || is_archive_name(&f.file_name);
            if let Some(expected) = f.sha1_hash.as_deref().filter(|s| !s.is_empty() && !archive) {
                match sha1_file(&part, flag).map_err(|e| e.to_string())? {
                    None => return Ok(Outcome::Cancelled),
                    Some(actual) if actual.eq_ignore_ascii_case(expected) => {}
                    Some(actual) => {
                        // Some RomM versions hash a file differently from its raw bytes (headers
                        // skipped). Download it again: identical bytes twice mean the server
                        // really serves this content, a transfer error would not repeat.
                        if previous_mismatch.as_deref() == Some(actual.as_str()) {
                            app.db.log(
                                "download",
                                &format!("{}: SHA-1 differs from RomM's but two downloads are identical; kept", f.file_name),
                            );
                        } else {
                            let _ = std::fs::remove_file(&part);
                            if previous_mismatch.is_some() {
                                return Err(format!("corrupted file: {} (SHA-1 mismatch twice)", f.file_name));
                            }
                            app.db.log("download", &format!("{}: SHA-1 mismatch, downloading again", f.file_name));
                            previous_mismatch = Some(actual);
                            retry = true;
                        }
                    }
                }
            }
            if retry {
                continue;
            }
            break len;
        };
        std::fs::rename(&part, &final_path).map_err(|e| e.to_string())?;
        received_before += f.file_size_bytes.max(len);
    }

    // Extract archives for the systems that need it.
    let mut install_root = staging.clone();
    if files.len() == 1 {
        let only = staging.join(relative_path(&detail, &files[0]).unwrap());
        if extractable(&only) && !keeps_archive(&game.platform_slug, &only) {
            app.db.update_download(id, "extracting", total, total, None);
            emit(app, id, rom_id, "extracting", total, total, None, 0.0);
            let out_dir = staging.join(".extracted");
            let _ = std::fs::remove_dir_all(&out_dir);
            let ext = only.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            if ext == "7z" {
                // The 7z reader refuses entries leading outside the folder (see systemfiles).
                sevenz_rust2::decompress_file(&only, &out_dir).map_err(|e| format!("the archive could not be extracted: {e}"))?;
            } else if ext == "rar" {
                extract_rar(&only, &out_dir)?;
            } else if let Err(e) = extract_zip(&only, &out_dir, flag) {
                // The built-in reader refused it: the system's tools may read it.
                app.db.log("download", &format!("{}: {e}; trying the system's tools", only.display()));
                let _ = std::fs::remove_dir_all(&out_dir);
                extract_external(&only, &out_dir, &e).map_err(|x| {
                    let head = std::fs::File::open(&only).ok().and_then(|mut f| {
                        let mut b = [0u8; 4];
                        std::io::Read::read_exact(&mut f, &mut b).ok().map(|_| b)
                    });
                    if head != Some(*b"PK\x03\x04") {
                        "the file on RomM is named .zip but is not a zip archive".to_string()
                    } else if e.contains("EOCD") {
                        "the zip on RomM is incomplete (its end is missing): upload it to RomM again".to_string()
                    } else {
                        x
                    }
                })?;
            }
            if flag.load(Ordering::SeqCst) {
                return Ok(Outcome::Cancelled);
            }
            app.db.update_download(id, "verifying", total, total, None);
            emit(app, id, rom_id, "verifying", total, total, None, 0.0);
            for m in files[0].archive_members.as_deref().unwrap_or_default() {
                let Some(expected) = m.sha1_hash.as_deref().filter(|s| !s.is_empty()) else {
                    continue;
                };
                let path = out_dir.join(safe_relative(&m.name).ok_or("archive entry refused")?);
                match sha1_file(&path, flag).map_err(|e| format!("{} missing from the archive: {e}", m.name))? {
                    None => return Ok(Outcome::Cancelled),
                    Some(actual) if actual.eq_ignore_ascii_case(expected) => {}
                    Some(_) => return Err(format!("corrupted file in the archive: {}", m.name)),
                }
            }
            install_root = out_dir;
        }
    }

    // Switch packages compressed with nsz: unpacked to the .nsp the emulators read.
    if game.platform_slug == "switch" && !crate::nsz::found(&install_root).is_empty() {
        app.db.update_download(id, "extracting", total, total, None);
        emit(app, id, rom_id, "extracting", total, total, None, 0.0);
        match crate::nsz::unpack_in_place(&install_root, flag) {
            Err(e) if e == crate::nsz::CANCELLED => return Ok(Outcome::Cancelled),
            Err(e) => return Err(format!("the .nsz package could not be unpacked: {e}")),
            Ok(made) => app.db.log("download", &format!("{}: {} package(s) unpacked from .nsz", game.name, made.len())),
        }
    }
    let main = pick_main(&install_root).ok_or("no game file found after install")?;
    let final_dir = app.paths.library().join(&game.platform_slug).join(rom_id.to_string());
    if final_dir.exists() {
        std::fs::remove_dir_all(&final_dir).map_err(|e| e.to_string())?;
    }
    std::fs::create_dir_all(final_dir.parent().unwrap()).map_err(|e| e.to_string())?;
    if install_root != staging {
        std::fs::rename(&install_root, &final_dir).map_err(|e| e.to_string())?;
    } else {
        std::fs::rename(&staging, &final_dir).map_err(|e| e.to_string())?;
    }
    let main_final = final_dir.join(main.strip_prefix(&install_root).unwrap_or(&main));
    let size = walk_size(&final_dir) as i64;
    app.db.set_local(rom_id, &final_dir.to_string_lossy(), &main_final.to_string_lossy(), size);
    app.db.update_download(id, "done", total, total, None);
    emit(app, id, rom_id, "done", total, total, None, 0.0);
    app.db.log("download", &format!("{} installed ({} MB)", game.name, size / 1_048_576));
    Ok(Outcome::Done)
}

/// Extracts a zip, refusing any entry that would escape the target directory ("zip slip").
pub fn extract_zip(zip_path: &Path, out_dir: &Path, flag: &AtomicBool) -> Result<(), String> {
    let f = std::fs::File::open(zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(f).map_err(|e| format!("unreadable archive: {e}"))?;
    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
    for i in 0..archive.len() {
        if flag.load(Ordering::SeqCst) {
            return Ok(());
        }
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let rel = entry
            .enclosed_name()
            .and_then(|p| safe_relative(&p.to_string_lossy()))
            .ok_or_else(|| format!("archive entry refused: {}", entry.name().unwrap_or_default()))?;
        let dest = out_dir.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
            continue;
        }
        if let Some(p) = dest.parent() {
            std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
        }
        let mut out = std::fs::File::create(&dest).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn walk_size(dir: &Path) -> u64 {
    let mut total = 0;
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                total += walk_size(&p);
            } else if let Ok(m) = e.metadata() {
                total += m.len();
            }
        }
    }
    total
}

fn collect_files(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                collect_files(&p, out);
            } else {
                out.push(p);
            }
        }
    }
}

/// File to hand to the emulator: preferred extension, otherwise the largest file.
pub fn pick_main(dir: &Path) -> Option<PathBuf> {
    let mut files = vec![];
    collect_files(dir, &mut files);
    let sized = files.into_iter().map(|p| (std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0), p)).collect();
    pick_main_of(sized)
}

/// Same choice from a list of (size, path), for files that are not on disk (virtual mount).
/// The game's main file comes before an update, a DLC or a patch shipped next to it (a Switch base
/// game before "Game Update [v131072].nsp" or a DLC title ID, which sort before it by name).
pub fn pick_main_of(mut files: Vec<(u64, PathBuf)>) -> Option<PathBuf> {
    files.sort_by(|a, b| (is_extra(&a.1), &a.1).cmp(&(is_extra(&b.1), &b.1)));
    for ext in MAIN_EXT {
        if let Some((_, p)) = files.iter().find(|(_, p)| p.extension().map(|e| e.eq_ignore_ascii_case(ext)).unwrap_or(false)) {
            return Some(p.clone());
        }
    }
    files.into_iter().max_by_key(|(size, p)| (!is_extra(p), *size)).map(|(_, p)| p)
}

/// The files inside a Switch package (.nsp, .nsz: a PFS0 archive), as listed in its header. None
/// for another format or a damaged header.
pub fn pfs0_names(path: &Path) -> Option<Vec<String>> {
    use std::io::Read;
    let mut f = std::fs::File::open(path).ok()?;
    let mut head = [0u8; 16];
    f.read_exact(&mut head).ok()?;
    if &head[..4] != b"PFS0" {
        return None;
    }
    let count = u32::from_le_bytes(head[4..8].try_into().ok()?) as usize;
    let strings = u32::from_le_bytes(head[8..12].try_into().ok()?) as usize;
    if count == 0 || count > 4096 || strings > 1 << 20 {
        return None;
    }
    let mut rest = vec![0u8; count * 24 + strings];
    f.read_exact(&mut rest).ok()?;
    let table = &rest[count * 24..];
    Some(
        (0..count)
            .filter_map(|i| {
                let at = u32::from_le_bytes(rest[i * 24 + 16..i * 24 + 20].try_into().ok()?) as usize;
                let end = table.get(at..)?.iter().position(|b| *b == 0)? + at;
                std::str::from_utf8(&table[at..end]).ok().map(String::from)
            })
            .collect(),
    )
}

/// What a Switch package (.nsp, .nsz: a PFS0 archive) holds, read from its ticket's name (the
/// rights ID starts with the title ID): "base", "update" or "dlc". None when it cannot tell (no
/// ticket, another format).
pub fn switch_kind(path: &Path) -> Option<&'static str> {
    let names = pfs0_names(path)?;
    let mut kind = None;
    for n in names {
        let Some(id) = n.strip_suffix(".tik").filter(|i| i.len() >= 16) else { continue };
        let tid = u64::from_str_radix(&id[..16], 16).ok()?;
        let k = match tid & 0xfff {
            0x000 => "base",
            0x800 => "update",
            _ => "dlc",
        };
        // A package holding a base game is the game, whatever else it carries.
        if k == "base" {
            return Some("base");
        }
        kind = Some(k);
    }
    kind
}

/// An update, a DLC or a patch rather than the game itself, by its name: the words, a version tag
/// other than v0, or a Switch title ID that is not a base game's (those end in 000).
pub fn is_extra(p: &Path) -> bool {
    let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    if ["update", "dlc", "patch", "[upd]"].iter().any(|w| name.contains(w)) {
        return true;
    }
    let bracketed = name.split('[').skip(1).filter_map(|s| s.split(']').next());
    for tag in bracketed {
        if let Some(v) = tag.strip_prefix('v') {
            if v.chars().all(|c| c.is_ascii_digit()) && !v.trim_start_matches('0').is_empty() {
                return true;
            }
        }
        if tag.len() == 16 && tag.chars().all(|c| c.is_ascii_hexdigit()) && !tag.ends_with("000") {
            return true;
        }
    }
    false
}

/// Local deletion of a game (never touches the RomM server).
pub fn delete_local(app: &Shared, rom_id: i64) -> Result<(), String> {
    if crate::emulators::playing_rom() == Some(rom_id) {
        return Err("a game is running: quit it first".into());
    }
    let dir = app.db.remove_local(rom_id).ok_or("game not installed")?;
    let dir = PathBuf::from(dir);
    let lib = app.paths.library().canonicalize().map_err(|e| e.to_string())?;
    if let Ok(canon) = dir.canonicalize() {
        if !canon.starts_with(&lib) || canon == lib {
            return Err("directory outside the library: deletion refused".into());
        }
        std::fs::remove_dir_all(&canon).map_err(|e| e.to_string())?;
    }
    app.db.log("library", &format!("game {rom_id} deleted locally"));
    app.emit(serde_json::json!({ "type": "library" }));
    Ok(())
}

/// At startup: checks that installed games are still present.
pub fn verify_local(app: &Shared) {
    for (rom_id, _dir, main, status) in app.db.local_games() {
        let ok = Path::new(&main).exists();
        let new_status = if ok { "ok" } else { "missing" };
        if new_status != status {
            app.db.set_local_status(rom_id, new_status);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn switch_base_game_before_update_and_dlc() {
        let f = |n: &str| (1u64, PathBuf::from(n));
        let picked = pick_main_of(vec![
            f("Game/Game DLC Pack [0100ABCD00001001][v0].nsp"),
            f("Game/Game Update [0100ABCD00000800][v131072].nsp"),
            f("Game/Game [0100ABCD00000000][v0].nsp"),
        ]);
        assert_eq!(picked, Some(PathBuf::from("Game/Game [0100ABCD00000000][v0].nsp")));
        let picked = pick_main_of(vec![f("g/base/Game.nsp"), f("g/update/Game [v65536].nsp")]);
        assert_eq!(picked, Some(PathBuf::from("g/base/Game.nsp")));
        // Discs stay in order.
        let picked = pick_main_of(vec![f("Game (Disc 2).chd"), f("Game (Disc 1).chd")]);
        assert_eq!(picked, Some(PathBuf::from("Game (Disc 1).chd")));
    }
    use std::io::Write;

    #[test]
    fn rejects_unsafe_paths() {
        assert!(safe_relative("../etc/passwd").is_none());
        assert!(safe_relative("/etc/passwd").is_none());
        assert!(safe_relative("a/../../b").is_none());
        assert!(safe_relative("Game\nkey = value.iso").is_none());
        assert_eq!(safe_relative("./Game/disc1.iso").unwrap(), PathBuf::from("Game/disc1.iso"));
    }

    #[test]
    fn zip_slip_is_refused_and_normal_zip_extracts() {
        let dir = tempfile::tempdir().unwrap();
        let good = dir.path().join("good.zip");
        {
            let mut z = zip::ZipWriter::new(std::fs::File::create(&good).unwrap());
            z.start_file("Game (Europe).md", zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(b"rom").unwrap();
            z.finish().unwrap();
        }
        let out = dir.path().join("out");
        extract_zip(&good, &out, &AtomicBool::new(false)).unwrap();
        assert_eq!(std::fs::read(out.join("Game (Europe).md")).unwrap(), b"rom");
        assert_eq!(pick_main(&out).unwrap(), out.join("Game (Europe).md"));

        let bad = dir.path().join("bad.zip");
        {
            let mut z = zip::ZipWriter::new(std::fs::File::create(&bad).unwrap());
            z.start_file("../../evil.txt", zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(b"x").unwrap();
            z.finish().unwrap();
        }
        let out2 = dir.path().join("out2");
        assert!(extract_zip(&bad, &out2, &AtomicBool::new(false)).is_err());
        assert!(!dir.path().join("evil.txt").exists());
    }

    #[test]
    fn a_switch_package_says_what_it_holds() {
        fn pfs0(names: &[&str]) -> Vec<u8> {
            let mut table = vec![];
            let mut offs = vec![];
            for n in names {
                offs.push(table.len() as u32);
                table.extend_from_slice(n.as_bytes());
                table.push(0);
            }
            let mut v = b"PFS0".to_vec();
            v.extend((names.len() as u32).to_le_bytes());
            v.extend((table.len() as u32).to_le_bytes());
            v.extend(0u32.to_le_bytes());
            for o in offs {
                v.extend([0u8; 16]);
                v.extend(o.to_le_bytes());
                v.extend(0u32.to_le_bytes());
            }
            v.extend(table);
            v
        }
        let dir = tempfile::tempdir().unwrap();
        let w = |name: &str, files: &[&str]| {
            let p = dir.path().join(name);
            std::fs::write(&p, pfs0(files)).unwrap();
            p
        };
        assert_eq!(switch_kind(&w("a.nsp", &["0100abcd12340000000000000000000a.tik", "x.nca"])), Some("base"));
        assert_eq!(switch_kind(&w("b.nsp", &["0100abcd12340800000000000000000a.tik"])), Some("update"));
        assert_eq!(switch_kind(&w("c.nsp", &["0100abcd12341001000000000000000a.tik"])), Some("dlc"));
        assert_eq!(switch_kind(&w("d.nsp", &["only.nca"])), None);
        std::fs::write(dir.path().join("e.xci"), b"HEAD....").unwrap();
        assert_eq!(switch_kind(&dir.path().join("e.xci")), None);
    }

    #[test]
    fn main_file_prefers_playlists_and_cues() {
        let dir = tempfile::tempdir().unwrap();
        for f in ["track01.bin", "track02.bin", "game.cue"] {
            std::fs::write(dir.path().join(f), b"x").unwrap();
        }
        assert_eq!(pick_main(dir.path()).unwrap().file_name().unwrap(), "game.cue");
    }
}
