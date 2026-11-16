//! Borne virtual mount: games played from RomM without a download.
//!
//! "Linking" a game puts it, and only it, in `<data>/mount/<platform>/<rom_id>/…`, a read-only
//! FUSE filesystem (no root needed). Nothing else of the catalog is exposed. Reads are served from
//! RomM on demand with Range requests and the active profile's token, so RomM's per-account
//! permissions apply, through a bounded disk cache of 4 MiB blocks (`<data>/cache/stream`).
//!
//! Linux only; elsewhere linking reports that the mount is unavailable.

use crate::downloads::{pick_main_of, relative_path};
use crate::state::Shared;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Mount state, shown in the status and on the game page.
static STATE: Mutex<MountState> = Mutex::new(MountState { mounted: false, error: None });

#[derive(Clone)]
struct MountState {
    mounted: bool,
    error: Option<String>,
}

pub fn status(app: &Shared) -> Value {
    let s = STATE.lock().unwrap_or_else(|e| e.into_inner()).clone();
    json!({
        "available": s.mounted,
        "path": app.paths.mount(),
        "error": s.error,
        "cache_limit_mb": cache_limit_mb(app),
    })
}

/// Whether games can be played from the network here: through the virtual mount on Linux; as
/// temporary copies elsewhere (macOS has no FUSE without a kernel extension).
pub fn available() -> bool {
    true
}

/// The answer of `link` where there is no virtual mount: the game is downloaded and kept as a
/// temporary copy, the least recently played ones removed past the cache limit.
pub const TEMPORARY: &str = "the game is downloaded to be played (temporary copy)";

fn temp_key(rom_id: i64) -> String {
    format!("netcache.{rom_id}")
}

/// A game downloaded to be played from the network (macOS): marked, with when it was last used.
pub fn mark_temporary(app: &Shared, rom_id: i64) {
    app.db.set_setting(&temp_key(rom_id), &crate::db::now().to_string());
}

pub fn clear_temporary(app: &Shared, rom_id: i64) {
    app.db.set_setting(&temp_key(rom_id), "");
}

pub fn is_temporary(app: &Shared, rom_id: i64) -> bool {
    app.db.setting(&temp_key(rom_id)).map(|v| !v.is_empty()).unwrap_or(false)
}

/// Removes the least recently used temporary copies until they fit the cache limit, never the
/// game being played nor `keep` (the one just downloaded).
pub fn evict_temporary(app: &Shared, keep: i64) {
    let limit = cache_limit_mb(app) * 1024 * 1024;
    let mut temps: Vec<(i64, i64, u64)> = app
        .db
        .local_games()
        .into_iter()
        .filter(|(id, ..)| is_temporary(app, *id))
        .map(|(id, dir, ..)| {
            let used = app.db.setting(&temp_key(id)).and_then(|v| v.parse().ok()).unwrap_or(0);
            (id, used, crate::downloads::dir_size(Path::new(&dir)))
        })
        .collect();
    let mut total: u64 = temps.iter().map(|t| t.2).sum();
    temps.sort_by_key(|t| t.1);
    for (id, _, size) in temps {
        if total <= limit {
            break;
        }
        if id == keep || crate::emulators::playing_rom() == Some(id) {
            continue;
        }
        if crate::downloads::delete_local(app, id).is_ok() {
            app.db.set_setting(&temp_key(id), "");
            total = total.saturating_sub(size);
            app.db.log("stream", &format!("temporary copy of game {id} removed (cache limit)"));
        }
    }
}

fn set_state(mounted: bool, error: Option<String>) {
    *STATE.lock().unwrap_or_else(|e| e.into_inner()) = MountState { mounted, error };
}

pub fn cache_limit_mb(app: &Shared) -> u64 {
    app.db.setting("stream_cache_mb").and_then(|v| v.parse().ok()).unwrap_or(20_480)
}

/// Exposes a game in the virtual mount. Returns the path of the file to launch.
/// The answer of `link` for a game stored compressed on RomM.
pub const COMPRESSED: &str = "the game is compressed on RomM: it is downloaded to be played";

pub fn link(app: &Shared, rom_id: i64) -> Result<PathBuf, String> {
    if !cfg!(target_os = "linux") {
        return Err(TEMPORARY.into());
    }
    if !STATE.lock().unwrap_or_else(|e| e.into_inner()).mounted {
        return Err(STATE.lock().unwrap_or_else(|e| e.into_inner()).error.clone().unwrap_or_else(|| "virtual mount unavailable".into()));
    }
    let game = app.db.game(rom_id).ok_or("unknown game")?;
    let client = app.client().ok_or("no paired profile or server offline")?;
    let detail = client.rom(rom_id).map_err(|e| e.to_string())?;
    let mut files = vec![];
    for f in detail.installable_files() {
        let rel = relative_path(&detail, f).ok_or_else(|| format!("file path refused: {}", f.full_path))?;
        files.push((f.id, rel.to_string_lossy().into_owned(), f.file_name.clone(), f.file_size_bytes));
    }
    if files.is_empty() {
        return Err("RomM lists no game file for this title".into());
    }
    let main =
        pick_main_of(files.iter().map(|(_, rel, _, size)| (*size as u64, PathBuf::from(rel))).collect()).ok_or("no game file found")?;
    // A compressed game cannot be handed to the emulator from the network: it is downloaded
    // (and extracted) instead, see emulators::play.
    if crate::downloads::extractable(&main) && !crate::downloads::keeps_archive(&game.platform_slug, &main) {
        return Err(COMPRESSED.into());
    }
    // RomM must be able to serve the game's file: asked directly, so that its own answer (a file
    // missing from its disk) is shown rather than an emulator failing on an unreadable file.
    if let Some((id, _, name, _)) = files.iter().find(|(_, rel, _, _)| Path::new(rel) == main) {
        client.fetch_range(*id, name, 0, 16).map_err(|e| e.to_string())?;
    }
    app.db.link_game(rom_id, &main.to_string_lossy(), &files);
    imp::refresh(app);
    app.db.log("stream", &format!("{} linked ({} file(s))", game.name, files.len()));
    Ok(app.paths.mount().join(&game.platform_slug).join(rom_id.to_string()).join(main))
}

pub fn unlink(app: &Shared, rom_id: i64) -> Result<(), String> {
    if !app.db.unlink_game(rom_id) {
        return Err("game not linked".into());
    }
    imp::refresh(app);
    imp::drop_cache(app, rom_id);
    app.db.log("stream", &format!("game {rom_id} unlinked"));
    Ok(())
}

pub fn start(app: &Shared) {
    imp::start(app);
}

/// Unmounts cleanly when Borne quits.
pub fn stop() {
    imp::stop();
}

#[cfg(not(target_os = "linux"))]
mod imp {
    use crate::state::Shared;
    pub fn start(_app: &Shared) {
        // No virtual mount: games are played from temporary copies (see TEMPORARY).
        super::set_state(true, None);
    }
    pub fn refresh(_app: &Shared) {}
    pub fn stop() {}
    pub fn drop_cache(_app: &Shared, _rom_id: i64) {}
}

#[cfg(target_os = "linux")]
mod imp {
    use crate::state::Shared;
    use fuser::{
        Errno, FileAttr, FileHandle, FileType, Filesystem, INodeNo, LockOwner, MountOption, OpenFlags, ReplyAttr, ReplyData,
        ReplyDirectory, ReplyEntry, Request,
    };
    use std::collections::{BTreeMap, HashMap};
    use std::ffi::OsStr;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, OnceLock, RwLock};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    const BLOCK: u64 = 4 * 1024 * 1024;
    const TTL: Duration = Duration::from_secs(1);
    const FILE_INO: u64 = 1 << 40;

    struct FileNode {
        file_id: i64,
        rom_id: i64,
        name: String,
        size: u64,
    }

    #[derive(Default)]
    struct Tree {
        dirs: HashMap<u64, BTreeMap<String, u64>>,
        parents: HashMap<u64, u64>,
        files: HashMap<u64, FileNode>,
        /// Directory path -> inode, kept across rebuilds so inodes stay stable.
        dir_ino: HashMap<String, u64>,
        next: u64,
    }

    impl Tree {
        fn dir(&mut self, path: &str, parent: u64) -> u64 {
            let ino = match self.dir_ino.get(path) {
                Some(i) => *i,
                None => {
                    self.next += 1;
                    self.dir_ino.insert(path.to_string(), self.next);
                    self.next
                }
            };
            self.dirs.entry(ino).or_default();
            self.parents.insert(ino, parent);
            ino
        }
    }

    /// One lock per open file (ROM id, inode).
    type FileLock = Arc<Mutex<()>>;

    struct Fs {
        app: Shared,
        tree: Arc<RwLock<Tree>>,
        locks: Arc<Mutex<HashMap<(i64, u64), FileLock>>>,
        written: Arc<AtomicU64>,
        /// The RomM client, kept between reads (one connection reused rather than a new one per
        /// block), renewed when the server or the profile changes.
        client: Arc<Mutex<Option<(String, crate::romm::Client)>>>,
        uid: u32,
        gid: u32,
    }

    static TREE: OnceLock<Arc<RwLock<Tree>>> = OnceLock::new();
    static SESSION: Mutex<Option<fuser::BackgroundSession>> = Mutex::new(None);

    fn rebuild(app: &Shared, tree: &mut Tree) {
        tree.dirs.clear();
        tree.parents.clear();
        tree.files.clear();
        if tree.next == 0 {
            tree.next = 1;
        }
        tree.dirs.insert(1, BTreeMap::new());
        tree.parents.insert(1, 1);
        for f in app.db.linked_files() {
            let platform = tree.dir(&f.platform_slug, 1);
            tree.dirs.get_mut(&1).unwrap().insert(f.platform_slug.clone(), platform);
            let game_path = format!("{}/{}", f.platform_slug, f.rom_id);
            let mut parent = tree.dir(&game_path, platform);
            tree.dirs.get_mut(&platform).unwrap().insert(f.rom_id.to_string(), parent);
            let rel = PathBuf::from(&f.rel_path);
            let comps: Vec<String> = rel.iter().map(|c| c.to_string_lossy().into_owned()).collect();
            let mut path = game_path;
            for (i, c) in comps.iter().enumerate() {
                if i + 1 == comps.len() {
                    let ino = FILE_INO + f.file_id as u64;
                    tree.files
                        .insert(ino, FileNode { file_id: f.file_id, rom_id: f.rom_id, name: f.file_name.clone(), size: f.size as u64 });
                    tree.parents.insert(ino, parent);
                    tree.dirs.get_mut(&parent).unwrap().insert(c.clone(), ino);
                } else {
                    path = format!("{path}/{c}");
                    let d = tree.dir(&path, parent);
                    tree.dirs.get_mut(&parent).unwrap().insert(c.clone(), d);
                    parent = d;
                }
            }
        }
    }

    pub fn refresh(app: &Shared) {
        if let Some(t) = TREE.get() {
            rebuild(app, &mut t.write().unwrap_or_else(|e| e.into_inner()));
        }
    }

    pub fn stop() {
        if let Some(session) = SESSION.lock().unwrap_or_else(|e| e.into_inner()).take() {
            drop(session);
        }
    }

    pub fn drop_cache(app: &Shared, rom_id: i64) {
        let _ = std::fs::remove_dir_all(app.paths.stream_cache().join(rom_id.to_string()));
    }

    /// Unmounts a mount left behind by a previous session that did not stop cleanly.
    fn clear_stale(path: &Path) {
        for bin in ["fusermount3", "fusermount"] {
            let ok = std::process::Command::new(bin)
                .arg("-u")
                .arg("-z")
                .arg(path)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
            if ok.is_ok() {
                return;
            }
        }
    }

    pub fn start(app: &Shared) {
        let mount = app.paths.mount();
        clear_stale(&mount);
        if let Err(e) = std::fs::create_dir_all(&mount) {
            super::set_state(false, Some(format!("cannot create {}: {e}", mount.display())));
            return;
        }
        let tree = TREE.get_or_init(|| Arc::new(RwLock::new(Tree::default()))).clone();
        rebuild(app, &mut tree.write().unwrap_or_else(|e| e.into_inner()));
        // SAFETY: getuid/getgid have no preconditions.
        let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
        let fs = Fs {
            app: app.clone(),
            tree,
            locks: Arc::new(Mutex::new(HashMap::new())),
            written: Arc::new(AtomicU64::new(0)),
            client: Arc::new(Mutex::new(None)),
            uid,
            gid,
        };
        let mut cfg = fuser::Config::default();
        cfg.mount_options = vec![MountOption::RO, MountOption::FSName("borne".into()), MountOption::NoExec];
        cfg.n_threads = Some(4);
        match fuser::spawn_mount(fs, &mount, &cfg) {
            Ok(session) => {
                *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = Some(session);
                super::set_state(true, None);
                crate::logfile::write("stream", &format!("virtual mount ready: {}", mount.display()));
            }
            Err(e) => {
                let msg = format!("virtual mount unavailable ({e}); FUSE (fusermount3) is required");
                crate::logfile::write("stream", &msg);
                super::set_state(false, Some(msg));
            }
        }
    }

    impl Fs {
        fn attr(&self, ino: u64, tree: &Tree) -> Option<FileAttr> {
            let (kind, size, perm) = if let Some(f) = tree.files.get(&ino) {
                (FileType::RegularFile, f.size, 0o444)
            } else if tree.dirs.contains_key(&ino) {
                (FileType::Directory, 0, 0o555)
            } else {
                return None;
            };
            Some(FileAttr {
                ino: INodeNo(ino),
                size,
                blocks: size.div_ceil(512),
                atime: UNIX_EPOCH,
                mtime: UNIX_EPOCH,
                ctime: UNIX_EPOCH,
                crtime: UNIX_EPOCH,
                kind,
                perm,
                nlink: if kind == FileType::Directory { 2 } else { 1 },
                uid: self.uid,
                gid: self.gid,
                rdev: 0,
                flags: 0,
                blksize: 512,
            })
        }

        fn block_path(&self, rom_id: i64, file_id: i64, block: u64) -> PathBuf {
            self.app.paths.stream_cache().join(rom_id.to_string()).join(file_id.to_string()).join(format!("{block}.blk"))
        }

        /// The RomM client of the active profile, reused while it stays the same.
        fn client(&self) -> Result<crate::romm::Client, String> {
            let key = format!("{:?}|{:?}", self.app.server_url(), self.app.active_profile().map(|p| p.id));
            let mut c = self.client.lock().unwrap_or_else(|e| e.into_inner());
            if let Some((k, client)) = c.as_ref() {
                if *k == key {
                    return Ok(client.clone());
                }
            }
            let client = self.app.client().ok_or("no paired profile")?;
            *c = Some((key, client.clone()));
            Ok(client)
        }

        /// Bytes `s..e` of one block of a file: from the cache (only what is asked is read), else
        /// the whole block from RomM, kept in the cache.
        fn block(&self, f: &FileNode, block: u64, s: usize, e: usize) -> Result<Vec<u8>, String> {
            let path = self.block_path(f.rom_id, f.file_id, block);
            let lock = self.locks.lock().unwrap_or_else(|e| e.into_inner()).entry((f.file_id, block)).or_default().clone();
            let _guard = lock.lock().unwrap_or_else(|e| e.into_inner());
            if let Ok(mut file) = std::fs::File::open(&path) {
                use std::io::{Read, Seek, SeekFrom};
                let len = file.metadata().map(|m| m.len() as usize).unwrap_or(0);
                let (s, e) = (s.min(len), e.min(len));
                let mut out = vec![0u8; e - s];
                if file.seek(SeekFrom::Start(s as u64)).is_ok() && file.read_exact(&mut out).is_ok() {
                    return Ok(out);
                }
            }
            let data = self.fetch(f, block, &path)?;
            Ok(data[s.min(data.len())..e.min(data.len())].to_vec())
        }

        /// One whole block from RomM, written to the cache.
        fn fetch(&self, f: &FileNode, block: u64, path: &Path) -> Result<Vec<u8>, String> {
            let start = block * BLOCK;
            let len = BLOCK.min(f.size.saturating_sub(start));
            let data = self.client()?.fetch_range(f.file_id, &f.name, start, len).map_err(|e| e.to_string())?;
            if data.len() as u64 != len {
                return Err(format!("short read from RomM ({} of {len} bytes)", data.len()));
            }
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
                let tmp = path.with_extension("part");
                if std::fs::write(&tmp, &data).is_ok() {
                    let _ = std::fs::rename(&tmp, path);
                }
            }
            if self.written.fetch_add(len, Ordering::Relaxed) + len > 256 * 1024 * 1024 {
                self.written.store(0, Ordering::Relaxed);
                let app = self.app.clone();
                std::thread::spawn(move || evict(&app));
            }
            Ok(data)
        }

        /// Reading on: the next block is fetched in the background while the emulator uses this
        /// one, so a game read in order rarely waits for RomM.
        fn prefetch(&self, f: &FileNode, block: u64) {
            if block * BLOCK >= f.size || self.block_path(f.rom_id, f.file_id, block).exists() {
                return;
            }
            let lock = self.locks.lock().unwrap_or_else(|e| e.into_inner()).entry((f.file_id, block)).or_default().clone();
            let me = Fs {
                app: self.app.clone(),
                tree: self.tree.clone(),
                locks: self.locks.clone(),
                written: self.written.clone(),
                client: self.client.clone(),
                uid: self.uid,
                gid: self.gid,
            };
            let node = FileNode { file_id: f.file_id, rom_id: f.rom_id, name: f.name.clone(), size: f.size };
            std::thread::spawn(move || {
                // Already being fetched (by a read or another prefetch): nothing to do.
                let Ok(_guard) = lock.try_lock() else { return };
                let path = me.block_path(node.rom_id, node.file_id, block);
                if !path.exists() {
                    let _ = me.fetch(&node, block, &path);
                }
            });
        }
    }

    /// Keeps the block cache under its limit, removing the least recently read blocks first.
    fn evict(app: &Shared) {
        let limit = super::cache_limit_mb(app) * 1024 * 1024;
        let mut blocks: Vec<(SystemTime, u64, PathBuf)> = vec![];
        let mut stack = vec![app.paths.stream_cache()];
        while let Some(dir) = stack.pop() {
            for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                let p = e.path();
                match e.metadata() {
                    Ok(m) if m.is_dir() => stack.push(p),
                    Ok(m) => blocks.push((m.accessed().or_else(|_| m.modified()).unwrap_or(UNIX_EPOCH), m.len(), p)),
                    Err(_) => {}
                }
            }
        }
        let mut total: u64 = blocks.iter().map(|b| b.1).sum();
        blocks.sort_by_key(|b| b.0);
        for (_, len, p) in blocks {
            if total <= limit {
                break;
            }
            if std::fs::remove_file(&p).is_ok() {
                total -= len;
            }
        }
    }

    impl Filesystem for Fs {
        fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
            let tree = self.tree.read().unwrap_or_else(|e| e.into_inner());
            let child = tree.dirs.get(&parent.0).and_then(|d| d.get(name.to_string_lossy().as_ref())).copied();
            match child.and_then(|c| self.attr(c, &tree)) {
                Some(a) => reply.entry(&TTL, &a, fuser::Generation(0)),
                None => reply.error(Errno::ENOENT),
            }
        }

        fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
            let tree = self.tree.read().unwrap_or_else(|e| e.into_inner());
            match self.attr(ino.0, &tree) {
                Some(a) => reply.attr(&TTL, &a),
                None => reply.error(Errno::ENOENT),
            }
        }

        fn readdir(&self, _req: &Request, ino: INodeNo, _fh: FileHandle, offset: u64, mut reply: ReplyDirectory) {
            let tree = self.tree.read().unwrap_or_else(|e| e.into_inner());
            let Some(children) = tree.dirs.get(&ino.0) else {
                return reply.error(Errno::ENOENT);
            };
            let parent = tree.parents.get(&ino.0).copied().unwrap_or(1);
            let mut entries = vec![(ino.0, FileType::Directory, ".".to_string()), (parent, FileType::Directory, "..".to_string())];
            for (name, child) in children {
                let kind = if tree.files.contains_key(child) { FileType::RegularFile } else { FileType::Directory };
                entries.push((*child, kind, name.clone()));
            }
            for (i, (child, kind, name)) in entries.into_iter().enumerate().skip(offset as usize) {
                if reply.add(INodeNo(child), (i + 1) as u64, kind, name) {
                    break;
                }
            }
            reply.ok();
        }

        #[allow(clippy::too_many_arguments)]
        fn read(
            &self,
            _req: &Request,
            ino: INodeNo,
            _fh: FileHandle,
            offset: u64,
            size: u32,
            _flags: OpenFlags,
            _lock: Option<LockOwner>,
            reply: ReplyData,
        ) {
            let node = {
                let tree = self.tree.read().unwrap_or_else(|e| e.into_inner());
                match tree.files.get(&ino.0) {
                    Some(f) => FileNode { file_id: f.file_id, rom_id: f.rom_id, name: f.name.clone(), size: f.size },
                    None => return reply.error(Errno::ENOENT),
                }
            };
            if offset >= node.size {
                return reply.data(&[]);
            }
            let end = (offset + size as u64).min(node.size);
            let mut out = Vec::with_capacity((end - offset) as usize);
            let mut pos = offset;
            while pos < end {
                let b = pos / BLOCK;
                let s = (pos - b * BLOCK) as usize;
                let e = ((end - b * BLOCK) as usize).min(BLOCK as usize);
                match self.block(&node, b, s, e) {
                    Ok(data) => {
                        if data.is_empty() {
                            break;
                        }
                        pos += data.len() as u64;
                        out.extend_from_slice(&data);
                        // Once, as the reads cross the middle of the block.
                        let half = (BLOCK / 2) as usize;
                        if s < half && e >= half {
                            self.prefetch(&node, b + 1);
                        }
                    }
                    Err(e) => {
                        crate::logfile::write("stream", &format!("virtual mount: {e}"));
                        return reply.error(Errno::EIO);
                    }
                }
            }
            reply.data(&out);
        }
    }
}
