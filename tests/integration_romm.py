"""End-to-end test of the Borne core against a real RomM server.

    python3 tests/integration_romm.py <borne binary> <RomM url> <admin> <password> <account 2> <password 2>

Starts the core without a UI in a temporary data directory, then checks:
server, profiles, pairing (approved through the RomM API as if from a phone), catalog and cover
sync, downloads (simple, extracted zip, large file interrupted by killing the core and then
resumed), local deletion, versions of a game grouped with per-profile choices, the Borne virtual
mount (a linked game read from RomM on demand, nothing else exposed), a second profile on another
RomM account, offline use.
"""
import base64, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile, time, urllib.request

CORE, ROMM, ADMIN, PWD, USER2, PWD2 = sys.argv[1:7]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # everything is local
data_dir = tempfile.mkdtemp(prefix="borne-it-")
env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
env["BORNE_DATA_DIR"] = data_dir
passed = []

def check(cond, label):
    if not cond:
        print(f"FAILED: {label}")
        sys.exit(1)
    passed.append(label)
    print(f"  ok  {label}")

def start_core():
    p = subprocess.Popen([CORE, "--no-ui"], env=env, stderr=subprocess.PIPE, text=True)
    api = None
    deadline = time.time() + 15
    while time.time() < deadline and api is None:
        line = p.stderr.readline()
        m = re.search(r"API (http://\S+)", line)
        if m:
            api = m.group(1)
    assert api, "the core did not start"
    # Drain stderr in the background so the core never blocks.
    import threading
    threading.Thread(target=lambda: [None for _ in p.stderr], daemon=True).start()
    return p, api

def call(api, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(api + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with opener.open(req, timeout=30) as r:
            raw = r.read()
            ctype = r.headers.get("Content-Type", "")
            return r.status, (json.loads(raw or b"null") if "json" in ctype else raw.decode(errors="replace"))
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"null")
        except ValueError:
            return e.code, raw.decode(errors="replace")

def romm(method, path, body=None, user=ADMIN, pwd=PWD):
    auth = "Basic " + base64.b64encode(f"{user}:{pwd}".encode()).decode()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ROMM + path, data=data, method=method,
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    with opener.open(req, timeout=30) as r:
        return json.loads(r.read() or b"null")

def wait(fn, timeout, label):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.5)
    check(False, f"{label} (timed out)")

def pair(api, profile_id, user, pwd):
    s, pairing = call(api, "POST", f"/api/v1/profiles/{profile_id}/pair")
    check(s == 200 and pairing["state"] == "waiting" and len(pairing["user_code"]) >= 4, f"pairing code shown ({user})")
    s, svg = call(api, "GET", "/api/v1/pairing/qr.svg")
    check(s == 200 and svg.lstrip().startswith("<?xml") or "<svg" in svg, f"pairing QR code generated ({user})")
    # The phone: the user approves the code in RomM.
    pending = romm("GET", f"/api/auth/device/pending/{pairing['user_code']}", user=user, pwd=pwd)
    romm("POST", "/api/auth/device/approve",
         {"user_code": pairing["user_code"], "approved_scopes": pending["allowed_scopes"]}, user=user, pwd=pwd)
    done = wait(lambda: (lambda st: st if st["pairing"] and st["pairing"]["state"] != "waiting" else None)(call(api, "GET", "/api/v1/status")[1]), 30, "pairing")
    check(done["pairing"]["state"] == "approved", f"pairing approved ({user})")

def wait_sync(api):
    def done():
        st = call(api, "GET", "/api/v1/status")[1]["sync"]
        return st if (not st["running"] and st["last_sync"]) or st["error"] else None
    return wait(done, 60, "sync")

def wait_download(api, rom_id, timeout=120):
    def done():
        g = call(api, "GET", f"/api/v1/games/{rom_id}")[1]["game"]
        if g["local_state"] == "local":
            return g
        dl = [d for d in call(api, "GET", "/api/v1/downloads")[1] if d["rom_id"] == rom_id]
        if dl and dl[0]["state"] == "failed":
            print("   error:", dl[0]["error"]); return g
        return None
    return wait(done, timeout, f"download {rom_id}")

try:
    core, api = start_core()
    print("Server and profiles")
    s, r = call(api, "POST", "/api/v1/server", {"url": "127.0.0.1:1"})
    check(s == 502, "unreachable server refused with a clear message")
    s, r = call(api, "POST", "/api/v1/server", {"url": ROMM})
    check(s == 200 and r["version"], "RomM server checked and saved")
    s, p1 = call(api, "POST", "/api/v1/profiles", {"name": "Light"})
    check(s == 200 and not p1["paired"], "local profile created")
    s, _ = call(api, "POST", "/api/v1/profiles", {"name": ""})
    check(s == 400, "empty profile name refused")

    print("Pairing")
    pair(api, p1["id"], ADMIN, PWD)
    st = call(api, "GET", "/api/v1/status")[1]
    check(st["active_profile"]["id"] == p1["id"] and st["active_profile"]["romm_user"] == ADMIN, "active profile bound to the RomM account")
    secret_file = os.path.join(data_dir, "secrets", p1["id"] + ".token")
    check(oct(os.stat(secret_file).st_mode & 0o777) == "0o600", "token stored as 0600")
    with open(os.path.join(data_dir, "state.db"), "rb") as f:
        check(b"rmm_" not in f.read(), "no token in the SQLite database")

    print("Catalog")
    sync = wait_sync(api)
    check(sync["error"] is None and sync["total"] == 33, "33 ROMs synced from RomM")
    wait(lambda: call(api, "GET", "/api/v1/status")[1]["sync"]["covers_pending"] == 0, 60, "covers")
    lib = call(api, "GET", "/api/v1/library")[1]
    covers = [g for g in lib if g["cover_local"] and os.path.exists(g["cover_local"])]
    check(len(lib) == 29, "33 ROMs shown as 29 games (versions grouped)")
    check(len(covers) == 29, "29 covers cached locally")
    plats = call(api, "GET", "/api/v1/platforms")[1]
    check({p["slug"] for p in plats} >= {"nes", "genesis", "ngc", "ps2", "switch"}, "5 platforms")
    nes = call(api, "GET", "/api/v1/library?platform=nes")[1]
    check(len(nes) == 12, "platform filter")

    print("Versions")
    def crystal(lang):
        return [g for g in call(api, "GET", f"/api/v1/library?platform=nes&lang={lang}")[1] if g["name"].startswith("Crystal")][0]
    fr, en = crystal("fr"), crystal("en")
    check(fr["version_count"] == 3 and "French" in fr["langs"], "French UI: the version with French shown first")
    check("USA" in en["regions"], "English UI: the USA version shown first")
    page = call(api, "GET", f"/api/v1/games/{fr['rom_id']}")[1]
    check(len(page["versions"]) == 3 and page["emu_language"] == "auto" and "ja" in page["emu_languages"], "game page lists every version")
    japan = [v for v in page["versions"] if "Japan" in v["regions"]][0]
    s, _ = call(api, "POST", f"/api/v1/games/{fr['rom_id']}/prefs", {"version": japan["rom_id"], "emu_language": "ja"})
    check(s == 200 and crystal("fr")["rom_id"] == japan["rom_id"], "chosen version kept for the profile")
    check(call(api, "GET", f"/api/v1/games/{fr['rom_id']}")[1]["emu_language"] == "ja", "emulator language kept for the profile")
    s, _ = call(api, "POST", f"/api/v1/games/{fr['rom_id']}/prefs", {"version": nes[5]["rom_id"]})
    check(s == 400, "a version of another game refused")
    s, _ = call(api, "POST", f"/api/v1/games/{fr['rom_id']}/prefs", {"version": None, "emu_language": "auto"})
    check(crystal("fr")["rom_id"] == fr["rom_id"], "choice reset to automatic")
    check(len(call(api, "GET", "/api/v1/library?q=zip")[1]) == 2, "search by name")
    s, r = call(api, "GET", "/api/v1/file?path=/etc/passwd".replace("/api/v1", ""))
    check(s == 403, "files outside the allowed folders refused")

    print("Downloads")
    small = nes[0]
    call(api, "POST", f"/api/v1/games/{small['rom_id']}/download")
    g = wait_download(api, small["rom_id"])
    check(g["local_state"] == "local" and os.path.exists(g["local_main"]), "NES game installed")
    with open(g["local_main"], "rb") as f:
        check(hashlib.sha1(f.read()).hexdigest() == small["sha1"], "SHA-1 identical to RomM")
    s, _ = call(api, "POST", f"/api/v1/games/{small['rom_id']}/download")
    check(s == 409, "downloading an installed game again refused")

    zipped = [x for x in lib if x["fs_name"].endswith(".zip")][0]
    call(api, "POST", f"/api/v1/games/{zipped['rom_id']}/download")
    g = wait_download(api, zipped["rom_id"])
    check(g["local_state"] == "local" and g["local_main"].endswith(".md"), "zip archive extracted, .md main file")
    check(not os.path.exists(os.path.join(g["local_dir"], zipped["fs_name"])), "archive removed after extraction")

    big = [x for x in lib if x["name"].startswith("Big")][0]
    # Rate limited to ~20 MB/s to kill the core in the middle of the transfer.
    core.send_signal(signal.SIGTERM); core.wait()
    env["BORNE_DEBUG_DL_KBPS"] = "20480"
    core, api = start_core()
    log_mark = os.path.getsize("/var/log/nginx/access.log") if os.path.exists("/var/log/nginx/access.log") else 0
    call(api, "POST", f"/api/v1/games/{big['rom_id']}/download")
    staging = os.path.join(data_dir, "library", ".staging", str(big["rom_id"]))
    def partial():
        for root, _, files in os.walk(staging):
            for f in files:
                if f.endswith(".part") and os.path.getsize(os.path.join(root, f)) > 8 * 1024 * 1024:
                    return os.path.getsize(os.path.join(root, f))
    size_before = wait(partial, 60, "start of the large download")
    core.send_signal(signal.SIGKILL)  # hard stop (crash, power off)
    core.wait()
    check(size_before < big["fs_size"], f"stopped mid-transfer ({size_before // 1048576} MB of {big['fs_size'] // 1048576})")
    env.pop("BORNE_DEBUG_DL_KBPS")
    check(not os.path.exists(os.path.join(data_dir, "library", "genesis", str(big["rom_id"]))), "no half-installed game after the stop")
    core, api = start_core()
    g = wait_download(api, big["rom_id"], 180)
    check(g["local_state"] == "local", f"download resumed after restart ({size_before // 1048576} MB already there)")
    with open(g["local_main"], "rb") as f:
        h = hashlib.sha1()
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    check(h.hexdigest() == big["sha1"], "large resumed file intact (SHA-1)")
    if log_mark or os.path.exists("/var/log/nginx/access.log"):
        with open("/var/log/nginx/access.log") as f:
            f.seek(log_mark)
            ranged = [l for l in f if "Big%20Download" in l and '" 206 ' in l]
        check(len(ranged) >= 1, "resumed with a Range request (HTTP 206), without downloading everything again")
    check(not os.path.exists(staging), "temporary folder cleaned up")

    print("Cancellation and deletion")
    other = nes[1]
    call(api, "POST", f"/api/v1/games/{other['rom_id']}/download")
    call(api, "POST", f"/api/v1/games/{big['rom_id']}/download")  # already installed: refused, not queued
    dls = call(api, "GET", "/api/v1/downloads")[1]
    pending = [d for d in dls if d["rom_id"] == other["rom_id"] and d["state"] in ("queued", "downloading", "verifying")]
    if pending:
        call(api, "DELETE", f"/api/v1/downloads/{pending[0]['id']}")
    s, _ = call(api, "DELETE", f"/api/v1/games/{small['rom_id']}/local")
    check(s == 200 and call(api, "GET", f"/api/v1/games/{small['rom_id']}")[1]["game"]["local_state"] == "remote", "local deletion (the game stays on RomM)")
    check(romm("GET", f"/api/roms/{small['rom_id']}")["id"] == small["rom_id"], "game still present in RomM")

    print("Virtual mount")
    settings = call(api, "GET", "/api/v1/settings")[1]
    mount = settings["stream"]["path"]
    check(settings["stream"]["available"] and settings["install_mode"] == "download", "virtual mount ready, download by default")
    check(os.listdir(mount) == [], "nothing exposed before a game is linked")
    target = [g for g in lib if g["name"].startswith("Thunder")][0]
    s, r = call(api, "POST", f"/api/v1/games/{target['rom_id']}/link")
    check(s == 200 and os.path.isfile(r["path"]), "linked game visible in the mount")
    check(os.listdir(mount) == ["genesis"] and os.listdir(os.path.join(mount, "genesis")) == [str(target["rom_id"])], "only the linked game is exposed")
    with open(r["path"], "rb") as f:
        check(hashlib.sha1(f.read()).hexdigest() == target["sha1"], "file read from RomM through the mount (SHA-1)")
    check(any(g["rom_id"] == target["rom_id"] for g in call(api, "GET", "/api/v1/library?local=1")[1]), "linked game listed with installed games")
    s, rb = call(api, "POST", f"/api/v1/games/{big['rom_id']}/link")
    with open(rb["path"], "rb") as f, open(call(api, "GET", f"/api/v1/games/{big['rom_id']}")[1]["game"]["local_main"], "rb") as local:
        ok_ranges = True
        for off in (0, 4 * 1024 * 1024 - 100, 50 * 1024 * 1024 + 123, big["fs_size"] - 5000):
            f.seek(off); local.seek(off)
            ok_ranges &= f.read(1 << 20) == local.read(1 << 20)
    check(ok_ranges, "random reads across blocks match the file")
    call(api, "DELETE", f"/api/v1/games/{big['rom_id']}/link")
    s, _ = call(api, "DELETE", f"/api/v1/games/{target['rom_id']}/link")
    check(s == 200 and os.listdir(mount) == [], "unlinked games disappear from the mount")
    check(not os.path.exists(os.path.join(data_dir, "cache", "stream", str(target["rom_id"]))), "their cached blocks are removed")
    s, st = call(api, "POST", "/api/v1/settings", {"install_mode": "stream"})
    check(s == 200 and st["install_mode"] == "stream", "install mode setting")
    s, _ = call(api, "POST", "/api/v1/settings", {"install_mode": "nfs"})
    check(s == 400, "unknown install mode refused")

    print("Second profile")
    s, p2 = call(api, "POST", "/api/v1/profiles", {"name": "Guest"})
    pair(api, p2["id"], USER2, PWD2)
    profiles = call(api, "GET", "/api/v1/profiles")[1]
    check(len(profiles) == 2 and all(p["paired"] for p in profiles), "two profiles paired with two RomM accounts")
    s, _ = call(api, "POST", f"/api/v1/profiles/{p2['id']}/activate")
    st = call(api, "GET", "/api/v1/status")[1]
    check(st["active_profile"]["romm_user"] == USER2, "active profile switch")
    s, _ = call(api, "POST", f"/api/v1/games/{fr['rom_id']}/prefs", {"version": japan["rom_id"]})
    call(api, "POST", f"/api/v1/profiles/{p1['id']}/activate")
    check(crystal("fr")["rom_id"] != japan["rom_id"], "version choices are per profile")
    call(api, "POST", f"/api/v1/profiles/{p2['id']}/activate")
    devices = romm("GET", "/api/devices")
    check(any(d.get("client") == "borne" for d in devices), "Borne device registered in RomM")

    print("Game details and media")
    rid = call(api, "GET", "/api/v1/library")[1][0]["rom_id"]
    s, f = call(api, "GET", f"/api/v1/games/{rid}/facts?lang=fr")
    check(s == 200 and f["facts"] is None and "screenshots" in f and "companies" in f, "game details come from RomM only")
    s, _ = call(api, "GET", f"/api/v1/games/{rid}/art/../../etc")
    check(s in (400, 404), "unknown art kind refused")
    s, _ = call(api, "GET", f"/api/v1/games/{rid}/art/side")
    check(s in (200, 404), "case spine served or reported missing")
    s, rep = call(api, "GET", "/api/v1/media/report")
    check(s == 200 and set(rep["kinds"]) == {"front", "side", "back", "physical", "logo"} and rep["platforms"], "media report per console")
    s, st = call(api, "GET", "/api/v1/screenscraper")
    check(s == 200 and "developer_access" in st and "password" not in json.dumps(st), "ScreenScraper status exposes no secret")
    if not st["developer_access"]:
        s, e = call(api, "POST", "/api/v1/screenscraper", {"user": "u", "password": "p"})
        check(s == 409 and "developer access" in e.get("error", ""), "ScreenScraper refused plainly without developer access")
    s, _ = call(api, "POST", "/api/v1/screenscraper", {"user": "", "password": ""})
    check(s == 400, "ScreenScraper account needs a user and a password")
    s, em = call(api, "GET", "/api/v1/emulators")
    check(s == 200 and {"retroarch", "dolphin", "pcsx2"} <= {e["id"] for e in em["programs"]} and not em["session"]["running"],
          "emulators listed, no game running")
    nes = [c for c in em["consoles"] if c["slug"] == "nes"]
    check(nes and nes[0]["chosen"] == "mesen" and len(nes[0]["choices"]) >= 2, "a choice of emulators per console, the first one by default")
    s, e = call(api, "POST", "/api/v1/consoles/nes/emulator", {"engine": "unknown"})
    check(s == 400, "an emulator unknown for the console refused")
    s, e = call(api, "POST", "/api/v1/games/999999/play", {})
    check(s == 409 and "unknown game" in e.get("error", ""), "playing an unknown game refused")
    s, e = call(api, "POST", "/api/v1/emulators/dolphin/path", {"path": "relative/dolphin"})
    check(s == 400, "an emulator path must be an absolute program")
    s, e = call(api, "POST", "/api/v1/session/stop", {})
    check(s == 200 and e["stopped"] is False, "nothing to stop when no game runs")
    s, e = call(api, "POST", "/api/v1/games/999999/gameplay", {})
    check(s == 404, "gameplay video of an unknown game refused")
    s, e = call(api, "POST", f"/api/v1/games/{rid}/gameplay", {})
    check((s == 200 and e["path"].endswith((".mp4", ".webm", ".mkv", ".m4v"))) or (s == 404 and "trailer" in e.get("error", "")),
          "gameplay video served (ScreenScraper, else the trailer) or reported missing")
    s, _ = call(api, "POST", "/api/v1/debug/stick?x=1&y=0")
    check(s != 200, "debug input closed outside tests")
    s, _ = call(api, "GET", f"/api/v1/games/{rid}/screenshots/9")
    check(s == 400, "screenshot index out of range refused")

    print("Diagnostics")
    s, rep = call(api, "POST", "/api/v1/diagnostic-report")
    check(s == 200 and rep["paths"], "diagnostic report exported")
    with open(rep["paths"][0], encoding="utf-8") as f:
        text = f.read()
    with open(secret_file, encoding="utf-8") as f:
        token = f.read().strip()
    check("RomM " in text and "--- log ---" in text and "synced" in text, "report holds versions and the log")
    check(token not in text and "rmm_" not in text and api.rsplit("/", 1)[-1] not in text, "report holds no token")
    with open(os.path.join(data_dir, "logs", "borne.log"), encoding="utf-8") as f:
        log = f.read()
    check(token not in log and api.rsplit("/", 1)[-1] not in log, "log file holds no token")

    lib_dir = os.environ.get("BORNE_IT_ROMM_LIBRARY")
    if lib_dir:
        # A server whose stored SHA-1 no longer matches what it serves (same size): Borne
        # downloads twice, gets identical bytes, keeps the game and says so in the log.
        print("Server hash differs from the served bytes")
        target = os.path.join(lib_dir, "genesis", "Hyper Rush (Japan).md")
        with open(target, "r+b") as f:
            f.seek(-1, 2); last = f.read(1); f.seek(-1, 2); f.write(bytes([last[0] ^ 0xFF]))
        try:
            hits = [g for g in call(api, "GET", "/api/v1/library?q=hyper%20rush")[1]]
            rid = hits[0]["rom_id"]
            call(api, "POST", f"/api/v1/games/{rid}/download")
            g = wait_download(api, rid)
            check(g["local_state"] == "local", "game kept when two downloads are identical")
            with open(os.path.join(data_dir, "logs", "borne.log"), encoding="utf-8") as f:
                check("two downloads are identical" in f.read(), "hash difference explained in the log")
        finally:
            with open(target, "r+b") as f:
                f.seek(-1, 2); f.write(last)

    print("Offline")
    core.send_signal(signal.SIGTERM); core.wait()
    env_offline = dict(env)
    # Make the server unreachable: point the database at a dead address.
    import sqlite3
    c = sqlite3.connect(os.path.join(data_dir, "state.db")); c.execute("UPDATE settings SET value='http://127.0.0.1:1' WHERE key='romm_url'"); c.commit(); c.close()
    core, api = start_core()
    time.sleep(2)
    lib = call(api, "GET", "/api/v1/library")[1]
    check(len(lib) == 29 and sum(g["local_state"] == "local" for g in lib) >= 2, "catalog and local games available offline")
    st = call(api, "GET", "/api/v1/status")[1]
    check(st["online"] is False, "offline state reported")

    print(f"\n{len(passed)} checks passed")
finally:
    try:
        core.send_signal(signal.SIGTERM)
    except Exception:
        pass
    subprocess.run(["fusermount3", "-u", "-z", os.path.join(data_dir, "mount")], capture_output=True)
    shutil.rmtree(data_dir, ignore_errors=True)
