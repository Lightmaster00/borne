//! Library view: versions of the same game (regions, languages, revisions) grouped into one entry.
//!
//! Group key: the platform plus the first metadata id RomM matched (IGDB, MobyGames, ScreenScraper…),
//! the same identity RomM uses for its "sibling" ROMs. Unmatched ROMs fall back to their file name
//! without tags ("Zelda (Europe) (Fr,De).sfc" -> "zelda").
//!
//! The version shown for a group is, in order: the one the profile chose, an installed or linked
//! one, then the best match for the UI language (languages, then regions), then the latest revision.

use crate::db::GameRow;
use serde_json::{json, Value};
use std::collections::HashMap;

const IDENTITY_FIELDS: [&str; 6] = ["igdb_id", "moby_id", "ss_id", "launchbox_id", "ra_id", "hasheous_id"];

/// Normalized title: lowercase letters and digits, single spaces.
pub fn normalize_title(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars().flat_map(char::to_lowercase) {
        if c.is_alphanumeric() {
            out.push(c);
        } else if !out.ends_with(' ') && !out.is_empty() {
            out.push(' ');
        }
    }
    out.trim_end().to_string()
}

pub fn group_key(v: &Value) -> String {
    let platform = v["platform_slug"].as_str().unwrap_or("");
    for field in IDENTITY_FIELDS {
        if let Some(id) = v[field].as_i64() {
            return format!("{platform}:{field}:{id}");
        }
    }
    let title = v["fs_name_no_tags"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| v["name"].as_str())
        .or_else(|| v["fs_name"].as_str())
        .unwrap_or("");
    format!("{platform}:name:{}", normalize_title(title))
}

/// RomM language names for a UI language code, and the regions that usually carry it.
fn language_hints(lang: &str) -> (&'static str, &'static [&'static str]) {
    match lang {
        "fr" => ("French", &["France", "Europe", "Canada", "World"]),
        "de" => ("German", &["Germany", "Europe", "World"]),
        "es" => ("Spanish", &["Spain", "Europe", "Latin America", "World"]),
        "it" => ("Italian", &["Italy", "Europe", "World"]),
        "ja" => ("Japanese", &["Japan", "World"]),
        "pt" => ("Portuguese", &["Brazil", "Portugal", "Europe", "World"]),
        "nl" => ("Dutch", &["Netherlands", "Europe", "World"]),
        _ => ("English", &["USA", "World", "Europe", "UK", "Australia"]),
    }
}

fn split(s: &Option<String>) -> Vec<String> {
    s.as_deref().unwrap_or("").split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect()
}

/// Language implied by a region when RomM lists no language for a version.
fn region_language(region: &str) -> Option<&'static str> {
    Some(match region {
        "USA" | "UK" | "Australia" | "World" | "Canada" => "English",
        "France" => "French",
        "Germany" => "German",
        "Spain" | "Latin America" => "Spanish",
        "Italy" => "Italian",
        "Japan" => "Japanese",
        "Brazil" | "Portugal" => "Portuguese",
        "Netherlands" => "Dutch",
        _ => return None,
    })
}

/// Languages of a version: listed by RomM, otherwise implied by its regions.
pub fn languages_of(g: &GameRow) -> Vec<String> {
    let listed = split(&g.languages);
    if !listed.is_empty() {
        return listed;
    }
    let mut out: Vec<String> = vec![];
    for r in split(&g.regions) {
        if let Some(l) = region_language(&r) {
            if !out.iter().any(|x| x == l) {
                out.push(l.to_string());
            }
        }
    }
    out
}

/// Higher is better.
fn score(g: &GameRow, lang: &str) -> i64 {
    let (language, regions) = language_hints(lang);
    let mut s = 0;
    if g.local_state == "local" || g.linked {
        s += 1000;
    }
    if languages_of(g).iter().any(|l| l == language) {
        s += 100;
    }
    let game_regions = split(&g.regions);
    if let Some(i) = regions.iter().position(|r| game_regions.iter().any(|g| g == r)) {
        s += 60 - 10 * i as i64;
    }
    s + g.revision.as_deref().and_then(|r| r.trim().parse::<i64>().ok()).unwrap_or(0).min(9)
}

/// Picks the version shown for a group.
pub fn pick<'a>(versions: &'a [GameRow], chosen: Option<i64>, lang: &str) -> &'a GameRow {
    if let Some(v) = chosen.and_then(|id| versions.iter().find(|g| g.rom_id == id)) {
        return v;
    }
    versions
        .iter()
        .max_by_key(|g| (score(g, lang), -g.rom_id))
        .expect("a group has at least one version")
}

/// One entry per group, in catalog order. `prefs`: group_key -> chosen rom_id.
pub fn groups(rows: Vec<GameRow>, prefs: &HashMap<String, (Option<i64>, Option<String>)>, lang: &str) -> Vec<Value> {
    let mut order: Vec<String> = vec![];
    let mut by_key: HashMap<String, Vec<GameRow>> = HashMap::new();
    for g in rows {
        let key = if g.group_key.is_empty() { format!("rom:{}", g.rom_id) } else { g.group_key.clone() };
        if !by_key.contains_key(&key) {
            order.push(key.clone());
        }
        by_key.entry(key).or_default().push(g);
    }
    order
        .into_iter()
        .map(|key| {
            let versions = &by_key[&key];
            let chosen = prefs.get(&key).and_then(|p| p.0);
            let shown = pick(versions, chosen, lang);
            entry(shown, versions)
        })
        .collect()
}

/// The shown version, plus what the library needs to know about the others.
pub fn entry(shown: &GameRow, versions: &[GameRow]) -> Value {
    let mut v = version_json(shown);
    v["version_count"] = json!(versions.len());
    fill_media(&mut v, versions);
    v["other_installed"] =
        json!(versions.iter().any(|g| g.rom_id != shown.rom_id && (g.local_state == "local" || g.linked)));
    v
}

/// A version for the UI: the stored row plus its languages (listed or implied by its regions).
pub fn version_json(g: &GameRow) -> Value {
    let mut v = json!(g);
    v["langs"] = json!(languages_of(g));
    v
}

/// A version without its own cover or trailer borrows another version's (same game).
pub fn fill_media(v: &mut Value, versions: &[GameRow]) {
    if v["cover_local"].is_null() {
        if let Some(c) = versions.iter().find_map(|g| g.cover_local.clone()) {
            v["cover_local"] = json!(c);
        }
    }
    if v["video_remote"].is_null() {
        if let Some(c) = versions.iter().find_map(|g| g.video_remote.clone()) {
            v["video_remote"] = json!(c);
        }
    }
}

/// Emulator languages offered on the game page ("auto" follows the UI language).
pub const EMU_LANGUAGES: [&str; 9] = ["auto", "en", "fr", "de", "es", "it", "nl", "pt", "ja"];

#[cfg(test)]
mod tests {
    use super::*;

    fn rom(id: i64, regions: &str, languages: &str, rev: &str) -> GameRow {
        GameRow {
            rom_id: id,
            group_key: "nes:name:crystal knights".into(),
            regions: Some(regions.into()),
            languages: (!languages.is_empty()).then(|| languages.into()),
            revision: (!rev.is_empty()).then(|| rev.into()),
            local_state: "remote".into(),
            ..Default::default()
        }
    }

    #[test]
    fn keys() {
        let a = json!({"platform_slug": "nes", "fs_name_no_tags": "Crystal Knights", "igdb_id": null});
        let b = json!({"platform_slug": "nes", "fs_name_no_tags": "Crystal  Knights!", "name": "x"});
        assert_eq!(group_key(&a), group_key(&b));
        assert_eq!(group_key(&a), "nes:name:crystal knights");
        let c = json!({"platform_slug": "nes", "igdb_id": 42, "fs_name_no_tags": "Other"});
        assert_eq!(group_key(&c), "nes:igdb_id:42");
    }

    #[test]
    fn picks_by_language_then_choice_then_install() {
        let mut v = vec![rom(1, "USA", "", ""), rom(2, "Europe", "English, French, German", ""), rom(3, "Japan", "", "1")];
        assert_eq!(pick(&v, None, "fr").rom_id, 2);
        assert_eq!(pick(&v, None, "en").rom_id, 1);
        assert_eq!(pick(&v, None, "ja").rom_id, 3);
        assert_eq!(pick(&v, Some(3), "fr").rom_id, 3, "the profile's choice wins");
        v[0].local_state = "local".into();
        assert_eq!(pick(&v, None, "fr").rom_id, 1, "an installed version comes first");
        let g = groups(v, &HashMap::new(), "fr");
        assert_eq!(g.len(), 1);
        assert_eq!(g[0]["version_count"], 3);
    }
}
