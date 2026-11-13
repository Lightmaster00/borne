//! System files: BIOS, keys and firmware the emulators need, provided by the user in Borne
//! (Settings → System files) from a file on the computer or from a link, then placed by Borne
//! where each emulator looks for them. Borne never ships or downloads such files by itself.
//!
//! What each console needs is in `systemfiles.json`. Files are checked when they are added
//! (expected size, PS3 update header, keys format, .nca files in a firmware archive) and kept in
//! `system/<console>/<item>/`. Before a game starts, `prepare` copies them for the chosen emulator
//! (RetroArch's system folder, PCSX2's BIOS folder, the keys and firmware of the Switch emulators,
//! RPCS3's firmware installation) and a missing required file stops the launch with a clear
//! message. A link to the RomM server gets the profile's token, so RomM's firmware links work.
//! RomM's own firmware for the console (its BIOS folder) is offered too, and after each sync the
//! missing files RomM has without doubt are taken from it.

use crate::state::Shared;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

#[derive(Deserialize, Clone)]
pub struct Item {
    pub id: String,
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub multi: bool,
    #[serde(default)]
    names: Vec<String>,
    #[serde(default)]
    ext: Vec<String>,
    #[serde(default)]
    size: Option<u64>,
    /// Known good dumps: MD5 → what it is (region, model).
    #[serde(default)]
    known: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct Catalog {
    consoles: BTreeMap<String, Vec<Item>>,
}

fn catalog() -> BTreeMap<String, Vec<Item>> {
    serde_json::from_str::<Catalog>(include_str!("systemfiles.json")).expect("systemfiles.json").consoles
}

pub fn items(console: &str) -> Vec<Item> {
    catalog().remove(console).unwrap_or_default()
}

fn dir(app: &Shared, console: &str, item: &str) -> PathBuf {
    app.paths.root.join("system").join(console).join(item)
}

fn files(app: &Shared, console: &str, item: &str) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir(app, console, item))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file() && !p.to_string_lossy().ends_with(".part"))
        .collect();
    v.sort();
    v
}

static TASK: Mutex<Option<Value>> = Mutex::new(None);

fn set_task(app: &Shared, v: Value) {
    *TASK.lock().unwrap() = Some(v);
    app.emit(json!({ "type": "systemfiles" }));
}

/// Settings view: per console of the library that needs files, each file and whether it is here.
pub fn status(app: &Shared) -> Value {
    let slugs: Vec<(String, String)> = app.db.platforms().into_iter().map(|p| (p.slug, p.name)).collect();
    let consoles: Vec<Value> = slugs
        .iter()
        .filter(|(s, _)| !items(s).is_empty())
        .map(|(slug, name)| {
            let list: Vec<Value> = items(slug)
                .iter()
                .map(|i| {
                    // Each BIOS with what its checksum says: a known dump (and which), or not known.
                    let f: Vec<String> = files(app, slug, &i.id)
                        .iter()
                        .filter_map(|p| {
                            let name = p.file_name()?.to_string_lossy().into_owned();
                            if i.known.is_empty() {
                                return Some(name);
                            }
                            Some(match md5_of(p).and_then(|m| i.known.get(&m).cloned()) {
                                Some(what) => format!("{name} ✓ {what}"),
                                None => format!("{name} (?)"),
                            })
                        })
                        .collect();
                    // Valid: there, and (where dumps are known) at least one is a known dump.
                    let valid = !f.is_empty() && (i.known.is_empty() || f.iter().any(|n| n.contains(" ✓ ")));
                    let shown = if i.kind == "firmware-nca" && !f.is_empty() { vec![format!("{} .nca", f.len())] } else { f };
                    json!({ "id": i.id, "name": i.name, "required": i.required, "files": shown, "valid": valid })
                })
                .collect();
            json!({ "slug": slug, "name": name, "items": list })
        })
        .collect();
    json!({ "consoles": consoles, "task": TASK.lock().unwrap().clone().unwrap_or(Value::Null) })
}

/// MD5 of a file, remembered while its size and date stay the same.
fn md5_of(p: &Path) -> Option<String> {
    use md5::Digest;
    static CACHE: Mutex<BTreeMap<(PathBuf, u64, i64), String>> = Mutex::new(BTreeMap::new());
    let meta = std::fs::metadata(p).ok()?;
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0);
    let key = (p.to_path_buf(), meta.len(), mtime);
    if let Some(m) = CACHE.lock().unwrap().get(&key) {
        return Some(m.clone());
    }
    let mut h = md5::Md5::new();
    let mut f = std::fs::File::open(p).ok()?;
    let mut buf = [0u8; 65536];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    let m: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
    CACHE.lock().unwrap().insert(key, m.clone());
    Some(m)
}

/// A missing required file for this console, said plainly.
pub fn check(app: &Shared, console: &str) -> Result<(), String> {
    for i in items(console) {
        if i.required && files(app, console, &i.id).is_empty() {
            return Err(format!("{} is missing: add it in Settings → System files", i.name));
        }
    }
    Ok(())
}

pub fn remove(app: &Shared, console: &str, item: &str) -> Result<(), String> {
    items(console).iter().find(|i| i.id == item).ok_or("unknown file")?;
    let _ = std::fs::remove_dir_all(dir(app, console, item));
    Ok(())
}

// ---------- adding ----------

/// Adds a file from the computer, in the background (firmware archives are large).
pub fn add_path(app: &Shared, console: &str, item: &str, path: &str) -> Result<(), String> {
    let it = items(console).into_iter().find(|i| i.id == item).ok_or("unknown file")?;
    let src = PathBuf::from(path.trim());
    if !src.is_absolute() || !src.is_file() {
        return Err("this file cannot be found".into());
    }
    begin(app, console, item)?;
    let (app, console) = (app.clone(), console.to_string());
    std::thread::spawn(move || {
        let name = src.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
        let r = std::fs::File::open(&src).map_err(|e| e.to_string()).and_then(|f| store(&app, &console, &it, &name, f));
        finish(&app, &console, &it.id, r);
    });
    Ok(())
}

/// Adds a file from a link (http or https). A link to the RomM server is sent with the profile's
/// token.
pub fn add_url(app: &Shared, console: &str, item: &str, url: &str) -> Result<(), String> {
    let it = items(console).into_iter().find(|i| i.id == item).ok_or("unknown file")?;
    let url = url.trim().to_string();
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("the link must start with http:// or https://".into());
    }
    begin(app, console, item)?;
    let (app, console) = (app.clone(), console.to_string());
    std::thread::spawn(move || {
        let r = fetch(&app, &url).and_then(|(name, reader)| store(&app, &console, &it, &name, reader));
        finish(&app, &console, &it.id, r);
    });
    Ok(())
}

fn begin(app: &Shared, console: &str, item: &str) -> Result<(), String> {
    let mut t = TASK.lock().unwrap();
    if t.as_ref().map(|v| v["running"] == true).unwrap_or(false) {
        return Err("a file is already being added".into());
    }
    *t = Some(json!({ "console": console, "item": item, "running": true, "error": null }));
    drop(t);
    app.emit(json!({ "type": "systemfiles" }));
    Ok(())
}

fn finish(app: &Shared, console: &str, item: &str, r: Result<(), String>) {
    if let Err(e) = &r {
        app.db.log("system files", &format!("{console}/{item}: {e}"));
    } else {
        app.db.log("system files", &format!("{console}/{item} added"));
    }
    set_task(app, json!({ "console": console, "item": item, "running": false, "error": r.err() }));
}

fn same_host(a: &str, b: &str) -> bool {
    let host = |u: &str| u.split("://").nth(1).and_then(|r| r.split('/').next()).map(|h| h.to_lowercase());
    host(a).is_some() && host(a) == host(b)
}

fn fetch(app: &Shared, url: &str) -> Result<(String, Box<dyn Read + Send>), String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .tls_config(crate::romm::tls())
        .timeout_connect(Some(Duration::from_secs(15)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .user_agent(format!("Borne/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .into();
    let mut req = agent.get(url);
    if let (Some(server), Some(p)) = (app.server_url(), app.active_profile()) {
        if same_host(url, &server) {
            if let Some(token) = crate::secrets::load(&app.paths, &p.id) {
                req = req.header("Authorization", &format!("Bearer {token}"));
            }
        }
    }
    let resp = req.call().map_err(|e| format!("the link cannot be reached: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("the link answered {}", resp.status().as_u16()));
    }
    let disposition = resp.headers().get("content-disposition").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let name = disposition
        .split("filename=")
        .nth(1)
        .map(|s| s.trim_matches(|c| c == '"' || c == ';' || c == ' ').to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let path = url.split('?').next().unwrap_or(url);
            let last = path.rsplit('/').next().unwrap_or("file");
            percent_decode(last)
        });
    let reader = resp.into_body().into_with_config().limit(8 << 30).reader();
    Ok((name, Box::new(reader)))
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A file name kept on disk: its last component, without anything that could leave the folder.
fn safe_name(name: &str) -> String {
    let n = name.rsplit(['/', '\\']).next().unwrap_or("file");
    let n: String = n.chars().filter(|c| !c.is_control()).collect();
    let n = n.trim().trim_start_matches('.').to_string();
    if n.is_empty() {
        "file".into()
    } else {
        n.chars().take(120).collect()
    }
}

/// Checks and keeps a file for an item.
fn store(app: &Shared, console: &str, it: &Item, name: &str, mut src: impl Read) -> Result<(), String> {
    let d = dir(app, console, &it.id);
    std::fs::create_dir_all(&d).map_err(|e| e.to_string())?;
    let name = safe_name(name);
    let tmp = d.join(format!("{name}.part"));
    let mut out = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let size = std::io::copy(&mut src, &mut out).map_err(|e| format!("the file could not be read: {e}"))?;
    drop(out);
    let r = check_and_place(&d, it, &name, &tmp, size);
    let _ = std::fs::remove_file(&tmp);
    r
}

fn check_and_place(d: &Path, it: &Item, name: &str, tmp: &Path, size: u64) -> Result<(), String> {
    let lower = name.to_lowercase();
    match it.kind.as_str() {
        "firmware-nca" => {
            // An archive of .nca files: they are extracted, flat.
            let f = std::fs::File::open(tmp).map_err(|e| e.to_string())?;
            let mut z = zip::ZipArchive::new(f).map_err(|_| "this is not a .zip archive of the firmware".to_string())?;
            let staging = d.join(".new");
            let _ = std::fs::remove_dir_all(&staging);
            std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
            let mut n = 0;
            for i in 0..z.len() {
                let mut e = z.by_index(i).map_err(|e| e.to_string())?;
                let entry = e.name().map_err(|e| e.to_string())?.into_owned();
                let base = entry.rsplit('/').next().unwrap_or("").to_string();
                if e.is_dir() || !base.to_lowercase().ends_with(".nca") {
                    continue;
                }
                let mut w = std::fs::File::create(staging.join(safe_name(&base))).map_err(|e| e.to_string())?;
                std::io::copy(&mut e, &mut w).map_err(|e| e.to_string())?;
                n += 1;
            }
            if n == 0 {
                let _ = std::fs::remove_dir_all(&staging);
                return Err("no .nca file in this archive: it is not a Switch firmware".into());
            }
            for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
                if e.path().is_file() {
                    let _ = std::fs::remove_file(e.path());
                }
            }
            for e in std::fs::read_dir(&staging).into_iter().flatten().flatten() {
                std::fs::rename(e.path(), d.join(e.file_name())).map_err(|e| e.to_string())?;
            }
            let _ = std::fs::remove_dir_all(&staging);
            Ok(())
        }
        "pup" => {
            let mut magic = [0u8; 5];
            std::fs::File::open(tmp).and_then(|mut f| f.read_exact(&mut magic)).map_err(|_| "this file is too small".to_string())?;
            if &magic != b"SCEUF" {
                return Err("this is not a PS3 update file (PS3UPDAT.PUP)".into());
            }
            replace(d, tmp, &it.names[0])
        }
        "keys" => {
            if size > 1 << 20 {
                return Err("this file is too large for a keys file".into());
            }
            let text = std::fs::read_to_string(tmp).map_err(|_| "this is not a keys file (text expected)".to_string())?;
            if !text.lines().any(|l| {
                l.contains('=')
                    && l.split('=').nth(1).map(|v| v.trim().chars().all(|c| c.is_ascii_hexdigit()) && !v.trim().is_empty()).unwrap_or(false)
            }) {
                return Err("this is not a keys file (lines of name = key expected)".into());
            }
            replace(d, tmp, &it.names[0])
        }
        _ => {
            if let Some(want) = it.size {
                if size != want {
                    return Err(format!("this file is {size} bytes, {want} expected: is it the right file?"));
                }
            }
            if !it.ext.is_empty() && !it.ext.iter().any(|e| lower.ends_with(e)) {
                return Err(format!("a {} file is expected", it.ext.join(" or ")));
            }
            // Known names: a dump named differently ("SCPH-5502.BIN") gets the name emulators expect.
            let normalized = lower.replace('-', "");
            let target = if it.names.is_empty() {
                name.to_string()
            } else if let Some(n) = it.names.iter().find(|n| n.to_lowercase() == normalized) {
                n.clone()
            } else if it.names.len() == 1 || !it.multi {
                it.names[0].clone()
            } else {
                name.to_string()
            };
            if it.multi {
                std::fs::rename(tmp, d.join(&target)).map_err(|e| e.to_string())
            } else {
                replace(d, tmp, &target)
            }
        }
    }
}

// ---------- from RomM ----------

/// Whether a file RomM keeps could be this item (name, extension, size).
fn fits(it: &Item, name: &str, size: u64) -> bool {
    let lower = name.to_lowercase();
    match it.kind.as_str() {
        "keys" => it.names.iter().any(|n| n.eq_ignore_ascii_case(name)),
        "firmware-nca" => lower.ends_with(".zip") && !lower.contains("keys"),
        "pup" => lower.ends_with(".pup"),
        _ => {
            let size_ok = it.size.map(|s| s == size).unwrap_or(true);
            let name_ok = if !it.names.is_empty() {
                let normalized = lower.replace('-', "");
                it.names.iter().any(|n| n.to_lowercase() == normalized) || (it.names.len() == 1 && it.size.is_some())
            } else {
                it.ext.is_empty() || it.ext.iter().any(|e| lower.ends_with(e))
            };
            size_ok && name_ok
        }
    }
}

/// RomM's firmware for this console that fits each item: {item: [{id, file_name, size}]}.
pub fn romm_candidates(app: &Shared, console: &str) -> Result<Value, String> {
    let client = app.client().ok_or("no paired profile or server offline")?;
    let platforms: Vec<i64> = app.db.platforms().into_iter().filter(|p| p.slug == console).map(|p| p.id).collect();
    let mut found: Vec<Value> = vec![];
    for pid in platforms {
        found.extend(client.firmware(pid).map_err(|e| format!("RomM: {e}"))?);
    }
    let mut out = serde_json::Map::new();
    for it in items(console) {
        let list: Vec<Value> = found
            .iter()
            .filter(|f| f["missing_from_fs"] != true)
            .filter(|f| fits(&it, f["file_name"].as_str().unwrap_or(""), f["file_size_bytes"].as_u64().unwrap_or(0)))
            .map(|f| json!({ "id": f["id"], "file_name": f["file_name"], "size": f["file_size_bytes"] }))
            .collect();
        out.insert(it.id.clone(), json!(list));
    }
    Ok(Value::Object(out))
}

fn add_romm_now(app: &Shared, console: &str, it: &Item, firmware_id: i64, file_name: &str) -> Result<(), String> {
    let client = app.client().ok_or("no paired profile or server offline")?;
    let d = dir(app, console, &it.id);
    std::fs::create_dir_all(&d).map_err(|e| e.to_string())?;
    let tmp = d.join(".romm.download");
    client
        .fetch_to_file(&format!("/api/firmware/{firmware_id}/content/{}", crate::romm::percent_encode(file_name)), &tmp, 8 << 30)
        .map_err(|e| format!("RomM: {e}"))?;
    let r = std::fs::File::open(&tmp).map_err(|e| e.to_string()).and_then(|f| store(app, console, it, file_name, f));
    let _ = std::fs::remove_file(&tmp);
    r
}

/// Adds one of RomM's files to an item, in the background.
pub fn add_romm(app: &Shared, console: &str, item: &str, firmware_id: i64) -> Result<(), String> {
    let it = items(console).into_iter().find(|i| i.id == item).ok_or("unknown file")?;
    let cands = romm_candidates(app, console)?;
    let file_name = cands[item]
        .as_array()
        .into_iter()
        .flatten()
        .find(|c| c["id"].as_i64() == Some(firmware_id))
        .and_then(|c| c["file_name"].as_str().map(String::from))
        .ok_or("RomM has no such file for this console")?;
    begin(app, console, item)?;
    let (app, console) = (app.clone(), console.to_string());
    std::thread::spawn(move || {
        let r = add_romm_now(&app, &console, &it, firmware_id, &file_name);
        finish(&app, &console, &it.id, r);
    });
    Ok(())
}

/// Every missing file RomM has without doubt (one fitting file, or all of them for items that
/// take several, like BIOS of several regions), for every console of the library. Run after each
/// sync and from Settings. Returns how many files were added.
pub fn fill_from_romm(app: &Shared) -> usize {
    if app.client().is_none() {
        return 0;
    }
    let mut added = 0;
    let consoles: Vec<String> = app.db.platforms().into_iter().map(|p| p.slug).filter(|s| !items(s).is_empty()).collect();
    for console in consoles {
        let Ok(cands) = romm_candidates(app, &console) else { continue };
        for it in items(&console) {
            if !files(app, &console, &it.id).is_empty() {
                continue;
            }
            let list = cands[&it.id].as_array().cloned().unwrap_or_default();
            let take: Vec<&Value> = if it.multi {
                list.iter().collect()
            } else if list.len() == 1 {
                vec![&list[0]]
            } else {
                vec![]
            };
            for c in take {
                let (Some(id), Some(name)) = (c["id"].as_i64(), c["file_name"].as_str()) else { continue };
                match add_romm_now(app, &console, &it, id, name) {
                    Ok(()) => added += 1,
                    Err(e) => app.db.log("system files", &format!("{console}/{} from RomM ({name}): {e}", it.id)),
                }
            }
        }
    }
    if added > 0 {
        app.db.log("system files", &format!("{added} file(s) taken from RomM"));
        app.emit(json!({ "type": "systemfiles" }));
    }
    added
}

/// The item's only file becomes this one.
fn replace(d: &Path, tmp: &Path, target: &str) -> Result<(), String> {
    for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
        if e.path() != tmp && e.path().is_file() {
            let _ = std::fs::remove_file(e.path());
        }
    }
    std::fs::rename(tmp, d.join(target)).map_err(|e| e.to_string())
}

/// Opens the system's file chooser (macOS: AppleScript; Linux: zenity or kdialog).
pub fn pick_file(title: &str) -> Result<String, String> {
    let title: String = title.chars().filter(|c| c.is_alphanumeric() || " .()-".contains(*c)).collect();
    let out = if cfg!(target_os = "macos") {
        std::process::Command::new("osascript").arg("-e").arg(format!("POSIX path of (choose file with prompt \"{title}\")")).output()
    } else if crate::emulators::which("zenity").is_some() {
        std::process::Command::new("zenity").args(["--file-selection", "--title", &title]).output()
    } else if crate::emulators::which("kdialog").is_some() {
        std::process::Command::new("kdialog").args(["--getopenfilename", ".", "--title", &title]).output()
    } else {
        return Err("no file chooser on this system: type the file's path".into());
    };
    let out = out.map_err(|e| e.to_string())?;
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || path.is_empty() {
        return Err("no file chosen".into());
    }
    Ok(path)
}

// ---------- placing for the emulators ----------

fn copy_if_changed(src: &Path, dst: &Path) -> Result<(), String> {
    let same = match (src.metadata(), dst.metadata()) {
        (Ok(a), Ok(b)) => a.len() == b.len() && b.modified().ok() >= a.modified().ok(),
        _ => false,
    };
    if same {
        return Ok(());
    }
    if let Some(p) = dst.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    std::fs::copy(src, dst).map(|_| ()).map_err(|e| format!("{}: {e}", dst.display()))
}

/// RetroArch's system folder (also used by the standalone BIOS folders below).
pub fn bios_dir(app: &Shared) -> PathBuf {
    app.paths.root.join("bios")
}

/// Puts the console's files where the chosen emulator reads them. `data` is the emulator's data
/// folder for this profile (Linux: Borne's own; macOS: the emulator's usual folder).
pub fn prepare(
    app: &Shared,
    console: &str,
    program: &str,
    data: &Path,
    exe: Option<&Path>,
    env: &[(String, String)],
) -> Result<(), String> {
    check(app, console)?;
    for it in items(console) {
        let fs = files(app, console, &it.id);
        if fs.is_empty() {
            continue;
        }
        match (it.kind.as_str(), program) {
            ("bios", _) => {
                for f in &fs {
                    let name = f.file_name().unwrap();
                    copy_if_changed(f, &bios_dir(app).join(name))?;
                    if console == "nds" {
                        copy_if_changed(f, &bios_dir(app).join("melonDS DS").join(name))?;
                    }
                }
            }
            ("keys", "eden" | "citron") => {
                for f in &fs {
                    copy_if_changed(f, &data.join("keys").join(f.file_name().unwrap()))?;
                }
            }
            ("keys", "ryubing") => {
                for f in &fs {
                    copy_if_changed(f, &data.join("system").join(f.file_name().unwrap()))?;
                }
            }
            ("firmware-nca", "eden" | "citron") => {
                let reg = data.join("nand/system/Contents/registered");
                for f in &fs {
                    copy_if_changed(f, &reg.join(f.file_name().unwrap()))?;
                }
            }
            // Ryujinx keeps each firmware NCA as a folder of that name holding a file "00".
            ("firmware-nca", "ryubing") => {
                let reg = data.join("bis/system/Contents/registered");
                for f in &fs {
                    copy_if_changed(f, &reg.join(f.file_name().unwrap()).join("00"))?;
                }
            }
            ("ps4-modules", "shadps4") => {
                for f in &fs {
                    copy_if_changed(f, &data.join("sys_modules").join(f.file_name().unwrap()))?;
                }
            }
            ("pup", "rpcs3") => {
                let marker = data.join(".borne-firmware");
                let stamp = fs[0].metadata().map(|m| m.len().to_string()).unwrap_or_default();
                if std::fs::read_to_string(&marker).ok().as_deref() != Some(stamp.as_str()) {
                    if let Some(exe) = exe {
                        let st = std::process::Command::new(exe)
                            .arg("--installfw")
                            .arg(&fs[0])
                            .envs(env.iter().cloned())
                            .stdout(std::process::Stdio::null())
                            .stderr(std::process::Stdio::null())
                            .status()
                            .map_err(|e| format!("RPCS3 could not install the firmware: {e}"))?;
                        if !st.success() {
                            return Err("RPCS3 could not install the PS3 firmware".into());
                        }
                        let _ = std::fs::write(&marker, stamp);
                    }
                }
            }
            _ => {}
        }
    }
    if console == "ps2" && program == "pcsx2" {
        let ini = data.join("PCSX2/inis/PCSX2.ini");
        let bios = dir(app, "ps2", "bios");
        crate::emulators::ini_set(&ini, &[("UI", "SetupWizardIncomplete", "false"), ("Folders", "Bios", &bios.to_string_lossy())])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(kind: &str, names: &[&str], size: Option<u64>, multi: bool) -> Item {
        Item {
            id: "x".into(),
            name: "x".into(),
            kind: kind.into(),
            required: true,
            multi,
            names: names.iter().map(|s| s.to_string()).collect(),
            ext: vec![],
            size,
            known: Default::default(),
        }
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("borne-sf-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn bios_size_and_names_are_checked() {
        let d = tmpdir("bios");
        let it = item("bios", &["scph5501.bin", "scph5502.bin"], Some(16), true);
        std::fs::write(d.join("a.part"), [0u8; 15]).unwrap();
        assert!(check_and_place(&d, &it, "SCPH-5502.BIN", &d.join("a.part"), 15).is_err());
        std::fs::write(d.join("a.part"), [0u8; 16]).unwrap();
        check_and_place(&d, &it, "SCPH-5502.BIN", &d.join("a.part"), 16).unwrap();
        assert!(d.join("scph5502.bin").is_file());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn keys_and_pup_are_recognised() {
        let d = tmpdir("keys");
        let keys = item("keys", &["prod.keys"], None, false);
        std::fs::write(d.join("k.part"), "hello world").unwrap();
        assert!(check_and_place(&d, &keys, "x.txt", &d.join("k.part"), 11).is_err());
        std::fs::write(d.join("k.part"), "header_key = 0123abcd\n").unwrap();
        check_and_place(&d, &keys, "mykeys.txt", &d.join("k.part"), 22).unwrap();
        assert!(d.join("prod.keys").is_file());
        let pup = item("pup", &["PS3UPDAT.PUP"], None, false);
        std::fs::write(d.join("p.part"), b"NOTPUP").unwrap();
        assert!(check_and_place(&d, &pup, "f.pup", &d.join("p.part"), 6).is_err());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn names_stay_inside_the_folder() {
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name("..hidden"), "hidden");
        assert_eq!(safe_name("a\\b\\c.bin"), "c.bin");
    }

    #[test]
    fn romm_files_fit_their_item() {
        let ps1 = item("bios", &["scph5501.bin", "scph5502.bin"], Some(524288), true);
        assert!(fits(&ps1, "SCPH-5502.bin", 524288));
        assert!(!fits(&ps1, "scph5502.bin", 1000));
        let keys = item("keys", &["prod.keys"], None, false);
        assert!(fits(&keys, "prod.keys", 9000) && !fits(&keys, "title.keys", 9000));
        let fw = item("firmware-nca", &[], None, false);
        assert!(fits(&fw, "Firmware 19.0.1.zip", 1) && !fits(&fw, "keys.zip", 1));
        let ds = item("bios", &["bios7.bin"], Some(16384), false);
        assert!(fits(&ds, "biosnds7.rom", 16384));
    }

    #[test]
    fn catalog_reads() {
        assert!(items("switch").iter().any(|i| i.id == "prod-keys" && i.required));
        assert!(items("ps3").iter().any(|i| i.kind == "pup"));
    }
}
