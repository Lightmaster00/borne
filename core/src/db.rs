//! Local SQLite database: cached catalog, profiles, local presence of games, downloads.
//! Secrets are never stored here (see `secrets.rs`).

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::path::Path;
use std::sync::{Arc, Mutex};

const SCHEMA_VERSION: i64 = 2;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    romm_user TEXT,
    romm_user_id INTEGER,
    device_id TEXT,
    paired INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER
);
CREATE TABLE IF NOT EXISTS platforms (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL,
    fs_slug TEXT NOT NULL,
    name TEXT NOT NULL,
    rom_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS games (
    rom_id INTEGER PRIMARY KEY,
    platform_id INTEGER NOT NULL,
    platform_slug TEXT NOT NULL,
    platform_name TEXT NOT NULL,
    name TEXT NOT NULL,
    sort_key TEXT NOT NULL,
    fs_name TEXT NOT NULL,
    fs_size INTEGER NOT NULL,
    multi_file INTEGER NOT NULL DEFAULT 0,
    summary TEXT,
    year INTEGER,
    genres TEXT,
    regions TEXT,
    languages TEXT,
    revision TEXT,
    group_key TEXT NOT NULL DEFAULT '',
    players TEXT,
    sha1 TEXT,
    cover_remote TEXT,
    cover_local TEXT,
    cover_stamp TEXT,
    video_remote TEXT,
    updated_at TEXT,
    seen_sync INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS games_platform ON games(platform_slug, sort_key);
CREATE TABLE IF NOT EXISTS local_games (
    rom_id INTEGER PRIMARY KEY,
    dir TEXT NOT NULL,
    main_file TEXT NOT NULL,
    size INTEGER NOT NULL,
    installed_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'ok'
);
CREATE TABLE IF NOT EXISTS downloads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rom_id INTEGER NOT NULL,
    state TEXT NOT NULL,
    received INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
-- Per-profile play record of a game group: last played, time played, favourite.
CREATE TABLE IF NOT EXISTS play_stats (
    profile_id TEXT NOT NULL,
    group_key TEXT NOT NULL,
    last_played INTEGER,
    seconds INTEGER NOT NULL DEFAULT 0,
    favourite INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (profile_id, group_key)
);
-- Per-profile choices on a game group: the version to play and the emulator language.
CREATE TABLE IF NOT EXISTS game_prefs (
    profile_id TEXT NOT NULL,
    group_key TEXT NOT NULL,
    rom_id INTEGER,
    emu_language TEXT,
    PRIMARY KEY (profile_id, group_key)
);
-- Games exposed in the Borne virtual mount (played from RomM without a download).
CREATE TABLE IF NOT EXISTS linked_games (
    rom_id INTEGER PRIMARY KEY,
    main_file TEXT NOT NULL,
    linked_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS linked_files (
    file_id INTEGER PRIMARY KEY,
    rom_id INTEGER NOT NULL,
    rel_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    size INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS media (
    group_key TEXT NOT NULL,
    kind TEXT NOT NULL,
    path TEXT NOT NULL,
    w INTEGER NOT NULL,
    h INTEGER NOT NULL,
    stamp TEXT NOT NULL,
    PRIMARY KEY (group_key, kind)
);
-- ScreenScraper's record of a game (titles per region, media addresses without credentials), kept
-- so that a change of interface language picks other titles and scans without asking again.
CREATE TABLE IF NOT EXISTS ss_records (
    group_key TEXT PRIMARY KEY,
    json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS oplog (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    message TEXT NOT NULL
);
"#;

/// Brings a database created by an older version up to date (columns added over time).
/// The catalog is a cache: new columns are filled by the next sync.
fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    let mut st = conn.prepare("SELECT name FROM pragma_table_info('games')")?;
    let cols: Vec<String> = st
        .query_map([], |r| r.get(0))?
        .filter_map(Result::ok)
        .collect();
    for (col, def) in [
        ("languages", "TEXT"),
        ("revision", "TEXT"),
        ("group_key", "TEXT NOT NULL DEFAULT ''"),
        ("extra", "TEXT"),
    ] {
        if !cols.iter().any(|c| c == col) {
            conn.execute_batch(&format!("ALTER TABLE games ADD COLUMN {col} {def}"))?;
        }
    }
    conn.execute_batch("CREATE INDEX IF NOT EXISTS games_group ON games(group_key)")?;
    // Sources removed in later versions: LaunchBox (index and images), Wikidata / Wikipedia facts.
    conn.execute_batch(
        "DROP TABLE IF EXISTS lb_games; DROP TABLE IF EXISTS lb_names; DROP TABLE IF EXISTS lb_images;
         DELETE FROM media WHERE kind = 'lb' OR stamp LIKE 'lb|%';
         DELETE FROM settings WHERE key IN ('lb_indexed', 'launchbox');
         DROP TABLE IF EXISTS facts;",
    )?;
    Ok(())
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(Clone)]
pub struct Db(Arc<Mutex<Connection>>);

#[derive(Serialize, Clone, Debug)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub romm_user: Option<String>,
    pub paired: bool,
    pub device_id: Option<String>,
    pub last_used_at: Option<i64>,
}

#[derive(Serialize, Clone, Debug)]
pub struct Platform {
    pub id: i64,
    pub slug: String,
    pub name: String,
    pub rom_count: i64,
    pub local_count: i64,
}

#[derive(Debug, Clone)]
pub struct MediaRow {
    pub kind: String,
    pub path: String,
    pub w: u32,
    pub h: u32,
    pub stamp: String,
}
fn media_from_row(r: &rusqlite::Row) -> rusqlite::Result<MediaRow> {
    Ok(MediaRow { kind: r.get(0)?, path: r.get(1)?, w: r.get(2)?, h: r.get(3)?, stamp: r.get(4)? })
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct GameRow {
    pub rom_id: i64,
    pub platform_slug: String,
    pub platform_name: String,
    pub name: String,
    pub fs_name: String,
    pub fs_size: i64,
    pub multi_file: bool,
    pub summary: Option<String>,
    pub year: Option<i64>,
    pub genres: Option<String>,
    pub regions: Option<String>,
    pub languages: Option<String>,
    pub revision: Option<String>,
    pub group_key: String,
    pub players: Option<String>,
    pub sha1: Option<String>,
    pub cover_remote: Option<String>,
    pub cover_local: Option<String>,
    pub cover_stamp: Option<String>,
    pub video_remote: Option<String>,
    pub updated_at: Option<String>,
    /// "remote" | "local" | "missing"
    pub local_state: String,
    pub local_dir: Option<String>,
    pub local_main: Option<String>,
    /// Exposed in the Borne virtual mount (played from RomM without a download).
    pub linked: bool,
    /// State of the current download, if any (queued, downloading, verifying, extracting, failed)
    pub download_state: Option<String>,
    pub download_received: Option<i64>,
    pub download_total: Option<i64>,
    pub download_error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct LinkedFile {
    pub file_id: i64,
    pub rom_id: i64,
    pub platform_slug: String,
    pub rel_path: String,
    pub file_name: String,
    pub size: i64,
}

#[derive(Serialize, Clone, Debug)]
pub struct Download {
    pub id: i64,
    pub rom_id: i64,
    pub name: String,
    pub state: String,
    pub received: i64,
    pub total: i64,
    pub error: Option<String>,
}

const GAME_SELECT: &str = "SELECT g.rom_id, g.platform_slug, g.platform_name, g.name, g.fs_name, g.fs_size, g.multi_file,
    g.summary, g.year, g.genres, g.regions, g.players, g.sha1, g.cover_remote, g.cover_local, g.cover_stamp, g.video_remote,
    g.updated_at, l.status, l.dir, l.main_file,
    (SELECT state FROM downloads d WHERE d.rom_id = g.rom_id AND d.state NOT IN ('done','cancelled') ORDER BY d.id DESC LIMIT 1),
    (SELECT received FROM downloads d WHERE d.rom_id = g.rom_id AND d.state NOT IN ('done','cancelled') ORDER BY d.id DESC LIMIT 1),
    (SELECT total FROM downloads d WHERE d.rom_id = g.rom_id AND d.state NOT IN ('done','cancelled') ORDER BY d.id DESC LIMIT 1),
    (SELECT error FROM downloads d WHERE d.rom_id = g.rom_id AND d.state NOT IN ('done','cancelled') ORDER BY d.id DESC LIMIT 1),
    g.languages, g.revision, g.group_key, (SELECT 1 FROM linked_games k WHERE k.rom_id = g.rom_id)
    FROM games g LEFT JOIN local_games l ON l.rom_id = g.rom_id";

fn game_from_row(r: &rusqlite::Row) -> rusqlite::Result<GameRow> {
    let status: Option<String> = r.get(18)?;
    Ok(GameRow {
        rom_id: r.get(0)?,
        platform_slug: r.get(1)?,
        platform_name: r.get(2)?,
        name: r.get(3)?,
        fs_name: r.get(4)?,
        fs_size: r.get(5)?,
        multi_file: r.get::<_, i64>(6)? != 0,
        summary: r.get(7)?,
        year: r.get(8)?,
        genres: r.get(9)?,
        regions: r.get(10)?,
        players: r.get(11)?,
        sha1: r.get(12)?,
        cover_remote: r.get(13)?,
        cover_local: r.get(14)?,
        cover_stamp: r.get(15)?,
        video_remote: r.get(16)?,
        updated_at: r.get(17)?,
        local_state: match status.as_deref() {
            None => "remote".into(),
            Some("ok") => "local".into(),
            Some(_) => "missing".into(),
        },
        local_dir: r.get(19)?,
        local_main: r.get(20)?,
        download_state: r.get(21)?,
        download_received: r.get(22)?,
        download_total: r.get(23)?,
        download_error: r.get(24)?,
        languages: r.get(25)?,
        revision: r.get(26)?,
        group_key: r.get(27)?,
        linked: r.get::<_, Option<i64>>(28)?.is_some(),
    })
}

/// Game data received from RomM, ready to be stored.
#[derive(Clone, Debug, Default)]
pub struct GameUpsert {
    pub rom_id: i64,
    pub platform_id: i64,
    pub platform_slug: String,
    pub platform_name: String,
    pub name: String,
    pub sort_key: String,
    pub fs_name: String,
    pub fs_size: i64,
    pub multi_file: bool,
    pub summary: Option<String>,
    pub year: Option<i64>,
    pub genres: Option<String>,
    pub regions: Option<String>,
    pub languages: Option<String>,
    pub revision: Option<String>,
    pub group_key: String,
    pub players: Option<String>,
    pub sha1: Option<String>,
    pub cover_remote: Option<String>,
    pub video_remote: Option<String>,
    pub updated_at: Option<String>,
    /// Metadata only the game page needs (JSON): studios, series, screenshots, release dates…
    pub extra: Option<String>,
}

impl Db {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.execute_batch(SCHEMA)?;
        migrate(&conn)?;
        conn.execute(
            "INSERT INTO settings(key, value) VALUES ('schema_version', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SCHEMA_VERSION.to_string()],
        )?;
        Ok(Self(Arc::new(Mutex::new(conn))))
    }

    #[cfg(test)]
    pub fn memory() -> Self {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        migrate(&conn).unwrap();
        Self(Arc::new(Mutex::new(conn)))
    }

    fn c(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    // ---------- settings ----------
    pub fn settings_with_prefix(&self, prefix: &str) -> Vec<(String, String)> {
        let c = self.c();
        let mut st = c.prepare("SELECT key, value FROM settings WHERE substr(key, 1, length(?1)) = ?1").unwrap();
        st.query_map([prefix], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().filter_map(Result::ok).collect()
    }
    pub fn setting(&self, key: &str) -> Option<String> {
        self.c()
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten()
    }
    pub fn set_setting(&self, key: &str, value: &str) {
        let _ = self.c().execute(
            "INSERT INTO settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        );
    }
    pub fn delete_setting(&self, key: &str) {
        let _ = self
            .c()
            .execute("DELETE FROM settings WHERE key = ?1", [key]);
    }

    pub fn log(&self, kind: &str, message: &str) {
        let _ = self.c().execute(
            "INSERT INTO oplog(ts, kind, message) VALUES (?1, ?2, ?3)",
            params![now(), kind, message],
        );
        crate::logfile::write(kind, message);
    }

    // ---------- profiles ----------
    pub fn profiles(&self) -> Vec<Profile> {
        let c = self.c();
        let mut st = c
            .prepare("SELECT id, name, romm_user, paired, device_id, last_used_at FROM profiles ORDER BY created_at")
            .unwrap();
        st.query_map([], |r| {
            Ok(Profile {
                id: r.get(0)?,
                name: r.get(1)?,
                romm_user: r.get(2)?,
                paired: r.get::<_, i64>(3)? != 0,
                device_id: r.get(4)?,
                last_used_at: r.get(5)?,
            })
        })
        .unwrap()
        .filter_map(Result::ok)
        .collect()
    }
    pub fn profile(&self, id: &str) -> Option<Profile> {
        self.profiles().into_iter().find(|p| p.id == id)
    }
    pub fn add_profile(&self, id: &str, name: &str) -> rusqlite::Result<()> {
        self.c().execute(
            "INSERT INTO profiles(id, name, created_at) VALUES (?1, ?2, ?3)",
            params![id, name, now()],
        )?;
        Ok(())
    }
    pub fn rename_profile(&self, id: &str, name: &str) -> bool {
        self.c()
            .execute(
                "UPDATE profiles SET name = ?2 WHERE id = ?1",
                params![id, name],
            )
            .unwrap_or(0)
            > 0
    }
    pub fn delete_profile(&self, id: &str) -> bool {
        self.c()
            .execute("DELETE FROM profiles WHERE id = ?1", [id])
            .unwrap_or(0)
            > 0
    }
    pub fn set_paired(&self, id: &str, user: &str, user_id: i64, device_id: &str) {
        let _ = self.c().execute(
            "UPDATE profiles SET paired = 1, romm_user = ?2, romm_user_id = ?3, device_id = ?4 WHERE id = ?1",
            params![id, user, user_id, device_id],
        );
    }
    pub fn set_unpaired(&self, id: &str) {
        let _ = self.c().execute(
            "UPDATE profiles SET paired = 0, device_id = NULL WHERE id = ?1",
            [id],
        );
    }
    pub fn touch_profile(&self, id: &str) {
        let _ = self.c().execute(
            "UPDATE profiles SET last_used_at = ?2 WHERE id = ?1",
            params![id, now()],
        );
    }

    // ---------- catalog ----------
    pub fn replace_platforms(&self, list: &[(i64, String, String, String, i64)]) {
        let mut c = self.c();
        let tx = c.transaction().unwrap();
        tx.execute("DELETE FROM platforms", []).unwrap();
        for (id, slug, fs_slug, name, count) in list {
            tx.execute(
                "INSERT INTO platforms(id, slug, fs_slug, name, rom_count) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, slug, fs_slug, name, count],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }

    pub fn platforms(&self) -> Vec<Platform> {
        let c = self.c();
        let mut st = c
            .prepare(
                "SELECT p.id, p.slug, p.name,
                    (SELECT COUNT(*) FROM games g WHERE g.platform_id = p.id),
                    (SELECT COUNT(*) FROM games g JOIN local_games l ON l.rom_id = g.rom_id WHERE g.platform_id = p.id AND l.status = 'ok')
                 FROM platforms p ORDER BY p.name",
            )
            .unwrap();
        st.query_map([], |r| {
            Ok(Platform {
                id: r.get(0)?,
                slug: r.get(1)?,
                name: r.get(2)?,
                rom_count: r.get(3)?,
                local_count: r.get(4)?,
            })
        })
        .unwrap()
        .filter_map(Result::ok)
        .filter(|p| p.rom_count > 0)
        .collect()
    }

    /// Stores a batch of games; returns the games whose cover must be (re)downloaded.
    pub fn upsert_games(&self, games: &[GameUpsert], sync_id: i64) -> Vec<(i64, String, String)> {
        let mut covers = vec![];
        let mut c = self.c();
        let tx = c.transaction().unwrap();
        for g in games {
            let old: Option<(Option<String>, Option<String>)> = tx
                .query_row(
                    "SELECT cover_stamp, cover_local FROM games WHERE rom_id = ?1",
                    [g.rom_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
                .unwrap();
            tx.execute(
                "INSERT INTO games(rom_id, platform_id, platform_slug, platform_name, name, sort_key, fs_name, fs_size, multi_file,
                    summary, year, genres, regions, players, sha1, cover_remote, video_remote, updated_at, seen_sync,
                    languages, revision, group_key, extra)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)
                 ON CONFLICT(rom_id) DO UPDATE SET platform_id = excluded.platform_id, platform_slug = excluded.platform_slug,
                    platform_name = excluded.platform_name, name = excluded.name, sort_key = excluded.sort_key,
                    fs_name = excluded.fs_name, fs_size = excluded.fs_size, multi_file = excluded.multi_file,
                    summary = excluded.summary, year = excluded.year, genres = excluded.genres, regions = excluded.regions,
                    players = excluded.players, sha1 = excluded.sha1, cover_remote = excluded.cover_remote,
                    video_remote = excluded.video_remote, updated_at = excluded.updated_at, seen_sync = excluded.seen_sync,
                    languages = excluded.languages, revision = excluded.revision, group_key = excluded.group_key,
                    extra = excluded.extra",
                params![
                    g.rom_id, g.platform_id, g.platform_slug, g.platform_name, g.name, g.sort_key, g.fs_name, g.fs_size,
                    g.multi_file as i64, g.summary, g.year, g.genres, g.regions, g.players, g.sha1, g.cover_remote,
                    g.video_remote, g.updated_at, sync_id, g.languages, g.revision, g.group_key, g.extra
                ],
            )
            .unwrap();
            if let Some(remote) = &g.cover_remote {
                // RomM's path contains a timestamp (?ts=…): it serves as a version marker.
                let stamp = remote.clone();
                let stale = match &old {
                    Some((Some(s), Some(local))) => s != &stamp || !Path::new(local).exists(),
                    _ => true,
                };
                if stale {
                    covers.push((g.rom_id, remote.clone(), stamp));
                }
            }
        }
        tx.commit().unwrap();
        covers
    }

    pub fn game_extra(&self, rom_id: i64) -> Option<String> {
        self.c()
            .query_row("SELECT extra FROM games WHERE rom_id = ?1", [rom_id], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten()
            .flatten()
    }

    /// Removes games that disappeared from RomM from the catalog (unless installed locally).
    pub fn prune_games(&self, sync_id: i64) -> usize {
        self.c()
            .execute(
                "DELETE FROM games WHERE seen_sync <> ?1 AND rom_id NOT IN (SELECT rom_id FROM local_games)
                    AND rom_id NOT IN (SELECT rom_id FROM linked_games)",
                [sync_id],
            )
            .unwrap_or(0)
    }

    /// Moves versions into another game group (see library::merge_groups).
    pub fn set_group_keys(&self, changes: &[(i64, String)]) {
        let mut c = self.c();
        let Ok(tx) = c.transaction() else { return };
        for (rom_id, key) in changes {
            let _ = tx.execute("UPDATE games SET group_key = ?2 WHERE rom_id = ?1", params![rom_id, key]);
        }
        let _ = tx.commit();
    }

    pub fn set_cover(&self, rom_id: i64, local: &str, stamp: &str) {
        let _ = self.c().execute(
            "UPDATE games SET cover_local = ?2, cover_stamp = ?3 WHERE rom_id = ?1",
            params![rom_id, local, stamp],
        );
    }

    pub fn games(
        &self,
        platform: Option<&str>,
        query: Option<&str>,
        local_only: bool,
    ) -> Vec<GameRow> {
        let mut sql = format!("{GAME_SELECT} WHERE 1 = 1");
        let mut args: Vec<String> = vec![];
        if let Some(p) = platform.filter(|p| !p.is_empty() && *p != "all") {
            args.push(p.to_string());
            sql += &format!(" AND g.platform_slug = ?{}", args.len());
        }
        if let Some(q) = query.filter(|q| !q.trim().is_empty()) {
            // Search text is literal: % and _ typed by the user are not wildcards.
            let escaped = q
                .trim()
                .to_lowercase()
                .replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_");
            args.push(format!("%{escaped}%"));
            sql += &format!(" AND lower(g.name) LIKE ?{} ESCAPE '\\'", args.len());
        }
        if local_only {
            sql += " AND (l.status = 'ok' OR g.rom_id IN (SELECT rom_id FROM linked_games))";
        }
        sql += " ORDER BY g.sort_key, g.rom_id";
        let c = self.c();
        let mut st = c.prepare(&sql).unwrap();
        st.query_map(rusqlite::params_from_iter(args.iter()), game_from_row)
            .unwrap()
            .filter_map(Result::ok)
            .collect()
    }

    pub fn game(&self, rom_id: i64) -> Option<GameRow> {
        let c = self.c();
        c.query_row(
            &format!("{GAME_SELECT} WHERE g.rom_id = ?1"),
            [rom_id],
            game_from_row,
        )
        .optional()
        .ok()
        .flatten()
    }

    // ---------- local games ----------
    pub fn set_local(&self, rom_id: i64, dir: &str, main_file: &str, size: i64) {
        let _ = self.c().execute(
            "INSERT INTO local_games(rom_id, dir, main_file, size, installed_at, status) VALUES (?1, ?2, ?3, ?4, ?5, 'ok')
             ON CONFLICT(rom_id) DO UPDATE SET dir = excluded.dir, main_file = excluded.main_file, size = excluded.size,
                installed_at = excluded.installed_at, status = 'ok'",
            params![rom_id, dir, main_file, size, now()],
        );
    }
    pub fn local_games(&self) -> Vec<(i64, String, String, String)> {
        let c = self.c();
        let mut st = c
            .prepare("SELECT rom_id, dir, main_file, status FROM local_games")
            .unwrap();
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .filter_map(Result::ok)
            .collect()
    }
    pub fn set_local_status(&self, rom_id: i64, status: &str) {
        let _ = self.c().execute(
            "UPDATE local_games SET status = ?2 WHERE rom_id = ?1",
            params![rom_id, status],
        );
    }
    pub fn remove_local(&self, rom_id: i64) -> Option<String> {
        let c = self.c();
        let dir: Option<String> = c
            .query_row(
                "SELECT dir FROM local_games WHERE rom_id = ?1",
                [rom_id],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten();
        let _ = c.execute("DELETE FROM local_games WHERE rom_id = ?1", [rom_id]);
        dir
    }

    pub fn group(&self, group_key: &str) -> Vec<GameRow> {
        let c = self.c();
        let mut st = c
            .prepare(&format!(
                "{GAME_SELECT} WHERE g.group_key = ?1 ORDER BY g.rom_id"
            ))
            .unwrap();
        st.query_map([group_key], game_from_row)
            .unwrap()
            .filter_map(Result::ok)
            .collect()
    }

    // ---------- game media (case scans, cartridge, logo) ----------
    pub fn media(&self, group_key: &str, kind: &str) -> Option<MediaRow> {
        self.c()
            .query_row(
                "SELECT kind, path, w, h, stamp FROM media WHERE group_key = ?1 AND kind = ?2",
                [group_key, kind],
                media_from_row,
            )
            .optional()
            .ok()
            .flatten()
    }
    pub fn media_of(&self, group_key: &str) -> Vec<MediaRow> {
        let c = self.c();
        let mut st = c
            .prepare("SELECT kind, path, w, h, stamp FROM media WHERE group_key = ?1")
            .unwrap();
        st.query_map([group_key], media_from_row)
            .unwrap()
            .filter_map(Result::ok)
            .collect()
    }
    pub fn set_media(&self, group_key: &str, kind: &str, path: &str, w: u32, h: u32, stamp: &str) {
        let _ = self.c().execute(
            "INSERT OR REPLACE INTO media (group_key, kind, path, w, h, stamp) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![group_key, kind, path, w, h, stamp],
        );
    }
    pub fn ss_record(&self, group_key: &str) -> Option<String> {
        self.c()
            .query_row("SELECT json FROM ss_records WHERE group_key = ?1", [group_key], |r| r.get(0))
            .optional()
            .ok()
            .flatten()
    }
    pub fn set_ss_record(&self, group_key: &str, json: &str) {
        let _ = self.c().execute(
            "INSERT OR REPLACE INTO ss_records (group_key, json) VALUES (?1, ?2)",
            rusqlite::params![group_key, json],
        );
    }
    pub fn ss_record_keys(&self) -> Vec<String> {
        let c = self.c();
        let mut st = c.prepare("SELECT group_key FROM ss_records").unwrap();
        st.query_map([], |r| r.get(0)).unwrap().filter_map(Result::ok).collect()
    }
    /// Forgets every media file (they are fetched again at the next sync).
    pub fn clear_media(&self) -> Vec<String> {
        let c = self.c();
        let paths: Vec<String> = c
            .prepare("SELECT path FROM media")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();
        let _ = c.execute("DELETE FROM media", []);
        paths
    }
    /// Games asked to ScreenScraper, and found there.
    pub fn ss_counts(&self) -> (i64, i64) {
        self.c()
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(stamp LIKE 'found|%'), 0) FROM media WHERE kind = 'ss'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap_or((0, 0))
    }
    pub fn group_keys(&self) -> Vec<String> {
        let c = self.c();
        let mut st = c.prepare("SELECT DISTINCT group_key FROM games").unwrap();
        st.query_map([], |r| r.get(0)).unwrap().filter_map(Result::ok).collect()
    }
    /// One row per game (group): its key, console slug and console name.
    pub fn groups_with_platform(&self) -> Vec<(String, String, String)> {
        let c = self.c();
        let mut st = c
            .prepare("SELECT group_key, MIN(platform_slug), MIN(platform_name) FROM games GROUP BY group_key")
            .unwrap();
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .filter_map(Result::ok)
            .collect()
    }

    // ---------- per-profile game preferences ----------
    /// All of a profile's choices: group_key -> (chosen version, emulator language).
    /// A session of a game ended: when, and how long.
    pub fn record_play(&self, profile: &str, group_key: &str, seconds: i64) {
        let _ = self.c().execute(
            "INSERT INTO play_stats(profile_id, group_key, last_played, seconds) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(profile_id, group_key) DO UPDATE SET last_played = ?3, seconds = seconds + ?4",
            params![profile, group_key, now(), seconds],
        );
    }

    pub fn set_favourite(&self, profile: &str, group_key: &str, on: bool) {
        let _ = self.c().execute(
            "INSERT INTO play_stats(profile_id, group_key, favourite) VALUES (?1, ?2, ?3)
             ON CONFLICT(profile_id, group_key) DO UPDATE SET favourite = ?3",
            params![profile, group_key, on as i64],
        );
    }

    /// group key → (last played, seconds played, favourite), for one profile.
    pub fn play_stats(&self, profile: &str) -> std::collections::HashMap<String, (Option<i64>, i64, bool)> {
        let c = self.c();
        let Ok(mut st) = c.prepare("SELECT group_key, last_played, seconds, favourite FROM play_stats WHERE profile_id = ?1") else {
            return Default::default();
        };
        st.query_map(params![profile], |r| Ok((r.get::<_, String>(0)?, (r.get(1)?, r.get(2)?, r.get::<_, i64>(3)? != 0))))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    pub fn game_prefs(
        &self,
        profile_id: &str,
    ) -> std::collections::HashMap<String, (Option<i64>, Option<String>)> {
        let c = self.c();
        let mut st = c
            .prepare("SELECT group_key, rom_id, emu_language FROM game_prefs WHERE profile_id = ?1")
            .unwrap();
        st.query_map([profile_id], |r| {
            Ok((r.get::<_, String>(0)?, (r.get(1)?, r.get(2)?)))
        })
        .unwrap()
        .filter_map(Result::ok)
        .collect()
    }
    pub fn set_game_pref(
        &self,
        profile_id: &str,
        group_key: &str,
        rom_id: Option<Option<i64>>,
        lang: Option<Option<&str>>,
    ) {
        let c = self.c();
        let _ = c.execute(
            "INSERT OR IGNORE INTO game_prefs(profile_id, group_key) VALUES (?1, ?2)",
            params![profile_id, group_key],
        );
        if let Some(rom_id) = rom_id {
            let _ = c.execute(
                "UPDATE game_prefs SET rom_id = ?3 WHERE profile_id = ?1 AND group_key = ?2",
                params![profile_id, group_key, rom_id],
            );
        }
        if let Some(lang) = lang {
            let _ = c.execute(
                "UPDATE game_prefs SET emu_language = ?3 WHERE profile_id = ?1 AND group_key = ?2",
                params![profile_id, group_key, lang],
            );
        }
    }

    // ---------- linked games (virtual mount) ----------
    pub fn link_game(&self, rom_id: i64, main_file: &str, files: &[(i64, String, String, i64)]) {
        let mut c = self.c();
        let tx = c.transaction().unwrap();
        tx.execute("DELETE FROM linked_files WHERE rom_id = ?1", [rom_id])
            .unwrap();
        for (file_id, rel, name, size) in files {
            tx.execute(
                "INSERT OR REPLACE INTO linked_files(file_id, rom_id, rel_path, file_name, size) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![file_id, rom_id, rel, name, size],
            )
            .unwrap();
        }
        tx.execute(
            "INSERT OR REPLACE INTO linked_games(rom_id, main_file, linked_at) VALUES (?1, ?2, ?3)",
            params![rom_id, main_file, now()],
        )
        .unwrap();
        tx.commit().unwrap();
    }
    pub fn unlink_game(&self, rom_id: i64) -> bool {
        let c = self.c();
        let _ = c.execute("DELETE FROM linked_files WHERE rom_id = ?1", [rom_id]);
        c.execute("DELETE FROM linked_games WHERE rom_id = ?1", [rom_id])
            .unwrap_or(0)
            > 0
    }
    /// Files of linked games: (file_id, rom_id, platform_slug, rel_path, file_name, size).
    pub fn linked_files(&self) -> Vec<LinkedFile> {
        let c = self.c();
        let mut st = c
            .prepare(
                "SELECT f.file_id, f.rom_id, COALESCE(g.platform_slug, 'unknown'), f.rel_path, f.file_name, f.size
                 FROM linked_files f LEFT JOIN games g ON g.rom_id = f.rom_id ORDER BY f.rom_id, f.rel_path",
            )
            .unwrap();
        st.query_map([], |r| {
            Ok(LinkedFile {
                file_id: r.get(0)?,
                rom_id: r.get(1)?,
                platform_slug: r.get(2)?,
                rel_path: r.get(3)?,
                file_name: r.get(4)?,
                size: r.get(5)?,
            })
        })
        .unwrap()
        .filter_map(Result::ok)
        .collect()
    }

    // ---------- downloads ----------
    pub fn enqueue_download(&self, rom_id: i64) -> Result<i64, String> {
        let c = self.c();
        let active: Option<i64> = c
            .query_row(
                "SELECT id FROM downloads WHERE rom_id = ?1 AND state IN ('queued','downloading','verifying','extracting')",
                [rom_id],
                |r| r.get(0),
            )
            .optional()
            .unwrap();
        if let Some(id) = active {
            return Ok(id);
        }
        c.execute(
            "INSERT INTO downloads(rom_id, state, created_at, updated_at) VALUES (?1, 'queued', ?2, ?2)",
            params![rom_id, now()],
        )
        .map_err(|e| e.to_string())?;
        Ok(c.last_insert_rowid())
    }
    pub fn next_queued_download(&self) -> Option<(i64, i64)> {
        self.c()
            .query_row(
                "SELECT id, rom_id FROM downloads WHERE state = 'queued' ORDER BY id LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .ok()
            .flatten()
    }
    pub fn update_download(
        &self,
        id: i64,
        state: &str,
        received: i64,
        total: i64,
        error: Option<&str>,
    ) {
        let _ = self.c().execute(
            "UPDATE downloads SET state = ?2, received = ?3, total = ?4, error = ?5, updated_at = ?6 WHERE id = ?1",
            params![id, state, received, total, error, now()],
        );
    }
    pub fn download_state(&self, id: i64) -> Option<String> {
        self.c()
            .query_row("SELECT state FROM downloads WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten()
    }
    /// At startup: downloads interrupted by a shutdown start again (resumed through Range).
    pub fn requeue_interrupted(&self) -> usize {
        self.c()
            .execute(
                "UPDATE downloads SET state = 'queued' WHERE state IN ('downloading','verifying','extracting')",
                [],
            )
            .unwrap_or(0)
    }
    pub fn downloads(&self) -> Vec<Download> {
        let c = self.c();
        let mut st = c
            .prepare(
                "SELECT d.id, d.rom_id, COALESCE(g.name, '?'), d.state, d.received, d.total, d.error
                 FROM downloads d LEFT JOIN games g ON g.rom_id = d.rom_id
                 WHERE d.state NOT IN ('done','cancelled') OR d.updated_at > ?1 ORDER BY d.id DESC LIMIT 50",
            )
            .unwrap();
        st.query_map([now() - 3600], |r| {
            Ok(Download {
                id: r.get(0)?,
                rom_id: r.get(1)?,
                name: r.get(2)?,
                state: r.get(3)?,
                received: r.get(4)?,
                total: r.get(5)?,
                error: r.get(6)?,
            })
        })
        .unwrap()
        .filter_map(Result::ok)
        .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(id: i64, name: &str) -> GameUpsert {
        GameUpsert {
            extra: None,
            rom_id: id,
            platform_id: 1,
            platform_slug: "nes".into(),
            platform_name: "NES".into(),
            name: name.into(),
            sort_key: name.to_lowercase(),
            fs_name: format!("{name}.nes"),
            fs_size: 10,
            cover_remote: Some(format!("/assets/{id}.png?ts=1")),
            ..Default::default()
        }
    }

    #[test]
    fn upsert_prune_and_local_state() {
        let db = Db::memory();
        let covers = db.upsert_games(&[sample(1, "Alpha"), sample(2, "Beta")], 1);
        assert_eq!(covers.len(), 2, "new covers to download");
        db.set_local(2, "/tmp/x", "/tmp/x/Beta.nes", 10);
        // New sync: Beta disappeared from RomM but is still installed, Alpha is still there.
        db.upsert_games(&[sample(1, "Alpha")], 2);
        assert_eq!(db.prune_games(2), 0);
        let all = db.games(None, None, false);
        assert_eq!(all.len(), 2);
        assert_eq!(db.game(2).unwrap().local_state, "local");
        assert_eq!(db.game(1).unwrap().local_state, "remote");
        assert_eq!(db.games(None, Some("alp"), false).len(), 1);
        assert_eq!(db.games(None, None, true).len(), 1);
    }

    #[test]
    fn download_queue_is_idempotent_and_resumable() {
        let db = Db::memory();
        db.upsert_games(&[sample(1, "Alpha")], 1);
        let a = db.enqueue_download(1).unwrap();
        let b = db.enqueue_download(1).unwrap();
        assert_eq!(a, b, "no duplicate for a game already queued");
        db.update_download(a, "downloading", 5, 10, None);
        assert_eq!(db.requeue_interrupted(), 1);
        assert_eq!(db.next_queued_download(), Some((a, 1)));
    }
}
