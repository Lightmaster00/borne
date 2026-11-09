//! Shared core state.

use crate::db::{Db, Profile};
use crate::events::Broadcaster;
use crate::pad::SharedPadState;
use crate::paths::Paths;
use crate::{romm, secrets};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};

#[derive(Serialize, Clone, Debug, Default)]
pub struct PairingState {
    pub profile_id: String,
    /// waiting | approved | denied | expired | error
    pub state: String,
    pub user_code: String,
    pub verification_url: String,
    pub expires_at: i64,
    pub error: Option<String>,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct SyncState {
    pub running: bool,
    pub done: usize,
    pub total: usize,
    pub covers_pending: usize,
    pub last_sync: Option<i64>,
    pub error: Option<String>,
}

pub struct App {
    pub paths: Paths,
    pub db: Db,
    pub hub: Broadcaster,
    pub pads: SharedPadState,
    pub resources: PathBuf,
    pub ui_themes: PathBuf,
    pub pairing: Mutex<Option<PairingState>>,
    /// Bumped on every new pairing: an older polling thread stops by itself.
    pub pairing_gen: AtomicU64,
    pub sync: Mutex<SyncState>,
    pub dl_cancel: Mutex<HashMap<i64, Arc<AtomicBool>>>,
    pub dl_wake: (Mutex<bool>, Condvar),
    pub online: AtomicBool,
    pub debug_input: bool,
}

pub type Shared = Arc<App>;

impl App {
    pub fn emit(&self, v: Value) {
        self.hub.send(v.to_string());
    }

    pub fn server_url(&self) -> Option<String> {
        self.db.setting("romm_url")
    }

    pub fn active_profile(&self) -> Option<Profile> {
        self.db
            .setting("active_profile")
            .and_then(|id| self.db.profile(&id))
    }

    /// RomM client authenticated with the active profile's token.
    pub fn client(&self) -> Option<romm::Client> {
        let url = self.server_url()?;
        let p = self.active_profile().filter(|p| p.paired)?;
        let token = secrets::load(&self.paths, &p.id)?;
        Some(romm::Client::new(&url, Some(token)))
    }

    pub fn anonymous_client(&self) -> Option<romm::Client> {
        self.server_url().map(|u| romm::Client::new(&u, None))
    }

    pub fn wake_downloads(&self) {
        let (lock, cv) = &self.dl_wake;
        *lock.lock().unwrap() = true;
        cv.notify_all();
    }

    pub fn set_online(&self, online: bool) {
        if self.online.swap(online, Ordering::SeqCst) != online {
            self.emit(serde_json::json!({ "type": "status", "online": online }));
        }
    }

    pub fn status(&self) -> Value {
        serde_json::json!({
            "server_url": self.server_url(),
            "online": self.online.load(Ordering::SeqCst),
            "active_profile": self.active_profile(),
            "profiles": self.db.profiles(),
            "pairing": *self.pairing.lock().unwrap(),
            "sync": *self.sync.lock().unwrap(),
            "free_space": crate::paths::free_space(&self.paths.root),
            "data_dir": self.paths.root,
        })
    }
}
