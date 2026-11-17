//! Switch packages compressed with nsz (.nsz) turned back into the .nsp they were made from.
//!
//! Eden (and the other emulators Borne starts) read .nsp only: given an .nsz they find no
//! Program-type NCA, since each NCA inside is stored as an .ncz. An .ncz is the NCA's first
//! 0x4000 bytes as they were (its encrypted header), then a list of its sections (offset, size,
//! encryption, key, counter), then the rest of the NCA decrypted and compressed with zstd, as one
//! stream or in blocks ("NCZBLOCK"). Unpacked, each section is encrypted again with its own key
//! (AES-128-CTR), which gives back the NCA byte for byte, so its hashes in the package hold.

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use aes::cipher::{KeyIvInit, StreamCipher, StreamCipherSeek};

type Ctr = ctr::Ctr128BE<aes::Aes128>;

const HEADER: u64 = 0x4000;

/// A file inside a PFS0 archive: its name and where its bytes are in the archive.
struct Entry {
    name: String,
    start: u64,
    size: u64,
}

fn u32le(b: &[u8]) -> u32 {
    u32::from_le_bytes(b[..4].try_into().unwrap())
}
fn u64le(b: &[u8]) -> u64 {
    u64::from_le_bytes(b[..8].try_into().unwrap())
}

fn entries(f: &mut std::fs::File) -> Result<Vec<Entry>, String> {
    let mut head = [0u8; 16];
    f.seek(SeekFrom::Start(0)).and_then(|_| f.read_exact(&mut head)).map_err(|e| e.to_string())?;
    if &head[..4] != b"PFS0" {
        return Err("this is not a Switch package (PFS0 expected)".into());
    }
    let (count, strings) = (u32le(&head[4..]) as usize, u32le(&head[8..]) as usize);
    if count > 10_000 || strings > 1 << 20 {
        return Err("the package's header is damaged".into());
    }
    let mut table = vec![0u8; count * 0x18 + strings];
    f.read_exact(&mut table).map_err(|e| format!("the package's header is damaged: {e}"))?;
    let data = 16 + table.len() as u64;
    let names = &table[count * 0x18..];
    (0..count)
        .map(|i| {
            let e = &table[i * 0x18..];
            let at = u32le(&e[16..]) as usize;
            let raw = names.get(at..).ok_or("the package's header is damaged")?;
            let end = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
            Ok(Entry { name: String::from_utf8_lossy(&raw[..end]).into_owned(), start: data + u64le(e), size: u64le(&e[8..]) })
        })
        .collect()
}

struct Section {
    offset: u64,
    size: u64,
    crypto: u64,
    key: [u8; 16],
    counter: [u8; 16],
}

/// Reads up to `len` bytes of `r`, limited to an entry of the archive.
struct Part<'a> {
    f: &'a mut std::fs::File,
    left: u64,
}
impl Read for Part<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.left == 0 {
            return Ok(0);
        }
        let n = (buf.len() as u64).min(self.left) as usize;
        let n = self.f.read(&mut buf[..n])?;
        self.left -= n as u64;
        Ok(n)
    }
}

/// An .ncz read: the NCA's header, its sections, its size once unpacked, and where its compressed
/// data starts.
struct Ncz {
    header: Vec<u8>,
    sections: Vec<Section>,
    size: u64,
    /// Block compression: block size and each block's compressed size.
    blocks: Option<(u64, Vec<u32>)>,
    data: u64,
}

fn read_ncz(f: &mut std::fs::File, e: &Entry) -> Result<Ncz, String> {
    let bad = |what: &str| format!("{}: {what}", e.name);
    if e.size < HEADER + 16 {
        return Err(bad("too small for an NCZ"));
    }
    f.seek(SeekFrom::Start(e.start)).map_err(|x| x.to_string())?;
    let mut header = vec![0u8; HEADER as usize];
    f.read_exact(&mut header).map_err(|x| bad(&x.to_string()))?;
    let mut h = [0u8; 16];
    f.read_exact(&mut h).map_err(|x| bad(&x.to_string()))?;
    if &h[..8] != b"NCZSECTN" {
        return Err(bad("not an NCZ (its section list is missing)"));
    }
    let count = u64le(&h[8..]);
    if count == 0 || count > 64 {
        return Err(bad("its section list is damaged"));
    }
    let mut sections = vec![];
    for _ in 0..count {
        let mut s = [0u8; 0x40];
        f.read_exact(&mut s).map_err(|x| bad(&x.to_string()))?;
        sections.push(Section {
            offset: u64le(&s),
            size: u64le(&s[8..]),
            crypto: u64le(&s[16..]),
            key: s[32..48].try_into().unwrap(),
            counter: s[48..64].try_into().unwrap(),
        });
    }
    sections.sort_by_key(|s| s.offset);
    let mut size = sections.iter().map(|s| s.offset + s.size).max().unwrap_or(HEADER).max(HEADER);
    let mut data = f.stream_position().map_err(|x| x.to_string())?;
    let mut magic = [0u8; 8];
    f.read_exact(&mut magic).map_err(|x| bad(&x.to_string()))?;
    let blocks = if &magic == b"NCZBLOCK" {
        let mut b = [0u8; 16];
        f.read_exact(&mut b).map_err(|x| bad(&x.to_string()))?;
        let exponent = b[3] as u32;
        let n = u32le(&b[4..]) as usize;
        if !(14..=32).contains(&exponent) || n > 1 << 24 {
            return Err(bad("its block list is damaged"));
        }
        size = HEADER + u64le(&b[8..]);
        let mut list = vec![0u8; n * 4];
        f.read_exact(&mut list).map_err(|x| bad(&x.to_string()))?;
        data = f.stream_position().map_err(|x| x.to_string())?;
        Some((1u64 << exponent, list.chunks(4).map(u32le).collect()))
    } else {
        None
    };
    Ok(Ncz { header, sections, size, blocks, data })
}

/// The NCA's data after its header (decrypted), as it comes out of the compressed stream or blocks.
fn plain<'a>(f: &'a mut std::fs::File, e: &Entry, z: &Ncz) -> Result<Box<dyn Read + 'a>, String> {
    f.seek(SeekFrom::Start(z.data)).map_err(|x| x.to_string())?;
    let left = e.start + e.size - z.data;
    let part = Part { f, left };
    match &z.blocks {
        None => Ok(Box::new(
            ruzstd::decoding::StreamingDecoder::new(part).map_err(|x| format!("{}: unreadable zstd data: {x}", e.name))?,
        )),
        Some((block, sizes)) => Ok(Box::new(Blocks {
            part,
            sizes: sizes.clone(),
            next: 0,
            block: *block,
            left: z.size - HEADER,
            buf: vec![],
            at: 0,
        })),
    }
}

/// NCZBLOCK data: each block compressed on its own, or stored as it is when compressing it did
/// not make it smaller.
struct Blocks<'a> {
    part: Part<'a>,
    sizes: Vec<u32>,
    next: usize,
    block: u64,
    left: u64,
    buf: Vec<u8>,
    at: usize,
}
impl Read for Blocks<'_> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.at == self.buf.len() {
            if self.next == self.sizes.len() || self.left == 0 {
                return Ok(0);
            }
            let want = self.block.min(self.left);
            let mut raw = vec![0u8; self.sizes[self.next] as usize];
            self.part.read_exact(&mut raw)?;
            self.next += 1;
            self.buf = if raw.len() as u64 >= want {
                raw.truncate(want as usize);
                raw
            } else {
                let mut d = vec![];
                ruzstd::decoding::StreamingDecoder::new(&raw[..])
                    .map_err(|e| std::io::Error::other(e.to_string()))?
                    .read_to_end(&mut d)?;
                d.truncate(want as usize);
                d
            };
            self.left -= self.buf.len() as u64;
            self.at = 0;
        }
        let n = out.len().min(self.buf.len() - self.at);
        out[..n].copy_from_slice(&self.buf[self.at..self.at + n]);
        self.at += n;
        Ok(n)
    }
}

/// Copies `len` bytes from `src` to `dst`, encrypted with `cipher` when given.
fn copy(
    src: &mut dyn Read,
    dst: &mut impl Write,
    mut len: u64,
    mut cipher: Option<&mut Ctr>,
    flag: &AtomicBool,
    name: &str,
) -> Result<(), String> {
    let mut buf = vec![0u8; 1 << 20];
    while len > 0 {
        if flag.load(Ordering::SeqCst) {
            return Err(CANCELLED.into());
        }
        let n = (buf.len() as u64).min(len) as usize;
        src.read_exact(&mut buf[..n]).map_err(|e| format!("{name}: its data ends too early ({e})"))?;
        if let Some(c) = cipher.as_deref_mut() {
            c.apply_keystream(&mut buf[..n]);
        }
        dst.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        len -= n as u64;
    }
    Ok(())
}

pub const CANCELLED: &str = "cancelled";

/// Writes the NCA an .ncz was made from.
fn unpack_ncz(f: &mut std::fs::File, e: &Entry, z: &Ncz, out: &mut impl Write, flag: &AtomicBool) -> Result<(), String> {
    out.write_all(&z.header).map_err(|x| x.to_string())?;
    let mut src = plain(f, e, z)?;
    let mut pos = HEADER;
    for s in &z.sections {
        let end = s.offset + s.size;
        if end <= pos {
            continue;
        }
        let start = s.offset.max(pos);
        if start > pos {
            copy(&mut src, out, start - pos, None, flag, &e.name)?;
        }
        if s.crypto == 3 || s.crypto == 4 {
            let mut iv = [0u8; 16];
            iv[..8].copy_from_slice(&s.counter[..8]);
            let mut c = Ctr::new(&s.key.into(), &iv.into());
            c.seek(start);
            copy(&mut src, out, end - start, Some(&mut c), flag, &e.name)?;
        } else {
            copy(&mut src, out, end - start, None, flag, &e.name)?;
        }
        pos = end;
    }
    if z.size > pos {
        copy(&mut src, out, z.size - pos, None, flag, &e.name)?;
    }
    Ok(())
}

fn is_ncz(name: &str) -> bool {
    name.to_lowercase().ends_with(".ncz")
}

/// Writes `nsp`, the package `nsz` was made from (written beside it first, then renamed).
pub fn to_nsp(nsz: &Path, nsp: &Path, flag: &AtomicBool) -> Result<(), String> {
    let mut f = std::fs::File::open(nsz).map_err(|e| format!("{}: {e}", nsz.display()))?;
    let list = entries(&mut f)?;
    // Each file's size in the .nsp: an .ncz becomes the .nca it was made from.
    let mut sizes = vec![];
    let mut nczs = vec![];
    for e in &list {
        if is_ncz(&e.name) {
            let z = read_ncz(&mut f, e)?;
            sizes.push(z.size);
            nczs.push(Some(z));
        } else {
            sizes.push(e.size);
            nczs.push(None);
        }
    }
    let names: Vec<String> =
        list.iter().map(|e| if is_ncz(&e.name) { format!("{}.nca", &e.name[..e.name.len() - 4]) } else { e.name.clone() }).collect();
    let mut strings = vec![];
    let mut at = vec![];
    for n in &names {
        at.push(strings.len() as u32);
        strings.extend_from_slice(n.as_bytes());
        strings.push(0);
    }
    // The header padded to 0x20 bytes, as packages are made.
    while (16 + list.len() * 0x18 + strings.len()) % 0x20 != 0 {
        strings.push(0);
    }
    let part = nsp.with_extension("nsp.part");
    let file = std::fs::File::create(&part).map_err(|e| format!("{}: {e}", part.display()))?;
    let mut out = std::io::BufWriter::with_capacity(1 << 20, file);
    let r = (|| {
        let mut head = b"PFS0".to_vec();
        head.extend_from_slice(&(list.len() as u32).to_le_bytes());
        head.extend_from_slice(&(strings.len() as u32).to_le_bytes());
        head.extend_from_slice(&0u32.to_le_bytes());
        let mut offset = 0u64;
        for (i, size) in sizes.iter().enumerate() {
            head.extend_from_slice(&offset.to_le_bytes());
            head.extend_from_slice(&size.to_le_bytes());
            head.extend_from_slice(&at[i].to_le_bytes());
            head.extend_from_slice(&0u32.to_le_bytes());
            offset += size;
        }
        head.extend_from_slice(&strings);
        out.write_all(&head).map_err(|e| e.to_string())?;
        for (e, z) in list.iter().zip(&nczs) {
            match z {
                Some(z) => unpack_ncz(&mut f, e, z, &mut out, flag)?,
                None => {
                    f.seek(SeekFrom::Start(e.start)).map_err(|x| x.to_string())?;
                    copy(&mut Part { f: &mut f, left: e.size }, &mut out, e.size, None, flag, &e.name)?;
                }
            }
        }
        out.flush().map_err(|e| e.to_string())?;
        drop(out);
        std::fs::rename(&part, nsp).map_err(|e| e.to_string())
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    r
}

fn is_nsz(p: &Path) -> bool {
    p.is_file() && p.extension().map(|e| e.eq_ignore_ascii_case("nsz")).unwrap_or(false)
}

/// The .nsz packages in `dir` and the folders below it (two levels: RomM's update/ and dlc/).
pub fn found(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![(dir.to_path_buf(), 0)];
    while let Some((d, depth)) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            if is_nsz(&p) {
                out.push(p);
            } else if depth < 2 && p.is_dir() {
                stack.push((p, depth + 1));
            }
        }
    }
    out.sort();
    out
}

/// Each .nsz in `dir` (and below) replaced with its .nsp; returns the packages made, as
/// (from, to).
pub fn unpack_in_place(dir: &Path, flag: &AtomicBool) -> Result<Vec<(PathBuf, PathBuf)>, String> {
    let mut done = vec![];
    for nsz in found(dir) {
        let nsp = nsz.with_extension("nsp");
        to_nsp(&nsz, &nsp, flag)?;
        let _ = std::fs::remove_file(&nsz);
        done.push((nsz, nsp));
    }
    Ok(done)
}

/// A folder of packages that cannot be written (played from RomM through the mount): its .nsz
/// unpacked into `cache`, its other packages linked there; returns the folder to give.
pub fn unpack_into(dir: &Path, cache: &Path, flag: &AtomicBool) -> Result<PathBuf, String> {
    std::fs::create_dir_all(cache).map_err(|e| e.to_string())?;
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        let Some(name) = p.file_name() else { continue };
        if is_nsz(&p) {
            let nsp = cache.join(Path::new(name).with_extension("nsp"));
            if !nsp.is_file() {
                to_nsp(&p, &nsp, flag)?;
            }
        } else if p.is_file() {
            let link = cache.join(name);
            if std::fs::symlink_metadata(&link).is_err() {
                let _ = std::os::unix::fs::symlink(&p, &link);
            }
        }
    }
    Ok(cache.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pfs0(files: &[(&str, Vec<u8>)]) -> Vec<u8> {
        let mut strings = vec![];
        let mut at = vec![];
        for (n, _) in files {
            at.push(strings.len() as u32);
            strings.extend_from_slice(n.as_bytes());
            strings.push(0);
        }
        let mut v = b"PFS0".to_vec();
        v.extend_from_slice(&(files.len() as u32).to_le_bytes());
        v.extend_from_slice(&(strings.len() as u32).to_le_bytes());
        v.extend_from_slice(&0u32.to_le_bytes());
        let mut off = 0u64;
        for (i, (_, d)) in files.iter().enumerate() {
            v.extend_from_slice(&off.to_le_bytes());
            v.extend_from_slice(&(d.len() as u64).to_le_bytes());
            v.extend_from_slice(&at[i].to_le_bytes());
            v.extend_from_slice(&0u32.to_le_bytes());
            off += d.len() as u64;
        }
        v.extend_from_slice(&strings);
        for (_, d) in files {
            v.extend_from_slice(d);
        }
        v
    }

    /// The smallest valid zstd frame holding `data` as one raw block.
    fn zstd_raw(data: &[u8]) -> Vec<u8> {
        let mut v = vec![0x28, 0xB5, 0x2F, 0xFD];
        // Frame header: single segment, 4-byte content size.
        v.push(0b1010_0000);
        v.extend_from_slice(&(data.len() as u32).to_le_bytes());
        for (i, chunk) in data.chunks(1 << 16).enumerate() {
            let last = (i + 1) * (1 << 16) >= data.len();
            let h = ((chunk.len() as u32) << 3) | u32::from(last); // raw block
            v.extend_from_slice(&h.to_le_bytes()[..3]);
            v.extend_from_slice(chunk);
        }
        v
    }

    #[test]
    fn an_nsz_becomes_the_nsp_it_was_made_from() {
        // The original NCA: a header, a plain section and an encrypted one.
        let size = 0x4000 + 0x2000 + 0x3000;
        let plain: Vec<u8> = (0..size).map(|i| (i * 7 % 251) as u8).collect();
        let key = [0x11u8; 16];
        let mut counter = [0u8; 16];
        counter[..8].copy_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        let mut nca = plain.clone();
        let mut iv = [0u8; 16];
        iv[..8].copy_from_slice(&counter[..8]);
        let mut c = Ctr::new(&key.into(), &iv.into());
        c.seek(0x6000u64);
        c.apply_keystream(&mut nca[0x6000..]);

        let mut ncz = nca[..0x4000].to_vec();
        ncz.extend_from_slice(b"NCZSECTN");
        ncz.extend_from_slice(&2u64.to_le_bytes());
        for (off, len, crypto) in [(0x4000u64, 0x2000u64, 1u64), (0x6000, 0x3000, 3)] {
            ncz.extend_from_slice(&off.to_le_bytes());
            ncz.extend_from_slice(&len.to_le_bytes());
            ncz.extend_from_slice(&crypto.to_le_bytes());
            ncz.extend_from_slice(&0u64.to_le_bytes());
            ncz.extend_from_slice(&key);
            ncz.extend_from_slice(&counter);
        }
        ncz.extend_from_slice(&zstd_raw(&plain[0x4000..]));

        let d = std::env::temp_dir().join(format!("borne-nsz-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("update")).unwrap();
        let tik = vec![9u8; 0x2C0];
        std::fs::write(d.join("Game.nsz"), pfs0(&[("abcd.ncz", ncz.clone()), ("x.tik", tik.clone())])).unwrap();
        std::fs::write(d.join("update/Up.nsz"), pfs0(&[("ef01.ncz", ncz)])).unwrap();

        let made = unpack_in_place(&d, &AtomicBool::new(false)).unwrap();
        assert_eq!(made.len(), 2);
        let want = pfs0(&[("abcd.nca", nca.clone()), ("x.tik", tik)]);
        let got = std::fs::read(d.join("Game.nsp")).unwrap();
        // Same files, same bytes (the header may only differ by its padding).
        let mut f = std::fs::File::open(d.join("Game.nsp")).unwrap();
        let es = entries(&mut f).unwrap();
        assert_eq!(es.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["abcd.nca", "x.tik"]);
        let body = &got[es[0].start as usize..(es[0].start + es[0].size) as usize];
        assert!(body == &nca[..], "the NCA comes back byte for byte");
        assert_eq!(&got[got.len() - 0x2C0..], &want[want.len() - 0x2C0..]);
        assert!(!d.join("Game.nsz").exists() && d.join("update/Up.nsp").is_file());
        let _ = std::fs::remove_dir_all(d);
    }
}
