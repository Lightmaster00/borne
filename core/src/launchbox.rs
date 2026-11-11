//! Case scans from the LaunchBox Games Database: free, no account. The core downloads its
//! public metadata (Metadata.zip, refreshed every 30 days), keeps the games of the consoles in
//! the library, matches them by console and title (or alternate title), and fetches their
//! "Box - Front", "Box - Spine", "Box - Back", "Cart - Front" / "Disc", "Clear Logo" and
//! "Fanart - Background" images, in the version's region first.
//!
//! Precedence: Borne's own ScreenScraper access, then LaunchBox, then RomM's copies.

use crate::state::Shared;
use quick_xml::events::Event;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

const METADATA_URL: &str = "https://gamesdb.launchbox-app.com/Metadata.zip";
const IMAGES_URL: &str = "https://images.launchbox-app.com";
const REFRESH_DAYS: u64 = 30;

static RUNNING: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<Option<Value>> = Mutex::new(None);

fn set_status(app: &Shared, v: Value) {
    *STATUS.lock().unwrap() = Some(v.clone());
    app.emit(json!({ "type": "launchbox", "launchbox": v }));
}

pub fn enabled(app: &Shared) -> bool {
    app.db.setting("launchbox").as_deref() != Some("off")
}

pub fn status(app: &Shared) -> Value {
    let (games, found) = app.db.lb_counts();
    json!({
        "enabled": enabled(app),
        "state": STATUS.lock().unwrap().clone().unwrap_or(json!({ "running": false })),
        "indexed": app.db.lb_indexed(),
        "games": games,
        "found": found,
    })
}

fn base() -> (String, String) {
    // BORNE_LAUNCHBOX_BASE points tests at a local stand-in (<base>/Metadata.zip, <base>/images/…).
    match std::env::var("BORNE_LAUNCHBOX_BASE") {
        Ok(b) => (format!("{b}/Metadata.zip"), format!("{b}/images")),
        Err(_) => (METADATA_URL.into(), IMAGES_URL.into()),
    }
}

fn agent(read_secs: u64) -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .tls_config(crate::romm::tls())
        .timeout_connect(Some(Duration::from_secs(15)))
        .timeout_recv_body(Some(Duration::from_secs(read_secs)))
        .user_agent(format!("Borne/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .into()
}

/// Lowercase, without bracketed tags, punctuation, accents and a leading article.
pub fn norm(title: &str) -> String {
    let mut s = String::new();
    let mut depth = 0;
    for c in title.chars() {
        match c {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = (depth - 1i32).max(0),
            _ if depth == 0 => s.push(c),
            _ => {}
        }
    }
    let folded: String = s
        .to_lowercase()
        .chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ä' | 'ã' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'í' | 'ì' | 'î' | 'ï' => 'i',
            'ó' | 'ò' | 'ô' | 'ö' | 'õ' => 'o',
            'ú' | 'ù' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            '&' => ' ',
            c => c,
        })
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect();
    let words: Vec<&str> = folded.split_whitespace().filter(|w| *w != "and").collect();
    let words = if words.first() == Some(&"the") { &words[1..] } else { &words[..] };
    words.join(" ")
}

fn metadata_path(app: &Shared) -> PathBuf {
    app.paths.art().join("launchbox-metadata.zip")
}

fn download_metadata(app: &Shared) -> Result<PathBuf, String> {
    let path = metadata_path(app);
    let fresh = std::fs::metadata(&path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .map(|age| age < Duration::from_secs(REFRESH_DAYS * 86400))
        .unwrap_or(false);
    if fresh && app.db.lb_indexed() {
        return Ok(path);
    }
    set_status(app, json!({ "running": true, "step": "download" }));
    let mut resp = agent(600).get(base().0).call().map_err(|e| format!("LaunchBox unreachable ({e})"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("LaunchBox answered {}", resp.status().as_u16()));
    }
    std::fs::create_dir_all(app.paths.art()).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("part");
    let mut reader = resp.body_mut().with_config().limit(2 << 30).reader();
    let mut out = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    std::io::copy(&mut reader, &mut out).map_err(|e| format!("download interrupted ({e})"))?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(path)
}

pub struct Index {
    pub games: Vec<(i64, String, String)>,      // id, platform, normalized title
    pub names: Vec<(i64, String)>,              // id, normalized alternate title
    pub images: Vec<(i64, String, String, String)>, // id, type, region, file
}

const IMAGE_TYPES: [&str; 9] = [
    "Box - Front", "Box - Front - Reconstructed", "Box - Spine", "Box - Back", "Box - Back - Reconstructed",
    "Cart - Front", "Disc", "Clear Logo", "Fanart - Background",
];

/// Reads Metadata.xml, keeping only the given consoles.
pub fn parse(xml: impl BufRead, platforms: &HashSet<String>) -> Result<Index, String> {
    let mut r = quick_xml::Reader::from_reader(xml);
    r.config_mut().trim_text(true);
    let mut buf = vec![];
    let mut idx = Index { games: vec![], names: vec![], images: vec![] };
    let mut kept: HashSet<i64> = HashSet::new();
    let mut elem = String::new();
    let mut field = String::new();
    let mut f: HashMap<String, String> = HashMap::new();
    loop {
        match r.read_event_into(&mut buf).map_err(|e| format!("unreadable LaunchBox data ({e})"))? {
            Event::Start(e) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                if matches!(name.as_str(), "Game" | "GameAlternateName" | "GameImage") {
                    elem = name;
                    f.clear();
                } else if !elem.is_empty() {
                    field = name;
                }
            }
            Event::Text(t) if !elem.is_empty() && !field.is_empty() => {
                let v = t.unescape().map(|c| c.into_owned()).unwrap_or_default();
                f.entry(field.clone()).or_default().push_str(&v);
            }
            Event::End(e) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                if name == elem {
                    let id = f.get("DatabaseID").and_then(|s| s.trim().parse::<i64>().ok());
                    match (elem.as_str(), id) {
                        ("Game", Some(id)) => {
                            let p = f.get("Platform").cloned().unwrap_or_default();
                            if platforms.contains(&p) {
                                kept.insert(id);
                                idx.games.push((id, p, norm(f.get("Name").map(String::as_str).unwrap_or(""))));
                            }
                        }
                        ("GameAlternateName", Some(id)) if kept.contains(&id) => {
                            idx.names.push((id, norm(f.get("AlternateName").map(String::as_str).unwrap_or(""))));
                        }
                        ("GameImage", Some(id)) if kept.contains(&id) => {
                            let t = f.get("Type").cloned().unwrap_or_default();
                            if IMAGE_TYPES.contains(&t.as_str()) {
                                if let Some(file) = f.get("FileName").filter(|s| !s.contains("..") && !s.starts_with('/')) {
                                    idx.images.push((id, t, f.get("Region").cloned().unwrap_or_default(), file.clone()));
                                }
                            }
                        }
                        _ => {}
                    }
                    elem.clear();
                } else {
                    field.clear();
                }
            }
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }
    Ok(idx)
}

fn import(app: &Shared, zip_path: &Path) -> Result<(), String> {
    set_status(app, json!({ "running": true, "step": "index" }));
    let platforms: HashSet<String> = app
        .db
        .groups_with_platform()
        .into_iter()
        .filter_map(|(_, slug, _)| crate::launchbox_platforms::name(&slug).map(String::from))
        .collect();
    let file = std::fs::File::open(zip_path).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("damaged LaunchBox archive ({e})"))?;
    let entry = zip.by_name("Metadata.xml").map_err(|_| "Metadata.xml missing from the LaunchBox archive")?;
    let idx = parse(std::io::BufReader::with_capacity(1 << 20, entry), &platforms)?;
    app.db.lb_replace(&idx);
    app.db.log("launchbox", &format!("{} games indexed for {} console(s)", idx.games.len(), platforms.len()));
    Ok(())
}

/// LaunchBox region names for a version's regions, then the generic ones.
fn regions(version_regions: &str) -> Vec<&'static str> {
    let mut out: Vec<&'static str> = vec![];
    for r in version_regions.split(',').map(str::trim) {
        let names: &[&'static str] = match r {
            "Europe" => &["Europe"],
            "USA" | "Canada" => &["North America", "United States"],
            "Japan" => &["Japan"],
            "World" => &["World"],
            "France" => &["France", "Europe"],
            "Germany" => &["Germany", "Europe"],
            "Spain" => &["Spain", "Europe"],
            "Italy" => &["Italy", "Europe"],
            "UK" => &["United Kingdom", "Europe"],
            "Australia" => &["Australia", "Europe"],
            "Brazil" => &["Brazil"],
            "Korea" => &["Korea"],
            "China" => &["China"],
            _ => &[],
        };
        for n in names {
            if !out.contains(n) {
                out.push(n);
            }
        }
    }
    for n in ["", "World", "North America", "Europe", "United States", "Japan"] {
        if !out.contains(&n) {
            out.push(n);
        }
    }
    out
}

fn pick(images: &[(String, String, String)], types: &[&str], regions: &[&str]) -> Option<String> {
    for t in types {
        for r in regions {
            if let Some((_, _, file)) = images.iter().find(|(ty, re, _)| ty == t && re == r) {
                return Some(file.clone());
            }
        }
        if let Some((_, _, file)) = images.iter().find(|(ty, _, _)| ty == t) {
            return Some(file.clone());
        }
    }
    None
}

fn fetch_group(app: &Shared, key: &str) -> Result<bool, String> {
    let versions = app.db.group(key);
    let Some(first) = versions.first() else { return Ok(false) };
    let Some(platform) = crate::launchbox_platforms::name(&first.platform_slug) else { return Ok(false) };
    let titles: Vec<String> = versions.iter().flat_map(|g| [norm(&g.name), norm(&g.fs_name)]).collect();
    let Some(id) = titles.iter().find_map(|t| app.db.lb_find(platform, t)) else { return Ok(false) };
    let images = app.db.lb_images(id);
    let region_list = regions(versions.iter().filter_map(|g| g.regions.clone()).collect::<Vec<_>>().join(",").as_str());
    let wanted: [(&str, &[&str]); 6] = [
        ("front", &["Box - Front", "Box - Front - Reconstructed"]),
        ("side", &["Box - Spine"]),
        ("back", &["Box - Back", "Box - Back - Reconstructed"]),
        ("physical", &["Cart - Front", "Disc"]),
        ("logo", &["Clear Logo"]),
        ("fanart", &["Fanart - Background"]),
    ];
    let images_url = base().1;
    for (kind, types) in wanted {
        let Some(file) = pick(&images, types, &region_list) else { continue };
        let stamp = format!("lb|{file}");
        if let Some(m) = app.db.media(key, kind) {
            let ours = m.stamp == stamp || m.stamp.starts_with("ss|");
            if ours && Path::new(&m.path).is_file() {
                continue;
            }
        }
        let url = format!("{images_url}/{}", file.replace(' ', "%20"));
        let bytes = (|| -> Result<Vec<u8>, String> {
            let mut resp = agent(60).get(&url).call().map_err(|e| e.to_string())?;
            if resp.status().as_u16() != 200 {
                return Err(format!("image answered {}", resp.status().as_u16()));
            }
            resp.body_mut().with_config().limit(30 << 20).read_to_vec().map_err(|e| e.to_string())
        })();
        match bytes.and_then(|b| crate::media::store(app, key, kind, &b)) {
            Ok((path, w, h)) => app.db.set_media(key, kind, &path.to_string_lossy(), w, h, &stamp),
            Err(e) => app.db.log("launchbox", &format!("{kind} of {key}: {e}")),
        }
    }
    Ok(true)
}

/// Indexes LaunchBox's metadata if needed, then fetches the media of games not looked up yet
/// (all of them with `again`). Background thread.
pub fn start(app: &Shared, again: bool) {
    if !enabled(app) || RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::Builder::new()
        .name("borne-launchbox".into())
        .spawn(move || {
            let r = (|| -> Result<(usize, usize), String> {
                let zip = download_metadata(&app)?;
                if !app.db.lb_indexed() || again {
                    import(&app, &zip)?;
                }
                let keys: Vec<String> = app
                    .db
                    .group_keys()
                    .into_iter()
                    .filter(|k| again || app.db.media(k, "lb").is_none())
                    .collect();
                let (mut done, mut found) = (0, 0);
                for key in &keys {
                    let hit = fetch_group(&app, key)?;
                    app.db.set_media(key, "lb", "", 0, 0, if hit { "found" } else { "not found" });
                    done += 1;
                    found += hit as usize;
                    set_status(&app, json!({ "running": true, "step": "images", "done": done, "total": keys.len(), "found": found }));
                    if done % 20 == 0 {
                        app.emit(json!({ "type": "library" }));
                    }
                }
                Ok((done, found))
            })();
            match r {
                Ok((done, found)) => {
                    app.db.log("launchbox", &format!("{found} of {done} game(s) found"));
                    set_status(&app, json!({ "running": false }));
                }
                Err(e) => {
                    app.db.log("launchbox", &e);
                    set_status(&app, json!({ "running": false, "error": e }));
                }
            }
            app.emit(json!({ "type": "library" }));
            RUNNING.store(false, Ordering::SeqCst);
        })
        .expect("launchbox thread");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_match_loosely() {
        assert_eq!(norm("The Legend of Zelda: Ocarina of Time (USA) (Rev 1)"), "legend of zelda ocarina of time");
        assert_eq!(norm("Pokémon - Version Rouge"), "pokemon version rouge");
        assert_eq!(norm("Mario & Luigi"), norm("Mario and Luigi"));
    }

    #[test]
    fn parses_launchbox_metadata() {
        let xml = r#"<?xml version="1.0"?><LaunchBox>
          <Game><Name>Paper Mario</Name><DatabaseID>141</DatabaseID><Platform>Nintendo 64</Platform></Game>
          <Game><Name>Other</Name><DatabaseID>9</DatabaseID><Platform>Sega Saturn</Platform></Game>
          <GameAlternateName><AlternateName>Mario Story</AlternateName><DatabaseID>141</DatabaseID></GameAlternateName>
          <GameImage><DatabaseID>141</DatabaseID><FileName>a.png</FileName><Type>Box - Spine</Type><Region>Europe</Region></GameImage>
          <GameImage><DatabaseID>141</DatabaseID><FileName>b.png</FileName><Type>Banner</Type></GameImage>
          <GameImage><DatabaseID>9</DatabaseID><FileName>c.png</FileName><Type>Box - Front</Type></GameImage>
        </LaunchBox>"#;
        let p: HashSet<String> = ["Nintendo 64".to_string()].into();
        let idx = parse(xml.as_bytes(), &p).unwrap();
        assert_eq!(idx.games, vec![(141, "Nintendo 64".into(), "paper mario".into())]);
        assert_eq!(idx.names, vec![(141, "mario story".into())]);
        assert_eq!(idx.images, vec![(141, "Box - Spine".into(), "Europe".into(), "a.png".into())]);
    }

    #[test]
    fn picks_the_version_region() {
        let imgs = vec![
            ("Box - Front".to_string(), "North America".to_string(), "us.jpg".to_string()),
            ("Box - Front".to_string(), "Europe".to_string(), "eu.jpg".to_string()),
        ];
        assert_eq!(pick(&imgs, &["Box - Front"], &regions("France")), Some("eu.jpg".into()));
        assert_eq!(pick(&imgs, &["Box - Front"], &regions("USA")), Some("us.jpg".into()));
    }
}
