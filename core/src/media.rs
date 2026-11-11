//! Game media kept on disk for every game: the case scans (front, spine, back), the cartridge or
//! disc ("physical") and the game's logo. They come from ScreenScraper through RomM
//! (`ss_metadata.*_path`, enabled by RomM's `scan.media`).
//!
//! One coherent set per game (group of versions): the case faces come from the version that has
//! the most of them, so front, spine and back belong to the same box; what that version lacks is
//! taken from another version. Each image is cleaned once when downloaded: uniform borders are
//! trimmed, a spine stored lying down is stood up, and the size is capped. Its pixel size is kept,
//! so the interface can shape a box before the image is loaded.

use crate::state::Shared;
use image::{DynamicImage, GenericImageView, ImageFormat, Rgba};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// Kinds kept for every game, in the order they are fetched.
pub const KINDS: [&str; 5] = ["front", "side", "back", "physical", "logo"];
const BOX: [&str; 3] = ["front", "side", "back"];

/// The remote path of each kind for a group: box faces from the version with the most of them.
pub fn sources(app: &Shared, group_key: &str) -> HashMap<&'static str, (i64, String)> {
    let versions = app.db.group(group_key);
    let arts: Vec<(i64, Value)> = versions
        .iter()
        .filter_map(|g| {
            let e: Value = serde_json::from_str(&app.db.game_extra(g.rom_id)?).ok()?;
            Some((g.rom_id, e["art"].clone()))
        })
        .collect();
    let best = arts
        .iter()
        .max_by_key(|(id, a)| {
            let n = BOX.iter().filter(|k| a[**k].is_string()).count();
            (n, a["front"].is_string(), -id)
        })
        .map(|(id, _)| *id);
    let mut out = HashMap::new();
    for kind in KINDS {
        let from_best = arts
            .iter()
            .filter(|(id, _)| Some(*id) == best)
            .find_map(|(id, a)| a[kind].as_str().map(|p| (*id, p.to_string())));
        let any = || {
            arts.iter()
                .find_map(|(id, a)| a[kind].as_str().map(|p| (*id, p.to_string())))
        };
        if let Some(v) = from_best.or_else(any) {
            out.insert(kind, v);
        }
    }
    out
}

fn dir(app: &Shared) -> PathBuf {
    app.paths.art().join("sets")
}

fn file_name(group_key: &str, kind: &str) -> String {
    // group keys are "slug:name:…": keep a short stable hash as the file name.
    let h = sha1_smol::Sha1::from(group_key.as_bytes()).digest().to_string();
    format!("{}-{kind}", &h[..16])
}

/// Trims the white or transparent margins scans often carry, at most 6% per side. Colored edges
/// are artwork (a console band, a dark header) and are never trimmed.
fn trim(img: &DynamicImage) -> DynamicImage {
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    if w < 16 || h < 16 {
        return img.clone();
    }
    let corner = *rgba.get_pixel(0, 0);
    let transparent = corner[3] < 16;
    if !transparent && !(0..3).all(|i| corner[i] >= 232) {
        return img.clone();
    }
    let close = |p: &Rgba<u8>| {
        if transparent {
            p[3] < 16
        } else {
            p[3] > 200 && (0..3).all(|i| p[i] >= 228)
        }
    };
    let row_uniform = |y: u32| (0..w).step_by(2).all(|x| close(rgba.get_pixel(x, y)));
    let col_uniform = |x: u32| (0..h).step_by(2).all(|y| close(rgba.get_pixel(x, y)));
    let (mx, my) = (w * 6 / 100, h * 6 / 100);
    let mut top = 0;
    while top < my && row_uniform(top) {
        top += 1;
    }
    let mut bottom = 0;
    while bottom < my && row_uniform(h - 1 - bottom) {
        bottom += 1;
    }
    let mut left = 0;
    while left < mx && col_uniform(left) {
        left += 1;
    }
    let mut right = 0;
    while right < mx && col_uniform(w - 1 - right) {
        right += 1;
    }
    if top + bottom + left + right == 0 {
        return img.clone();
    }
    img.crop_imm(left, top, w - left - right, h - top - bottom)
}

/// Cleans a downloaded image and writes it; returns (path, width, height).
pub fn store(app: &Shared, group_key: &str, kind: &str, bytes: &[u8]) -> Result<(PathBuf, u32, u32), String> {
    let img = decode(bytes)?;
    let img = if kind == "logo" || kind == "physical" { img } else { trim(&img) };
    finish(app, group_key, kind, img)
}

/// Decodes an image from the network, refusing absurd sizes before decoding (memory bombs).
pub fn decode(bytes: &[u8]) -> Result<DynamicImage, String> {
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| format!("unreadable image ({e})"))?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(12_000);
    limits.max_image_height = Some(12_000);
    limits.max_alloc = Some(256 << 20);
    reader.limits(limits);
    reader.decode().map_err(|e| format!("unreadable image ({e})"))
}

fn finish(app: &Shared, group_key: &str, kind: &str, mut img: DynamicImage) -> Result<(PathBuf, u32, u32), String> {
    if kind == "side" && img.width() > img.height() {
        img = img.rotate270();
    }
    let cap = if kind == "logo" { 900 } else { 1000 };
    if img.width().max(img.height()) > cap {
        img = img.resize(cap, cap, image::imageops::FilterType::Lanczos3);
    }
    let (w, h) = img.dimensions();
    let opaque = BOX.contains(&kind) || kind == "fanart";
    let d = dir(app);
    std::fs::create_dir_all(&d).map_err(|e| e.to_string())?;
    let path = d.join(format!("{}.{}", file_name(group_key, kind), if opaque { "jpg" } else { "png" }));
    let tmp = path.with_extension("tmp");
    let r = if opaque {
        let mut f = std::io::BufWriter::new(std::fs::File::create(&tmp).map_err(|e| e.to_string())?);
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut f, 90)
            .encode_image(&img.to_rgb8())
            .map_err(|e| e.to_string())
    } else {
        img.save_with_format(&tmp, ImageFormat::Png).map_err(|e| e.to_string())
    };
    r.and_then(|_| std::fs::rename(&tmp, &path).map_err(|e| e.to_string()))?;
    Ok((path, w, h))
}

/// Fetches one kind for a group if it is missing or its source changed.
pub fn ensure(app: &Shared, client: &crate::romm::Client, group_key: &str, kind: &str, src: &(i64, String)) -> Result<(), String> {
    let stamp = format!("{}|{}", src.0, src.1);
    if let Some(m) = app.db.media(group_key, kind) {
        // ScreenScraper's copy (Borne's own access) takes precedence over RomM's.
        let ss = m.stamp.starts_with("ss|");
        if (ss || m.stamp == stamp) && std::path::Path::new(&m.path).is_file() {
            return Ok(());
        }
    }
    let bytes = client.fetch_bytes(&src.1, 25 * 1024 * 1024).map_err(|e| e.to_string())?;
    if !crate::catalog::looks_like_image(&bytes) {
        return Err("not an image".into());
    }
    let (path, w, h) = store(app, group_key, kind, &bytes)?;
    app.db.set_media(group_key, kind, &path.to_string_lossy(), w, h, &stamp);
    Ok(())
}

/// After a sync: fetches the media of every game, 4 at a time. Missing ones are retried at the
/// next sync; a changed source in RomM is fetched again.
pub fn prefetch(app: &Shared, client: &crate::romm::Client) {
    let mut jobs: Vec<(String, &'static str, (i64, String))> = vec![];
    for key in app.db.group_keys() {
        for (kind, src) in sources(app, &key) {
            let stamp = format!("{}|{}", src.0, src.1);
            let fresh = app
                .db
                .media(&key, kind)
                .map(|m| (m.stamp == stamp || m.stamp.starts_with("ss|")) && std::path::Path::new(&m.path).is_file())
                .unwrap_or(false);
            if !fresh {
                jobs.push((key.clone(), kind, src));
            }
        }
    }
    if jobs.is_empty() {
        return;
    }
    let total = jobs.len();
    app.sync.lock().unwrap().media_pending = total;
    app.emit(json!({ "type": "sync", "sync": app.sync.lock().unwrap().clone() }));
    let queue = Arc::new(Mutex::new(jobs));
    let failed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut handles = vec![];
    for _ in 0..4 {
        let (queue, app, client, failed) = (queue.clone(), app.clone(), client.clone(), failed.clone());
        handles.push(std::thread::spawn(move || loop {
            let Some((key, kind, src)) = queue.lock().unwrap().pop() else { break };
            if let Err(e) = ensure(&app, &client, &key, kind, &src) {
                failed.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                app.db.log("media", &format!("{kind} of {key}: {e}"));
            }
            let left = {
                let mut s = app.sync.lock().unwrap();
                s.media_pending = s.media_pending.saturating_sub(1);
                s.media_pending
            };
            if left % 25 == 0 {
                app.emit(json!({ "type": "library" }));
                app.emit(json!({ "type": "sync", "sync": app.sync.lock().unwrap().clone() }));
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let failed = failed.load(std::sync::atomic::Ordering::Relaxed);
    app.db.log("media", &format!("{} image(s) fetched, {failed} failed", total - failed));
    app.emit(json!({ "type": "library" }));
}

/// What the interface needs for a game: the kinds on disk and the pixel size of the case faces.
pub fn summary(app: &Shared, group_key: &str) -> Value {
    let mut kinds = vec![];
    let mut sizes = serde_json::Map::new();
    for m in app.db.media_of(group_key) {
        if std::path::Path::new(&m.path).is_file() {
            sizes.insert(m.kind.clone(), json!([m.w, m.h]));
            kinds.push(m.kind);
        }
    }
    json!({ "kinds": kinds, "sizes": sizes })
}

/// Per console: how many games have each kind on disk, and how many RomM has no scan for.
pub fn report(app: &Shared) -> Value {
    let mut per: HashMap<String, (String, usize, HashMap<String, usize>)> = HashMap::new();
    for (key, slug, name) in app.db.groups_with_platform() {
        let e = per.entry(slug).or_insert((name, 0, HashMap::new()));
        e.1 += 1;
        for m in app.db.media_of(&key) {
            *e.2.entry(m.kind).or_default() += 1;
        }
    }
    let mut out: Vec<Value> = per
        .into_iter()
        .map(|(slug, (name, games, counts))| {
            json!({ "platform": slug, "name": name, "games": games, "have": counts })
        })
        .collect();
    out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    json!({ "kinds": KINDS, "platforms": out })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::RgbaImage;

    #[test]
    fn trims_uniform_borders_only() {
        let mut img = RgbaImage::from_pixel(100, 200, Rgba([255, 255, 255, 255]));
        for y in 10..190 {
            for x in 5..95 {
                img.put_pixel(x, y, Rgba([200, 20, 20, 255]));
            }
        }
        let t = trim(&DynamicImage::ImageRgba8(img));
        assert_eq!(t.dimensions(), (90, 180));
        // An image with no border is left alone.
        let plain = RgbaImage::from_pixel(50, 50, Rgba([10, 10, 10, 255]));
        let mut p = plain.clone();
        p.put_pixel(24, 0, Rgba([250, 0, 0, 255]));
        p.put_pixel(0, 24, Rgba([250, 0, 0, 255]));
        p.put_pixel(49, 24, Rgba([250, 0, 0, 255]));
        p.put_pixel(24, 49, Rgba([250, 0, 0, 255]));
        assert_eq!(trim(&DynamicImage::ImageRgba8(p)).dimensions(), (50, 50));
        // A colored band at the edge is artwork, not a margin.
        let mut band = RgbaImage::from_pixel(60, 100, Rgba([30, 40, 120, 255]));
        for y in 0..5 {
            for x in 0..60 {
                band.put_pixel(x, y, Rgba([200, 20, 30, 255]));
            }
        }
        assert_eq!(trim(&DynamicImage::ImageRgba8(band)).dimensions(), (60, 100));
    }
}
