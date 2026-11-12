#!/usr/bin/env python3
"""Writes the update manifest, the checksums and the release notes of a build.

    scripts/release/manifest.py <dist dir> <tag> <channel>

<dist dir> holds what the build jobs produced: per platform the full archive and
`parts-<platform>.json` (scripts/release/parts.py) with its part archives. Writes into it:

    latest.json   read by Borne's updater (core/src/update.rs): version, build, notes, and per
                  platform the full archive and its parts (url, sha256, size, tree)
    SHA256SUMS    every published file
and `notes.md` in the current folder: the release notes.

Environment: BORNE_VERSION, BORNE_BUILD, BORNE_COMMIT, GITHUB_REPOSITORY, PREVIOUS_TAG (stable).
"""
import datetime
import hashlib
import json
import os
import subprocess
import sys

PLATFORMS = {  # manifest key: (full archive, parts file, label)
    "linux-x86_64": ("Borne-linux-x86_64.tar.gz", "parts-linux-x86_64.json", "Linux (x86_64)"),
    "macos-aarch64": ("Borne-macos-arm64.zip", "parts-macos-arm64.json", "macOS (Apple Silicon)"),
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def mb(n):
    return f"{n / 1048576:.1f} MB"


def changes(tag, channel):
    """Commit subjects since the previous stable tag (stable), or this build's commit (dev)."""
    if channel == "stable":
        prev = os.environ.get("PREVIOUS_TAG", "")
        rng = f"{prev}..{tag}" if prev else tag
        out = subprocess.run(["git", "log", "--no-merges", "--format=%s", rng], capture_output=True, text=True).stdout
    else:
        out = subprocess.run(["git", "log", "-1", "--format=%s"], capture_output=True, text=True).stdout
    return [l.strip() for l in out.splitlines() if l.strip()]


def main():
    dist, tag, channel = sys.argv[1:4]
    repo = os.environ["GITHUB_REPOSITORY"]
    url = f"https://github.com/{repo}/releases/download/{tag}/"
    assets, files = {}, []
    for key, (archive, parts_file, _) in PLATFORMS.items():
        path = os.path.join(dist, archive)
        if not os.path.exists(path):
            continue
        parts = json.load(open(os.path.join(dist, parts_file)))
        assets[key] = {
            "url": url + archive, "sha256": sha256(path), "size": os.path.getsize(path),
            "parts": {name: {"url": url + p["file"], "sha256": p["sha256"], "size": p["size"], "tree": p["tree"]}
                      for name, p in parts.items()},
        }
        files += [archive] + [p["file"] for p in parts.values()]
    subjects = changes(tag, channel)
    manifest = {
        "version": os.environ["BORNE_VERSION"], "build": int(os.environ["BORNE_BUILD"]), "channel": channel,
        "commit": os.environ["BORNE_COMMIT"], "date": datetime.date.today().isoformat(),
        "notes": "\n".join(f"- {s}" for s in subjects), "assets": assets,
    }
    json.dump(manifest, open(os.path.join(dist, "latest.json"), "w"), indent=1)
    with open(os.path.join(dist, "SHA256SUMS"), "w") as f:
        for name in files + ["latest.json"]:
            f.write(f"{sha256(os.path.join(dist, name))}  {name}\n")

    # Release notes: what changed, how to install, what an update weighs.
    lines = []
    if channel == "dev":
        lines += [f"Development build {manifest['build']} ({manifest['version']}, {manifest['commit']}), "
                  "rebuilt on every change of `main`. For the tested versions, use the latest stable release.", ""]
    lines += ["## Changes", ""] + [f"- {s}" for s in subjects] + [""]
    lines += ["## Install", "",
              "- **Linux** (x86_64; ChimeraOS, SteamOS, any desktop): download `Borne-linux-x86_64.tar.gz`, then",
              "  ```", "  tar xzf Borne-linux-x86_64.tar.gz && ./Borne/install.sh", "  ```",
              "  Borne is added to your applications menu (on ChimeraOS / SteamOS, add it to Steam as a non-Steam game).",
              "- **macOS** (Apple Silicon): download `Borne-macos-arm64.zip`, move `Borne.app` to Applications, then the",
              "  first time right-click it → **Open** (the app is not notarized).", "",
              "## Updates", "",
              "Borne updates itself (Settings → Updates) and downloads only the parts that changed:", "",
              "| | Whole version | Programs | Interface | Qt runtime |", "|---|---|---|---|---|"]
    for key, (archive, _, label) in PLATFORMS.items():
        a = assets.get(key)
        if a:
            p = a["parts"]
            lines.append(f"| {label} | {mb(a['size'])} | {mb(p['core']['size'])} | {mb(p['ui']['size'])} | {mb(p['runtime']['size'])} |")
    lines += ["", "The Qt runtime only changes when Qt does; a usual update is the programs and the interface.",
              "Every file is checked against its SHA-256 (`SHA256SUMS`)."]
    open("notes.md", "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
