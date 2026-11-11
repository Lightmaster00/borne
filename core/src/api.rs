//! Core local HTTP API, version 1.
//!
//! Listens on 127.0.0.1 (random port); every route is prefixed with a random token
//! handed to the UI by the supervisor. JSON bodies and responses.
//! Events (gamepads, pairing, sync, downloads) go through the WebSocket.
//!
//! System
//!   GET    /api/v1/hello                         versions (negotiation)
//!   GET    /api/v1/status                        server, active profile, pairing, sync, disk space
//!   GET    /api/v1/diagnostics                   session, GPU, VRAM, VA-API, memory
//!   POST   /api/v1/server        {url}           sets the RomM server (checked before saving)
//! Profiles
//!   GET    /api/v1/profiles
//!   POST   /api/v1/profiles      {name}
//!   PUT    /api/v1/profiles/<id> {name}
//!   DELETE /api/v1/profiles/<id>
//!   POST   /api/v1/profiles/<id>/activate
//!   POST   /api/v1/profiles/<id>/pair            starts RomM pairing
//!   GET    /api/v1/pairing  ·  DELETE /api/v1/pairing  ·  GET /api/v1/pairing/qr.svg
//! Library
//!   POST   /api/v1/sync                          syncs the catalog
//!   GET    /api/v1/platforms
//!   GET    /api/v1/library?platform=&q=&local=1&lang=fr   one entry per game, versions grouped
//!   GET    /api/v1/games/<rom_id>?lang=fr        game page: shown version, all versions, choices
//!   GET    /api/v1/games/<rom_id>/facts?lang=fr  credits, introduction, anecdotes (Wikidata,
//!                                                Wikipedia), studios, series, screenshots (RomM)
//!   GET    /api/v1/games/<rom_id>/screenshots/<n>  a screenshot, fetched from RomM and cached
//!   POST   /api/v1/games/<rom_id>/download
//!   DELETE /api/v1/games/<rom_id>/local          deletes the local copy (never on RomM)
//!   POST   /api/v1/games/<rom_id>/link           exposes the game in the virtual mount (no download)
//!   DELETE /api/v1/games/<rom_id>/link           removes it from the virtual mount
//!   POST   /api/v1/games/<rom_id>/prefs  {version?, emu_language?}   active profile's choices
//!   POST   /api/v1/games/<rom_id>/trailer         fetches the RomM trailer once (token, cache) → {path}
//!   POST   /api/v1/games/<rom_id>/play            starts the game with its emulator → session
//!   GET    /api/v1/games/<rom_id>/cheats          cheats of this exact version, and which are on
//!   POST   /api/v1/games/<rom_id>/cheats {on}     the cheats turned on (per profile)
//!   GET    /api/v1/system-files                   BIOS, keys, firmware per console, and which are here
//!   POST   /api/v1/system-files/<console>/<item> {path | url | pick | romm}   adds one (checked, in the background)
//!   GET    /api/v1/system-files/<console>/romm    RomM's files that fit each item
//!   POST   /api/v1/system-files/from-romm         takes every missing file RomM has without doubt
//!   DELETE /api/v1/system-files/<console>/<item>  removes it
//!   GET    /api/v1/session                        the running game, if any
//!   POST   /api/v1/session/stop                   ends the running game
//!   GET    /api/v1/emulators                      emulators: where found, systems, cores
//!   POST   /api/v1/emulators/<id>/path {path}     the user's own program for an emulator ("" to forget)
//!   POST   /api/v1/emulators/<id>/install         installs or updates it (Borne's own copy)
//!   POST   /api/v1/consoles/<slug>/emulator {engine}  the emulator chosen for a console
//!   POST   /api/v1/emulators/auto-update {on}     updates installed by themselves (default on)
//!   POST   /api/v1/games/<rom_id>/gameplay        gameplay video: ScreenScraper's, else the trailer → {path}
//!   GET    /api/v1/settings                      install mode, virtual mount state
//!   POST   /api/v1/settings  {install_mode?, stream_cache_mb?, update_channel?, update_auto?}
//! Updates
//!   GET    /api/v1/update                        current build, channel, state of the update
//!   GET    /api/v1/media/report                  per console: games with case scans, cartridge, logo
//!   POST   /api/v1/media/refresh                 forgets the media files and fetches them again
//!   GET    /api/v1/screenscraper                 Borne's ScreenScraper account and fetch progress
//!   POST   /api/v1/screenscraper                 {user,password}: checks, saves, fetches
//!   DELETE /api/v1/screenscraper                 forgets the account
//!   POST   /api/v1/screenscraper/fetch           {"again": bool}: asks ScreenScraper for the games
//!   POST   /api/v1/update/check                  looks for a newer build (event "update");
//!                                                 {"force": true} offers the latest even if not newer
//!   POST   /api/v1/update/download               downloads and verifies it
//!   POST   /api/v1/update/apply                  installs it; Borne restarts when the UI quits
//!   GET    /api/v1/downloads  ·  DELETE /api/v1/downloads/<id>
//! Misc
//!   POST   /api/v1/report  ·  GET /file?path=…
//!   POST   /api/v1/diagnostic-report             writes a shareable report (logs, no secrets)
//!   POST   /api/v1/debug/pad?action=…            automated tests (BORNE_DEBUG_INPUT=1)
//!   POST   /api/v1/debug/stick?x=…&y=…           automated tests: the right stick

use crate::state::Shared;
use crate::{catalog, diag, downloads, library, pairing, romm, secrets, stream, update};
use serde_json::{json, Value};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

pub const API_VERSION: u32 = 1;

fn header(k: &str, v: &str) -> Header {
    Header::from_bytes(k.as_bytes(), v.as_bytes()).expect("valid header")
}

fn reply(req: Request, status: u16, body: Value) {
    let r = Response::from_string(body.to_string())
        .with_status_code(StatusCode(status))
        .with_header(header("Content-Type", "application/json; charset=utf-8"))
        .with_header(header("Cache-Control", "no-store"));
    let _ = req.respond(r);
}

fn ok(req: Request, body: Value) {
    reply(req, 200, body)
}

fn err(req: Request, status: u16, message: &str) {
    reply(req, status, json!({ "error": message }))
}

fn percent_decode(s: &str) -> String {
    fn hex(c: u8) -> Option<u8> {
        (c as char).to_digit(16).map(|d| d as u8)
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query(q: &str, key: &str) -> Option<String> {
    q.split('&').find_map(|kv| {
        kv.strip_prefix(key)
            .and_then(|r| r.strip_prefix('='))
            .map(percent_decode)
    })
}

fn body_json(req: &mut Request) -> Value {
    let mut s = String::new();
    let _ = req.as_reader().take(1024 * 1024).read_to_string(&mut s);
    serde_json::from_str(&s).unwrap_or(Value::Null)
}

fn mime(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .as_deref()
    {
        Some("mp4") | Some("m4v") => "video/mp4",
        Some("webm") => "video/webm",
        Some("mkv") => "video/x-matroska",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("svg") => "image/svg+xml",
        _ => "application/octet-stream",
    }
}

fn parse_range(v: &str, size: u64) -> Option<(u64, u64)> {
    if size == 0 {
        return None;
    }
    let spec = v.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (a, b) = spec.split_once('-')?;
    let (start, end) = if a.is_empty() {
        let n: u64 = b.parse().ok().filter(|n| *n > 0)?;
        (size.saturating_sub(n), size - 1)
    } else {
        let s: u64 = a.parse().ok()?;
        let e = if b.is_empty() {
            size - 1
        } else {
            b.parse::<u64>().ok()?.min(size - 1)
        };
        (s, e)
    };
    (start <= end && start < size).then_some((start, end))
}

fn serve_file(req: Request, raw: &str, roots: &[PathBuf]) {
    let Ok(path) = PathBuf::from(raw).canonicalize() else {
        let _ = req.respond(Response::empty(StatusCode(404)));
        return;
    };
    if !roots.iter().any(|r| path.starts_with(r)) {
        let _ = req.respond(Response::empty(StatusCode(403)));
        return;
    }
    let Ok(mut file) = File::open(&path) else {
        let _ = req.respond(Response::empty(StatusCode(404)));
        return;
    };
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    let range = req
        .headers()
        .iter()
        .find(|h| h.field.equiv("Range"))
        .and_then(|h| parse_range(h.value.as_str(), size));
    let mut headers = vec![
        header("Content-Type", mime(&path)),
        header("Accept-Ranges", "bytes"),
    ];
    match range {
        Some((start, end)) => {
            let len = end - start + 1;
            if file.seek(SeekFrom::Start(start)).is_err() {
                let _ = req.respond(Response::empty(StatusCode(416)));
                return;
            }
            headers.push(header(
                "Content-Range",
                &format!("bytes {start}-{end}/{size}"),
            ));
            let _ = req.respond(Response::new(
                StatusCode(206),
                headers,
                file.take(len),
                Some(len as usize),
                None,
            ));
        }
        None => {
            let _ = req.respond(Response::new(
                StatusCode(200),
                headers,
                file,
                Some(size as usize),
                None,
            ));
        }
    }
}

/// "download" (copy to disk) or "stream" (Borne virtual mount): what A does on a game page.
fn install_mode(app: &Shared) -> String {
    // A saved "stream" choice falls back to downloads where the mount cannot work.
    match app.db.setting("install_mode").as_deref() {
        Some("stream") if stream::available() => "stream".into(),
        _ => "download".into(),
    }
}

fn settings(app: &Shared) -> Value {
    json!({ "install_mode": install_mode(app), "stream": stream::status(app), "update": update::status(app),
            "media": crate::media::report(app), "screenscraper": crate::screenscraper::status(app),
            "emulators": crate::emulators::list(app),
            "system_files": crate::systemfiles::status(app) })
}

/// Installing or linking a version makes it the one the active profile sees for that game.
fn choose_version(app: &Shared, rom_id: i64) {
    if let (Some(p), Some(g)) = (app.active_profile(), app.db.game(rom_id)) {
        app.db
            .set_game_pref(&p.id, &g.group_key, Some(Some(rom_id)), None);
    }
}

/// A game's n-th screenshot: from the cache, or fetched from RomM (with the profile's token).
fn screenshot(app: &Shared, rom_id: i64, n: usize) -> Result<PathBuf, String> {
    let dir = app.paths.screenshots();
    let path = dir.join(format!("{rom_id}-{n}.img"));
    if path.is_file() {
        return Ok(path);
    }
    let extra: Value = app
        .db
        .game_extra(rom_id)
        .and_then(|e| serde_json::from_str(&e).ok())
        .ok_or("no screenshots")?;
    let remote = extra["screenshots"][n]
        .as_str()
        .ok_or("no such screenshot")?;
    let client = app.client().ok_or("offline")?;
    let bytes = client
        .fetch_bytes(remote, 20 * 1024 * 1024)
        .map_err(|e| e.to_string())?;
    if !catalog::looks_like_image(&bytes) {
        return Err("not an image".into());
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &bytes)
        .and_then(|_| std::fs::rename(&tmp, &path))
        .map_err(|e| e.to_string())?;
    Ok(path)
}

/// Width / height of a cover file on disk (header only, remembered).
fn cover_ratio(path: &str) -> Option<f64> {
    static CACHE: std::sync::Mutex<Option<std::collections::HashMap<String, (std::time::SystemTime, f64)>>> = std::sync::Mutex::new(None);
    let mtime = std::fs::metadata(path).and_then(|m| m.modified()).ok()?;
    let mut g = CACHE.lock().unwrap();
    let map = g.get_or_insert_with(std::collections::HashMap::new);
    if let Some((t, r)) = map.get(path) {
        if *t == mtime {
            return Some(*r);
        }
    }
    let (w, h) = image::image_dimensions(path).ok()?;
    let r = w as f64 / h.max(1) as f64;
    map.insert(path.to_string(), (mtime, r));
    Some(r)
}

/// The art kinds RomM has for these versions of a game.
fn art_kinds(app: &Shared, ids: &[i64]) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for e in ids.iter().filter_map(|id| app.db.game_extra(*id)) {
        let extra: Value = serde_json::from_str(&e).unwrap_or(Value::Null);
        if let Some(o) = extra["art"].as_object() {
            // Case faces, cartridge and logo are listed once on disk (media::summary).
            out.extend(o.keys().filter(|k| !crate::media::KINDS.contains(&k.as_str())).cloned());
        }
        if extra["art"]["fanart"].is_string() || extra["screenshots"][0].is_string() {
            out.push("backdrop".into());
        }
    }
    out.sort();
    out.dedup();
    out
}

pub const ART_KINDS: [&str; 8] = ["front", "side", "back", "fanart", "logo", "physical", "title", "backdrop"];

/// A box scan or artwork of the game (any version of it), fetched once from RomM with the
/// profile's token and kept on disk. "backdrop": the fanart, else the first screenshot.
fn art(app: &Shared, rom_id: i64, kind: &str) -> Result<PathBuf, String> {
    if crate::media::KINDS.contains(&kind) {
        let g = app.db.game(rom_id).ok_or("unknown game")?;
        if let Some(m) = app.db.media(&g.group_key, kind).filter(|m| std::path::Path::new(&m.path).is_file()) {
            return Ok(PathBuf::from(m.path));
        }
        let src = crate::media::sources(app, &g.group_key).remove(kind).ok_or("not in RomM")?;
        let client = app.client().ok_or("offline")?;
        crate::media::ensure(app, &client, &g.group_key, kind, &src)?;
        return app.db.media(&g.group_key, kind).map(|m| PathBuf::from(m.path)).ok_or("not stored".into());
    }
    if kind == "fanart" || kind == "backdrop" {
        if let Some(m) = app.db.game(rom_id).and_then(|g| app.db.media(&g.group_key, "fanart")) {
            if std::path::Path::new(&m.path).is_file() {
                return Ok(PathBuf::from(m.path));
            }
        }
    }
    let dir = app.paths.art();
    let path = dir.join(format!("{rom_id}-{kind}.img"));
    if path.is_file() {
        return Ok(path);
    }
    let g = app.db.game(rom_id).ok_or("unknown game")?;
    let extras: Vec<Value> = std::iter::once(g.rom_id)
        .chain(app.db.group(&g.group_key).iter().map(|v| v.rom_id))
        .filter_map(|id| app.db.game_extra(id))
        .filter_map(|e| serde_json::from_str(&e).ok())
        .collect();
    let find = |k: &str| extras.iter().find_map(|e| e["art"][k].as_str().map(String::from));
    let remote = match kind {
        "backdrop" => find("fanart").or_else(|| extras.iter().find_map(|e| e["screenshots"][0].as_str().map(String::from))),
        k => find(k),
    }
    .ok_or("not in RomM")?;
    let client = app.client().ok_or("offline")?;
    let bytes = client
        .fetch_bytes(&remote, 25 * 1024 * 1024)
        .map_err(|e| e.to_string())?;
    if !catalog::looks_like_image(&bytes) {
        return Err("not an image".into());
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &bytes)
        .and_then(|_| std::fs::rename(&tmp, &path))
        .map_err(|e| e.to_string())?;
    Ok(path)
}

/// The game's trailer, fetched once from RomM with the profile's token and kept on disk, so
/// the player reads a local file (seeking works, no credentials in a URL). Capped at 300 MB;
/// the oldest trailers are removed past 2 GB.
fn trailer(app: &Shared, rom_id: i64) -> Result<PathBuf, String> {
    let g = app.db.game(rom_id).ok_or("unknown game")?;
    // A version without its own trailer uses another version's (same game).
    let (rom_id, remote) = std::iter::once(g.clone())
        .chain(app.db.group(&g.group_key))
        .find_map(|v| v.video_remote.clone().map(|r| (v.rom_id, r)))
        .ok_or("no trailer in RomM for this game")?;
    let remote = catalog::resource_path(&remote);
    let ext = remote
        .split('?')
        .next()
        .and_then(|p| p.rsplit('/').next())
        .and_then(|n| n.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()))
        .filter(|e| ["mp4", "m4v", "webm", "mkv"].contains(&e.as_str()))
        .unwrap_or_else(|| "mp4".into());
    let dir = app.paths.videos();
    let path = dir.join(format!("{rom_id}.{ext}"));
    if path.is_file() {
        return Ok(path);
    }
    let client = app.client().ok_or("offline")?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!("{rom_id}.part"));
    client
        .fetch_to_file(&remote, &tmp, 300 * 1024 * 1024)
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            app.db.log("trailer", &format!("game {rom_id}: {e}"));
            e.to_string()
        })?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    prune_videos(&dir, 2 * 1024 * 1024 * 1024);
    Ok(path)
}

/// A video of the game being played, for the library's video background: ScreenScraper's
/// gameplay capture when there is one, else RomM's trailer. Kept on disk like the trailers.
fn gameplay(app: &Shared, rom_id: i64) -> Result<PathBuf, String> {
    let g = app.db.game(rom_id).ok_or("unknown game")?;
    let dir = app.paths.videos();
    match crate::screenscraper::video(app, &g.group_key, &dir) {
        Ok(p) => {
            prune_videos(&dir, 2 * 1024 * 1024 * 1024);
            Ok(p)
        }
        Err(ss) => trailer(app, rom_id).map_err(|t| format!("{ss}; {t}")),
    }
}

fn prune_videos(dir: &std::path::Path, max: u64) {
    let mut files: Vec<(std::time::SystemTime, u64, PathBuf)> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            Some((m.modified().ok()?, m.len(), e.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort();
    for (_, len, p) in files {
        if total <= max {
            break;
        }
        if std::fs::remove_file(&p).is_ok() {
            total -= len;
        }
    }
}

fn new_profile_id() -> String {
    use rand::Rng;
    let mut rng = rand::rng();
    (0..12)
        .map(|_| format!("{:x}", rng.random_range(0..16u8)))
        .collect()
}

fn handle(mut req: Request, app: &Shared, token: &str, roots: &[PathBuf]) {
    let url = req.url().to_string();
    let Some(rest) = url.strip_prefix(&format!("/{token}/")) else {
        let _ = req.respond(Response::empty(StatusCode(404)));
        return;
    };
    let (route, q) = rest.split_once('?').unwrap_or((rest, ""));
    let route = route.to_string();
    let q = q.to_string();
    let parts: Vec<&str> = route.split('/').collect();
    let method = req.method().clone();

    match (&method, parts.as_slice()) {
        // ---------- system ----------
        (Method::Get, ["api", "v1", "hello"]) => ok(
            req,
            json!({ "api": API_VERSION, "core": update::VERSION, "build": update::build() }),
        ),
        (Method::Get, ["api", "v1", "status"]) => ok(req, app.status()),
        (Method::Get, ["api", "v1", "diagnostics"]) => ok(req, json!(diag::diagnostics())),
        (Method::Get, ["api", "v1", "pads"]) => {
            let s = app.pads.lock().unwrap().clone();
            ok(req, json!(s))
        }
        (Method::Post, ["api", "v1", "server"]) => {
            let body = body_json(&mut req);
            let url = match romm::normalize_url(body["url"].as_str().unwrap_or("")) {
                Ok(u) => u,
                Err(e) => return err(req, 400, &e),
            };
            match romm::Client::new(&url, None).heartbeat() {
                Ok(version) => {
                    if app.server_url().as_deref() != Some(url.as_str()) {
                        // Tokens belong to one server: switching servers requires pairing again.
                        for p in app.db.profiles() {
                            secrets::delete(&app.paths, &p.id);
                            app.db.set_unpaired(&p.id);
                        }
                        app.db.set_setting("romm_url", &url);
                        app.db.log(
                            "server",
                            &format!("RomM server set: {url} (version {version})"),
                        );
                    }
                    app.set_online(true);
                    ok(req, json!({ "url": url, "version": version }))
                }
                Err(e) => err(req, 502, &e.to_string()),
            }
        }

        // ---------- profiles ----------
        (Method::Get, ["api", "v1", "profiles"]) => ok(req, json!(app.db.profiles())),
        (Method::Post, ["api", "v1", "profiles"]) => {
            let body = body_json(&mut req);
            let name = body["name"].as_str().unwrap_or("").trim().to_string();
            if name.is_empty() || name.chars().count() > 40 {
                return err(req, 400, "invalid profile name (1 to 40 characters)");
            }
            let id = new_profile_id();
            match app.db.add_profile(&id, &name) {
                Ok(()) => {
                    let _ = std::fs::create_dir_all(app.paths.profiles().join(&id));
                    app.emit(json!({ "type": "profiles", "profiles": app.db.profiles() }));
                    ok(req, json!(app.db.profile(&id)))
                }
                Err(e) => err(req, 500, &e.to_string()),
            }
        }
        (Method::Put, ["api", "v1", "profiles", id]) => {
            let body = body_json(&mut req);
            let name = body["name"].as_str().unwrap_or("").trim();
            if name.is_empty() || name.chars().count() > 40 {
                return err(req, 400, "invalid profile name");
            }
            if app.db.rename_profile(id, name) {
                app.emit(json!({ "type": "profiles", "profiles": app.db.profiles() }));
                ok(req, json!(app.db.profile(id)))
            } else {
                err(req, 404, "unknown profile")
            }
        }
        (Method::Delete, ["api", "v1", "profiles", id]) => {
            // The profile's saves (profiles/<id> directory) are kept on disk.
            secrets::delete(&app.paths, id);
            if app.db.delete_profile(id) {
                if app.db.setting("active_profile").as_deref() == Some(*id) {
                    app.db.delete_setting("active_profile");
                }
                app.emit(json!({ "type": "profiles", "profiles": app.db.profiles() }));
                ok(req, json!({ "deleted": id }))
            } else {
                err(req, 404, "unknown profile")
            }
        }
        (Method::Post, ["api", "v1", "profiles", id, "activate"]) => match app.db.profile(id) {
            Some(p) => {
                app.db.set_setting("active_profile", &p.id);
                app.db.touch_profile(&p.id);
                app.emit(json!({ "type": "profiles", "profiles": app.db.profiles() }));
                if p.paired {
                    catalog::start_sync(app);
                }
                ok(req, json!(p))
            }
            None => err(req, 404, "unknown profile"),
        },
        (Method::Post, ["api", "v1", "profiles", id, "pair"]) => match pairing::start(app, id) {
            Ok(state) => ok(req, json!(state)),
            Err(e) => err(req, 502, &e),
        },
        (Method::Get, ["api", "v1", "pairing"]) => ok(req, json!(*app.pairing.lock().unwrap())),
        (Method::Delete, ["api", "v1", "pairing"]) => {
            pairing::cancel(app);
            ok(req, json!({ "cancelled": true }))
        }
        (Method::Get, ["api", "v1", "pairing", "qr.svg"]) => {
            let url = app
                .pairing
                .lock()
                .unwrap()
                .as_ref()
                .map(|p| p.verification_url.clone());
            match url.and_then(|u| pairing::qr_svg(&u)) {
                Some(svg) => {
                    let r = Response::from_string(svg)
                        .with_header(header("Content-Type", "image/svg+xml"))
                        .with_header(header("Cache-Control", "no-store"));
                    let _ = req.respond(r);
                }
                None => err(req, 404, "no pairing in progress"),
            }
        }

        // ---------- library ----------
        (Method::Post, ["api", "v1", "sync"]) => {
            if app.client().is_none() {
                return err(req, 409, "no paired profile");
            }
            catalog::start_sync(app);
            ok(req, json!(*app.sync.lock().unwrap()))
        }
        (Method::Get, ["api", "v1", "platforms"]) => ok(req, json!(app.db.platforms())),
        (Method::Get, ["api", "v1", "library"]) => {
            let platform = query(&q, "platform");
            let search = query(&q, "q");
            let local = query(&q, "local").as_deref() == Some("1");
            let lang = query(&q, "lang").unwrap_or_else(|| "en".into());
            let rows = app.db.games(platform.as_deref(), search.as_deref(), local);
            let prefs = app
                .active_profile()
                .map(|p| app.db.game_prefs(&p.id))
                .unwrap_or_default();
            crate::screenscraper::set_ui_lang(app, &lang);
            let mut list = library::groups(rows, &prefs, &lang);
            // Titles in the interface language (ScreenScraper), the list sorted on them.
            let mut renamed = false;
            for v in list.iter_mut() {
                if let Some(t) = v["group_key"].as_str().and_then(|k| crate::screenscraper::title(app, k, &lang)) {
                    if v["name"].as_str() != Some(t.as_str()) {
                        v["name"] = json!(t);
                        renamed = true;
                    }
                }
            }
            if renamed {
                list.sort_by_cached_key(|v| library::title_sort_key(v["name"].as_str().unwrap_or("")));
            }
            // Which scans exist (spine, backdrop…), so the UI asks only for those.
            for v in list.iter_mut() {
                // Every version of the game counts, even those filtered out (Installed, search).
                let mut ids = vec![v["rom_id"].as_i64().unwrap_or(0)];
                let mut kinds = vec![];
                if let Some(k) = v["group_key"].as_str().map(String::from) {
                    let group = app.db.group(&k);
                    ids.extend(group.iter().map(|g| g.rom_id));
                    library::fill_media(v, &group);
                    let m = crate::media::summary(app, &k);
                    kinds.extend(m["kinds"].as_array().cloned().unwrap_or_default());
                    v["media_sizes"] = m["sizes"].clone();
                }
                kinds.extend(art_kinds(app, &ids).into_iter().map(Value::String));
                v["art_kinds"] = json!(kinds);
                if let Some(r) = v["cover_local"].as_str().and_then(cover_ratio) {
                    v["cover_ar"] = json!(r);
                }
            }
            ok(req, json!(list))
        }
        (Method::Get, ["api", "v1", "games", id]) => {
            match id.parse::<i64>().ok().and_then(|i| app.db.game(i)) {
                Some(g) => {
                    let versions = app.db.group(&g.group_key);
                    let prefs = app
                        .active_profile()
                        .and_then(|p| app.db.game_prefs(&p.id).remove(&g.group_key))
                        .unwrap_or((None, None));
                    let mut game = library::version_json(&g);
                    let lang = query(&q, "lang").unwrap_or_else(|| "en".into());
                    if let Some(t) = crate::screenscraper::title(app, &g.group_key, &lang) {
                        game["name"] = json!(t);
                    }
                    let all = if versions.is_empty() { vec![g.clone()] } else { versions.clone() };
                    library::fill_media(&mut game, &versions);
                    let ids: Vec<i64> = std::iter::once(g.rom_id).chain(versions.iter().map(|v| v.rom_id)).collect();
                    let m = crate::media::summary(app, &g.group_key);
                    let mut kinds = m["kinds"].as_array().cloned().unwrap_or_default();
                    kinds.extend(art_kinds(app, &ids).into_iter().map(Value::String));
                    game["art_kinds"] = json!(kinds);
                    game["media_sizes"] = m["sizes"].clone();
                    if let Some(r) = game["cover_local"].as_str().and_then(cover_ratio) {
                        game["cover_ar"] = json!(r);
                    }
                    ok(
                        req,
                        json!({
                            "game": game,
                            "chosen_version": prefs.0,
                            "versions": if versions.is_empty() { vec![g] } else { versions }
                                .iter()
                                .map(library::version_json)
                                .collect::<Vec<_>>(),
                            "emu_language": prefs.1.unwrap_or_else(|| "auto".into()),
                            "emu_languages": library::EMU_LANGUAGES,
                            "languages": library::game_languages(&all),
                            "install_mode": install_mode(app),
                            "stream": stream::status(app),
                        }),
                    )
                }
                None => err(req, 404, "unknown game"),
            }
        }
        (Method::Get, ["api", "v1", "games", id, "facts"]) => {
            match id.parse::<i64>().ok().filter(|i| app.db.game(*i).is_some()) {
                Some(rom_id) => {
                    let extra: Value = app
                        .db
                        .game_extra(rom_id)
                        .and_then(|e| serde_json::from_str(&e).ok())
                        .unwrap_or(Value::Null);
                    let shots = extra["screenshots"]
                        .as_array()
                        .map(|a| a.len())
                        .unwrap_or(0);
                    ok(
                        req,
                        json!({
                            // Credits come from RomM only (no third-party lookups).
                            "facts": Value::Null,
                            "companies": extra["companies"],
                            "franchises": extra["franchises"],
                            "screenshots": shots,
                        }),
                    )
                }
                None => err(req, 404, "unknown game"),
            }
        }
        (Method::Post, ["api", "v1", "games", id, "trailer"]) => match id.parse::<i64>() {
            Ok(rom_id) => match trailer(app, rom_id) {
                Ok(path) => ok(req, json!({ "path": path })),
                Err(e) => err(req, 404, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Post, ["api", "v1", "games", id, "play"]) => match id.parse::<i64>() {
            Ok(rom_id) => match crate::emulators::play(app, rom_id) {
                Ok(s) => ok(req, s),
                Err(e) => err(req, 409, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Get, ["api", "v1", "games", id, "cheats"]) => match id.parse::<i64>() {
            Ok(rom_id) => ok(req, crate::cheats::list(app, rom_id)),
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Post, ["api", "v1", "games", id, "cheats"]) => match id.parse::<i64>() {
            Ok(rom_id) => {
                let b = body_json(&mut req);
                let on: Vec<String> = b["on"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(String::from)).take(500).collect();
                ok(req, crate::cheats::set(app, rom_id, &on))
            }
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Get, ["api", "v1", "system-files"]) => ok(req, crate::systemfiles::status(app)),
        (Method::Post, ["api", "v1", "system-files", console, item]) => {
            let b = body_json(&mut req);
            let r = if let Some(id) = b["romm"].as_i64() {
                crate::systemfiles::add_romm(app, console, item, id)
            } else if let Some(u) = b["url"].as_str() {
                crate::systemfiles::add_url(app, console, item, u)
            } else if let Some(p) = b["path"].as_str() {
                crate::systemfiles::add_path(app, console, item, p)
            } else if b["pick"].as_bool().unwrap_or(false) {
                crate::systemfiles::pick_file(b["title"].as_str().unwrap_or("Borne")).and_then(|p| crate::systemfiles::add_path(app, console, item, &p))
            } else {
                Err("a path, a link or pick expected".into())
            };
            match r {
                Ok(()) => ok(req, crate::systemfiles::status(app)),
                Err(e) => err(req, 400, &e),
            }
        }
        (Method::Get, ["api", "v1", "system-files", console, "romm"]) => match crate::systemfiles::romm_candidates(app, console) {
            Ok(v) => ok(req, v),
            Err(e) => err(req, 502, &e),
        },
        (Method::Post, ["api", "v1", "system-files", "from-romm"]) => {
            let n = crate::systemfiles::fill_from_romm(app);
            ok(req, json!({ "added": n, "status": crate::systemfiles::status(app) }))
        }
        (Method::Delete, ["api", "v1", "system-files", console, item]) => match crate::systemfiles::remove(app, console, item) {
            Ok(()) => ok(req, crate::systemfiles::status(app)),
            Err(e) => err(req, 400, &e),
        },
        (Method::Get, ["api", "v1", "session"]) => ok(req, crate::emulators::session()),
        (Method::Post, ["api", "v1", "session", "stop"]) => ok(req, json!({ "stopped": crate::emulators::stop() })),
        (Method::Get, ["api", "v1", "emulators"]) => ok(req, crate::emulators::list(app)),
        (Method::Post, ["api", "v1", "emulators", id, "path"]) => {
            let b = body_json(&mut req);
            match crate::emulators::set_path(app, id, b["path"].as_str().unwrap_or_default()) {
                Ok(()) => ok(req, crate::emulators::list(app)),
                Err(e) => err(req, 400, &e),
            }
        }
        (Method::Post, ["api", "v1", "emulators", id, "install"]) => match crate::emuinstall::start(app, id, vec![]) {
            Ok(()) => ok(req, json!({ "started": true })),
            Err(e) => err(req, 409, &e),
        },
        (Method::Post, ["api", "v1", "consoles", slug, "emulator"]) => {
            let b = body_json(&mut req);
            match crate::emulators::choose(app, slug, b["engine"].as_str().unwrap_or_default()) {
                Ok(()) => ok(req, crate::emulators::list(app)),
                Err(e) => err(req, 400, &e),
            }
        }
        (Method::Post, ["api", "v1", "emulators", "auto-update"]) => {
            let b = body_json(&mut req);
            app.db.set_setting("emu_auto_update", if b["on"].as_bool().unwrap_or(true) { "on" } else { "off" });
            ok(req, crate::emulators::list(app))
        }
        (Method::Post, ["api", "v1", "games", id, "gameplay"]) => match id.parse::<i64>() {
            Ok(rom_id) => match gameplay(app, rom_id) {
                Ok(path) => ok(req, json!({ "path": path })),
                Err(e) => err(req, 404, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Get, ["api", "v1", "media", "report"]) => ok(req, crate::media::report(app)),
        (Method::Post, ["api", "v1", "screenscraper", "pause"]) => {
            let b = body_json(&mut req);
            crate::screenscraper::pause(app, b["paused"].as_bool().unwrap_or(true));
            ok(req, crate::screenscraper::status(app))
        }
        (Method::Post, ["api", "v1", "screenscraper", "stop"]) => {
            crate::screenscraper::stop(app);
            ok(req, crate::screenscraper::status(app))
        }
        (Method::Get, ["api", "v1", "screenscraper"]) => ok(req, crate::screenscraper::status(app)),
        (Method::Post, ["api", "v1", "screenscraper"]) => {
            let b = body_json(&mut req);
            let c = crate::screenscraper::Credentials {
                user: b["user"].as_str().unwrap_or_default().trim().to_string(),
                password: b["password"].as_str().unwrap_or_default().to_string(),
            };
            if c.user.is_empty() || c.password.is_empty() {
                return err(req, 400, "user and password are required");
            }
            match crate::screenscraper::save(app, &c) {
                Ok(info) => {
                    crate::screenscraper::start(app, false);
                    ok(req, json!({ "account": info, "status": crate::screenscraper::status(app) }))
                }
                Err(e) => err(req, 409, &e),
            }
        }
        (Method::Delete, ["api", "v1", "screenscraper"]) => {
            crate::screenscraper::forget(app);
            ok(req, crate::screenscraper::status(app))
        }
        (Method::Post, ["api", "v1", "screenscraper", "fetch"]) => {
            let again = body_json(&mut req)["again"].as_bool().unwrap_or(false);
            crate::screenscraper::start(app, again);
            ok(req, crate::screenscraper::status(app))
        }
        (Method::Post, ["api", "v1", "media", "refresh"]) => {
            for p in app.db.clear_media() {
                let _ = std::fs::remove_file(p);
            }
            catalog::start_sync(app);
            ok(req, json!({ "refreshing": true }))
        }
        (Method::Get, ["api", "v1", "games", id, "art", kind]) => {
            match id.parse::<i64>() {
                Ok(rom_id) if ART_KINDS.contains(kind) => match art(app, rom_id, kind) {
                    Ok(path) => serve_file(req, &path.to_string_lossy(), roots),
                    Err(e) => err(req, 404, &e),
                },
                _ => err(req, 400, "invalid identifier"),
            }
        }
        (Method::Get, ["api", "v1", "games", id, "screenshots", n]) => {
            match (id.parse::<i64>(), n.parse::<usize>()) {
                (Ok(rom_id), Ok(n)) if n < 8 => match screenshot(app, rom_id, n) {
                    Ok(path) => serve_file(req, &path.to_string_lossy(), roots),
                    Err(e) => err(req, 404, &e),
                },
                _ => err(req, 400, "invalid identifier"),
            }
        }
        (Method::Post, ["api", "v1", "games", id, "prefs"]) => {
            let body = body_json(&mut req);
            let (Some(g), Some(p)) = (
                id.parse::<i64>().ok().and_then(|i| app.db.game(i)),
                app.active_profile(),
            ) else {
                return err(req, 404, "unknown game or no active profile");
            };
            let version = body.get("version").map(|v| v.as_i64());
            if let Some(Some(v)) = version {
                if app
                    .db
                    .game(v)
                    .map(|x| x.group_key != g.group_key)
                    .unwrap_or(true)
                {
                    return err(req, 400, "this version belongs to another game");
                }
            }
            let lang = body
                .get("emu_language")
                .map(|v| v.as_str().filter(|l| *l != "auto"));
            if let Some(Some(l)) = lang {
                if !library::EMU_LANGUAGES.contains(&l) {
                    return err(req, 400, "unknown language");
                }
            }
            app.db.set_game_pref(&p.id, &g.group_key, version, lang);
            ok(req, json!({ "ok": true }))
        }
        (Method::Post, ["api", "v1", "games", id, "link"]) => match id.parse::<i64>() {
            Ok(rom_id) => match stream::link(app, rom_id) {
                Ok(path) => {
                    choose_version(app, rom_id);
                    ok(req, json!({ "linked": rom_id, "path": path }))
                }
                Err(e) => err(req, 409, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Delete, ["api", "v1", "games", id, "link"]) => match id.parse::<i64>() {
            Ok(rom_id) => match stream::unlink(app, rom_id) {
                Ok(()) => ok(req, json!({ "unlinked": rom_id })),
                Err(e) => err(req, 409, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Get, ["api", "v1", "settings"]) => ok(req, settings(app)),
        (Method::Get, ["api", "v1", "update"]) => ok(req, update::status(app)),
        (Method::Post, ["api", "v1", "update", "check"]) => {
            let force = body_json(&mut req)["force"].as_bool().unwrap_or(false);
            update::check(app, force);
            ok(req, update::status(app))
        }
        (Method::Post, ["api", "v1", "update", "download"]) => match update::download(app) {
            Ok(()) => ok(req, update::status(app)),
            Err(e) => err(req, 409, &e),
        },
        (Method::Post, ["api", "v1", "update", "apply"]) => match update::apply(app) {
            Ok(()) => ok(req, json!({ "restart": true })),
            Err(e) => err(req, 409, &e),
        },
        (Method::Post, ["api", "v1", "settings"]) => {
            let body = body_json(&mut req);
            if let Some(m) = body["install_mode"].as_str() {
                if !["download", "stream"].contains(&m) {
                    return err(req, 400, "install_mode: download or stream");
                }
                if m == "stream" && !stream::available() {
                    return err(
                        req,
                        409,
                        "the virtual mount is not available on this system",
                    );
                }
                app.db.set_setting("install_mode", m);
            }
            if let Some(c) = body["update_channel"].as_str() {
                if !["stable", "dev"].contains(&c) {
                    return err(req, 400, "update_channel: stable or dev");
                }
                app.db.set_setting("update_channel", c);
            }
            if let Some(a) = body["update_auto"].as_bool() {
                app.db.set_setting("update_auto", if a { "1" } else { "0" });
            }
            if let Some(mb) = body["stream_cache_mb"].as_u64() {
                if !(1024..=1_048_576).contains(&mb) {
                    return err(req, 400, "stream_cache_mb: 1024 to 1048576");
                }
                app.db.set_setting("stream_cache_mb", &mb.to_string());
            }
            ok(req, settings(app))
        }
        (Method::Post, ["api", "v1", "games", id, "download"]) => match id.parse::<i64>() {
            Ok(rom_id) => match downloads::enqueue(app, rom_id) {
                Ok(dl) => {
                    choose_version(app, rom_id);
                    ok(req, json!({ "download_id": dl }))
                }
                Err(e) => err(req, 409, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Delete, ["api", "v1", "games", id, "local"]) => match id.parse::<i64>() {
            Ok(rom_id) => match downloads::delete_local(app, rom_id) {
                Ok(()) => ok(req, json!({ "deleted": rom_id })),
                Err(e) => err(req, 409, &e),
            },
            Err(_) => err(req, 400, "invalid identifier"),
        },
        (Method::Get, ["api", "v1", "downloads"]) => ok(req, json!(app.db.downloads())),
        (Method::Delete, ["api", "v1", "downloads", id]) => match id.parse::<i64>() {
            Ok(dl) if downloads::cancel(app, dl) => ok(req, json!({ "cancelled": dl })),
            _ => err(req, 404, "unknown or finished download"),
        },

        // ---------- misc ----------
        (Method::Post, ["api", "v1", "diagnostic-report"]) => match diag::export_report(app) {
            Ok(paths) => ok(req, json!({ "paths": paths })),
            Err(e) => err(req, 500, &e),
        },
        (Method::Post, ["api", "v1", "report"]) => {
            let mut body = String::new();
            let _ = req
                .as_reader()
                .take(4 * 1024 * 1024)
                .read_to_string(&mut body);
            let path = app
                .paths
                .reports()
                .join(format!("bench-{}.json", crate::db::now()));
            match std::fs::write(&path, body) {
                Ok(()) => ok(req, json!({ "path": path })),
                Err(e) => err(req, 500, &e.to_string()),
            }
        }
        (Method::Post, ["api", "v1", "debug", "stick"]) if app.debug_input => {
            let f = |k: &str| query(&q, k).and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0).clamp(-1.0, 1.0);
            app.emit(json!({ "type": "stick", "x": f("x"), "y": f("y") }));
            ok(req, json!({ "ok": true }))
        }
        (Method::Post, ["api", "v1", "debug", "pad"]) if app.debug_input => {
            const OK: [&str; 14] = [
                "up", "down", "left", "right", "a", "b", "x", "y", "start", "select", "lb", "rb",
                "lt", "rt",
            ];
            match query(&q, "action") {
                Some(a) if OK.contains(&a.as_str()) => {
                    app.emit(json!({ "type": "pad", "action": a, "pad": "test", "repeat": false }));
                    ok(req, json!({ "ok": true }))
                }
                _ => err(req, 400, "unknown action"),
            }
        }
        (Method::Get, ["file"]) => match query(&q, "path") {
            Some(p) => serve_file(req, &p, roots),
            None => {
                let _ = req.respond(Response::empty(StatusCode(400)));
            }
        },
        _ => err(req, 404, "unknown route"),
    }
}

/// Starts the server and returns its port.
pub fn start(app: Shared, token: String) -> std::io::Result<u16> {
    let server = Server::http("127.0.0.1:0").map_err(|e| std::io::Error::other(e.to_string()))?;
    let port = server.server_addr().to_ip().map(|a| a.port()).unwrap_or(0);
    // Only covers and bundled resources are served: nothing else from the disk.
    let roots: Vec<PathBuf> = [
        app.paths.covers(),
        app.paths.screenshots(),
        app.paths.videos(),
        app.paths.art(),
        app.resources.clone(),
    ]
    .into_iter()
    .filter_map(|r| r.canonicalize().ok())
    .collect();
    let server = std::sync::Arc::new(server);
    std::thread::Builder::new()
        .name("borne-http".into())
        .spawn(move || {
            for req in server.incoming_requests() {
                let (app, token, roots) = (app.clone(), token.clone(), roots.clone());
                std::thread::spawn(move || handle(req, &app, &token, &roots));
            }
        })?;
    Ok(port)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_queries_without_panicking() {
        assert_eq!(percent_decode("a%20b+c"), "a b c");
        assert_eq!(percent_decode("%C3%A9"), "é");
        assert_eq!(percent_decode("%é%"), "%é%");
        assert_eq!(percent_decode("%4"), "%4");
        assert_eq!(query("q=a%26b&x=1", "q").as_deref(), Some("a&b"));
    }

    #[test]
    fn ranges() {
        assert_eq!(parse_range("bytes=0-9", 100), Some((0, 9)));
        assert_eq!(parse_range("bytes=90-", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=-10", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=-0", 100), None);
        assert_eq!(parse_range("bytes=0-", 0), None);
        assert_eq!(parse_range("bytes=200-", 100), None);
    }
}
