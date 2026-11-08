"""End-to-end test of the Borne core against a real RomM server.

    python3 tests/integration_romm.py <borne binary> <RomM url> <admin> <password> <account 2> <password 2>

Starts the core without a UI in a temporary data directory, then checks:
server, profiles, pairing (approved through the RomM API as if from a phone), catalog and cover
sync, downloads (simple, extracted zip, large file interrupted by killing the core and then
resumed), local deletion, a second profile on another RomM account.
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
        g = call(api, "GET", f"/api/v1/games/{rom_id}")[1]
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
    check(sync["error"] is None and sync["total"] == 29, "29 games synced from RomM")
    wait(lambda: call(api, "GET", "/api/v1/status")[1]["sync"]["covers_pending"] == 0, 60, "covers")
    lib = call(api, "GET", "/api/v1/library")[1]
    covers = [g for g in lib if g["cover_local"] and os.path.exists(g["cover_local"])]
    check(len(covers) == 29, "29 covers cached locally")
    plats = call(api, "GET", "/api/v1/platforms")[1]
    check({p["slug"] for p in plats} >= {"nes", "genesis", "ngc", "ps2", "switch"}, "5 platforms")
    nes = call(api, "GET", "/api/v1/library?platform=nes")[1]
    check(len(nes) == 12, "platform filter")
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
    check(s == 200 and call(api, "GET", f"/api/v1/games/{small['rom_id']}")[1]["local_state"] == "remote", "local deletion (the game stays on RomM)")
    check(romm("GET", f"/api/roms/{small['rom_id']}")["id"] == small["rom_id"], "game still present in RomM")

    print("Second profile")
    s, p2 = call(api, "POST", "/api/v1/profiles", {"name": "Guest"})
    pair(api, p2["id"], USER2, PWD2)
    profiles = call(api, "GET", "/api/v1/profiles")[1]
    check(len(profiles) == 2 and all(p["paired"] for p in profiles), "two profiles paired with two RomM accounts")
    s, _ = call(api, "POST", f"/api/v1/profiles/{p2['id']}/activate")
    st = call(api, "GET", "/api/v1/status")[1]
    check(st["active_profile"]["romm_user"] == USER2, "active profile switch")
    devices = romm("GET", "/api/devices")
    check(any(d.get("client") == "borne" for d in devices), "Borne device registered in RomM")

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
    shutil.rmtree(data_dir, ignore_errors=True)
