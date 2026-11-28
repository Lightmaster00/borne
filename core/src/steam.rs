//! Borne in Steam, as a non-Steam game: its entry, artwork and icon.
//!
//! - ChimeraOS (Chimera installed): a shortcut file in `~/.local/share/chimera/shortcuts/borne.yaml`;
//!   Chimera adds it to every Steam account when the Steam session starts. Written at each start
//!   of Borne (so it follows the program when it moves), unless the user removed Borne from there.
//! - Elsewhere (SteamOS desktop, any Linux with Steam): the entry is written into each account's
//!   `userdata/<id>/config/shortcuts.vdf` (binary VDF), only while Steam is closed (Steam rewrites
//!   that file when it quits), with its grid artwork. `borne --add-to-steam` does it from a
//!   terminal (install.sh runs it), Settings → Help from Borne.
//!
//! The artwork is Borne's own (resources/steam): grid, poster, hero, logo.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

fn data_home() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home().join(".local/share"))
}

/// Steam's own folder (native install, Flatpak on Linux, or Registry/Program Files on Windows).
fn steam_root() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::ffi::OsStringExt;
        use windows_sys::Win32::System::Registry::{HKEY_CURRENT_USER, KEY_READ, REG_SZ, RegCloseKey, RegOpenKeyExW, RegQueryValueExW};
        let sub: Vec<u16> = "Software\\Valve\\Steam\0".encode_utf16().collect();
        let val: Vec<u16> = "SteamPath\0".encode_utf16().collect();
        let mut key = std::ptr::null_mut();
        if unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, sub.as_ptr(), 0, KEY_READ, &mut key) } == 0 {
            let mut ty = 0u32;
            let mut bytes = 0u32;
            if unsafe { RegQueryValueExW(key, val.as_ptr(), std::ptr::null(), &mut ty, std::ptr::null_mut(), &mut bytes) } == 0
                && ty == REG_SZ
                && bytes > 2
            {
                let mut buf = vec![0u16; (bytes as usize) / 2];
                if unsafe { RegQueryValueExW(key, val.as_ptr(), std::ptr::null(), &mut ty, buf.as_mut_ptr() as *mut u8, &mut bytes) }
                    == 0
                {
                    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
                    let p = PathBuf::from(std::ffi::OsString::from_wide(&buf[..len]));
                    unsafe { RegCloseKey(key) };
                    if p.join("userdata").is_dir() {
                        return Some(p);
                    }
                }
            }
            unsafe { RegCloseKey(key) };
        }
        return [PathBuf::from(r"C:\Program Files (x86)\Steam"), PathBuf::from(r"C:\Program Files\Steam")]
            .into_iter()
            .find(|p| p.join("userdata").is_dir());
    }
    #[cfg(not(target_os = "windows"))]
    [data_home().join("Steam"), home().join(".steam/steam"), home().join(".var/app/com.valvesoftware.Steam/.local/share/Steam")]
        .into_iter()
        .find(|p| p.join("userdata").is_dir())
}

fn chimera_dir() -> PathBuf {
    data_home().join("chimera")
}

/// Chimera manages the Steam shortcuts here (ChimeraOS).
pub fn chimera() -> bool {
    chimera_dir().is_dir() || crate::emulators::which("chimera").is_some()
}

fn chimera_file() -> PathBuf {
    chimera_dir().join("shortcuts/borne.yaml")
}

/// What starts Borne: the package's `borne` script/executable (next to bin/), else this program.
pub fn launcher() -> PathBuf {
    let exe = std::env::current_exe().ok().and_then(|p| p.canonicalize().ok()).unwrap_or_else(|| PathBuf::from("borne"));
    if cfg!(target_os = "windows") {
        return exe;
    }
    let root = exe.parent().and_then(|b| b.parent()).map(Path::to_path_buf);
    root.map(|r| r.join("borne")).filter(|s| s.is_file()).unwrap_or(exe)
}

fn steam_running() -> bool {
    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
        };
        unsafe {
            let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snap == -1isize as _ {
                return false;
            }
            let mut pe: PROCESSENTRY32W = std::mem::zeroed();
            pe.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            let mut running = false;
            if Process32FirstW(snap, &mut pe) != 0 {
                loop {
                    let end = pe.szExeFile.iter().position(|&c| c == 0).unwrap_or(pe.szExeFile.len());
                    let name = String::from_utf16_lossy(&pe.szExeFile[..end]).to_ascii_lowercase();
                    if name == "steam.exe" || name == "steamwebhelper.exe" {
                        running = true;
                        break;
                    }
                    if Process32NextW(snap, &mut pe) == 0 {
                        break;
                    }
                }
            }
            CloseHandle(snap);
            return running;
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let Ok(dir) = std::fs::read_dir("/proc") else { return false };
        dir.flatten()
            .any(|e| std::fs::read_to_string(e.path().join("comm")).map(|c| matches!(c.trim(), "steam" | "steamwebhelper")).unwrap_or(false))
    }
}

/// The id Steam gives a non-Steam game (and its artwork files): CRC-32 of the program and name,
/// top bit set.
pub fn shortcut_id(exe: &str, name: &str) -> u32 {
    crc32fast::hash(format!("{exe}{name}").as_bytes()) | 0x8000_0000
}

// ---------- binary VDF (shortcuts.vdf) ----------

#[derive(Clone, Debug, PartialEq)]
pub enum Vdf {
    Map(Vec<(String, Vdf)>),
    Str(String),
    Int(u32),
    /// Other kinds kept as they are (type byte, raw value).
    Raw(u8, Vec<u8>),
}

fn cstr(b: &[u8], i: &mut usize) -> Option<String> {
    let end = b[*i..].iter().position(|&c| c == 0)? + *i;
    let s = String::from_utf8_lossy(&b[*i..end]).into_owned();
    *i = end + 1;
    Some(s)
}

fn parse_map(b: &[u8], i: &mut usize) -> Option<Vec<(String, Vdf)>> {
    let mut out = vec![];
    loop {
        let t = *b.get(*i)?;
        *i += 1;
        if t == 0x08 {
            return Some(out);
        }
        let key = cstr(b, i)?;
        let v = match t {
            0x00 => Vdf::Map(parse_map(b, i)?),
            0x01 => Vdf::Str(cstr(b, i)?),
            0x02 => {
                let v = u32::from_le_bytes(b.get(*i..*i + 4)?.try_into().ok()?);
                *i += 4;
                Vdf::Int(v)
            }
            0x03 | 0x07 => {
                let n = if t == 0x03 { 4 } else { 8 };
                let raw = b.get(*i..*i + n)?.to_vec();
                *i += n;
                Vdf::Raw(t, raw)
            }
            _ => return None,
        };
        out.push((key, v));
    }
}

/// Reads shortcuts.vdf: its top map ("shortcuts" → entries).
pub fn parse_vdf(b: &[u8]) -> Option<Vec<(String, Vdf)>> {
    let mut i = 0;
    let top = parse_map(b, &mut i)?;
    Some(top)
}

fn write_map(out: &mut Vec<u8>, m: &[(String, Vdf)]) {
    for (k, v) in m {
        let (t, body): (u8, Vec<u8>) = match v {
            Vdf::Map(m) => {
                let mut b = vec![];
                write_map(&mut b, m);
                (0x00, b)
            }
            Vdf::Str(s) => {
                let mut b = s.as_bytes().to_vec();
                b.push(0);
                (0x01, b)
            }
            Vdf::Int(n) => (0x02, n.to_le_bytes().to_vec()),
            Vdf::Raw(t, r) => (*t, r.clone()),
        };
        out.push(t);
        out.extend(k.as_bytes());
        out.push(0);
        out.extend(body);
    }
    out.push(0x08);
}

pub fn write_vdf(top: &[(String, Vdf)]) -> Vec<u8> {
    let mut out = vec![];
    write_map(&mut out, top);
    out
}

fn get<'a>(m: &'a [(String, Vdf)], key: &str) -> Option<&'a Vdf> {
    m.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v)
}

/// Borne's entry in an account's shortcuts (added, or brought up to date), the others kept.
pub fn with_borne(top: Option<Vec<(String, Vdf)>>, exe: &str, icon: &str) -> Vec<(String, Vdf)> {
    let mut top = top.unwrap_or_default();
    if get(&top, "shortcuts").is_none() {
        top = vec![("shortcuts".into(), Vdf::Map(vec![]))];
    }
    let quoted = format!("\"{exe}\"");
    let dir = Path::new(exe).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let entry = vec![
        ("appid".to_string(), Vdf::Int(shortcut_id(&quoted, "Borne"))),
        ("AppName".into(), Vdf::Str("Borne".into())),
        ("Exe".into(), Vdf::Str(quoted.clone())),
        ("StartDir".into(), Vdf::Str(format!("\"{dir}\""))),
        ("icon".into(), Vdf::Str(icon.into())),
        ("ShortcutPath".into(), Vdf::Str(String::new())),
        ("LaunchOptions".into(), Vdf::Str(String::new())),
        ("IsHidden".into(), Vdf::Int(0)),
        ("AllowDesktopConfig".into(), Vdf::Int(1)),
        ("AllowOverlay".into(), Vdf::Int(1)),
        ("OpenVR".into(), Vdf::Int(0)),
        ("Devkit".into(), Vdf::Int(0)),
        ("DevkitGameID".into(), Vdf::Str(String::new())),
        ("DevkitOverrideAppID".into(), Vdf::Int(0)),
        ("LastPlayTime".into(), Vdf::Int(0)),
        ("FlatpakAppID".into(), Vdf::Str(String::new())),
        ("tags".into(), Vdf::Map(vec![])),
    ];
    for (k, v) in top.iter_mut() {
        if !k.eq_ignore_ascii_case("shortcuts") {
            continue;
        }
        let Vdf::Map(list) = v else { continue };
        // Ours: named Borne, or starting a `borne` program (an older place).
        let ours = list.iter().position(|(_, e)| {
            let Vdf::Map(e) = e else { return false };
            let name = matches!(get(e, "AppName"), Some(Vdf::Str(n)) if n == "Borne");
            let prog = matches!(get(e, "Exe"), Some(Vdf::Str(x)) if {
                let p = x.trim_matches('"').to_ascii_lowercase();
                p.ends_with("/borne") || p.ends_with("\\borne.exe") || p.ends_with("/borne.exe")
            });
            name || prog
        });
        match ours {
            Some(i) => list[i].1 = Vdf::Map(entry.clone()),
            None => {
                let next = list.iter().filter_map(|(k, _)| k.parse::<usize>().ok()).max().map(|n| n + 1).unwrap_or(0);
                list.push((next.to_string(), Vdf::Map(entry.clone())));
            }
        }
    }
    top
}

/// The artwork of Borne's entry in an account's grid folder.
fn copy_art(resources: &Path, grid: &Path, id: u32) -> Result<(), String> {
    std::fs::create_dir_all(grid).map_err(|e| e.to_string())?;
    let art = resources.join("steam");
    for (src, dst) in [
        ("grid.png", format!("{id}.png")),
        ("poster.png", format!("{id}p.png")),
        ("hero.png", format!("{id}_hero.png")),
        ("logo.png", format!("{id}_logo.png")),
    ] {
        if art.join(src).is_file() {
            std::fs::copy(art.join(src), grid.join(dst)).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Chimera's shortcut file for Borne.
pub fn chimera_yaml(exe: &Path, resources: &Path) -> String {
    let q = |p: &Path| format!("'{}'", p.to_string_lossy().replace('\'', "''"));
    let art = resources.join("steam");
    let mut y = format!("name: Borne\ncmd: {}\ndir: {}\n", q(exe), q(exe.parent().unwrap_or(Path::new("/"))));
    for (k, f) in [("banner", "grid.png"), ("poster", "poster.png"), ("background", "hero.png"), ("logo", "logo.png")] {
        if art.join(f).is_file() {
            y.push_str(&format!("{k}: {}\n", q(&art.join(f))));
        }
    }
    let icon = resources.join("borne.png");
    if icon.is_file() {
        y.push_str(&format!("icon: {}\n", q(&icon)));
    }
    y.push_str("hidden: false\ntags:\n  - Borne\n");
    y
}

/// Adds Borne to Steam (or brings its entry up to date). Ok: what was done, for the user.
pub fn add(resources: &Path) -> Result<String, String> {
    let exe = launcher();
    if chimera() {
        let f = chimera_file();
        std::fs::create_dir_all(f.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(&f, chimera_yaml(&exe, resources)).map_err(|e| e.to_string())?;
        return Ok("chimera".into());
    }
    let root = steam_root().ok_or("Steam is not installed for this user")?;
    if steam_running() {
        return Err("close Steam first: it rewrites its shortcuts when it quits".into());
    }
    let icon = resources.join("borne.png").to_string_lossy().into_owned();
    let mut n = 0;
    for user in std::fs::read_dir(root.join("userdata")).map_err(|e| e.to_string())?.flatten() {
        let name = user.file_name().to_string_lossy().into_owned();
        if !name.chars().all(|c| c.is_ascii_digit()) || name == "0" {
            continue;
        }
        let config = user.path().join("config");
        let file = config.join("shortcuts.vdf");
        let old = std::fs::read(&file).ok();
        let parsed = match &old {
            Some(b) if !b.is_empty() => Some(parse_vdf(b).ok_or("Steam's shortcuts file could not be read")?),
            _ => None,
        };
        let top = with_borne(parsed, &exe.to_string_lossy(), &icon);
        std::fs::create_dir_all(&config).map_err(|e| e.to_string())?;
        if let Some(b) = &old {
            let _ = std::fs::write(config.join("shortcuts.vdf.borne-backup"), b);
        }
        let tmp = config.join("shortcuts.vdf.borne-new");
        std::fs::write(&tmp, write_vdf(&top)).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &file).map_err(|e| e.to_string())?;
        let id = shortcut_id(&format!("\"{}\"", exe.to_string_lossy()), "Borne");
        copy_art(resources, &config.join("grid"), id)?;
        n += 1;
    }
    if n == 0 {
        return Err("no Steam account on this computer yet: open Steam and sign in once".into());
    }
    Ok("steam".into())
}

/// Whether Borne is in Steam, and how it would be added.
pub fn status() -> Value {
    let exe = launcher();
    let chimera = chimera();
    let added = if chimera {
        chimera_file().is_file()
    } else {
        steam_root()
            .and_then(|r| std::fs::read_dir(r.join("userdata")).ok())
            .map(|d| {
                d.flatten().any(|u| {
                    std::fs::read(u.path().join("config/shortcuts.vdf"))
                        .ok()
                        .and_then(|b| parse_vdf(&b))
                        .map(|top| {
                            matches!(get(&top, "shortcuts"), Some(Vdf::Map(l)) if l.iter().any(|(_, e)| matches!(e, Vdf::Map(e) if matches!(get(e, "AppName"), Some(Vdf::Str(n)) if n == "Borne"))))
                        })
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false)
    };
    json!({
        "available": (cfg!(target_os = "linux") || cfg!(target_os = "windows")) && (chimera || steam_root().is_some()),
        "chimera": chimera,
        "added": added,
        "steam_running": !chimera && steam_running(),
        "exe": exe.to_string_lossy(),
    })
}

/// At each start on ChimeraOS: Borne's shortcut kept pointing at this copy of Borne (unless the
/// user turned it off in Settings).
pub fn keep_up_to_date(app: &crate::state::Shared, resources: &Path) {
    if !cfg!(target_os = "linux") || !chimera() || app.db.setting("steam_shortcut").as_deref() == Some("off") {
        return;
    }
    let want = chimera_yaml(&launcher(), resources);
    if std::fs::read_to_string(chimera_file()).ok().as_deref() != Some(want.as_str()) {
        match add(resources) {
            Ok(_) => app.db.log("steam", "Borne's Steam shortcut written for Chimera (shown after the next Steam session start)"),
            Err(e) => app.db.log("steam", &format!("Steam shortcut not written: {e}")),
        }
    }
}

/// Removes Borne's ChimeraOS shortcut (and keeps it removed).
pub fn remove_chimera(app: &crate::state::Shared) {
    app.db.set_setting("steam_shortcut", "off");
    let _ = std::fs::remove_file(chimera_file());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcuts_vdf_round_trip_and_borne_entry() {
        // An account with one shortcut already.
        let other = vec![
            ("appid".to_string(), Vdf::Int(123)),
            ("AppName".into(), Vdf::Str("Other".into())),
            ("Exe".into(), Vdf::Str("\"/usr/bin/other\"".into())),
            ("LastPlayTime".into(), Vdf::Int(5)),
            ("tags".into(), Vdf::Map(vec![("0".into(), Vdf::Str("Fav".into()))])),
        ];
        let top = vec![("shortcuts".to_string(), Vdf::Map(vec![("0".into(), Vdf::Map(other.clone()))]))];
        let bytes = write_vdf(&top);
        assert_eq!(bytes[0], 0x00);
        assert_eq!(*bytes.last().unwrap(), 0x08);
        assert_eq!(parse_vdf(&bytes).unwrap(), top);

        let with = with_borne(parse_vdf(&bytes), "/home/u/.local/opt/Borne/borne", "/i.png");
        let Some(Vdf::Map(list)) = get(&with, "shortcuts") else { panic!() };
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].1, Vdf::Map(other), "the other shortcut is kept");
        assert_eq!(list[1].0, "1");
        // Again (Borne moved): the same entry is brought up to date, not doubled.
        let again = with_borne(Some(with.clone()), "/opt/Borne/borne", "/i.png");
        let Some(Vdf::Map(list)) = get(&again, "shortcuts") else { panic!() };
        assert_eq!(list.len(), 2);
        let Vdf::Map(e) = &list[1].1 else { panic!() };
        assert_eq!(get(e, "Exe"), Some(&Vdf::Str("\"/opt/Borne/borne\"".into())));
        assert_eq!(get(e, "appid"), Some(&Vdf::Int(shortcut_id("\"/opt/Borne/borne\"", "Borne"))));
        // A missing file: a new list.
        let fresh = with_borne(None, "/b/borne", "");
        assert!(matches!(get(&fresh, "shortcuts"), Some(Vdf::Map(l)) if l.len() == 1));
        assert!(shortcut_id("a", "b") & 0x8000_0000 != 0);
    }

    #[test]
    fn chimera_shortcut_file() {
        let y = chimera_yaml(Path::new("/home/gamer/.local/opt/Borne/borne"), Path::new("/nonexistent"));
        assert!(y.starts_with("name: Borne\ncmd: '/home/gamer/.local/opt/Borne/borne'\ndir: '/home/gamer/.local/opt/Borne'\n"), "{y}");
        assert!(y.contains("hidden: false"));
    }
}
