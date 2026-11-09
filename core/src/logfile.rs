//! Persistent log: `<data>/logs/borne.log`, rotated to `borne.log.1` past 2 MB.
//!
//! Everything the core reports (sync, downloads, errors) lands here as well as on stderr,
//! so a user can export it from Settings › Help when something goes wrong.
//! Secrets never reach this file: callers log messages, never tokens or URLs carrying them.

use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

const MAX_BYTES: u64 = 2 * 1024 * 1024;

static LOG: Mutex<Option<PathBuf>> = Mutex::new(None);

pub fn init(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    *LOG.lock().unwrap() = Some(dir.join("borne.log"));
}

pub fn path() -> Option<PathBuf> {
    LOG.lock().unwrap().clone()
}

/// Writes one line to stderr and to the log file.
pub fn write(kind: &str, message: &str) {
    eprintln!("[borne] {kind}: {message}");
    let guard = LOG.lock().unwrap();
    let Some(path) = guard.as_ref() else { return };
    if std::fs::metadata(path)
        .map(|m| m.len() > MAX_BYTES)
        .unwrap_or(false)
    {
        let _ = std::fs::rename(path, path.with_extension("log.1"));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let ts = crate::db::now();
        // One line per entry, whatever the message contains.
        let clean: String = message
            .chars()
            .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
            .collect();
        let _ = writeln!(f, "{ts} {kind}: {clean}");
    }
}

/// Last `max` bytes of the current log (and of the rotated one if the current is short).
pub fn tail(max: usize) -> String {
    let Some(path) = path() else {
        return String::new();
    };
    let mut text = std::fs::read(path.with_extension("log.1")).unwrap_or_default();
    text.extend(std::fs::read(&path).unwrap_or_default());
    let start = text.len().saturating_sub(max);
    String::from_utf8_lossy(&text[start..]).into_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn writes_and_rotates() {
        let dir = tempfile::tempdir().unwrap();
        super::init(dir.path().to_path_buf());
        super::write("test", "first\nline");
        let t = super::tail(10_000);
        assert!(t.contains("test: first line"), "{t}");
        let big = "x".repeat(super::MAX_BYTES as usize + 10);
        super::write("test", &big);
        super::write("test", "after");
        assert!(dir.path().join("borne.log.1").exists());
        assert!(super::tail(100).contains("after"));
    }
}
