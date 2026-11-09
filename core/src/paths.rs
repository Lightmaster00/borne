//! Data locations (XDG).
//!
//!   ~/.local/share/borne/
//!     state.db          local database (catalog, profiles, downloads)
//!     library/<platform>/<rom_id>/   downloaded games (shared between profiles)
//!     media/covers/     cached covers
//!     secrets/          RomM tokens (0600), never in the database
//!     profiles/<id>/    per-profile saves and states (stage 2)
//!     themes/           user themes
//!     mount/            Borne virtual mount: linked games read from RomM on demand (Linux)
//!     cache/stream/     blocks of linked games already read (bounded)
//!
//! BORNE_DATA_DIR overrides the root (tests, portable installs).

use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn from_env() -> Self {
        let root = std::env::var_os("BORNE_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("borne"));
        Self { root }
    }

    pub fn db(&self) -> PathBuf {
        self.root.join("state.db")
    }
    pub fn library(&self) -> PathBuf {
        self.root.join("library")
    }
    pub fn covers(&self) -> PathBuf {
        self.root.join("media").join("covers")
    }
    pub fn secrets(&self) -> PathBuf {
        self.root.join("secrets")
    }
    pub fn profiles(&self) -> PathBuf {
        self.root.join("profiles")
    }
    pub fn themes(&self) -> PathBuf {
        self.root.join("themes")
    }
    /// Borne virtual mount: linked games, read from RomM on demand.
    pub fn mount(&self) -> PathBuf {
        self.root.join("mount")
    }
    /// Blocks of linked games already read (bounded cache).
    pub fn stream_cache(&self) -> PathBuf {
        self.root.join("cache").join("stream")
    }
    pub fn reports(&self) -> PathBuf {
        self.root.join("reports")
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        for d in [self.root.clone(), self.library(), self.covers(), self.profiles(), self.themes(), self.reports(), self.stream_cache()] {
            std::fs::create_dir_all(d)?;
        }
        std::fs::create_dir_all(self.secrets())?;
        set_mode(&self.secrets(), 0o700)
    }
}

pub fn set_mode(path: &std::path::Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

/// Free space (bytes) on the filesystem containing `path`.
pub fn free_space(path: &std::path::Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid C string and `st` a correctly sized struct.
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    #[allow(clippy::unnecessary_cast)] // types differ between Linux and macOS
    let free = st.f_bavail as u64 * st.f_frsize as u64;
    (rc == 0).then_some(free)
}

/// Stable machine identifier (for the RomM device identifier).
/// Linux: machine-id. Elsewhere (macOS): a random identifier created once and kept
/// in the data directory.
pub fn machine_id(paths: &Paths) -> String {
    for p in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
        if let Ok(s) = std::fs::read_to_string(p) {
            let s = s.trim();
            if !s.is_empty() {
                return s.to_string();
            }
        }
    }
    let file = paths.root.join("device-id");
    if let Ok(s) = std::fs::read_to_string(&file) {
        if !s.trim().is_empty() {
            return s.trim().to_string();
        }
    }
    use rand::Rng;
    let mut rng = rand::rng();
    let id: String = (0..32).map(|_| format!("{:x}", rng.random_range(0..16u8))).collect();
    let _ = std::fs::write(&file, &id);
    id
}

/// Machine name (shown in RomM's device list).
pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: valid 256-byte buffer; gethostname writes a NUL-terminated string.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if rc == 0 {
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        let name = String::from_utf8_lossy(&buf[..end]).trim().trim_end_matches(".local").to_string();
        if !name.is_empty() {
            return name;
        }
    }
    "computer".into()
}
