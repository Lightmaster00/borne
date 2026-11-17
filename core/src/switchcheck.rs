//! A Switch package (.nsp, .nsz) read before its game starts, with the player's own keys: each
//! content's header (NCA, encrypted with prod.keys' header_key, AES-128-XTS with Nintendo's
//! tweak) says what it is (the program, its metadata, its icons, data), whose it is (title ID)
//! and which master key opens it. The emulators only say "missing a Program-type NCA" for every
//! one of these failures; this says which: keys that cannot read the package at all, keys older
//! than the game, or a package holding no program (an update or a DLC given as the game).

use aes::cipher::KeyInit;
use aes::Aes128;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use xts_mode::Xts128;

/// Nintendo's XTS tweak: the sector number, big-endian.
fn get_nintendo_tweak(sector: u128) -> [u8; 16] {
    sector.to_be_bytes()
}

/// One content of the package.
#[derive(Debug, Clone, PartialEq)]
pub struct Content {
    pub name: String,
    /// "program", "meta", "control", "manual", "data", "publicdata"; "unreadable" when the keys
    /// do not open its header.
    pub kind: String,
    pub title_id: u64,
    /// The master key that opens it (0 for the first generations).
    pub master_key: u8,
}

/// What a package holds, as read with the keys.
#[derive(Debug, Clone, PartialEq)]
pub struct Package {
    pub contents: Vec<Content>,
}

/// The keys of a prod.keys file: name → bytes.
pub fn keys(text: &str) -> std::collections::HashMap<String, Vec<u8>> {
    text.lines()
        .filter_map(|l| {
            let (k, v) = l.split_once('=')?;
            let bytes = (0..v.trim().len() / 2)
                .map(|i| u8::from_str_radix(v.trim().get(i * 2..i * 2 + 2)?, 16).ok())
                .collect::<Option<Vec<u8>>>()?;
            Some((k.trim().to_lowercase(), bytes))
        })
        .collect()
}

/// The newest master key the keys hold (master_key_XX), if any.
pub fn newest_master_key(keys: &std::collections::HashMap<String, Vec<u8>>) -> Option<u8> {
    keys.keys().filter_map(|k| k.strip_prefix("master_key_").and_then(|h| u8::from_str_radix(h, 16).ok())).max()
}

/// The package's contents, read with `header_key` (32 bytes). None when the file is not a PFS0
/// package.
pub fn read(path: &Path, header_key: &[u8]) -> Option<Package> {
    let mut f = std::fs::File::open(path).ok()?;
    let mut head = [0u8; 16];
    f.read_exact(&mut head).ok()?;
    if &head[..4] != b"PFS0" {
        return None;
    }
    let count = u32::from_le_bytes(head[4..8].try_into().ok()?) as usize;
    let strings = u32::from_le_bytes(head[8..12].try_into().ok()?) as usize;
    if count == 0 || count > 4096 || strings > 1 << 20 {
        return None;
    }
    let mut rest = vec![0u8; count * 24 + strings];
    f.read_exact(&mut rest).ok()?;
    let data_start = 16 + rest.len() as u64;
    let table = &rest[count * 24..];
    let xts = (header_key.len() == 32)
        .then(|| {
            Xts128::<Aes128>::new(Aes128::new_from_slice(&header_key[..16]).ok()?, Aes128::new_from_slice(&header_key[16..]).ok()?).into()
        })
        .flatten();
    let mut contents = vec![];
    for i in 0..count {
        let e = &rest[i * 24..i * 24 + 24];
        let offset = u64::from_le_bytes(e[0..8].try_into().ok()?);
        let size = u64::from_le_bytes(e[8..16].try_into().ok()?);
        let at = u32::from_le_bytes(e[16..20].try_into().ok()?) as usize;
        let end = table.get(at..)?.iter().position(|b| *b == 0)? + at;
        let name = std::str::from_utf8(&table[at..end]).ok()?.to_string();
        let lower = name.to_lowercase();
        if !(lower.ends_with(".nca") || lower.ends_with(".ncz")) || size < 0xC00 {
            continue;
        }
        let mut h = vec![0u8; 0xC00];
        if f.seek(SeekFrom::Start(data_start + offset)).is_err() || f.read_exact(&mut h).is_err() {
            contents.push(Content { name, kind: "unreadable".into(), title_id: 0, master_key: 0 });
            continue;
        }
        let Some(x) = &xts else {
            contents.push(Content { name, kind: "unreadable".into(), title_id: 0, master_key: 0 });
            continue;
        };
        x.decrypt_area(&mut h, 0x200, 0, get_nintendo_tweak);
        if &h[0x200..0x203] != b"NCA" {
            contents.push(Content { name, kind: "unreadable".into(), title_id: 0, master_key: 0 });
            continue;
        }
        let kind = match h[0x205] {
            0 => "program",
            1 => "meta",
            2 => "control",
            3 => "manual",
            4 => "data",
            5 => "publicdata",
            _ => "unknown",
        };
        let generation = h[0x206].max(h[0x220]);
        contents.push(Content {
            name,
            kind: kind.into(),
            title_id: u64::from_le_bytes(h[0x210..0x218].try_into().ok()?),
            master_key: generation.saturating_sub(1),
        });
    }
    Some(Package { contents })
}

/// Before a Switch game starts: why its package cannot play with these keys, in the player's
/// words; None when it can (or when it cannot be told: not a package, no keys to read it with).
pub fn problem(path: &Path, prod_keys: &str) -> Option<String> {
    let keys = keys(prod_keys);
    let header = keys.get("header_key")?;
    let p = read(path, header)?;
    if p.contents.is_empty() {
        return None;
    }
    if p.contents.iter().all(|c| c.kind == "unreadable") {
        return Some("the Switch keys (prod.keys) cannot read this game: their header_key is wrong or damaged; take prod.keys again from your Switch".into());
    }
    let newest = newest_master_key(&keys).unwrap_or(0);
    if let Some(need) = p.contents.iter().filter(|c| c.kind != "unreadable").map(|c| c.master_key).max() {
        if need > newest {
            return Some(format!(
                "this game needs newer Switch keys (master key {need:02x}; yours stop at {newest:02x}): take prod.keys and the firmware again from a Switch updated since the game came out"
            ));
        }
    }
    // An update's program is a program too, under the update's title ID (ending in 800).
    let programs: Vec<&Content> = p.contents.iter().filter(|c| c.kind == "program").collect();
    if !programs.is_empty() && programs.iter().all(|c| c.title_id & 0xfff == 0x800) {
        return Some("this file holds an update, not the game itself: add the base game to this game on RomM".into());
    }
    if programs.is_empty() {
        let what = if p.contents.iter().any(|c| c.title_id & 0xfff == 0x800) {
            "an update"
        } else if p.contents.iter().any(|c| c.kind == "data" || c.kind == "publicdata") {
            "a DLC"
        } else {
            "no game"
        };
        return Some(format!("this file holds {what}, not the game itself: add the base game to this game on RomM"));
    }
    None
}

/// The package as the diagnostic report shows it.
pub fn describe(path: &Path, prod_keys: &str) -> String {
    let keys = keys(prod_keys);
    let Some(header) = keys.get("header_key") else { return "no header_key in prod.keys".into() };
    match read(path, header) {
        None => "not a PFS0 package".into(),
        Some(p) => p
            .contents
            .iter()
            .map(|c| format!("{} {} {:016x} mk{:02x}", c.name.chars().take(12).collect::<String>(), c.kind, c.title_id, c.master_key))
            .collect::<Vec<_>>()
            .join(" | "),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::KeyInit;

    /// A package with one NCA header of this kind, encrypted with `key`.
    fn package(key: &[u8; 32], kind: u8, title: u64, generation: u8) -> Vec<u8> {
        let mut h = vec![0u8; 0xC00];
        h[0x200..0x204].copy_from_slice(b"NCA3");
        h[0x205] = kind;
        h[0x220] = generation;
        h[0x210..0x218].copy_from_slice(&title.to_le_bytes());
        let x = Xts128::<Aes128>::new(Aes128::new_from_slice(&key[..16]).unwrap(), Aes128::new_from_slice(&key[16..]).unwrap());
        x.encrypt_area(&mut h, 0x200, 0, get_nintendo_tweak);
        let name = b"abcdef.nca\0";
        let mut v = b"PFS0".to_vec();
        v.extend(1u32.to_le_bytes());
        v.extend((name.len() as u32).to_le_bytes());
        v.extend(0u32.to_le_bytes());
        v.extend(0u64.to_le_bytes());
        v.extend((h.len() as u64).to_le_bytes());
        v.extend(0u32.to_le_bytes());
        v.extend(0u32.to_le_bytes());
        v.extend(name);
        v.extend(h);
        v
    }

    #[test]
    fn a_package_is_read_with_the_players_keys() {
        let key = [7u8; 32];
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        let prod = format!("header_key = {hex}\nmaster_key_00 = 00\nmaster_key_05 = 00\n");
        let d = tempfile::tempdir().unwrap();
        let write = |n: &str, v: Vec<u8>| {
            let p = d.path().join(n);
            std::fs::write(&p, v).unwrap();
            p
        };
        let game = write("game.nsp", package(&key, 0, 0x0100_0000_0000_1000, 3));
        assert_eq!(problem(&game, &prod), None);
        let newer = write("new.nsp", package(&key, 0, 0x0100_0000_0000_1000, 0x10));
        assert!(problem(&newer, &prod).unwrap().contains("needs newer Switch keys"));
        let update = write("upd.nsp", package(&key, 0, 0x0100_0000_0000_1800, 3));
        assert!(problem(&update, &prod).unwrap().contains("an update"));
        let dlc = write("dlc.nsp", package(&key, 4, 0x0100_0000_0000_1001, 3));
        assert!(problem(&dlc, &prod).unwrap().contains("a DLC"));
        let other = format!("header_key = {}\nmaster_key_05 = 00\n", "11".repeat(32));
        assert!(problem(&game, &other).unwrap().contains("cannot read this game"));
        assert_eq!(problem(&game, "no keys"), None, "nothing to read with: nothing said");
        assert!(describe(&game, &prod).contains("program 0100000000001000 mk02"));
    }
}
