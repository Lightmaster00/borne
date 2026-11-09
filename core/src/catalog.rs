//! Syncs the RomM catalog into the local database, and caches covers.
//!
//! The local catalog lets the library be browsed offline. A sync runs
//! at startup (if the active profile is paired), after pairing, and on demand.

use crate::db::GameUpsert;
use crate::romm::RommError;
use crate::state::Shared;
use serde_json::Value;
use std::sync::{Arc, Mutex};

const PAGE: usize = 250;

/// Year from a Unix timestamp (seconds or milliseconds).
pub fn year_from_timestamp(ts: i64) -> Option<i64> {
    if ts == 0 {
        return None; // RomM returns 0 when the date is unknown
    }
    let secs = if ts.abs() > 100_000_000_000 { ts / 1000 } else { ts };
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
        .filter_map(|x| x.as_str().map(String::from).or_else(|| x.get("name").and_then(|n| n.as_str()).map(String::from)))
        .collect();
    (!parts.is_empty()).then(|| parts.join(", "))
}

fn non_empty(v: &Value) -> Option<String> {
    v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

pub fn map_rom(v: &Value) -> Option<GameUpsert> {
    let name = non_empty(&v["name"]).or_else(|| non_empty(&v["fs_name_no_tags"])).or_else(|| non_empty(&v["fs_name"]))?;
    Some(GameUpsert {
        rom_id: v["id"].as_i64()?,
        platform_id: v["platform_id"].as_i64().unwrap_or(0),
        platform_slug: non_empty(&v["platform_slug"]).unwrap_or_default(),
        platform_name: non_empty(&v["platform_custom_name"])
            .or_else(|| non_empty(&v["platform_display_name"]))
            .unwrap_or_default(),
        sort_key: non_empty(&v["name_sort_key"]).unwrap_or_else(|| name.to_lowercase()),
        name,
        fs_name: non_empty(&v["fs_name"]).unwrap_or_default(),
        fs_size: v["fs_size_bytes"].as_i64().unwrap_or(0),
        multi_file: v["has_multiple_files"].as_bool().unwrap_or(false),
        summary: non_empty(&v["summary"]),
        year: v["metadatum"]["first_release_date"].as_i64().and_then(year_from_timestamp),
        genres: join_strings(&v["metadatum"]["genres"]),
        regions: join_strings(&v["regions"]),
        languages: join_strings(&v["languages"]),
        revision: non_empty(&v["revision"]),
        group_key: crate::library::group_key(v),
        players: non_empty(&v["metadatum"]["player_count"]),
        sha1: non_empty(&v["sha1_hash"]),
        cover_remote: non_empty(&v["path_cover_large"]).or_else(|| non_empty(&v["url_cover"])),
        video_remote: non_empty(&v["path_video"]),
        updated_at: non_empty(&v["updated_at"]),
    })
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
    let client = app.client().ok_or_else(|| RommError::Http(0, "no paired profile".into()))?;
    let platforms = client.platforms()?;
    app.set_online(true);
    let list: Vec<(i64, String, String, String, i64)> = platforms
        .iter()
        .filter_map(|p| {
            Some((
                p["id"].as_i64()?,
                p["slug"].as_str()?.to_string(),
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
        let (items, total) = client.roms_page(offset, PAGE)?;
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
    app.db.log("sync", &format!("{offset} games synced, {removed} removed"));
    app.emit(serde_json::json!({ "type": "library" }));
    fetch_covers(app, &client, covers);
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
    let dir = app.paths.covers();
    let mut handles = vec![];
    for _ in 0..4 {
        let (queue, app, client, dir) = (queue.clone(), app.clone(), client.clone(), dir.clone());
        handles.push(std::thread::spawn(move || loop {
            let Some((rom_id, remote, stamp)) = queue.lock().unwrap().pop() else { break };
            let ext = remote.split('?').next().and_then(|p| p.rsplit('.').next()).filter(|e| e.len() <= 4).unwrap_or("img");
            let path = dir.join(format!("{rom_id}.{ext}"));
            if let Ok(bytes) = client.fetch_bytes(&remote, 20 * 1024 * 1024) {
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
    app.emit(serde_json::json!({ "type": "library" }));
}

#[cfg(test)]
mod tests {
    use super::*;

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
