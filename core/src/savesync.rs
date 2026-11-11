//! Saves kept in step with RomM, per profile (each profile is a RomM account).
//!
//! Before a game starts, the newest save of that game on RomM replaces the local one when it is
//! newer; after the game, a save that changed goes to RomM. When both sides changed since the last
//! sync, the newest wins and the other is archived (`profiles/<id>/archive/`), never deleted: a
//! local file is always copied to the archive before it is replaced.
//!
//! First pass: battery saves of the consoles run by RetroArch (`<game>.srm` in the profile's saves
//! folder), sent with the core's name as the emulator, as RomM's own player (EmulatorJS) does.
//! Offline, the game starts with the local save; the change is sent after the next game, or when
//! RomM is back (pending sends are retried at each start).

use crate::state::Shared;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn enabled(app: &Shared) -> bool {
    app.db.setting("save_sync").as_deref() != Some("off")
}

/// The local battery save of a game run by a RetroArch core.
pub fn save_path(app: &Shared, profile: &str, system: &str, rom: &Path) -> PathBuf {
    let stem = rom.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    app.paths.profiles().join(profile).join("saves").join(system).join(format!("{stem}.srm"))
}

fn state_key(profile: &str, rom_id: i64) -> String {
    format!("savesync.{profile}.{rom_id}")
}

/// What was in step at the last sync: the local file's hash and RomM's save time.
fn last(app: &Shared, profile: &str, rom_id: i64) -> Value {
    app.db.setting(&state_key(profile, rom_id)).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}
fn remember(app: &Shared, profile: &str, rom_id: i64, v: Value) {
    app.db.set_setting(&state_key(profile, rom_id), &v.to_string());
}

fn hash(p: &Path) -> Option<String> {
    std::fs::read(p).ok().map(|b| crate::emuinstall::sha256_bytes(&b))
}

fn mtime(p: &Path) -> i64 {
    p.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// RomM's time ("2026-11-11T21:07:11Z" or with an offset) in seconds.
fn parse_time(s: &str) -> i64 {
    let s = s.trim();
    let (date, time) = match s.split_once('T') {
        Some(x) => x,
        None => return 0,
    };
    let d: Vec<i64> = date.split('-').filter_map(|x| x.parse().ok()).collect();
    if d.len() != 3 {
        return 0;
    }
    let (clock, offset) = {
        let t = time.trim_end_matches('Z');
        match t.rfind(['+', '-']) {
            Some(i) if i > 0 => {
                let off = &t[i..];
                let sign = if off.starts_with('-') { -1 } else { 1 };
                let parts: Vec<i64> = off[1..].split(':').filter_map(|x| x.parse().ok()).collect();
                let secs = parts.first().copied().unwrap_or(0) * 3600 + parts.get(1).copied().unwrap_or(0) * 60;
                (&t[..i], sign * secs)
            }
            _ => (t, 0),
        }
    };
    let c: Vec<f64> = clock.split(':').filter_map(|x| x.parse().ok()).collect();
    if c.len() < 2 {
        return 0;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let (y, m, day) = (if d[1] <= 2 { d[0] - 1 } else { d[0] }, d[1], d[2]);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    days * 86400 + (c[0] as i64) * 3600 + (c[1] as i64) * 60 + c.get(2).copied().unwrap_or(0.0) as i64 - offset
}

fn archive(app: &Shared, profile: &str, system: &str, file: &Path) {
    if !file.is_file() {
        return;
    }
    let dir = app.paths.profiles().join(profile).join("archive").join(system);
    if std::fs::create_dir_all(&dir).is_ok() {
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let _ = std::fs::copy(file, dir.join(format!("{name}.{}", now())));
    }
}

/// RomM's newest save of this game for this file name (the .srm of the same name, any core).
fn newest_remote(saves: &[Value], file_name: &str) -> Option<Value> {
    saves
        .iter()
        .filter(|s| s["file_name"].as_str().map(|n| n.eq_ignore_ascii_case(file_name)).unwrap_or(false) && s["missing_from_fs"] != true)
        .max_by_key(|s| parse_time(s["updated_at"].as_str().unwrap_or("")))
        .cloned()
}

/// Before a game: RomM's save when it is newer. Returns a short note for the log.
pub fn pull(app: &Shared, profile: &str, rom_id: i64, system: &str, rom: &Path) -> Result<String, String> {
    if !enabled(app) {
        return Ok("save sync off".into());
    }
    let client = app.client().ok_or("offline")?;
    let local = save_path(app, profile, system, rom);
    let name = local.file_name().unwrap().to_string_lossy().into_owned();
    let saves = client.saves(rom_id).map_err(|e| e.to_string())?;
    let Some(remote) = newest_remote(&saves, &name) else { return Ok("no save on RomM".into()) };
    let remote_time = parse_time(remote["updated_at"].as_str().unwrap_or(""));
    let prev = last(app, profile, rom_id);
    let local_hash = hash(&local);
    let local_changed = local_hash.is_some() && local_hash.as_deref() != prev["hash"].as_str();
    let remote_changed = remote_time > prev["remote"].as_i64().unwrap_or(0);
    if !remote_changed {
        return Ok("up to date".into());
    }
    if local_changed && mtime(&local) > remote_time {
        // Both changed: the local one is newer and wins (sent after the game); RomM's is kept by RomM.
        return Ok("local save newer".into());
    }
    let id = remote["id"].as_i64().ok_or("save without id")?;
    let tmp = local.with_extension("srm.download");
    std::fs::create_dir_all(local.parent().unwrap()).map_err(|e| e.to_string())?;
    client.fetch_to_file(&format!("/api/saves/{id}/content"), &tmp, 64 << 20).map_err(|e| e.to_string())?;
    archive(app, profile, system, &local);
    std::fs::rename(&tmp, &local).map_err(|e| e.to_string())?;
    remember(app, profile, rom_id, json!({ "hash": hash(&local), "remote": remote_time, "pending": false }));
    Ok("save taken from RomM".into())
}

/// After a game: the save goes to RomM when it changed (or is still waiting to be sent).
pub fn push(app: &Shared, profile: &str, rom_id: i64, system: &str, rom: &Path, emulator: &str) -> Result<Option<String>, String> {
    if !enabled(app) {
        return Ok(None);
    }
    let local = save_path(app, profile, system, rom);
    let Some(h) = hash(&local) else { return Ok(None) };
    let prev = last(app, profile, rom_id);
    if prev["hash"].as_str() == Some(h.as_str()) && prev["pending"] != true {
        return Ok(None);
    }
    let pending = || remember(app, profile, rom_id, json!({ "hash": prev["hash"], "remote": prev["remote"], "pending": true, "system": system, "rom": rom, "emulator": emulator }));
    let Some(client) = app.client() else {
        pending();
        return Err("RomM unreachable: the save will be sent later".into());
    };
    let data = std::fs::read(&local).map_err(|e| e.to_string())?;
    let name = local.file_name().unwrap().to_string_lossy().into_owned();
    match client.upload_save(rom_id, emulator, &name, &data) {
        Ok(v) => {
            let t = parse_time(v["updated_at"].as_str().unwrap_or(""));
            remember(app, profile, rom_id, json!({ "hash": h, "remote": if t > 0 { t } else { now() }, "pending": false }));
            Ok(Some("save sent to RomM".into()))
        }
        Err(e) => {
            pending();
            Err(format!("the save will be sent later: {e}"))
        }
    }
}

/// Sends the saves still waiting (RomM was unreachable), for the active profile.
pub fn retry_pending(app: &Shared) {
    let Some(p) = app.active_profile() else { return };
    let prefix = format!("savesync.{}.", p.id);
    for (k, v) in app.db.settings_with_prefix(&prefix) {
        let Ok(v) = serde_json::from_str::<Value>(&v) else { continue };
        if v["pending"] != true {
            continue;
        }
        let Some(rom_id) = k.strip_prefix(&prefix).and_then(|r| r.parse::<i64>().ok()) else { continue };
        let (Some(system), Some(rom), Some(emu)) = (v["system"].as_str(), v["rom"].as_str(), v["emulator"].as_str()) else { continue };
        match push(app, &p.id, rom_id, system, Path::new(rom), emu) {
            Ok(Some(_)) => app.db.log("saves", &format!("game {rom_id}: pending save sent")),
            Err(e) => app.db.log("saves", &format!("game {rom_id}: {e}")),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn romm_times() {
        assert_eq!(parse_time("1970-01-01T00:00:10Z"), 10);
        assert_eq!(parse_time("2026-11-11T21:07:11Z"), 1_794_431_231);
        assert_eq!(parse_time("2026-11-11T22:07:11+01:00"), 1_794_431_231);
        assert_eq!(parse_time("2026-11-11T21:07:11.123456"), 1_794_431_231);
        assert_eq!(parse_time("nonsense"), 0);
    }

    #[test]
    fn the_newest_save_of_the_same_file_is_chosen() {
        let saves = vec![
            json!({ "id": 1, "file_name": "Game (World).srm", "updated_at": "2026-01-01T00:00:00Z" }),
            json!({ "id": 2, "file_name": "Game (World).srm", "updated_at": "2026-02-01T00:00:00Z" }),
            json!({ "id": 3, "file_name": "Other.srm", "updated_at": "2026-03-01T00:00:00Z" }),
        ];
        assert_eq!(newest_remote(&saves, "game (world).srm").unwrap()["id"], 2);
        assert!(newest_remote(&saves, "None.srm").is_none());
    }
}
