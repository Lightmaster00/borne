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
//!   POST   /api/v1/games/<rom_id>/download
//!   DELETE /api/v1/games/<rom_id>/local          deletes the local copy (never on RomM)
//!   POST   /api/v1/games/<rom_id>/link           exposes the game in the virtual mount (no download)
//!   DELETE /api/v1/games/<rom_id>/link           removes it from the virtual mount
//!   POST   /api/v1/games/<rom_id>/prefs  {version?, emu_language?}   active profile's choices
//!   GET    /api/v1/settings                      install mode, virtual mount state
//!   POST   /api/v1/settings  {install_mode?, stream_cache_mb?, update_channel?, update_auto?}
//! Updates
//!   GET    /api/v1/update                        current build, channel, state of the update
//!   POST   /api/v1/update/check                  looks for a newer build (event "update")
//!   POST   /api/v1/update/download               downloads and verifies it
//!   POST   /api/v1/update/apply                  installs it; Borne restarts when the UI quits
//!   GET    /api/v1/downloads  ·  DELETE /api/v1/downloads/<id>
//! Misc
//!   POST   /api/v1/report  ·  GET /file?path=…
//!   POST   /api/v1/diagnostic-report             writes a shareable report (logs, no secrets)
//!   POST   /api/v1/debug/pad?action=…            automated tests (BORNE_DEBUG_INPUT=1)

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
    json!({ "install_mode": install_mode(app), "stream": stream::status(app), "update": update::status(app) })
}

/// Installing or linking a version makes it the one the active profile sees for that game.
fn choose_version(app: &Shared, rom_id: i64) {
    if let (Some(p), Some(g)) = (app.active_profile(), app.db.game(rom_id)) {
        app.db
            .set_game_pref(&p.id, &g.group_key, Some(Some(rom_id)), None);
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
            ok(req, json!(library::groups(rows, &prefs, &lang)))
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
                    library::fill_media(&mut game, &versions);
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
                            "install_mode": install_mode(app),
                            "stream": stream::status(app),
                        }),
                    )
                }
                None => err(req, 404, "unknown game"),
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
            update::check(app);
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
        (Method::Post, ["api", "v1", "debug", "pad"]) if app.debug_input => {
            const OK: [&str; 12] = [
                "up", "down", "left", "right", "a", "b", "x", "y", "start", "select", "lb", "rb",
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
    let roots: Vec<PathBuf> = [app.paths.covers(), app.resources.clone()]
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
