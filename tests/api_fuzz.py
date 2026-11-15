#!/usr/bin/env python3
"""Hits every API route with odd input (ids, bodies, paths); fails on a crash, a 5xx or a panic.

    python3 tests/api_fuzz.py core/target/release/borne http://127.0.0.1:8080 <user> <password>
"""
import json, os, re, subprocess, sys, tempfile, time, urllib.request, urllib.error

core, server, user, password = sys.argv[1:5]
data = tempfile.mkdtemp(prefix="borne-fuzz-")
env = dict(os.environ, BORNE_DATA_DIR=data)
p = subprocess.Popen([core, "--no-ui"], env=env, stderr=subprocess.PIPE, text=True)
api = None
while api is None:
    line = p.stderr.readline()
    m = re.search(r"API (\S+)", line)
    if m:
        api = m.group(1)

def call(method, path, body=None, timeout=40):
    req = urllib.request.Request(api + path, method=method,
                                 data=None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode()))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()

call("POST", "/api/v1/server", {"url": server})
pid = json.loads(call("POST", "/api/v1/profiles", {"name": "Fuzz"})[1]).get("id")
call("POST", f"/api/v1/profiles/{pid}/activate")
print("login", call("POST", "/api/v1/profiles/login", {"username": user, "password": password})[0])
call("POST", "/api/v1/sync"); time.sleep(8)

src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../core/src/api.rs")).read()
routes = set(re.findall(r"//!\s+((?:GET|POST|PUT|DELETE)(?:\|POST)?)\s+(/api/v1/\S+)", src))
skip = ("install", "update/download", "update/apply", "debug/", "diagnostic-report", "media/refresh",
        "screenscraper/fetch", "from-romm", "emulators/auto-update", "pairing")
ids = ["1", "4", "34", "0", "-1", "999999999", "abc", "..%2F..%2Fetc", "%00", "%C3%A9"]
bodies = [None, b"", b"{", b"[]", b"null", {"x": 1}, {"path": "/etc/passwd"}, {"url": "file:///etc/passwd"},
          {"key": "../../x", "value": "\n[evil]"}, {"name": "x" * 5000}, {"on": "yes"}, {"version": "abc"},
          {"url": "http://127.0.0.1:1/"}, {"engine": "../../bin/sh"}, {"value": 1e309}]
n = 0
failures = 0
for methods, route in sorted(routes):
    if any(s in route for s in skip):
        continue
    for method in methods.split("|"):
        for i in ids:
            path = re.sub(r"<[^>]+>", i, route.split("?")[0])
            for b in bodies if method != "GET" else [None]:
                st, _ = call(method, path, b)
                n += 1
                if st == 0 or st >= 500 and st not in (502, 503):
                    failures += 1
                    print("!", method, path, b if not isinstance(b, dict) else json.dumps(b)[:60], st)
        if p.poll() is not None:
            sys.exit(f"core exited after {method} {route}")
for q in ["q=%", "q=%e9%", "platform=../x", "sort=;drop", "lang=" + "x" * 1000]:
    call("GET", "/api/v1/library?" + q)
log = open(os.path.join(data, "logs/borne.log")).read()
panics = [l for l in log.splitlines() if "panic" in l]
print(n, "requests;", len(panics), "panics")
for l in panics[:20]:
    print(l)
p.terminate()
sys.exit(1 if panics or failures else 0)
