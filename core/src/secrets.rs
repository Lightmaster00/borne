//! RomM tokens.
//!
//! One file per profile in `secrets/` (directory 0700, files 0600), written atomically.
//! Tokens are never stored in SQLite, never logged, never returned by the local API.
//! (Planned: Secret Service vault when available; ChimeraOS in a gamescope session
//! usually has none, hence this default storage.)

use crate::paths::{set_mode, Paths};
use std::io::Write;

fn path(paths: &Paths, profile_id: &str) -> std::path::PathBuf {
    paths.secrets().join(format!("{profile_id}.token"))
}

pub fn store(paths: &Paths, profile_id: &str, token: &str) -> std::io::Result<()> {
    let final_path = path(paths, profile_id);
    let tmp = final_path.with_extension("tmp");
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode_0600()
            .open(&tmp)?;
        f.write_all(token.as_bytes())?;
        f.sync_all()?;
    }
    set_mode(&tmp, 0o600)?;
    std::fs::rename(tmp, final_path)
}

pub fn load(paths: &Paths, profile_id: &str) -> Option<String> {
    std::fs::read_to_string(path(paths, profile_id))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn delete(paths: &Paths, profile_id: &str) {
    let _ = std::fs::remove_file(path(paths, profile_id));
}

trait Mode0600 {
    fn mode_0600(&mut self) -> &mut Self;
}
impl Mode0600 for std::fs::OpenOptions {
    fn mode_0600(&mut self) -> &mut Self {
        use std::os::unix::fs::OpenOptionsExt;
        self.mode(0o600)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn token_roundtrip_with_strict_permissions() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths { root: dir.path().to_path_buf() };
        paths.ensure().unwrap();
        store(&paths, "p1", "rmm_secret").unwrap();
        assert_eq!(load(&paths, "p1").as_deref(), Some("rmm_secret"));
        let mode = std::fs::metadata(path(&paths, "p1")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let dmode = std::fs::metadata(paths.secrets()).unwrap().permissions().mode() & 0o777;
        assert_eq!(dmode, 0o700);
        delete(&paths, "p1");
        assert!(load(&paths, "p1").is_none());
    }
}
