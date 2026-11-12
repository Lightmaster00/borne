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
/// are artwork (a console band, a dark header) and are never trimmed. A white margin is a scanner's
/// only when it runs all round the picture: white at the top alone is a white case's own band (Wii,
/// 3DS) and stays.
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
    if !transparent && (top == 0 || bottom == 0 || left == 0 || right == 0) {
        return img.clone();
    }
    if top + bottom + left + right == 0 {
        return img.clone();
    }
    img.crop_imm(left, top, w - left - right, h - top - bottom)
}

/// Cleans a downloaded image and writes it; returns (path, width, height).
pub fn store(app: &Shared, group_key: &str, kind: &str, bytes: &[u8]) -> Result<(PathBuf, u32, u32), String> {
    let img = decode(bytes)?;
    let mut img = if matches!(kind, "logo" | "logo-mono" | "physical" | "steamgrid" | "marquee" | "fanart") { img } else { trim(&img) };
    if kind == "front" && cd_case(group_key) {
        img = cut_hinge(&img);
    }
    finish(app, group_key, kind, img)
}

/// Consoles whose front scans may show the jewel case's hinge (PlayStation). Saturn and the
/// others keep their scans whole: their covers carry a band of their own on the left.
pub fn cd_case(group_key: &str) -> bool {
    matches!(group_key.split(':').next(), Some("psx" | "ps"))
}

/// A jewel case scan with the case's hinge on its left: the hinge cut, the cover insert kept whole
/// (with the console's band, "PlayStation" and the like, on its left). The hinge is the run of
/// columns from the left edge that do not change from top to bottom (moulded ridges run straight
/// down) and are light or ridged (changing from one column to the next); it stops at the first
/// column carrying a logo or text, or at the insert's flat black band, which is never cut. The hinge's pins at the very top and bottom are not
/// read, and at most 18 % is cut.
pub fn cut_hinge(img: &DynamicImage) -> DynamicImage {
    let g = img.to_luma8();
    let (w, h) = (g.width(), g.height());
    if w < 40 || h < 40 || (w as f64) < h as f64 * 1.02 {
        return img.clone(); // a square insert (or narrower): no hinge
    }
    let (top, bottom) = (h * 6 / 100, h * 94 / 100);
    let step = ((bottom - top) / 120).max(1);
    let max = w * 18 / 100;
    // Each column's mean and spread from top to bottom.
    let stats: Vec<(f64, f64)> = (0..(max + 3).min(w))
        .map(|x| {
            let vals: Vec<f64> = (top..bottom).step_by(step as usize).map(|y| g.get_pixel(x, y)[0] as f64).collect();
            let mean = vals.iter().sum::<f64>() / vals.len() as f64;
            let var = vals.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / vals.len() as f64;
            (mean, var.sqrt())
        })
        .collect();
    // Ridged: the columns around change from one to the next (moulded plastic), unlike a flat band.
    let ridged = |x: usize| -> bool {
        let lo = x.saturating_sub(2);
        let hi = (x + 2).min(stats.len() - 2);
        (lo..=hi).any(|k| (stats[k + 1].0 - stats[k].0).abs() > 6.0)
    };
    let hinge = |x: usize| -> bool { stats[x].1 < 9.0 && (stats[x].0 >= 40.0 || ridged(x)) };
    let mut x = 0;
    while x < max as usize && hinge(x) {
        x += 1;
    }
    if x < (w / 50) as usize {
        return img.clone();
    }
    img.crop_imm(x as u32, 0, w - x as u32, h)
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
    // Pictures shown full screen keep a screen's width.
    let cap = match kind {
        "logo" | "logo-mono" => 900,
        "steamgrid" | "marquee" | "fanart" | "photo" => 1920,
        _ => 1000,
    };
    if img.width().max(img.height()) > cap {
        img = img.resize(cap, cap, image::imageops::FilterType::Lanczos3);
    }
    let (w, h) = img.dimensions();
    let opaque = BOX.contains(&kind) || matches!(kind, "fanart" | "steamgrid" | "marquee");
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
    let mut spine = Value::Null;
    for m in app.db.media_of(group_key) {
        if std::path::Path::new(&m.path).is_file() {
            sizes.insert(m.kind.clone(), json!([m.w, m.h]));
            if m.kind == "side" {
                spine = dominant_color_cached(&m.path).map(Value::String).unwrap_or(Value::Null);
            }
            kinds.push(m.kind);
        }
    }
    json!({ "kinds": kinds, "sizes": sizes, "spine_color": spine })
}

/// The spine scan's dominant colour, read once per file version (kept in memory).
fn dominant_color_cached(path: &str) -> Option<String> {
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<HashMap<String, Option<String>>>> = OnceLock::new();
    let stamp = std::fs::metadata(path).and_then(|m| m.modified()).ok()?;
    let key = format!("{path}|{stamp:?}");
    let cache = CACHE.get_or_init(Default::default);
    if let Some(c) = cache.lock().ok()?.get(&key) {
        return c.clone();
    }
    let c = image::open(path).ok().and_then(|img| dominant_color(&img));
    cache.lock().ok()?.insert(key, c.clone());
    c
}

/// The colour most present in a picture, as "#rrggbb": pixels are sorted into coarse colour bins
/// (16 levels per channel), and the fullest bin's pixels are averaged. Transparent pixels are left out.
pub fn dominant_color(img: &DynamicImage) -> Option<String> {
    let small = img.thumbnail(96, 96).to_rgba8();
    let mut bins: HashMap<u32, (u64, [u64; 3])> = HashMap::new();
    for p in small.pixels() {
        if p[3] < 128 {
            continue;
        }
        let key = ((p[0] as u32 >> 4) << 8) | ((p[1] as u32 >> 4) << 4) | (p[2] as u32 >> 4);
        let e = bins.entry(key).or_insert((0, [0; 3]));
        e.0 += 1;
        for i in 0..3 {
            e.1[i] += p[i] as u64;
        }
    }
    let (n, sum) = bins.into_values().max_by_key(|(n, _)| *n)?;
    Some(format!("#{:02x}{:02x}{:02x}", sum[0] / n, sum[1] / n, sum[2] / n))
}

/// Per console: the proportions (width / height) of its case as its front scans show them, from
/// at least three scans, most common first. Every case of a console is drawn to them, so the
/// scans fit without being cut. A console sold in two kinds of case (a Japanese Saturn jewel case
/// and an American long box, a Super Nintendo box wide or upright) gets both shapes.
pub fn case_ratios(app: &Shared) -> HashMap<String, Vec<f64>> {
    let mut per: HashMap<String, Vec<f64>> = HashMap::new();
    for (key, slug, _) in app.db.groups_with_platform() {
        if let Some(m) = app.db.media(&key, "front").filter(|m| m.w > 0 && m.h > 0) {
            per.entry(slug).or_default().push(m.w as f64 / m.h as f64);
        }
    }
    per.into_iter().filter(|(_, v)| v.len() >= 3).map(|(slug, v)| (slug, case_shapes(v))).collect()
}

/// The one or two usual proportions among scans: split at the widest gap when it is larger than
/// 22 % and each side holds a fifth of them; the median of each side, the larger side first.
pub fn case_shapes(mut v: Vec<f64>) -> Vec<f64> {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median = |s: &[f64]| s[s.len() / 2];
    let min_side = (v.len() as f64 * 0.2).ceil() as usize;
    let split = (min_side.max(1)..=v.len().saturating_sub(min_side.max(1)))
        .filter(|&i| i > 0 && i < v.len())
        .max_by(|&a, &b| (v[a] / v[a - 1]).partial_cmp(&(v[b] / v[b - 1])).unwrap_or(std::cmp::Ordering::Equal))
        .filter(|&i| v[i] / v[i - 1] > 1.22);
    match split {
        Some(i) => {
            let (a, b) = v.split_at(i);
            if a.len() >= b.len() { vec![median(a), median(b)] } else { vec![median(b), median(a)] }
        }
        None => vec![median(&v)],
    }
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
    fn cuts_a_jewel_case_hinge_only() {
        // 140 x 120: a 16 px hinge of vertical ridges, then the insert (a band with a logo).
        let mut img = image::RgbImage::new(140, 120);
        for (x, y, p) in img.enumerate_pixels_mut() {
            *p = if x < 16 {
                if x % 4 == 0 { image::Rgb([200, 200, 205]) } else { image::Rgb([90, 90, 95]) }
            } else if x < 40 {
                if (30..50).contains(&y) { image::Rgb([255, 255, 255]) } else { image::Rgb([5, 5, 5]) }
            } else {
                image::Rgb([((x * 7 + y * 3) % 255) as u8, (y * 2 % 255) as u8, 80])
            };
        }
        let out = cut_hinge(&DynamicImage::ImageRgb8(img.clone()));
        assert_eq!((out.width(), out.height()), (124, 120));
        // A square insert is left alone.
        let sq = DynamicImage::ImageRgb8(image::imageops::crop_imm(&img, 16, 0, 120, 120).to_image());
        assert_eq!(cut_hinge(&sq).width(), 120);
        // A black band whose logo sits at the very top is not taken for a hinge.
        let mut band = image::RgbImage::from_pixel(130, 120, image::Rgb([6, 6, 6]));
        for x in 30..130 {
            for y in 0..120 {
                band.put_pixel(x, y, image::Rgb([((x * 5 + y) % 255) as u8, 60, 120]));
            }
        }
        assert_eq!(cut_hinge(&DynamicImage::ImageRgb8(band.clone())).width(), 130);
        // A dark hinge (black plastic with ridges) before that band is cut, the band kept.
        let mut dark = image::RgbImage::from_pixel(150, 120, image::Rgb([6, 6, 6]));
        for x in 0..150 {
            for y in 0..120 {
                let p = if x < 20 {
                    if x % 3 == 0 { [45, 45, 48] } else { [12, 12, 14] }
                } else if x < 50 {
                    [6, 6, 6]
                } else {
                    [((x * 5 + y) % 255) as u8, 60, 120]
                };
                dark.put_pixel(x, y, image::Rgb(p));
            }
        }
        let cut = cut_hinge(&DynamicImage::ImageRgb8(dark)).width();
        assert!((128..=131).contains(&cut), "{cut}");
    }

    #[test]
    fn case_shapes_one_or_two() {
        assert_eq!(case_shapes(vec![0.70, 0.71, 0.72, 0.69]), vec![0.71]);
        // Saturn: three Japanese jewel inserts, two American long boxes.
        assert_eq!(case_shapes(vec![1.0, 0.98, 1.02, 0.72, 0.73]), vec![1.0, 0.73]);
        // One odd scan does not make a shape.
        assert_eq!(case_shapes(vec![0.70, 0.71, 0.72, 0.69, 0.70, 0.71, 1.3]), vec![0.71]);
    }

    #[test]
    fn dominant_colour_is_the_most_present() {
        // A red spine with a white title on a third of it.
        let mut img = image::RgbImage::from_pixel(30, 300, image::Rgb([210, 20, 30]));
        for y in 100..200 {
            for x in 0..30 {
                img.put_pixel(x, y, image::Rgb([250, 250, 250]));
            }
        }
        assert_eq!(dominant_color(&DynamicImage::ImageRgb8(img)).as_deref(), Some("#d2141e"));
    }

    #[test]
    fn white_band_at_the_top_stays() {
        // A white case's band on top (with a grey logo further down), art below.
        let mut img = image::RgbImage::from_pixel(100, 140, image::Rgb([255, 255, 255]));
        for (_, y, p) in img.enumerate_pixels_mut() {
            if y >= 20 {
                *p = image::Rgb([40, 90, 160]);
            }
        }
        let out = trim(&DynamicImage::ImageRgb8(img));
        assert_eq!((out.width(), out.height()), (100, 140));
    }

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
