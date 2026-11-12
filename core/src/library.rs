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

const IDENTITY_FIELDS: [&str; 6] = [
    "igdb_id",
    "moby_id",
    "ss_id",
    "launchbox_id",
    "ra_id",
    "hasheous_id",
];

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

/// A file name's title without its tags and extension, normalized:
/// "Final Fantasy VII (Europe) (Disc 2).chd" -> "final fantasy vii".
pub fn title_key(fs_name: &str) -> String {
    let stem = match fs_name.rfind('.') {
        Some(i) if fs_name.len() - i <= 6 => &fs_name[..i],
        _ => fs_name,
    };
    let mut out = String::new();
    let mut depth = 0;
    for c in stem.chars() {
        match c {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = (depth - 1).max(0),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    normalize_title(&out)
}

/// One entry per game: versions RomM matched differently (one by IGDB, another by ScreenScraper,
/// another not at all), the discs of one game and versions ScreenScraper knows as the same game
/// end up in separate groups, and the game shows two or three times. Rows (rom id, platform,
/// group key, file name, ScreenScraper game id) are joined when they share a group key, a title
/// (on the same console) or a ScreenScraper id; each joined group takes the key most of its
/// versions had (an id rather than a title), so existing groups keep theirs. Returns the rows
/// whose key changes.
pub fn merge_groups(rows: &[(i64, String, String, String, Option<String>)]) -> Vec<(i64, String)> {
    let n = rows.len();
    let mut parent: Vec<usize> = (0..n).collect();
    fn find(p: &mut Vec<usize>, i: usize) -> usize {
        let mut r = i;
        while p[r] != r {
            r = p[r];
        }
        let mut j = i;
        while p[j] != r {
            let next = p[j];
            p[j] = r;
            j = next;
        }
        r
    }
    let mut first: HashMap<String, usize> = HashMap::new();
    for (i, (_, platform, key, fs_name, ss)) in rows.iter().enumerate() {
        let title = title_key(fs_name);
        let mut links = vec![format!("k|{key}")];
        if !title.is_empty() {
            links.push(format!("t|{platform}|{title}"));
        }
        if let Some(id) = ss {
            links.push(format!("s|{platform}|{id}"));
        }
        for l in links {
            match first.get(&l) {
                Some(&j) => {
                    let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                    if a != b {
                        parent[a] = b;
                    }
                }
                None => {
                    first.insert(l, i);
                }
            }
        }
    }
    let mut clusters: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..n {
        let r = find(&mut parent, i);
        clusters.entry(r).or_default().push(i);
    }
    let mut out = vec![];
    for members in clusters.values() {
        let mut count: HashMap<&str, usize> = HashMap::new();
        for &i in members {
            *count.entry(rows[i].2.as_str()).or_default() += 1;
        }
        if count.len() < 2 {
            continue;
        }
        let best = count
            .iter()
            .max_by(|a, b| {
                let id = |k: &str| !k.contains(":name:");
                (id(a.0), a.1, std::cmp::Reverse(*a.0)).cmp(&(id(b.0), b.1, std::cmp::Reverse(*b.0)))
            })
            .map(|(k, _)| k.to_string())
            .unwrap();
        for &i in members {
            if rows[i].2 != best {
                out.push((rows[i].0, best.clone()));
            }
        }
    }
    out
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
    s.as_deref()
        .unwrap_or("")
        .split(',')
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .collect()
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
    if let Some(i) = regions
        .iter()
        .position(|r| game_regions.iter().any(|g| g == r))
    {
        s += 60 - 10 * i as i64;
    }
    s + g
        .revision
        .as_deref()
        .and_then(|r| r.trim().parse::<i64>().ok())
        .unwrap_or(0)
        .min(9)
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
pub fn groups(
    rows: Vec<GameRow>,
    prefs: &HashMap<String, (Option<i64>, Option<String>)>,
    lang: &str,
) -> Vec<Value> {
    let mut order: Vec<String> = vec![];
    let mut by_key: HashMap<String, Vec<GameRow>> = HashMap::new();
    for g in rows {
        let key = if g.group_key.is_empty() {
            format!("rom:{}", g.rom_id)
        } else {
            g.group_key.clone()
        };
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

/// Sort key for a title: case and accents ignored, a leading article set aside
/// ("The Legend of Zelda" sorts under L, "La Légende de Zelda" too).
/// The shelf's order "by name": by the first three letters of the title (articles set aside), then
/// by release date, so a series stands in the order it came out ("Final Fantasy VII" before
/// "Final Fantasy IX"), then by the whole title. Games without a date come last in their run.
pub fn shelf_order(list: &mut [Value]) {
    list.sort_by_cached_key(|v| {
        let title = title_sort_key(v["name"].as_str().unwrap_or(""));
        let head: String = title.chars().filter(|c| c.is_alphanumeric()).take(3).collect();
        (head, v["year"].as_i64().unwrap_or(i64::MAX), title)
    });
}

pub fn title_sort_key(name: &str) -> String {
    let lower: String = name
        .to_lowercase()
        .chars()
        .map(|c| match c {
            'à' | 'â' | 'ä' | 'á' | 'ã' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'î' | 'ï' | 'í' => 'i',
            'ô' | 'ö' | 'ó' | 'õ' => 'o',
            'ù' | 'û' | 'ü' | 'ú' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            c => c,
        })
        .collect();
    for a in ["the ", "a ", "an ", "le ", "la ", "les ", "l'", "l’", "der ", "die ", "das ", "el ", "los ", "las ", "il ", "lo ", "gli "] {
        if let Some(rest) = lower.strip_prefix(a) {
            return rest.trim_start().to_string();
        }
    }
    lower
}

/// The shown version, plus what the library needs to know about the others.
pub fn entry(shown: &GameRow, versions: &[GameRow]) -> Value {
    let mut v = version_json(shown);
    v["version_count"] = json!(versions.len());
    fill_media(&mut v, versions);
    v["other_installed"] = json!(versions
        .iter()
        .any(|g| g.rom_id != shown.rom_id && (g.local_state == "local" || g.linked)));
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

/// Language codes accepted as a game's language ("auto" follows the UI language).
pub const EMU_LANGUAGES: [&str; 17] = [
    "auto", "en", "fr", "de", "es", "it", "nl", "pt", "ja", "sv", "da", "no", "fi", "pl", "ru", "ko", "zh",
];

const LANGUAGE_CODES: [(&str, &str); 16] = [
    ("English", "en"), ("French", "fr"), ("German", "de"), ("Spanish", "es"), ("Italian", "it"),
    ("Dutch", "nl"), ("Portuguese", "pt"), ("Japanese", "ja"), ("Swedish", "sv"), ("Danish", "da"),
    ("Norwegian", "no"), ("Finnish", "fi"), ("Polish", "pl"), ("Russian", "ru"), ("Korean", "ko"),
    ("Chinese", "zh"),
];

/// The languages the game really exists in (across its versions), each with the version that
/// is launched for it: the best one carrying that language (installed first, then the region
/// that usually carries it). In the order of LANGUAGE_CODES.
pub fn game_languages(versions: &[GameRow]) -> Vec<Value> {
    LANGUAGE_CODES
        .iter()
        .filter_map(|(name, code)| {
            versions
                .iter()
                .filter(|g| languages_of(g).iter().any(|l| l == name))
                // The region that natively speaks it first (English → USA, French → France or
                // Europe…), then installed, then the usual score.
                .max_by_key(|g| {
                    let regions = split(&g.regions);
                    let rank = language_hints(code).1.iter().position(|r| regions.iter().any(|x| x == r));
                    (rank.map(|i| 100 - i as i64).unwrap_or(0), score(g, code), -g.rom_id)
                })
                .map(|g| json!({ "code": code, "version": g.rom_id }))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn shelf_order_follows_three_letters_then_date() {
        let mut l = vec![
            serde_json::json!({"name": "Final Fantasy IX", "year": 2000}),
            serde_json::json!({"name": "The Legend of Zelda", "year": 1986}),
            serde_json::json!({"name": "Final Fantasy VII", "year": 1997}),
            serde_json::json!({"name": "Fighting Force", "year": 1997}),
            serde_json::json!({"name": "Final Fantasy Tactics"}),
        ];
        super::shelf_order(&mut l);
        let names: Vec<&str> = l.iter().map(|v| v["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["Fighting Force", "Final Fantasy VII", "Final Fantasy IX", "Final Fantasy Tactics", "The Legend of Zelda"]);
    }

    #[test]
    fn versions_left_apart_are_joined() {
        let r = |id: i64, key: &str, file: &str, ss: Option<&str>| (id, "psx".to_string(), key.to_string(), file.to_string(), ss.map(String::from));
        let rows = vec![
            // Discs and regions matched differently by RomM.
            r(1, "psx:igdb_id:427", "Final Fantasy VII (Europe) (Disc 1).chd", None),
            r(2, "psx:igdb_id:427", "Final Fantasy VII (Europe) (Disc 2).chd", None),
            r(3, "psx:name:final fantasy vii", "Final Fantasy VII (Europe) (Disc 3).chd", None),
            r(4, "psx:ss_id:5", "Final Fantasy VII (USA) (Disc 1).chd", None),
            // Another title, same ScreenScraper game.
            r(5, "psx:igdb_id:9", "Crash Bandicoot (Europe).chd", Some("77")),
            r(6, "psx:name:crash bandicoot japan", "Crash Bandicoot Japan.chd", Some("77")),
            // Another game stays apart.
            r(7, "psx:igdb_id:1", "Spyro the Dragon (Europe).chd", None),
        ];
        let mut changes = super::merge_groups(&rows);
        changes.sort();
        assert_eq!(changes, vec![(3, "psx:igdb_id:427".to_string()), (4, "psx:igdb_id:427".to_string()), (6, "psx:igdb_id:9".to_string())]);
        assert_eq!(super::title_key("Final Fantasy VII (Europe) (Disc 2).chd"), "final fantasy vii");
    }

    use super::*;

    #[test]
    fn titles_sort_without_articles_and_accents() {
        assert_eq!(title_sort_key("The Legend of Zelda"), "legend of zelda");
        assert_eq!(title_sort_key("La Légende de Zelda"), "legende de zelda");
        assert_eq!(title_sort_key("L'Odyssée"), "odyssee");
    }

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
        let a =
            json!({"platform_slug": "nes", "fs_name_no_tags": "Crystal Knights", "igdb_id": null});
        let b =
            json!({"platform_slug": "nes", "fs_name_no_tags": "Crystal  Knights!", "name": "x"});
        assert_eq!(group_key(&a), group_key(&b));
        assert_eq!(group_key(&a), "nes:name:crystal knights");
        let c = json!({"platform_slug": "nes", "igdb_id": 42, "fs_name_no_tags": "Other"});
        assert_eq!(group_key(&c), "nes:igdb_id:42");
    }

    #[test]
    fn languages_launch_their_version() {
        let mut eu = rom(2, "Europe", "English,French,German", "");
        eu.linked = true;
        let v = vec![rom(1, "USA", "", ""), eu, rom(3, "Japan", "", "")];
        let l = game_languages(&v);
        let get = |c: &str| l.iter().find(|x| x["code"] == c).map(|x| x["version"].as_i64().unwrap());
        assert_eq!((get("en"), get("fr"), get("de"), get("ja"), get("es")), (Some(1), Some(2), Some(2), Some(3), None));
    }

    #[test]
    fn picks_by_language_then_choice_then_install() {
        let mut v = vec![
            rom(1, "USA", "", ""),
            rom(2, "Europe", "English, French, German", ""),
            rom(3, "Japan", "", "1"),
        ];
        assert_eq!(pick(&v, None, "fr").rom_id, 2);
        assert_eq!(pick(&v, None, "en").rom_id, 1);
        assert_eq!(pick(&v, None, "ja").rom_id, 3);
        assert_eq!(
            pick(&v, Some(3), "fr").rom_id,
            3,
            "the profile's choice wins"
        );
        v[0].local_state = "local".into();
        assert_eq!(
            pick(&v, None, "fr").rom_id,
            1,
            "an installed version comes first"
        );
        let g = groups(v, &HashMap::new(), "fr");
        assert_eq!(g.len(), 1);
        assert_eq!(g[0]["version_count"], 3);
    }
}
