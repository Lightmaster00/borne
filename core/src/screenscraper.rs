//! Borne's own ScreenScraper access (Settings → ScreenScraper), independent of RomM: with the
//! user's ScreenScraper account and developer credentials, the core asks ScreenScraper for every
//! game and keeps its case scans (front, spine, back), cartridge or disc, logo and fanart.
//!
//! Games are matched by ScreenScraper's game id when RomM has it, else by the file's hashes,
//! name and size. Images follow the version's region (Europe → eu, then wor, us…). A spine
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

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Credentials {
    pub user: String,
    pub password: String,
    pub dev_id: String,
    pub dev_password: String,
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
    let mut req = agent()
        .get(format!("{}/{endpoint}", api()))
        .query("devid", &c.dev_id)
        .query("devpassword", &c.dev_password)
        .query("softname", "borne")
        .query("output", "json")
        .query("ssid", &c.user)
        .query("sspassword", &c.password);
    for (k, v) in params {
        req = req.query(*k, v);
    }
    let mut resp = req.call().map_err(|e| format!("ScreenScraper unreachable ({e})"))?;
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
        "configured": c.is_some(),
        "user": c.map(|c| c.user),
        "state": status_get(),
        "asked": asked,
        "found": found,
        "games": app.db.group_keys().len(),
    })
}

/// ScreenScraper region codes for a version's regions, then the usual fallbacks.
fn regions(version_regions: &str) -> Vec<&'static str> {
    let mut out = vec![];
    for r in version_regions.split(',').map(str::trim) {
        let code = match r {
            "Europe" => "eu",
            "USA" => "us",
            "Japan" => "jp",
            "World" => "wor",
            "France" => "fr",
            "Germany" => "de",
            "Spain" => "sp",
            "Italy" => "it",
            "UK" => "uk",
            "Australia" => "au",
            "Brazil" => "br",
            "Korea" => "kr",
            "China" => "cn",
            "Canada" => "us",
            "Netherlands" => "nl",
            _ => continue,
        };
        if !out.contains(&code) {
            out.push(code);
        }
        if ["fr", "de", "sp", "it", "uk", "nl"].contains(&code) && !out.contains(&"eu") {
            out.push("eu");
        }
    }
    for c in ["wor", "eu", "us", "ss", "jp", "unk"] {
        if !out.contains(&c) {
            out.push(c);
        }
    }
    out
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

fn download(url: &str) -> Result<Vec<u8>, String> {
    let mut resp = agent().get(url).call().map_err(|e| e.to_string())?;
    if resp.status().as_u16() != 200 {
        return Err(format!("image answered {}", resp.status().as_u16()));
    }
    resp.body_mut().with_config().limit(30 << 20).read_to_vec().map_err(|e| e.to_string())
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
fn fetch_game(app: &Shared, group_key: &str, rec: &Value) -> usize {
    let medias: Vec<Value> = rec["jeu"]["medias"].as_array().cloned().unwrap_or_default();
    let regions = regions(rec["regions"].as_str().unwrap_or(""));
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
        match download(url).and_then(|b| crate::media::store(app, group_key, kind, &b)) {
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
    // No spine scan: cut it from the unfolded case texture (back | spine | front).
    let has_side = app.db.media(group_key, "side").map(|m| m.stamp.starts_with("ss|")).unwrap_or(false);
    if !has_side {
        if let (Some(ar), Some(url)) = (front_ar, pick(&medias, &["box-texture"], &regions)) {
            if let Ok(img) = download(url).and_then(|b| image::load_from_memory(&b).map_err(|e| e.to_string())) {
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
                .filter(|k| again || app.db.media(k, "ss").is_none())
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
                        fetch_game(&app, key, &rec);
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
        })
        .expect("screenscraper thread");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regions_follow_the_version() {
        assert_eq!(regions("France")[..3], ["fr", "eu", "wor"]);
        assert_eq!(regions("USA")[0], "us");
        assert_eq!(regions("")[0], "wor");
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
        assert_eq!(pick(&m, &["box-2D"], &regions("Europe")), Some("E"));
        assert_eq!(pick(&m, &["wheel-hd", "wheel"], &regions("Europe")), Some("W"));
    }
}
