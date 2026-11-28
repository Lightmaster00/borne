#!/usr/bin/env bash
# End-to-end test of in-app updates (Windows), against a local release server: the installed
# build 100 finds build 101 on the dev channel, refuses a manifest altered after signing and a
# damaged download, downloads the archive, and applies the update: the core exits, the detached
# updater in %TEMP% swaps the package and relaunches the new core, which the test follows
# through the log file (the updater inherits the core's standard output). Then build 102 is
# published in parts where only the core changed: only that part is downloaded and applied.
#
#   tests/update_test-windows.sh <package dir>   (e.g. out/Borne, built by scripts/package-windows.sh)
# Runs under Git Bash (curl, sed, python3, taskkill).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$(cd "$1" && pwd)"
WORK="$(mktemp -d)"
cleanup() {
  taskkill //F //IM borne.exe >/dev/null 2>&1 || true
  kill "${SRV:-}" 2>/dev/null || true
  sleep 0.5
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
fail() { echo "FAILED: $1"; echo "--- core log ---"; cat "$WORK/core.log" 2>/dev/null; exit 1; }
ok() { echo "  ok  $1"; }
FSIZE() { python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$1"; }
FHASH() { python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }

# A release key made for this test: the builds take only manifests signed with it (as official
# builds do when the repository has one), and every manifest below is signed with it.
openssl genpkey -algorithm ed25519 -out "$WORK/key.pem" 2>/dev/null
export UPDATE_SIGNING_KEY="$(cat "$WORK/key.pem")"
export UPDATE_PUBLIC_KEY="$(openssl pkey -in "$WORK/key.pem" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n')"
export BORNE_UPDATE_PUBKEY="$UPDATE_PUBLIC_KEY"
# Signs a manifest (again, after a change: its old signature taken off first).
sign() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]; b = open(p, "rb").read().strip()
open(p, "wb").write(re.sub(rb'^\{"signature":"[0-9a-f]*",', b"{", b))
PY
  python3 "$HERE/scripts/release/sign.py" "$1" >/dev/null
}

build_core() {  # <build number> <version> <output binary>
  BORNE_BUILD="$1" BORNE_VERSION="$2" BORNE_COMMIT=test cargo build --release -q --manifest-path "$HERE/core/Cargo.toml"
  cp "$HERE/core/target/release/borne.exe" "$3"
}

# Installed copy (build 100) and the published one (build 101).
mkdir -p "$WORK/install" "$WORK/release/download/dev" "$WORK/new"
cp -a "$PKG" "$WORK/install/Borne"
build_core 100 0.1.0 "$WORK/install/Borne/bin/borne.exe"
cp -a "$PKG" "$WORK/new/Borne"
build_core 101 0.1.1 "$WORK/new/Borne/bin/borne.exe"
(cd "$WORK/new" && python3 -c "import shutil; shutil.make_archive('Borne-windows-x86_64', 'zip', root_dir='$WORK/new', base_dir='Borne')")
mv "$WORK/new/Borne-windows-x86_64.zip" "$WORK/release/download/dev/"
SHA=$(FHASH "$WORK/release/download/dev/Borne-windows-x86_64.zip")
SIZE=$(FSIZE "$WORK/release/download/dev/Borne-windows-x86_64.zip")

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$PORT"
cat > "$WORK/release/download/dev/latest.json" <<EOF
{ "version": "0.1.1", "build": 101, "channel": "dev", "commit": "test", "date": "today", "notes": "Test build",
  "assets": { "windows-x86_64": { "url": "$BASE/download/dev/Borne-windows-x86_64.zip", "sha256": "$SHA", "size": $SIZE } } }
EOF
sign "$WORK/release/download/dev/latest.json"

(cd "$WORK/release" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV=$!

export BORNE_DATA_DIR="$WORK/data" BORNE_UPDATE_URL="$BASE"
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
"$WORK/install/Borne/bin/borne.exe" --no-ui > "$WORK/core.log" 2>&1 &
CORE=$!
api() { grep -ao 'API http://[^ ]*' "$WORK/core.log" | tail -1 | cut -d' ' -f2; }
for _ in $(seq 1 40); do [ -n "$(api)" ] && break; sleep 0.25; done
API=$(api); [ -n "$API" ] || fail "the core did not start"
state() { curl -sf "$API/api/v1/update" | python3 -c 'import json,sys; print(json.load(sys.stdin)["update"]["state"])'; }
wait_state() { for _ in $(seq 1 120); do [ "$(state)" = "$1" ] && return 0; sleep 0.5; done; return 1; }

curl -sf "$API/api/v1/hello" | grep -q '"build":100' || fail "installed build"
ok "installed build 100"
curl -sf -X POST "$API/api/v1/settings" -H 'Content-Type: application/json' -d '{"update_channel":"dev"}' >/dev/null
curl -sf -X POST "$API/api/v1/update/check" >/dev/null
wait_state available || fail "update not found ($(state))"
ok "build 101 found on the dev channel"

# A manifest changed after signing (here: another build number) must be refused.
M="$WORK/release/download/dev/latest.json"
cp "$M" "$WORK/signed.json"
sed -i 's/"build": 101/"build": 109/' "$M"
curl -sf -X POST "$API/api/v1/update/check" >/dev/null
wait_state error || fail "altered manifest accepted ($(state))"
curl -sf "$API/api/v1/update" | grep -q "signature" || fail "altered manifest: not refused for its signature"
ok "altered manifest refused (signature)"
cp "$WORK/signed.json" "$M"

# A damaged download must be refused and leave the installation untouched.
GOOD_SHA="$SHA"
sed -i "s/$GOOD_SHA/0000000000000000000000000000000000000000000000000000000000000000/" "$M"
sign "$M"
curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state available || fail "recheck"
curl -sf -X POST "$API/api/v1/update/download" >/dev/null
wait_state error || fail "damaged download not detected ($(state))"
[ ! -d "$WORK/install/.borne-update-101/Borne" ] || fail "damaged update extracted"
ok "damaged download refused (SHA-256)"
sed -i "s/0000000000000000000000000000000000000000000000000000000000000000/$GOOD_SHA/" "$M"
sign "$M"

curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state available || fail "recheck"
curl -sf -X POST "$API/api/v1/update/download" >/dev/null
wait_state ready || fail "download ($(state))"
ok "downloaded, verified and extracted"
OLD_API="$API"
curl -sf -X POST "$API/api/v1/update/apply" >/dev/null || fail "apply"
# Unlike on Unix (re-exec, same process), the core exits and the updater relaunches it: the old
# pid dies and a new core answers on a new address, written to the same log file.
for _ in $(seq 1 120); do [ -n "$(api)" ] && [ "$(api)" != "$OLD_API" ] && break; sleep 0.5; done
API=$(api); [ "$API" != "$OLD_API" ] || fail "no restart"
for _ in $(seq 1 20); do curl -sf "$API/api/v1/hello" >/dev/null && break; sleep 0.25; done
curl -sf "$API/api/v1/hello" | grep -q '"build":101' || fail "new build not running"
ok "restarted on build 101 (updater swap)"
[ -f "$WORK/install/.borne-previous/bin/borne.exe" ] || fail "previous version not kept"
ok "previous version kept aside"
curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state uptodate || fail "up to date ($(state))"
ok "up to date afterwards"

# Build 102, published in parts: only the core differs from the installed build 101.
rm -rf "$WORK/new" && mkdir -p "$WORK/new"
cp -a "$WORK/install/Borne" "$WORK/new/Borne"
build_core 102 0.1.2 "$WORK/new/Borne/bin/borne.exe"
D="$WORK/release/download/dev"
rm -f "$D"/*.zip "$D"/*.tar.gz
(cd "$WORK/new" && python3 -c "import shutil; shutil.make_archive('Borne-windows-x86_64', 'zip', root_dir='$WORK/new', base_dir='Borne')")
mv "$WORK/new/Borne-windows-x86_64.zip" "$D/"
python3 "$HERE/scripts/release/parts.py" "$WORK/new/Borne" windows "$D" Borne-windows-x86_64 > "$WORK/parts.json"
python3 - "$D" "$BASE" "$WORK/parts.json" <<'PY'
import hashlib, json, os, sys
d, base, parts = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
full = open(f"{d}/Borne-windows-x86_64.zip", "rb").read()
asset = {"url": f"{base}/download/dev/Borne-windows-x86_64.zip", "sha256": hashlib.sha256(full).hexdigest(), "size": len(full),
         "parts": {k: {"url": f"{base}/download/dev/{v['file']}", "sha256": v["sha256"], "size": v["size"], "tree": v["tree"]} for k, v in parts.items()}}
json.dump({"version": "0.1.2", "build": 102, "channel": "dev", "commit": "test", "date": "today", "notes": "Test build",
           "assets": {"windows-x86_64": asset}}, open(f"{d}/latest.json", "w"))
PY
sign "$D/latest.json"
CORE_SIZE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["core"]["size"])' "$WORK/parts.json")
curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state available || fail "build 102 not found ($(state))"
ANNOUNCED=$(curl -sf "$API/api/v1/update" | python3 -c 'import json,sys; u=json.load(sys.stdin)["update"]; print(u["size"], ",".join(u["parts"]))')
[ "$ANNOUNCED" = "$CORE_SIZE core" ] || fail "announced download: $ANNOUNCED, expected $CORE_SIZE core"
ok "announced before downloading: only the core part"
curl -sf -X POST "$API/api/v1/update/download" >/dev/null
wait_state ready || fail "download by parts ($(state))"
TOTAL=$(curl -sf "$API/api/v1/update" | python3 -c 'import json,sys; print(json.load(sys.stdin)["update"]["total"])')
[ "$TOTAL" = "$CORE_SIZE" ] || fail "downloaded $TOTAL bytes, expected only the core part ($CORE_SIZE)"
ok "only the changed part downloaded ($((CORE_SIZE / 1024)) KB of $(( $(FSIZE "$D/Borne-windows-x86_64.zip") / 1024 )) KB)"
OLD_API="$API"
curl -sf -X POST "$API/api/v1/update/apply" >/dev/null || fail "apply 102"
for _ in $(seq 1 120); do [ -n "$(api)" ] && [ "$(api)" != "$OLD_API" ] && break; sleep 0.5; done
API=$(api)
for _ in $(seq 1 20); do curl -sf "$API/api/v1/hello" >/dev/null && break; sleep 0.25; done
curl -sf "$API/api/v1/hello" | grep -q '"build":102' || fail "build 102 not running"
[ "$("$WORK/install/Borne/bin/borne.exe" --part-hashes "$WORK/install/Borne")" = "$("$WORK/new/Borne/bin/borne.exe" --part-hashes "$WORK/new/Borne")" ] \
  || fail "the assembled package differs from the published one"
ok "restarted on build 102, package identical to the published one"
echo "Update test passed"
