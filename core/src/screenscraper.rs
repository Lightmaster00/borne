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
    pub done: usize,
    pub total: usize,
    pub found: usize,
    pub error: Option<String>,
    pub requests_today: Option<i64>,
    pub max_requests: Option<i64>,
}

static RUNNING: AtomicBool = AtomicBool::new(false);
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
    let body = resp
        .body_mut()
        .with_config()
        .limit(8 << 20)
        .read_to_string()
        .unwrap_or_default();
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
        s.error = None;
    });
    Ok(json!({ "user": u["id"], "level": u["niveau"], "requests_today": num("requeststoday"), "max_requests": num("maxrequestsperday") }))
}

pub fn save(app: &Shared, c: &Credentials) -> Result<Value, String> {
    let info = test(app, c)?;
    crate::secrets::store(&app.paths, SECRET_ID, &serde_json::to_string(c).unwrap())
        .map_err(|e| e.to_string())?;
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
    let bytes = resp
        .body_mut()
        .with_config()
        .limit(150 << 20)
        .read_to_vec()
        .map_err(|_| "video download interrupted".to_string())?;
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
    let systems: Value = app
        .db
        .setting("ss_systems")
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
    for g in versions {
        let extra: Value = app.db.game_extra(g.rom_id).and_then(|e| serde_json::from_str(&e).ok()).unwrap_or(Value::Null);
        let ss = &extra["ss"];
        let mut params: Vec<(&str, String)> = vec![];
        if let Some(id) = ss["id"].as_i64() {
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

/// Fetches and stores one game's media from its ScreenScraper record.
/// `rec` is the redacted record; the scans follow the interface language.
fn fetch_game(app: &Shared, c: &Credentials, group_key: &str, rec: &Value) -> usize {
    let medias: Vec<Value> = rec["jeu"]["medias"].as_array().cloned().unwrap_or_default();
    let regions = ui_regions(&ui_lang(app));
    let mut stored = 0;
    let wanted: [(&str, &[&str]); 6] = [
        ("front", &["box-2D"]),
        ("side", &["box-2D-side"]),
        ("back", &["box-2D-back"]),
        ("physical", &["support-2D"]),
        ("logo", &["wheel-hd", "wheel"]),
        ("fanart", &["fanart"]),
    ];
    let mut front_ar = None;
    for (kind, types) in wanted {
        let Some(url) = pick(&medias, types, &regions) else { continue };
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
    let video = pick(&medias, &["video-normalized", "video"], &regions)
        .map(|u| format!("ss|{}", redact(u)))
        .unwrap_or_else(|| "none".into());
    if app.db.media(group_key, "video").map(|m| m.stamp != video).unwrap_or(true) {
        app.db.set_media(group_key, "video", "", 0, 0, &video);
    }
    // No spine scan: cut it from the unfolded case texture (back | spine | front).
    let has_side = app.db.media(group_key, "side").map(|m| m.stamp.starts_with("ss|")).unwrap_or(false);
    if !has_side {
        if let (Some(ar), Some(url)) = (front_ar, pick(&medias, &["box-texture"], &regions)) {
            if let Ok(img) = download(c, url).and_then(|b| crate::media::decode(&b)) {
                let (w, h) = (img.width() as f64, img.height() as f64);
                let face = h * ar;
                let spine = w - 2.0 * face;
                if spine > w * 0.01 && spine < w * 0.25 {
                    let cut = img.crop_imm(face.round() as u32, 0, spine.round().max(1.0) as u32, h as u32);
                    let mut png = std::io::Cursor::new(vec![]);
                    if cut.write_to(&mut png, image::ImageFormat::Png).is_ok() {
                        if let Ok((path, sw, sh)) = crate::media::store(app, group_key, "side", png.get_ref()) {
                            app.db.set_media(group_key, "side", &path.to_string_lossy(), sw, sh, &format!("ss|texture|{}", redact(url)));
                            stored += 1;
                        }
                    }
                }
            }
        }
    }
    stored
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
            for (i, key) in keys.iter().enumerate() {
                let versions = app.db.group(key);
                match lookup(&app, &c, &versions) {
                    Ok(Some(rec)) => {
                        let rec = redact_record(&rec);
                        app.db.set_ss_record(key, &rec.to_string());
                        fetch_game(&app, &c, key, &rec);
                        app.db.set_media(key, "ss", "", 0, 0, &format!("found|{}", rec["jeu"]["id"]));
                        status_set(&app, |s| s.found += 1);
                    }
                    Ok(None) => app.db.set_media(key, "ss", "", 0, 0, "not found"),
                    Err(e) => {
                        app.db.log("screenscraper", &e);
                        status_set(&app, |s| s.error = Some(e));
                        break;
                    }
                }
                status_set(&app, |s| s.done = i + 1);
                if i % 10 == 9 {
                    app.emit(json!({ "type": "library" }));
                }
                std::thread::sleep(Duration::from_millis(400));
            }
            status_set(&app, |s| s.running = false);
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
