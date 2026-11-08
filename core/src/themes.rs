//! Themes: built-in (<package>/ui/themes, read-only) then user (<data>/themes).
//! Each theme: theme.json (manifest), Theme.qml (required), Card.qml… (optional).
//! The core lists themes and reads manifests; the UI validates and loads them in isolation.

use serde::Serialize;
use std::path::Path;

#[derive(Serialize)]
pub struct ThemeEntry {
    pub builtin: bool,
    pub dir: String,
    pub manifest: String,
    pub files: Vec<String>,
}

pub fn all_themes(builtin_dir: &Path, user_dir: &Path) -> Vec<ThemeEntry> {
    let mut out = scan(builtin_dir, true);
    out.extend(scan(user_dir, false));
    out
}

fn scan(root: &Path, builtin: bool) -> Vec<ThemeEntry> {
    let mut out = vec![];
    let Ok(rd) = std::fs::read_dir(root) else { return out };
    for e in rd.flatten() {
        let dir = e.path();
        let Ok(manifest) = std::fs::read_to_string(dir.join("theme.json")) else { continue };
        if manifest.len() > 64 * 1024 {
            continue;
        }
        let files = ["Theme.qml", "Card.qml", "Detail.qml", "Background.qml"]
            .iter()
            .filter(|f| dir.join(f).exists())
            .map(|f| f.to_string())
            .collect();
        out.push(ThemeEntry { builtin, dir: dir.to_string_lossy().into_owned(), manifest, files });
    }
    out.sort_by(|a, b| a.dir.cmp(&b.dir));
    out
}
