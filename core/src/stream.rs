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
use std::path::PathBuf;
use std::sync::Mutex;

/// Mount state, shown in the status and on the game page.
static STATE: Mutex<MountState> = Mutex::new(MountState { mounted: false, error: None });

#[derive(Clone)]
struct MountState {
    mounted: bool,
    error: Option<String>,
}

pub fn status(app: &Shared) -> Value {
    let s = STATE.lock().unwrap().clone();
    json!({
        "available": s.mounted,
        "path": app.paths.mount(),
        "error": s.error,
        "cache_limit_mb": cache_limit_mb(app),
    })
}

/// Whether this system can host the virtual mount at all.
pub fn available() -> bool {
    cfg!(target_os = "linux")
}

fn set_state(mounted: bool, error: Option<String>) {
    *STATE.lock().unwrap() = MountState { mounted, error };
}

pub fn cache_limit_mb(app: &Shared) -> u64 {
    app.db.setting("stream_cache_mb").and_then(|v| v.parse().ok()).unwrap_or(20_480)
}

/// Exposes a game in the virtual mount. Returns the path of the file to launch.
pub fn link(app: &Shared, rom_id: i64) -> Result<PathBuf, String> {
    if !STATE.lock().unwrap().mounted {
        return Err(STATE.lock().unwrap().error.clone().unwrap_or_else(|| "virtual mount unavailable".into()));
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
        super::set_state(false, Some("the virtual mount is only available on Linux".into()));
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
        locks: Mutex<HashMap<(i64, u64), FileLock>>,
        written: AtomicU64,
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
            rebuild(app, &mut t.write().unwrap());
        }
    }

    pub fn stop() {
        if let Some(session) = SESSION.lock().unwrap().take() {
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
        rebuild(app, &mut tree.write().unwrap());
        // SAFETY: getuid/getgid have no preconditions.
        let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
        let fs = Fs { app: app.clone(), tree, locks: Mutex::new(HashMap::new()), written: AtomicU64::new(0), uid, gid };
        let mut cfg = fuser::Config::default();
        cfg.mount_options = vec![MountOption::RO, MountOption::FSName("borne".into()), MountOption::NoExec];
        cfg.n_threads = Some(4);
        match fuser::spawn_mount(fs, &mount, &cfg) {
            Ok(session) => {
                *SESSION.lock().unwrap() = Some(session);
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

        /// One block of a file, from the cache or from RomM.
        fn block(&self, f: &FileNode, block: u64) -> Result<Vec<u8>, String> {
            let path = self.block_path(f.rom_id, f.file_id, block);
            let lock = self.locks.lock().unwrap().entry((f.file_id, block)).or_default().clone();
            let _guard = lock.lock().unwrap();
            if let Ok(data) = std::fs::read(&path) {
                return Ok(data);
            }
            let client = self.app.client().ok_or("no paired profile")?;
            let start = block * BLOCK;
            let len = BLOCK.min(f.size.saturating_sub(start));
            let data = client.fetch_range(f.file_id, &f.name, start, len).map_err(|e| e.to_string())?;
            if data.len() as u64 != len {
                return Err(format!("short read from RomM ({} of {len} bytes)", data.len()));
            }
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
                let tmp = path.with_extension("part");
                if std::fs::write(&tmp, &data).is_ok() {
                    let _ = std::fs::rename(&tmp, &path);
                }
            }
            if self.written.fetch_add(len, Ordering::Relaxed) + len > 256 * 1024 * 1024 {
                self.written.store(0, Ordering::Relaxed);
                let app = self.app.clone();
                std::thread::spawn(move || evict(&app));
            }
            Ok(data)
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
            let tree = self.tree.read().unwrap();
            let child = tree.dirs.get(&parent.0).and_then(|d| d.get(name.to_string_lossy().as_ref())).copied();
            match child.and_then(|c| self.attr(c, &tree)) {
                Some(a) => reply.entry(&TTL, &a, fuser::Generation(0)),
                None => reply.error(Errno::ENOENT),
            }
        }

        fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
            let tree = self.tree.read().unwrap();
            match self.attr(ino.0, &tree) {
                Some(a) => reply.attr(&TTL, &a),
                None => reply.error(Errno::ENOENT),
            }
        }

        fn readdir(&self, _req: &Request, ino: INodeNo, _fh: FileHandle, offset: u64, mut reply: ReplyDirectory) {
            let tree = self.tree.read().unwrap();
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
                let tree = self.tree.read().unwrap();
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
                match self.block(&node, b) {
                    Ok(data) => {
                        let s = (pos - b * BLOCK) as usize;
                        let e = ((end - b * BLOCK) as usize).min(data.len());
                        if s >= e {
                            break;
                        }
                        out.extend_from_slice(&data[s..e]);
                        pos = b * BLOCK + e as u64;
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
