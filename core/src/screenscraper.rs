//! Borne's own ScreenScraper access (Settings → Game images), independent of RomM: with the
//! user's ScreenScraper account, the core asks ScreenScraper for every game and keeps its case
//! scans (front, spine, back), cartridge or disc, logo and fanart.
//!
//! ScreenScraper also requires the software's developer credentials. They are compiled into the
//! official builds from CI secrets (see build.rs): never in the repository, never readable in the
//! binary, never logged, never returned by the API. A build without them reports it plainly.
//!
//! Games are matched by ScreenScraper's game id when RomM has it, else by the file's hashes,
//! name and size. Titles and images follow the interface language (French → fr, then eu, wor…;
//! Japanese → jp…); the record is kept (without credentials) so a new language needs no new
//! lookup. A spine
//! missing on ScreenScraper is cut from the unfolded case texture ("box-texture": back, spine,
//! front) when there is one. What comes from ScreenScraper takes precedence over RomM's copies.
//!
//! One request at a time, within the account's daily quota; a game asked once is not asked
//! again until "Fetch again". Credentials live in a 0600 file and never reach the logs.

use crate::state::Shared;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

const API: &str = "https://api.screenscraper.fr/api2";
/// The API address; BORNE_SCREENSCRAPER_API points tests at a local stand-in.
fn api() -> String {
    std::env::var("BORNE_SCREENSCRAPER_API").unwrap_or_else(|_| API.to_string())
}
const SECRET_ID: &str = "screenscraper";

/// The user's ScreenScraper account (the developer credentials are Borne's, compiled in).
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Credentials {
    pub user: String,
    pub password: String,
}

mod dev {
    include!(concat!(env!("OUT_DIR"), "/ss_dev.rs"));
}
fn unmask((data, key): (&[u8], &[u8])) -> String {
    String::from_utf8(data.iter().zip(key).map(|(b, k)| b ^ k).collect()).unwrap_or_default()
}
/// Borne's developer credentials: compiled in, else (development builds) BORNE_SS_DEV_ID and
/// BORNE_SS_DEV_PASSWORD in the environment when the core starts.
fn developer() -> Option<(String, String)> {
    let (id, pw) = (unmask(dev::SS_DEV_ID), unmask(dev::SS_DEV_PASSWORD));
    if !id.is_empty() && !pw.is_empty() {
        return Some((id, pw));
    }
    match (std::env::var("BORNE_SS_DEV_ID"), std::env::var("BORNE_SS_DEV_PASSWORD")) {
        (Ok(i), Ok(p)) if !i.is_empty() && !p.is_empty() => Some((i, p)),
        _ => None,
    }
}
pub fn developer_access() -> bool {
    developer().is_some()
}

#[derive(Serialize, Clone, Default)]
pub struct Status {
    pub running: bool,
    pub paused: bool,
    pub threads: usize,
    pub max_threads: Option<i64>,
    pub done: usize,
    pub total: usize,
    pub found: usize,
    pub error: Option<String>,
    pub requests_today: Option<i64>,
    pub max_requests: Option<i64>,
}

static RUNNING: AtomicBool = AtomicBool::new(false);
static PAUSED: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);

/// Pauses or resumes the run under way (the game being asked finishes first).
pub fn pause(app: &Shared, paused: bool) {
    PAUSED.store(paused, Ordering::SeqCst);
    status_set(app, |s| s.paused = paused && s.running);
}

/// Stops the run under way; what was fetched stays, the rest is asked next time.
pub fn stop(app: &Shared) {
    if RUNNING.load(Ordering::SeqCst) {
        STOP.store(true, Ordering::SeqCst);
        PAUSED.store(false, Ordering::SeqCst);
        status_set(app, |s| s.paused = false);
    }
}
static STATUS: Mutex<Option<Status>> = Mutex::new(None);

fn status_get() -> Status {
    STATUS.lock().unwrap().clone().unwrap_or_default()
}
fn status_set(app: &Shared, f: impl FnOnce(&mut Status)) {
    let s = {
        let mut g = STATUS.lock().unwrap();
        let s = g.get_or_insert_with(Status::default);
        f(s);
        s.clone()
    };
    app.emit(json!({ "type": "screenscraper", "screenscraper": s }));
}

pub fn credentials(app: &Shared) -> Option<Credentials> {
    let raw = crate::secrets::load(&app.paths, SECRET_ID)?;
    serde_json::from_str(&raw).ok()
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .tls_config(crate::romm::tls())
        .timeout_connect(Some(Duration::from_secs(10)))
        .timeout_recv_response(Some(Duration::from_secs(40)))
        .user_agent(format!("Borne/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .into()
}

/// Removes credentials from a ScreenScraper URL (media URLs carry them) before it is stored or
/// logged.
fn redact(url: &str) -> String {
    let Some((base, q)) = url.split_once('?') else { return url.to_string() };
    let kept: Vec<&str> = q
        .split('&')
        .filter(|kv| !["devid=", "devpassword=", "ssid=", "sspassword=", "softname="].iter().any(|k| kv.starts_with(k)))
        .collect();
    format!("{base}?{}", kept.join("&"))
}

fn call(c: &Credentials, endpoint: &str, params: &[(&str, String)]) -> Result<Value, String> {
    let (dev_id, dev_password) = developer().ok_or("this build of Borne has no ScreenScraper developer access")?;
    let mut req = agent()
        .get(format!("{}/{endpoint}", api()))
        .query("devid", &dev_id)
        .query("devpassword", &dev_password)
        .query("softname", "borne")
        .query("output", "json")
        .query("ssid", &c.user)
        .query("sspassword", &c.password);
    for (k, v) in params {
        req = req.query(*k, v);
    }
    // The error text is not kept: it could carry the request URL, credentials included.
    let mut resp = req.call().map_err(|_| "ScreenScraper unreachable (network)".to_string())?;
    let code = resp.status().as_u16();
    let body = resp.body_mut().with_config().limit(8 << 20).read_to_string().unwrap_or_default();
    match code {
        200 => serde_json::from_str(&body).map_err(|_| {
            let t: String = body.split_whitespace().collect::<Vec<_>>().join(" ");
            format!("unexpected answer: {}", t.chars().take(120).collect::<String>())
        }),
        404 => Err("not found".into()),
        400 => Err("request refused (400)".into()),
        401 => Err("ScreenScraper is closed to non-members for now (server saturated)".into()),
        403 => Err("credentials refused: check the account and the developer id".into()),
        423 => Err("ScreenScraper's API is closed for now".into()),
        426 => Err("this version of the software is refused by ScreenScraper".into()),
        429 | 430 => Err("ScreenScraper's daily quota for this account is used up".into()),
        431 => Err("too many unknown games for today on ScreenScraper".into()),
        c => Err(format!("ScreenScraper answered {c}")),
    }
}

/// Checks the credentials (ssuserInfos.php) and keeps the quota figures.
pub fn test(app: &Shared, c: &Credentials) -> Result<Value, String> {
    let v = call(c, "ssuserInfos.php", &[])?;
    let u = &v["response"]["ssuser"];
    let num = |k: &str| u[k].as_str().and_then(|s| s.parse::<i64>().ok()).or_else(|| u[k].as_i64());
    status_set(app, |s| {
        s.requests_today = num("requeststoday");
        s.max_requests = num("maxrequestsperday");
        s.max_threads = num("maxthreads");
        s.error = None;
    });
    Ok(json!({ "user": u["id"], "level": u["niveau"], "requests_today": num("requeststoday"), "max_requests": num("maxrequestsperday") }))
}

pub fn save(app: &Shared, c: &Credentials) -> Result<Value, String> {
    let info = test(app, c)?;
    crate::secrets::store(&app.paths, SECRET_ID, &serde_json::to_string(c).unwrap()).map_err(|e| e.to_string())?;
    app.db.log("screenscraper", "account saved");
    Ok(info)
}

pub fn forget(app: &Shared) {
    crate::secrets::delete(&app.paths, SECRET_ID);
}

pub fn status(app: &Shared) -> Value {
    let c = credentials(app);
    let (asked, found) = app.db.ss_counts();
    json!({
        "developer_access": developer_access(),
        "configured": c.is_some(),
        "user": c.map(|c| c.user),
        "state": status_get(),
        "asked": asked,
        "found": found,
        "games": app.db.group_keys().len(),
    })
}

/// The URL of one media type, in the order of the regions.
fn pick<'a>(medias: &'a [Value], types: &[&str], regions: &[&str]) -> Option<&'a str> {
    for t in types {
        for r in regions {
            if let Some(m) = medias.iter().find(|m| {
                m["type"].as_str() == Some(t)
                    && m["parent"].as_str().unwrap_or("jeu") == "jeu"
                    && m["region"].as_str().unwrap_or("unk") == *r
            }) {
                return m["url"].as_str();
            }
        }
        if let Some(m) = medias.iter().find(|m| m["type"].as_str() == Some(t) && m["parent"].as_str().unwrap_or("jeu") == "jeu") {
            return m["url"].as_str();
        }
    }
    None
}

/// A media request: the address is kept without credentials, they are added for the request only.
fn media_get(c: &Credentials, noted: &str) -> Result<ureq::RequestBuilder<ureq::typestate::WithoutBody>, String> {
    let (dev_id, dev_password) = developer().ok_or("this build of Borne has no ScreenScraper developer access")?;
    // Only ScreenScraper's own hosts get the credentials, whatever the database holds.
    let host_ok = noted
        .strip_prefix("https://")
        .and_then(|r| r.split('/').next())
        .map(|h| h == "screenscraper.fr" || h.ends_with(".screenscraper.fr"))
        .unwrap_or(false);
    if !host_ok && std::env::var("BORNE_SCREENSCRAPER_API").is_err() {
        return Err("unexpected media address".into());
    }
    Ok(agent()
        .get(noted)
        .query("devid", &dev_id)
        .query("devpassword", &dev_password)
        .query("softname", "borne")
        .query("ssid", &c.user)
        .query("sspassword", &c.password))
}

/// Errors never include the address (it carries the credentials).
fn download(c: &Credentials, noted: &str) -> Result<Vec<u8>, String> {
    let mut resp = media_get(c, noted)?.call().map_err(|_| "image unreachable (network)".to_string())?;
    if resp.status().as_u16() != 200 {
        return Err(format!("image answered {}", resp.status().as_u16()));
    }
    resp.body_mut().with_config().limit(30 << 20).read_to_vec().map_err(|_| "image download interrupted".to_string())
}

/// The record without the credentials ScreenScraper puts in its media addresses.
fn redact_record(rec: &Value) -> Value {
    let mut r = rec.clone();
    if let Some(ms) = r["jeu"]["medias"].as_array_mut() {
        for m in ms {
            if let Some(u) = m["url"].as_str().map(redact) {
                m["url"] = json!(u);
            }
        }
    }
    r
}

/// ScreenScraper regions for the interface language: the title and the case scans shown are
/// those of the language Borne is displayed in (French → fr, then European…; Japanese → jp…).
pub fn ui_regions(lang: &str) -> Vec<&'static str> {
    let first: &[&str] = match lang {
        "fr" => &["fr", "eu"],
        "de" => &["de", "eu"],
        "es" => &["sp", "eu"],
        "it" => &["it", "eu"],
        "nl" => &["nl", "eu"],
        "pt" => &["pt", "br", "eu"],
        "sv" => &["se", "eu"],
        "da" => &["dk", "eu"],
        "no" => &["no", "eu"],
        "fi" => &["fi", "eu"],
        "pl" => &["pl", "eu"],
        "ru" => &["ru", "eu"],
        "ja" => &["jp"],
        "ko" => &["kr", "jp"],
        "zh" => &["cn", "tw", "jp"],
        _ => &["us", "wor", "uk", "eu"],
    };
    let mut out: Vec<&'static str> = first.to_vec();
    for c in ["wor", "eu", "us", "uk", "ss", "jp", "unk"] {
        if !out.contains(&c) {
            out.push(c);
        }
    }
    out
}

fn ui_lang(app: &Shared) -> String {
    app.db.setting("ui_lang").unwrap_or_else(|| "en".into())
}

/// The game's title in the interface language, from its ScreenScraper record.
pub fn title(app: &Shared, group_key: &str, lang: &str) -> Option<String> {
    let rec: Value = serde_json::from_str(&app.db.ss_record(group_key)?).ok()?;
    let names = rec["jeu"]["noms"].as_array()?;
    for r in ui_regions(lang) {
        if let Some(t) = names.iter().find(|n| n["region"].as_str() == Some(r)).and_then(|n| n["text"].as_str()) {
            let t = t.trim();
            if !t.is_empty() {
                return Some(t.to_string());
            }
        }
    }
    None
}

/// Every title ScreenScraper knows for the game (each region's), for the search.
pub fn all_titles(app: &Shared, group_key: &str) -> Vec<String> {
    let Some(rec) = app.db.ss_record(group_key).and_then(|r| serde_json::from_str::<Value>(&r).ok()) else { return vec![] };
    let mut out: Vec<String> = rec["jeu"]["noms"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| n["text"].as_str().map(|t| t.trim().to_string()))
        .filter(|t| !t.is_empty())
        .collect();
    out.sort();
    out.dedup();
    out
}

/// The interface language changed: titles follow at once, and the scans of that language are
/// fetched from the kept records (no new lookup), in the background.
pub fn set_ui_lang(app: &Shared, lang: &str) {
    if app.db.setting("ui_lang").as_deref() == Some(lang) {
        return;
    }
    app.db.set_setting("ui_lang", lang);
    RELOCALIZE.store(true, Ordering::SeqCst);
    relocalize(app);
}

/// Set when the scans must follow a new language; done as soon as ScreenScraper is free.
static RELOCALIZE: AtomicBool = AtomicBool::new(false);

fn relocalize(app: &Shared) {
    let Some(c) = credentials(app) else { return };
    if developer().is_none() || !RELOCALIZE.load(Ordering::SeqCst) || RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        while RELOCALIZE.swap(false, Ordering::SeqCst) {
            for (i, key) in app.db.ss_record_keys().iter().enumerate() {
                if let Some(rec) = app.db.ss_record(key).and_then(|j| serde_json::from_str::<Value>(&j).ok()) {
                    fetch_game(&app, &c, key, &rec);
                }
                if i % 20 == 19 {
                    app.emit(json!({ "type": "library" }));
                }
            }
        }
        RUNNING.store(false, Ordering::SeqCst);
        app.emit(json!({ "type": "library" }));
    });
}

/// The game's gameplay video from ScreenScraper, downloaded once into `dir` (the credentials are
/// added back to the noted address only for the request). Err when the game has none.
pub fn video(app: &Shared, group_key: &str, dir: &std::path::Path) -> Result<std::path::PathBuf, String> {
    let m = app.db.media(group_key, "video").ok_or("no gameplay video known for this game")?;
    if !m.path.is_empty() && std::path::Path::new(&m.path).is_file() {
        return Ok(m.path.into());
    }
    let noted = m.stamp.strip_prefix("ss|").ok_or("no gameplay video on ScreenScraper for this game")?;
    let c = credentials(app).ok_or("no ScreenScraper account")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let name: String = group_key.chars().map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '_' }).take(80).collect();
    let path = dir.join(format!("ss-{name}.mp4"));
    let tmp = dir.join(format!("ss-{name}.part"));
    let mut resp = media_get(&c, noted)?
        .config()
        .timeout_recv_body(Some(Duration::from_secs(180)))
        .build()
        .call()
        .map_err(|_| "video unreachable (network)".to_string())?;
    if resp.status().as_u16() != 200 {
        return Err(format!("video answered {}", resp.status().as_u16()));
    }
    let ctype = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let bytes = resp.body_mut().with_config().limit(150 << 20).read_to_vec().map_err(|_| "video download interrupted".to_string())?;
    // ScreenScraper answers a text message (not an error code) when the media is missing.
    if bytes.len() < 4096 || ctype.starts_with("text") || ctype.contains("json") {
        app.db.set_media(group_key, "video", "", 0, 0, "none");
        return Err("no gameplay video on ScreenScraper for this game".into());
    }
    std::fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    app.db.set_media(group_key, "video", &path.to_string_lossy(), 0, 0, &m.stamp);
    Ok(path)
}

/// The game's ScreenScraper record, matched by id, else by hashes, name and size.
fn lookup(app: &Shared, c: &Credentials, versions: &[crate::db::GameRow]) -> Result<Option<Value>, String> {
    let systems: Value = app.db.setting("ss_systems").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);
    // A match the user chose by hand wins over everything.
    let chosen = versions.first().and_then(|g| app.db.setting(&format!("ss_match.{}", g.group_key))).and_then(|v| v.parse::<i64>().ok());
    for g in versions {
        let extra: Value = app.db.game_extra(g.rom_id).and_then(|e| serde_json::from_str(&e).ok()).unwrap_or(Value::Null);
        let ss = &extra["ss"];
        let mut params: Vec<(&str, String)> = vec![];
        if let Some(id) = chosen.or_else(|| ss["id"].as_i64()) {
            params.push(("gameid", id.to_string()));
        } else {
            if let Some(sys) = systems[&g.platform_slug].as_i64() {
                params.push(("systemeid", sys.to_string()));
            }
            params.push(("romtype", "rom".into()));
            params.push(("romnom", g.fs_name.clone()));
            if g.fs_size > 0 {
                params.push(("romtaille", g.fs_size.to_string()));
            }
            if let Some(h) = ss["crc"].as_str() {
                params.push(("crc", h.to_string()));
            }
            if let Some(h) = ss["md5"].as_str() {
                params.push(("md5", h.to_string()));
            }
            if let Some(h) = &g.sha1 {
                params.push(("sha1", h.clone()));
            }
        }
        match call(c, "jeuInfos.php", &params) {
            Ok(v) if v["response"]["jeu"].is_object() => {
                let u = &v["response"]["ssuser"];
                let num = |k: &str| u[k].as_str().and_then(|s| s.parse::<i64>().ok()).or_else(|| u[k].as_i64());
                status_set(app, |s| {
                    s.requests_today = num("requeststoday").or(s.requests_today);
                    s.max_requests = num("maxrequestsperday").or(s.max_requests);
                });
                return Ok(Some(json!({ "jeu": v["response"]["jeu"], "regions": g.regions.clone().unwrap_or_default() })));
            }
            Err(e) if e == "not found" => continue,
            Err(e) => return Err(e),
            Ok(_) => continue,
        }
    }
    Ok(None)
}

/// ScreenScraper's media types for the art without any text ("Steam Grid Vierge", "ScreenMarquee
/// Vierge"), found by their French names in the list of media types (kept a week), then the
/// usual types as a fallback.
fn blank_types(app: &Shared, c: &Credentials) -> (Vec<String>, Vec<String>) {
    let cached: Option<Value> = app.db.setting("ss_media_types").and_then(|s| serde_json::from_str(&s).ok());
    let list = match cached.filter(|v| v["at"].as_i64().unwrap_or(0) > now() - 7 * 86400) {
        Some(v) => v["types"].clone(),
        None => match call(c, "mediasJeuListe.php", &[]) {
            Ok(v) => {
                let types = json!(v["response"]["medias"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|m| json!({ "short": m["nomcourt"], "name": m["nom"] }))
                    .collect::<Vec<_>>());
                app.db.set_setting("ss_media_types", &json!({ "at": now(), "types": types }).to_string());
                types
            }
            Err(_) => Value::Null,
        },
    };
    let find = |words: &[&str]| -> Vec<String> {
        list.as_array()
            .into_iter()
            .flatten()
            .filter(|m| {
                let n = m["name"].as_str().unwrap_or("").to_lowercase();
                n.contains("vierge") && words.iter().all(|w| n.contains(w))
            })
            .filter_map(|m| m["short"].as_str().map(String::from))
            .collect()
    };
    let mut steam = find(&["steam"]);
    steam.push("steamgrid".into());
    let mut marquee = find(&["marquee"]);
    marquee.push("screenmarquee".into());
    (steam, marquee)
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Short names of ScreenScraper's system media without any text on them whose name has all the
/// given words (from its list of system media types, "… vierge" in French), most specific first.
fn system_blank_types(c: &Credentials, words: &[&str]) -> Vec<String> {
    let Ok(v) = call(c, "mediasSystemeListe.php", &[]) else { return Vec::new() };
    v["response"]["medias"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|m| {
            let n = m["nom"].as_str().unwrap_or("").to_lowercase();
            n.contains("vierge") && words.iter().all(|w| n.contains(w))
        })
        .filter_map(|m| m["nomcourt"].as_str().map(String::from))
        .collect()
}

/// The consoles' own images (logo, monochrome logo, photo, and the frame drawn round the screen:
/// the console's blank Steam grid, else its Steam grid or fan art), from ScreenScraper's list of
/// systems, for the consoles of the library. Kept as media of "system:<slug>".
fn fetch_systems(app: &Shared, c: &Credentials, again: bool) {
    let ids: Value = app.db.setting("ss_systems").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);
    let slugs: Vec<(String, i64)> = app.db.platforms().into_iter().filter_map(|p| ids[&p.slug].as_i64().map(|id| (p.slug, id))).collect();
    let missing = |slug: &str| app.db.media(&format!("system:{slug}"), "logo").is_none();
    // Frames came later than the logos: look once for every console already fetched.
    let frames_asked = app.db.setting("ss_system_frames").is_some();
    if slugs.is_empty() || !(again || !frames_asked || slugs.iter().any(|(s, _)| missing(s))) {
        return;
    }
    let mut frame_types = system_blank_types(c, &["steam"]);
    frame_types.extend(["steamgrid".to_string(), "fanart".to_string()]);
    let frame_types: Vec<&str> = frame_types.iter().map(String::as_str).collect();
    let Ok(v) = call(c, "systemesListe.php", &[]) else { return };
    app.db.set_setting("ss_system_frames", "1");
    let systems = v["response"]["systemes"].as_array().cloned().unwrap_or_default();
    let regions = ui_regions(&ui_lang(app));
    for (slug, id) in slugs {
        let Some(sys) = systems.iter().find(|s| s["id"].as_i64() == Some(id) || s["id"].as_str() == Some(&id.to_string())) else {
            continue;
        };
        let medias: Vec<Value> = sys["medias"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(|mut m| {
                // System media carry no "parent": treat them as the game's own for `pick`.
                m["parent"] = json!("jeu");
                if let Some(u) = m["url"].as_str().map(redact) {
                    m["url"] = json!(u);
                }
                m
            })
            .collect();
        let key = format!("system:{slug}");
        for (kind, types) in [
            ("logo", &["wheel", "wheel-hd"][..]),
            ("logo-mono", &["logo-monochrome", "wheel-carbon"][..]),
            ("photo", &["photo", "illustration"][..]),
            ("frame", &frame_types[..]),
        ] {
            let Some(url) = pick(&medias, types, &regions) else { continue };
            let stamp = format!("ss|{url}");
            if !again && app.db.media(&key, kind).map(|m| m.stamp == stamp && std::path::Path::new(&m.path).is_file()).unwrap_or(false) {
                continue;
            }
            match download(c, url).and_then(|b| crate::media::store(app, &key, kind, &b)) {
                Ok((path, w, h)) => app.db.set_media(&key, kind, &path.to_string_lossy(), w, h, &stamp),
                Err(e) => app.db.log("screenscraper", &format!("{kind} of {slug}: {e}")),
            }
        }
    }
    app.emit(json!({ "type": "platforms" }));
}

/// Fetches and stores one game's media from its ScreenScraper record.
/// `rec` is the redacted record; the scans follow the interface language.
fn fetch_game(app: &Shared, c: &Credentials, group_key: &str, rec: &Value) -> usize {
    let medias: Vec<Value> = rec["jeu"]["medias"].as_array().cloned().unwrap_or_default();
    // The box region the user chose for this game comes first, then the interface language's.
    let chosen = app.db.setting(&format!("ss_region.{group_key}"));
    let mut regions: Vec<&str> = chosen.as_deref().into_iter().collect();
    regions.extend(ui_regions(&ui_lang(app)));
    let mut stored = 0;
    let (steam, marquee) = blank_types(app, c);
    let wanted: Vec<(&str, Vec<String>)> = vec![
        ("front", vec!["box-2D".into()]),
        ("side", vec!["box-2D-side".into()]),
        ("back", vec!["box-2D-back".into()]),
        ("physical", vec!["support-2D".into()]),
        ("logo", vec!["wheel-hd".into(), "wheel".into()]),
        ("fanart", vec!["fanart".into()]),
        // Art without any title on it: the library's background and the game page's picture.
        ("steamgrid", steam),
        ("marquee", marquee),
    ];
    let mut front_ar = None;
    for (kind, types) in wanted {
        let types: Vec<&str> = types.iter().map(String::as_str).collect();
        let Some(url) = pick(&medias, &types, &regions) else { continue };
        let stamp = format!("ss|{}", redact(url));
        if app.db.media(group_key, kind).map(|m| m.stamp == stamp && std::path::Path::new(&m.path).is_file()).unwrap_or(false) {
            stored += 1;
            if kind == "front" {
                front_ar = app.db.media(group_key, kind).map(|m| m.w as f64 / m.h as f64);
            }
            continue;
        }
        match download(c, url).and_then(|b| crate::media::store(app, group_key, kind, &b)) {
            Ok((path, w, h)) => {
                app.db.set_media(group_key, kind, &path.to_string_lossy(), w, h, &stamp);
                if kind == "front" {
                    front_ar = Some(w as f64 / h as f64);
                }
                stored += 1;
            }
            Err(e) => app.db.log("screenscraper", &format!("{kind} of {group_key}: {e}")),
        }
    }
    // The gameplay video is only noted here (redacted address): it is downloaded the first
    // time the game is shown with the video background, see `video`.
    let video =
        pick(&medias, &["video-normalized", "video"], &regions).map(|u| format!("ss|{}", redact(u))).unwrap_or_else(|| "none".into());
    if app.db.media(group_key, "video").map(|m| m.stamp != video).unwrap_or(true) {
        app.db.set_media(group_key, "video", "", 0, 0, &video);
    }
    // No spine scan: cut it from the unfolded case texture (back | spine | front). Not for CD
    // jewel cases: their back insert folds into a spine on each side, and the cut would take parts
    // of both (the title twice); their spine shows the title in the case's colour instead.
    let has_side =
        app.db.media(group_key, "side").map(|m| m.stamp.starts_with("ss|") && !m.stamp.starts_with(OLD_SPINE_CUT)).unwrap_or(false);
    if !has_side && !jewel_case(group_key) {
        if let Some(ar) = front_ar {
            if cut_spine(app, c, group_key, &medias, &regions, ar) {
                stored += 1;
            }
        }
    }
    stored
}

/// CD consoles whose games come in a jewel case.
fn jewel_case(group_key: &str) -> bool {
    matches!(group_key.split(':').next(), Some("psx" | "ps" | "saturn" | "segacd" | "dc"))
}

/// Spines cut from the case texture of jewel cases (the title twice, see fetch_game): removed once.
fn drop_jewel_texture_spines(app: &Shared) {
    for key in app.db.group_keys() {
        if jewel_case(&key) && app.db.media(&key, "side").map(|m| m.stamp.starts_with("ss|texture")).unwrap_or(false) {
            app.db.delete_media(&key, "side");
            app.emit(json!({ "type": "media", "group_key": key }));
        }
    }
}

/// Stamp of spines cut before their edges were looked for (often off centre): cut again.
const OLD_SPINE_CUT: &str = "ss|texture|";

/// Cuts the spine out of the unfolded case texture (back | spine | front) and stores it.
/// `ar` is the front's width / height, which gives the spine's place; its two folds are then
/// looked for near there, so the cut sits exactly on the spine.
fn cut_spine(app: &Shared, c: &Credentials, group_key: &str, medias: &[Value], regions: &[&str], ar: f64) -> bool {
    let Some(url) = pick(medias, &["box-texture"], regions) else { return false };
    let Ok(img) = download(c, url).and_then(|b| crate::media::decode(&b)) else { return false };
    let Some((x, w)) = spine_span(&img.to_luma8(), ar) else { return false };
    let cut = img.crop_imm(x, 0, w, img.height());
    let mut png = std::io::Cursor::new(vec![]);
    if cut.write_to(&mut png, image::ImageFormat::Png).is_err() {
        return false;
    }
    match crate::media::store(app, group_key, "side", png.get_ref()) {
        Ok((path, sw, sh)) => {
            app.db.set_media(group_key, "side", &path.to_string_lossy(), sw, sh, &format!("ss|texture2|{}", redact(url)));
            true
        }
        Err(_) => false,
    }
}

/// Where the spine lies in an unfolded case texture: (left edge, width) in pixels. The front's
/// proportions give a first guess (the spine in the middle, between two faces as wide as the
/// front); each fold is then the sharpest vertical edge near that guess, and the cut stays a pixel
/// inside the folds.
fn spine_span(g: &image::GrayImage, ar: f64) -> Option<(u32, u32)> {
    let (w, h) = (g.width() as f64, g.height() as f64);
    let face = h * ar;
    let spine = w - 2.0 * face;
    if !(spine > w * 0.01 && spine < w * 0.25) {
        return None;
    }
    // How sharp a vertical edge is between columns x - 1 and x (rows sampled).
    let step = (g.height() / 200).max(1);
    let edge = |x: u32| -> f64 {
        let mut s = 0u64;
        let mut n = 0u64;
        let mut y = 0;
        while y < g.height() {
            s += (g.get_pixel(x, y)[0] as i32 - g.get_pixel(x - 1, y)[0] as i32).unsigned_abs() as u64;
            n += 1;
            y += step;
        }
        s as f64 / n.max(1) as f64
    };
    let tol = (spine * 0.45).max(2.0);
    let best = |guess: f64| -> f64 {
        let lo = (guess - tol).max(1.0) as u32;
        let hi = (guess + tol).min(w - 1.0) as u32;
        let mut pick = (guess, -1.0);
        for x in lo..=hi {
            let e = edge(x);
            // A slight preference for the guess, so an even texture keeps it.
            let score = e - (x as f64 - guess).abs() * 0.02;
            if score > pick.1 {
                pick = (x as f64, score);
            }
        }
        pick.0
    };
    let (mut l, mut r) = (best(face), best(w - face));
    if !(r - l > spine * 0.6 && r - l < spine * 1.5) {
        (l, r) = (face, w - face);
    }
    let x = (l + 1.0).round() as u32;
    let width = ((r - 1.0) - (l + 1.0)).round().max(1.0) as u32;
    Some((x, width.min(g.width() - x)))
}

/// Fronts stored damaged by an earlier version, fetched again once from the kept records: white
/// cases (Wii, 3DS…) whose white band on top was taken for a scanner's margin (media::trim), and
/// Saturn, Mega-CD and Dreamcast covers whose left band was taken for a case hinge.
fn refetch_fronts(app: &Shared, c: &Credentials) {
    for key in app.db.ss_record_keys() {
        let (slug, flag) = (key.split(':').next().unwrap_or(""), format!("front_v3.{key}"));
        let damaged = matches!(slug, "wii" | "wiiu" | "3ds" | "nds" | "xbox360") && app.db.setting(&format!("front_v2.{key}")).is_none()
            || matches!(slug, "saturn" | "segacd" | "dc");
        if !damaged || app.db.setting(&flag).is_some() {
            continue;
        }
        let Some(rec) = app.db.ss_record(&key).and_then(|r| serde_json::from_str::<Value>(&r).ok()) else { continue };
        let medias: Vec<Value> = rec["jeu"]["medias"].as_array().cloned().unwrap_or_default();
        let chosen = app.db.setting(&format!("ss_region.{key}"));
        let mut regions: Vec<&str> = chosen.as_deref().into_iter().collect();
        regions.extend(ui_regions(&ui_lang(app)));
        if let Some(url) = pick(&medias, &["box-2D"], &regions) {
            match download(c, url).and_then(|b| crate::media::store(app, &key, "front", &b)) {
                Ok((path, w, h)) => {
                    app.db.set_media(&key, "front", &path.to_string_lossy(), w, h, &format!("ss|{}", redact(url)));
                    app.emit(json!({ "type": "media", "group_key": key }));
                }
                Err(e) => {
                    app.db.log("screenscraper", &format!("front of {key}: {e}"));
                    continue; // tried again next time
                }
            }
        }
        app.db.set_setting(&flag, "1");
    }
    // Their spines too: the white band on top of a Wii or 3DS spine was trimmed the same way.
    for key in app.db.ss_record_keys() {
        let flag = format!("side_v3.{key}");
        if !matches!(key.split(':').next(), Some("wii" | "wiiu" | "3ds" | "nds" | "xbox360")) || app.db.setting(&flag).is_some() {
            continue;
        }
        let Some(rec) = app.db.ss_record(&key).and_then(|r| serde_json::from_str::<Value>(&r).ok()) else { continue };
        let medias: Vec<Value> = rec["jeu"]["medias"].as_array().cloned().unwrap_or_default();
        let chosen = app.db.setting(&format!("ss_region.{key}"));
        let mut regions: Vec<&str> = chosen.as_deref().into_iter().collect();
        regions.extend(ui_regions(&ui_lang(app)));
        if let Some(url) = pick(&medias, &["box-2D-side"], &regions) {
            match download(c, url).and_then(|b| crate::media::store(app, &key, "side", &b)) {
                Ok((path, w, h)) => app.db.set_media(&key, "side", &path.to_string_lossy(), w, h, &format!("ss|{}", redact(url))),
                Err(e) => {
                    app.db.log("screenscraper", &format!("spine of {key}: {e}"));
                    continue;
                }
            }
        } else if let Some(ar) = app.db.media(&key, "front").filter(|m| m.h > 0).map(|m| m.w as f64 / m.h as f64) {
            cut_spine(app, c, &key, &medias, &regions, ar);
        }
        app.emit(json!({ "type": "media", "group_key": key }));
        app.db.set_setting(&flag, "1");
    }
}

/// Spines stored before their pale side margins were cut (media::trim_spine_sides): cut once now,
/// at startup.
pub fn trim_stored_spines(app: &Shared) {
    for key in app.db.group_keys() {
        if app.db.setting(&format!("spine_trim1.{key}")).is_some() {
            continue;
        }
        if let Some(m) = app.db.media(&key, "side") {
            if let Ok(bytes) = std::fs::read(&m.path) {
                if let Ok((path, w, h)) = crate::media::store(app, &key, "side", &bytes) {
                    if (w, h) != (m.w, m.h) {
                        app.db.set_media(&key, "side", &path.to_string_lossy(), w, h, &m.stamp);
                        app.emit(json!({ "type": "media", "group_key": key }));
                    }
                }
            }
        }
        app.db.set_setting(&format!("spine_trim1.{key}"), "1");
    }
}

/// Fronts of CD cases stored before their hinge was cut this way: cut once now (see
/// media::cut_hinge), at startup, with or without a ScreenScraper account.
pub fn cut_stored_hinges(app: &Shared) {
    for key in app.db.group_keys() {
        // hinge_cut3: the hinge found by the band's black (media::cut_hinge), every stored front.
        if !crate::media::cd_case(&key) || app.db.setting(&format!("hinge_cut3.{key}")).is_some() {
            continue;
        }
        if let Some(m) = app.db.media(&key, "front") {
            if let Ok(bytes) = std::fs::read(&m.path) {
                if let Ok((path, w, h)) = crate::media::store(app, &key, "front", &bytes) {
                    app.db.set_media(&key, "front", &path.to_string_lossy(), w, h, &m.stamp);
                    app.emit(json!({ "type": "media", "group_key": key }));
                }
            }
        }
        app.db.set_setting(&format!("hinge_cut3.{key}"), "1");
    }
}

/// Spines cut the old way (often off centre) cut again from the kept records, in the background.
fn recut_spines(app: &Shared, c: &Credentials) {
    for key in app.db.ss_record_keys() {
        if jewel_case(&key) || !app.db.media(&key, "side").map(|m| m.stamp.starts_with(OLD_SPINE_CUT)).unwrap_or(false) {
            continue;
        }
        let Some(rec) = app.db.ss_record(&key).and_then(|r| serde_json::from_str::<Value>(&r).ok()) else { continue };
        let Some(ar) = app.db.media(&key, "front").filter(|m| m.h > 0).map(|m| m.w as f64 / m.h as f64) else { continue };
        let medias: Vec<Value> = rec["jeu"]["medias"].as_array().cloned().unwrap_or_default();
        let chosen = app.db.setting(&format!("ss_region.{key}"));
        let mut regions: Vec<&str> = chosen.as_deref().into_iter().collect();
        regions.extend(ui_regions(&ui_lang(app)));
        cut_spine(app, c, &key, &medias, &regions, ar);
    }
}

/// Asks ScreenScraper for every game not asked yet (all of them with `again`), in the background.
pub fn start(app: &Shared, again: bool) {
    let Some(c) = credentials(app) else { return };
    if RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::Builder::new()
        .name("borne-screenscraper".into())
        .spawn(move || {
            let keys: Vec<String> = app
                .db
                .group_keys()
                .into_iter()
                .filter(|k| {
                    again
                        || match app.db.media(k, "ss") {
                            None => true,
                            // Found before the record was kept (titles, videos): asked once more.
                            Some(m) => m.stamp.starts_with("found") && app.db.ss_record(k).is_none(),
                        }
                })
                .collect();
            status_set(&app, |s| {
                s.running = true;
                s.done = 0;
                s.total = keys.len();
                s.found = 0;
                s.error = None;
            });
            // As many requests at once as the account allows (ScreenScraper's maxthreads, 1 for
            // a free account), up to 4.
            let threads = test(&app, &c).ok().and_then(|_| status_get().max_threads).map(|n| n.clamp(1, 4) as usize).unwrap_or(1);
            fetch_systems(&app, &c, again);
            drop_jewel_texture_spines(&app);
            recut_spines(&app, &c);
            refetch_fronts(&app, &c);
            STOP.store(false, Ordering::SeqCst);
            PAUSED.store(false, Ordering::SeqCst);
            status_set(&app, |s| {
                s.threads = threads;
                s.paused = false;
            });
            let queue = std::sync::Arc::new(Mutex::new(keys.into_iter().collect::<std::collections::VecDeque<String>>()));
            std::thread::scope(|scope| {
                for _ in 0..threads {
                    let (queue, app, c) = (queue.clone(), &app, &c);
                    scope.spawn(move || loop {
                        while PAUSED.load(Ordering::SeqCst) && !STOP.load(Ordering::SeqCst) {
                            std::thread::sleep(Duration::from_millis(300));
                        }
                        if STOP.load(Ordering::SeqCst) {
                            return;
                        }
                        let Some(key) = queue.lock().unwrap().pop_front() else { return };
                        let versions = app.db.group(&key);
                        match lookup(app, c, &versions) {
                            Ok(Some(rec)) => {
                                let rec = redact_record(&rec);
                                app.db.set_ss_record(&key, &rec.to_string());
                                fetch_game(app, c, &key, &rec);
                                app.db.set_media(&key, "ss", "", 0, 0, &format!("found|{}", rec["jeu"]["id"]));
                                status_set(app, |s| s.found += 1);
                            }
                            Ok(None) => app.db.set_media(&key, "ss", "", 0, 0, "not found"),
                            Err(e) => {
                                app.db.log("screenscraper", &e);
                                status_set(app, |s| s.error = Some(e));
                                STOP.store(true, Ordering::SeqCst);
                                return;
                            }
                        }
                        let done = {
                            let mut d = 0;
                            status_set(app, |s| {
                                s.done += 1;
                                d = s.done;
                            });
                            d
                        };
                        if done % 10 == 0 {
                            app.emit(json!({ "type": "library" }));
                        }
                    });
                }
            });
            if STOP.swap(false, Ordering::SeqCst) {
                app.db.log("screenscraper", "stopped");
            }
            PAUSED.store(false, Ordering::SeqCst);
            status_set(&app, |s| s.paused = false);
            status_set(&app, |s| s.running = false);
            // Games ScreenScraper knows as one: their versions joined.
            crate::catalog::merge_groups(&app);
            app.emit(json!({ "type": "library" }));
            let st = status_get();
            app.db.log("screenscraper", &format!("{} of {} game(s) found", st.found, st.done));
            RUNNING.store(false, Ordering::SeqCst);
            // The language changed during the run: its scans now.
            relocalize(&app);
        })
        .expect("screenscraper thread");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spine_cut_sits_on_the_folds() {
        // back 300 px | spine 40 px | front 280 px, 400 px high; the front scan's proportions are
        // a little off (as after trimming), so the first guess misses the folds.
        let mut g = image::GrayImage::new(620, 400);
        for (x, _, p) in g.enumerate_pixels_mut() {
            p[0] = if x < 300 {
                90
            } else if x < 340 {
                220
            } else {
                40
            };
        }
        let (x, w) = spine_span(&g, 290.0 / 400.0).unwrap();
        assert_eq!((x, w), (301, 38));
    }

    #[test]
    fn regions_follow_the_interface_language() {
        assert_eq!(ui_regions("fr")[..3], ["fr", "eu", "wor"]);
        assert_eq!(ui_regions("en")[0], "us");
        assert_eq!(ui_regions("ja")[0], "jp");
    }

    #[test]
    fn credentials_never_kept_in_urls() {
        let u = redact("https://x/api2/mediaJeu.php?devid=a&devpassword=b&softname=c&ssid=d&sspassword=e&systemeid=3&media=box-2D(eu)");
        assert_eq!(u, "https://x/api2/mediaJeu.php?systemeid=3&media=box-2D(eu)");
    }

    #[test]
    fn picks_the_region_then_any() {
        let m = vec![
            json!({"type": "box-2D", "region": "us", "url": "U", "parent": "jeu"}),
            json!({"type": "box-2D", "region": "eu", "url": "E", "parent": "jeu"}),
            json!({"type": "wheel", "region": "jp", "url": "W", "parent": "jeu"}),
        ];
        assert_eq!(pick(&m, &["box-2D"], &ui_regions("fr")), Some("E"));
        assert_eq!(pick(&m, &["wheel-hd", "wheel"], &ui_regions("fr")), Some("W"));
    }
}

// ---------- the user's corrections ----------

/// Per console: games found on ScreenScraper, not found, not looked up yet, and the names of
/// those not found (for Settings → Game images).
/// A console's name and its games (name, ROM id, ScreenScraper state).
type ConsoleGames = (String, Vec<(String, i64, String)>);

pub fn report(app: &Shared) -> Value {
    let mut by: std::collections::BTreeMap<String, ConsoleGames> = Default::default();
    let mut seen = std::collections::HashSet::new();
    for g in app.db.games(None, None, false) {
        if !seen.insert(g.group_key.clone()) {
            continue;
        }
        let state = app.db.media(&g.group_key, "ss").map(|m| m.stamp).unwrap_or_default();
        let e = by.entry(g.platform_slug.clone()).or_insert_with(|| (g.platform_name.clone(), vec![]));
        e.1.push((g.name.clone(), g.rom_id, state));
    }
    json!(by
        .into_iter()
        .map(|(slug, (name, games))| {
            let found = games.iter().filter(|g| g.2.starts_with("found")).count();
            let missing: Vec<Value> = games.iter().filter(|g| g.2 == "not found").map(|g| json!({ "name": g.0, "rom_id": g.1 })).collect();
            json!({ "slug": slug, "name": name, "total": games.len(), "found": found, "not_found": missing.len(),
                    "pending": games.len() - found - missing.len(), "missing": missing })
        })
        .collect::<Vec<_>>())
}

/// Searches ScreenScraper by name (and console), to correct a match: id, title, year, console.
pub fn search(app: &Shared, name: &str, platform: &str) -> Result<Value, String> {
    let c = credentials(app).ok_or("no ScreenScraper account")?;
    let systems: Value = app.db.setting("ss_systems").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);
    let mut params = vec![("recherche", name.to_string())];
    if let Some(sys) = systems[platform].as_i64() {
        params.push(("systemeid", sys.to_string()));
    }
    let v = call(&c, "jeuRecherche.php", &params)?;
    let regions = ui_regions(&ui_lang(app));
    let list: Vec<Value> = v["response"]["jeux"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|j| j["id"].as_str().map(|s| !s.is_empty() && s != "0").unwrap_or(j["id"].is_number()))
        .map(|j| {
            let names = j["noms"].as_array().cloned().unwrap_or_default();
            let title = regions
                .iter()
                .find_map(|r| names.iter().find(|n| n["region"].as_str() == Some(r)).and_then(|n| n["text"].as_str()))
                .or_else(|| names.first().and_then(|n| n["text"].as_str()))
                .unwrap_or("?");
            let year = j["dates"]
                .as_array()
                .and_then(|d| d.first())
                .and_then(|d| d["text"].as_str())
                .map(|t| t.chars().take(4).collect::<String>());
            json!({
                "id": j["id"].as_str().and_then(|s| s.parse::<i64>().ok()).or_else(|| j["id"].as_i64()),
                "name": title,
                "year": year,
                "system": j["systeme"]["text"],
                "publisher": j["editeur"]["text"],
            })
        })
        .take(12)
        .collect();
    Ok(json!(list))
}

/// The user picked the right ScreenScraper game (Some) or the box region (region): kept, and the
/// game's media fetched again at once, in the background.
pub fn correct(app: &Shared, group_key: &str, ss_id: Option<i64>, region: Option<&str>) -> Result<(), String> {
    let c = credentials(app).ok_or("no ScreenScraper account")?;
    if let Some(id) = ss_id {
        app.db.set_setting(&format!("ss_match.{group_key}"), &id.to_string());
    }
    if let Some(r) = region {
        if r.is_empty() {
            app.db.delete_setting(&format!("ss_region.{group_key}"));
        } else {
            app.db.set_setting(&format!("ss_region.{group_key}"), r);
        }
    }
    let (app, key) = (app.clone(), group_key.to_string());
    std::thread::spawn(move || {
        let versions = app.db.group(&key);
        // The region alone: the record already kept is enough.
        let rec = if ss_id.is_none() { app.db.ss_record(&key).and_then(|r| serde_json::from_str::<Value>(&r).ok()) } else { None };
        let rec = match rec {
            Some(r) => Some(r),
            None => match lookup(&app, &c, &versions) {
                Ok(Some(r)) => {
                    let r = redact_record(&r);
                    app.db.set_ss_record(&key, &r.to_string());
                    app.db.set_media(&key, "ss", "", 0, 0, &format!("found|{}", r["jeu"]["id"]));
                    Some(r)
                }
                Ok(None) => None,
                Err(e) => {
                    app.db.log("screenscraper", &e);
                    None
                }
            },
        };
        if let Some(r) = rec {
            fetch_game(&app, &c, &key, &r);
        }
        app.emit(json!({ "type": "library" }));
        app.emit(json!({ "type": "media", "group_key": key }));
    });
    Ok(())
}

/// Box regions ScreenScraper has for this game (from the kept record), and the one chosen.
pub fn regions(app: &Shared, group_key: &str) -> Value {
    let rec: Value = app.db.ss_record(group_key).and_then(|r| serde_json::from_str(&r).ok()).unwrap_or(Value::Null);
    let mut list: Vec<String> = rec["jeu"]["medias"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|m| m["type"].as_str() == Some("box-2D"))
        .filter_map(|m| m["region"].as_str().map(String::from))
        .collect();
    list.sort();
    list.dedup();
    json!({ "regions": list, "chosen": app.db.setting(&format!("ss_region.{group_key}")) })
}
