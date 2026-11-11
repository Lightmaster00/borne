//! Syncs the RomM catalog into the local database, and caches covers.
//!
//! The local catalog lets the library be browsed offline. A sync runs
//! at startup (if the active profile is paired), after pairing, and on demand.

use crate::db::GameUpsert;
use crate::romm::RommError;
use crate::state::Shared;
use serde_json::Value;
use std::sync::{Arc, Mutex};

/// Games per catalog page. Kept modest: RomM serializes a lot per game and slow servers
/// (NAS, Raspberry Pi) can take minutes for large pages.
const PAGE: usize = 100;

/// Year from a Unix timestamp (seconds or milliseconds).
pub fn year_from_timestamp(ts: i64) -> Option<i64> {
    if ts == 0 {
        return None; // RomM returns 0 when the date is unknown
    }
    let secs = if ts.abs() > 100_000_000_000 {
        ts / 1000
    } else {
        ts
    };
    let days = secs.div_euclid(86_400);
    // "Civil from days" algorithm (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (1950..2100).contains(&year).then_some(year)
}

fn join_strings(v: &Value) -> Option<String> {
    let parts: Vec<String> = v
        .as_array()?
        .iter()
        .filter_map(|x| {
            x.as_str()
                .map(String::from)
                .or_else(|| x.get("name").and_then(|n| n.as_str()).map(String::from))
        })
        .collect();
    (!parts.is_empty()).then(|| parts.join(", "))
}

fn non_empty(v: &Value) -> Option<String> {
    v.as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Platform slugs become directory names (library, virtual mount): only `[a-z0-9_-]` is kept,
/// so a server can never make Borne write outside its folders.
pub fn safe_slug(s: &str) -> String {
    let out: String = s
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        "unknown".into()
    } else {
        out
    }
}

/// RomM gives some media (trailers) relative to its resources folder ("roms/12/34/video/…");
/// they are served under /assets/romm/resources/.
pub fn resource_path(p: &str) -> String {
    if p.starts_with('/') || p.starts_with("http://") || p.starts_with("https://") {
        p.to_string()
    } else {
        format!("/assets/romm/resources/{}", p.trim_start_matches("./"))
    }
}

pub fn map_rom(v: &Value) -> Option<GameUpsert> {
    let name = non_empty(&v["name"])
        .or_else(|| non_empty(&v["fs_name_no_tags"]))
        .or_else(|| non_empty(&v["fs_name"]))?;
    Some(GameUpsert {
        rom_id: v["id"].as_i64()?,
        platform_id: v["platform_id"].as_i64().unwrap_or(0),
        platform_slug: safe_slug(&non_empty(&v["platform_slug"]).unwrap_or_default()),
        platform_name: non_empty(&v["platform_custom_name"])
            .or_else(|| non_empty(&v["platform_display_name"]))
            .unwrap_or_default(),
        sort_key: non_empty(&v["name_sort_key"]).unwrap_or_else(|| name.to_lowercase()),
        name,
        fs_name: non_empty(&v["fs_name"]).unwrap_or_default(),
        fs_size: v["fs_size_bytes"].as_i64().unwrap_or(0),
        multi_file: v["has_multiple_files"].as_bool().unwrap_or(false),
        summary: non_empty(&v["summary"]),
        year: v["metadatum"]["first_release_date"]
            .as_i64()
            .and_then(year_from_timestamp),
        genres: join_strings(&v["metadatum"]["genres"]),
        regions: join_strings(&v["regions"]),
        languages: join_strings(&v["languages"]),
        revision: non_empty(&v["revision"]),
        group_key: crate::library::group_key(v),
        players: non_empty(&v["metadatum"]["player_count"]),
        sha1: non_empty(&v["sha1_hash"]),
        cover_remote: non_empty(&v["path_cover_large"]).or_else(|| non_empty(&v["url_cover"])),
        video_remote: non_empty(&v["path_video"]).map(|p| resource_path(&p)),
        updated_at: non_empty(&v["updated_at"]),
        extra: Some(extra_of(v).to_string()),
    })
}

/// What the game page shows beyond the library row: studios, series, screenshots, ids.
pub fn extra_of(v: &Value) -> Value {
    let strings = |x: &Value| -> Vec<String> {
        x.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|s| {
                        s.as_str()
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                            .map(String::from)
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let shots: Vec<String> = strings(&v["merged_screenshots"])
        .into_iter()
        .take(8)
        .collect();
    serde_json::json!({
        "companies": strings(&v["metadatum"]["companies"]),
        "franchises": strings(&v["metadatum"]["franchises"]),
        "collections": strings(&v["metadatum"]["collections"]),
        "screenshots": shots,
        "art": art_of(v),
        "igdb_id": v["igdb_id"].as_i64(),
        "release": v["metadatum"]["first_release_date"].as_i64(),
    })
}

/// ScreenScraper scans stored by RomM (when enabled in its scan.media): front, spine, back cover,
/// fanart, transparent logo, cartridge or disc. Paths under /assets/romm/resources/.
pub fn art_of(v: &Value) -> Value {
    let ss = &v["ss_metadata"];
    let mut out = serde_json::Map::new();
    for (kind, field) in [
        ("front", "box2d_path"),
        ("side", "box2d_side_path"),
        ("back", "box2d_back_path"),
        ("fanart", "fanart_path"),
        ("logo", "logo_path"),
        ("physical", "physical_path"),
        ("title", "title_screen_path"),
    ] {
        if let Some(p) = ss[field].as_str().map(str::trim).filter(|p| !p.is_empty()) {
            out.insert(kind.into(), Value::String(resource_path(p)));
        }
    }
    Value::Object(out)
}

/// Starts a background sync (no effect if one is already running).
pub fn start_sync(app: &Shared) {
    {
        let mut s = app.sync.lock().unwrap();
        if s.running {
            return;
        }
        s.running = true;
        s.done = 0;
        s.total = 0;
        s.error = None;
    }
    let app = app.clone();
    std::thread::Builder::new()
        .name("borne-sync".into())
        .spawn(move || {
            let result = sync(&app);
            let mut s = app.sync.lock().unwrap();
            s.running = false;
            match result {
                Ok(()) => s.last_sync = Some(crate::db::now()),
                Err(e) => {
                    if matches!(e, RommError::Offline(_)) {
                        app.set_online(false);
                    }
                    if matches!(e, RommError::Unauthorized) {
                        if let Some(p) = app.active_profile() {
                            app.db.set_unpaired(&p.id);
                            app.emit(serde_json::json!({ "type": "profiles", "profiles": app.db.profiles() }));
                        }
                    }
                    app.db.log("sync", &e.to_string());
                    s.error = Some(e.to_string());
                }
            }
            app.emit(serde_json::json!({ "type": "sync", "sync": s.clone() }));
        })
        .expect("sync thread");
}

fn emit_progress(app: &Shared) {
    let s = app.sync.lock().unwrap().clone();
    app.emit(serde_json::json!({ "type": "sync", "sync": s }));
}

fn sync(app: &Shared) -> Result<(), RommError> {
    let client = app
        .client()
        .ok_or_else(|| RommError::Http(0, "no paired profile".into()))?;
    let platforms = client.platforms()?;
    app.set_online(true);
    let list: Vec<(i64, String, String, String, i64)> = platforms
        .iter()
        .filter_map(|p| {
            Some((
                p["id"].as_i64()?,
                safe_slug(p["slug"].as_str()?),
                p["fs_slug"].as_str().unwrap_or_default().to_string(),
                p["custom_name"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .or_else(|| p["display_name"].as_str())
                    .or_else(|| p["name"].as_str())
                    .unwrap_or_default()
                    .to_string(),
                p["rom_count"].as_i64().unwrap_or(0),
            ))
        })
        .collect();
    app.db.replace_platforms(&list);

    let sync_id = crate::db::now();
    let mut offset = 0;
    let mut covers = vec![];
    loop {
        // One retry with a smaller page if the server times out or drops the connection.
        let (items, total) = match client.roms_page(offset, PAGE) {
            Err(RommError::Offline(e)) => {
                app.db.log(
                    "sync",
                    &format!("page at {offset} failed ({e}); retrying with a smaller page"),
                );
                client.roms_page(offset, PAGE / 4)?
            }
            other => other?,
        };
        let games: Vec<GameUpsert> = items.iter().filter_map(map_rom).collect();
        covers.extend(app.db.upsert_games(&games, sync_id));
        offset += items.len();
        {
            let mut s = app.sync.lock().unwrap();
            s.done = offset.min(total);
            s.total = total;
        }
        emit_progress(app);
        if items.is_empty() || offset >= total {
            break;
        }
    }
    let removed = app.db.prune_games(sync_id);
    app.db
        .log("sync", &format!("{offset} games synced, {removed} removed"));
    app.emit(serde_json::json!({ "type": "library" }));
    fetch_covers(app, &client, covers);
    crate::media::prefetch(app, &client);
    Ok(())
}

/// Downloads missing or changed covers with 4 threads.
fn fetch_covers(app: &Shared, client: &crate::romm::Client, covers: Vec<(i64, String, String)>) {
    if covers.is_empty() {
        return;
    }
    app.sync.lock().unwrap().covers_pending = covers.len();
    emit_progress(app);
    let queue = Arc::new(Mutex::new(covers));
    let failed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let dir = app.paths.covers();
    let mut handles = vec![];
    for _ in 0..4 {
        let (queue, app, client, dir, failed) = (
            queue.clone(),
            app.clone(),
            client.clone(),
            dir.clone(),
            failed.clone(),
        );
        handles.push(std::thread::spawn(move || loop {
            let Some((rom_id, remote, stamp)) = queue.lock().unwrap().pop() else {
                break;
            };
            let ext = remote
                .split('?')
                .next()
                .and_then(|p| p.rsplit('/').next())
                .and_then(|name| name.rsplit_once('.').map(|(_, e)| e))
                .filter(|e| {
                    !e.is_empty() && e.len() <= 4 && e.chars().all(|c| c.is_ascii_alphanumeric())
                })
                .unwrap_or("img");
            let path = dir.join(format!("{rom_id}.{ext}"));
            if let Ok(bytes) = client.fetch_bytes(&remote, 20 * 1024 * 1024) {
                // RomM may answer an HTML page (proxy login, error page) with 200: keep images only.
                if !looks_like_image(&bytes) {
                    failed.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let mut s = app.sync.lock().unwrap();
                    s.covers_pending = s.covers_pending.saturating_sub(1);
                    continue;
                }
                let tmp = path.with_extension("tmp");
                if std::fs::write(&tmp, &bytes).is_ok() && std::fs::rename(&tmp, &path).is_ok() {
                    app.db.set_cover(rom_id, &path.to_string_lossy(), &stamp);
                }
            }
            let left = {
                let mut s = app.sync.lock().unwrap();
                s.covers_pending = s.covers_pending.saturating_sub(1);
                s.covers_pending
            };
            if left % 20 == 0 {
                app.emit(serde_json::json!({ "type": "library" }));
                emit_progress(&app);
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let failed = failed.load(std::sync::atomic::Ordering::Relaxed);
    if failed > 0 {
        app.db.log(
            "sync",
            &format!("{failed} cover(s) were not images and were skipped"),
        );
    }
    app.emit(serde_json::json!({ "type": "library" }));
}

pub fn looks_like_image(b: &[u8]) -> bool {
    b.starts_with(&[0x89, b'P', b'N', b'G'])
        || b.starts_with(&[0xFF, 0xD8, 0xFF])
        || (b.len() > 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP")
        || b.starts_with(b"GIF8")
        || (b.len() > 12 && &b[4..8] == b"ftyp") // AVIF
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_paths_point_at_resources() {
        assert_eq!(resource_path("roms/3/12/video/video.mp4"), "/assets/romm/resources/roms/3/12/video/video.mp4");
        assert_eq!(resource_path("/assets/romm/resources/x.mp4"), "/assets/romm/resources/x.mp4");
        assert_eq!(resource_path("https://cdn/x.mp4"), "https://cdn/x.mp4");
    }

    #[test]
    fn slugs_are_safe_directory_names() {
        assert_eq!(safe_slug("snes"), "snes");
        assert_eq!(safe_slug("../../etc"), "etc");
        assert_eq!(safe_slug("Genesis/MegaDrive"), "genesis-megadrive");
        assert_eq!(safe_slug(".."), "unknown");
    }

    #[test]
    fn years() {
        assert_eq!(year_from_timestamp(946_684_800), Some(2000));
        assert_eq!(year_from_timestamp(946_684_800_000), Some(2000));
        assert_eq!(year_from_timestamp(509_587_200), Some(1986));
        assert_eq!(year_from_timestamp(0), None);
    }

    #[test]
    fn maps_romm_item() {
        let v = serde_json::json!({
            "id": 7, "platform_id": 2, "platform_slug": "nes", "platform_display_name": "NES",
            "name": "Pixel Quest", "name_sort_key": "pixel quest", "fs_name": "Pixel Quest (Europe).nes",
            "fs_size_bytes": 40976, "has_multiple_files": false, "summary": "",
            "metadatum": { "first_release_date": 509587200000i64, "genres": ["Action", "Platform"], "player_count": "1-2" },
            "regions": ["Europe"], "sha1_hash": "abc", "path_cover_large": "/assets/x.png?ts=1", "path_video": null,
            "updated_at": "2026-11-08T16:15:31+00:00"
        });
        let g = map_rom(&v).unwrap();
        assert_eq!(g.rom_id, 7);
        assert_eq!(g.year, Some(1986));
        assert_eq!(g.genres.as_deref(), Some("Action, Platform"));
        assert_eq!(g.summary, None, "empty summary ignored");
        assert_eq!(g.cover_remote.as_deref(), Some("/assets/x.png?ts=1"));
    }
}
