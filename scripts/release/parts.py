#!/usr/bin/env python3
"""Splits a built Borne package into the parts used by in-app updates.

    scripts/release/parts.py <package> <linux|macos> <output dir> <asset prefix>

<package> is the package folder (Linux `Borne/`, macOS `Borne.app`). For each part (core, ui,
runtime) it writes `<asset prefix>-<part>.tar.gz` (paths relative to the package, reproducible:
sorted, fixed times and owners) and prints a JSON object:

    {"core": {"file": "...", "sha256": "...", "size": 123, "tree": "..."}, ...}

`tree` hashes the part's files exactly as the core does (core/src/update.rs, tree_hashes): the
installed copy is compared to it to fetch only the parts that changed. Keep both in step.
"""
import gzip
import hashlib
import json
import os
import sys
import tarfile

RULES = {
    "linux": {"runtime": ("lib/", "plugins/", "qml/"), "ui": ("ui/", "resources/")},
    "macos": {"runtime": ("Contents/Frameworks/", "Contents/PlugIns/", "Contents/Resources/qml/"),
              "ui": ("Contents/Resources/ui/", "Contents/Resources/resources/")},
}
PARTS = ("core", "ui", "runtime")
EPOCH = 1700000000  # fixed time in the archives: same files, same archive


def part_of(rel, platform):
    rules = RULES[platform]
    if rel.startswith(rules["runtime"]):
        return "runtime"
    if rel.startswith(rules["ui"]):
        return "ui"
    return "core"


def entries(root):
    """Every file and symbolic link under root, as (relative path, full path), sorted."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isdir(full):
                out.append((os.path.relpath(full, root).replace(os.sep, "/"), full))
    return sorted(out, key=lambda e: e[0].encode())


def line(rel, full):
    st = os.lstat(full)
    if os.path.islink(full):
        return f"{rel}\0l\0{os.readlink(full)}\n"
    h = hashlib.sha256()
    with open(full, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return f"{rel}\0f\0{h.hexdigest()}{'x' if st.st_mode & 0o111 else '-'}\n"


def main():
    pkg, platform, out_dir, prefix = sys.argv[1:5]
    os.makedirs(out_dir, exist_ok=True)
    groups = {p: [] for p in PARTS}
    for rel, full in entries(pkg):
        groups[part_of(rel, platform)].append((rel, full))
    result = {}
    for part, files in groups.items():
        tree = hashlib.sha256()
        name = f"{prefix}-{part}.tar.gz"
        path = os.path.join(out_dir, name)
        with open(path, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, compresslevel=9) as gz, \
                tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for rel, full in files:
                tree.update(line(rel, full).encode())
                info = tar.gettarinfo(full, arcname=rel)
                info.mtime = EPOCH
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                if info.isfile():
                    with open(full, "rb") as f:
                        tar.addfile(info, f)
                else:
                    tar.addfile(info)
        data = open(path, "rb").read()
        result[part] = {"file": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                        "tree": tree.hexdigest()}
    json.dump(result, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
