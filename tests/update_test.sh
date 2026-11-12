#!/usr/bin/env bash
# End-to-end test of in-app updates (Linux), against a local release server:
# an installed build 100 finds build 101 on the dev channel (full archive only, as older manifests),
# downloads it, verifies its SHA-256, swaps the package and restarts on the new core; then build
# 102 is published in parts (scripts/release/parts.py) where only the core changed: only that part
# is downloaded, the package is assembled and checked, and the core restarts on build 102.
#
#   tests/update_test.sh <package dir>      (e.g. out/Borne, built by scripts/package.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$(cd "$1" && pwd)"
WORK="$(mktemp -d)"
cleanup() {
  kill "${SRV:-}" "${CORE:-}" 2>/dev/null || true
  sleep 0.5
  fusermount3 -u -z "$WORK/data/mount" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAILED: $1"; echo "--- core log ---"; cat "$WORK/core.log" 2>/dev/null; exit 1; }
ok() { echo "  ok  $1"; }

build_core() {  # <build number> <version> <output binary>
  BORNE_BUILD="$1" BORNE_VERSION="$2" BORNE_COMMIT=test cargo build --release -q --manifest-path "$HERE/core/Cargo.toml"
  cp "$HERE/core/target/release/borne" "$3"
}

# Installed copy (build 100) and the published one (build 101).
mkdir -p "$WORK/install" "$WORK/release/download/dev" "$WORK/new"
cp -a "$PKG" "$WORK/install/Borne"
build_core 100 0.1.0 "$WORK/install/Borne/bin/borne"
cp -a "$PKG" "$WORK/new/Borne"
build_core 101 0.1.1 "$WORK/new/Borne/bin/borne"
tar czf "$WORK/release/download/dev/Borne-linux-x86_64.tar.gz" -C "$WORK/new" Borne
SHA=$(sha256sum "$WORK/release/download/dev/Borne-linux-x86_64.tar.gz" | cut -d' ' -f1)
SIZE=$(stat -c %s "$WORK/release/download/dev/Borne-linux-x86_64.tar.gz")

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$PORT"
cat > "$WORK/release/download/dev/latest.json" <<EOF
{ "version": "0.1.1", "build": 101, "channel": "dev", "commit": "test", "date": "today", "notes": "Test build",
  "assets": { "linux-x86_64": { "url": "$BASE/download/dev/Borne-linux-x86_64.tar.gz", "sha256": "$SHA", "size": $SIZE } } }
EOF
(cd "$WORK/release" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV=$!

export BORNE_DATA_DIR="$WORK/data" BORNE_UPDATE_URL="$BASE"
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
"$WORK/install/Borne/bin/borne" --no-ui > "$WORK/core.log" 2>&1 &
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

# A damaged download must be refused and leave the installation untouched.
GOOD_SHA="$SHA"
sed -i "s/$GOOD_SHA/0000000000000000000000000000000000000000000000000000000000000000/" "$WORK/release/download/dev/latest.json"
curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state available || fail "recheck"
curl -sf -X POST "$API/api/v1/update/download" >/dev/null
wait_state error || fail "damaged download not detected ($(state))"
[ ! -d "$WORK/install/.borne-update-101/Borne" ] || fail "damaged update extracted"
ok "damaged download refused (SHA-256)"
sed -i "s/0000000000000000000000000000000000000000000000000000000000000000/$GOOD_SHA/" "$WORK/release/download/dev/latest.json"

curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state available || fail "recheck"
curl -sf -X POST "$API/api/v1/update/download" >/dev/null
wait_state ready || fail "download ($(state))"
ok "downloaded, verified and extracted"
OLD_API="$API"
curl -sf -X POST "$API/api/v1/update/apply" >/dev/null || fail "apply"
for _ in $(seq 1 40); do [ "$(api)" != "$OLD_API" ] && break; sleep 0.25; done
API=$(api); [ "$API" != "$OLD_API" ] || fail "no restart"
for _ in $(seq 1 20); do curl -sf "$API/api/v1/hello" >/dev/null && break; sleep 0.25; done
curl -sf "$API/api/v1/hello" | grep -q '"build":101' || fail "new build not running"
ok "restarted on build 101 (same process, new core)"
kill -0 $CORE || fail "core stopped"
[ -x "$WORK/install/.borne-previous/bin/borne" ] || fail "previous version not kept"
ok "previous version kept aside"
curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state uptodate || fail "up to date ($(state))"
ok "up to date afterwards"

# Build 102, published in parts: only the core differs from the installed build 101.
rm -rf "$WORK/new" && mkdir -p "$WORK/new"
cp -a "$WORK/install/Borne" "$WORK/new/Borne"
build_core 102 0.1.2 "$WORK/new/Borne/bin/borne"
D="$WORK/release/download/dev"
rm -f "$D"/*.tar.gz
tar czf "$D/Borne-linux-x86_64.tar.gz" -C "$WORK/new" Borne
python3 "$HERE/scripts/release/parts.py" "$WORK/new/Borne" linux "$D" Borne-linux-x86_64 > "$WORK/parts.json"
python3 - "$D" "$BASE" "$WORK/parts.json" <<'PY'
import hashlib, json, os, sys
d, base, parts = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
full = open(f"{d}/Borne-linux-x86_64.tar.gz", "rb").read()
asset = {"url": f"{base}/download/dev/Borne-linux-x86_64.tar.gz", "sha256": hashlib.sha256(full).hexdigest(), "size": len(full),
         "parts": {k: {"url": f"{base}/download/dev/{v['file']}", "sha256": v["sha256"], "size": v["size"], "tree": v["tree"]} for k, v in parts.items()}}
json.dump({"version": "0.1.2", "build": 102, "channel": "dev", "commit": "test", "date": "today", "notes": "Test build",
           "assets": {"linux-x86_64": asset}}, open(f"{d}/latest.json", "w"))
PY
CORE_SIZE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["core"]["size"])' "$WORK/parts.json")
curl -sf -X POST "$API/api/v1/update/check" >/dev/null; wait_state available || fail "build 102 not found ($(state))"
curl -sf -X POST "$API/api/v1/update/download" >/dev/null
wait_state ready || fail "download by parts ($(state))"
TOTAL=$(curl -sf "$API/api/v1/update" | python3 -c 'import json,sys; print(json.load(sys.stdin)["update"]["total"])')
[ "$TOTAL" = "$CORE_SIZE" ] || fail "downloaded $TOTAL bytes, expected only the core part ($CORE_SIZE)"
ok "only the changed part downloaded ($((CORE_SIZE / 1024)) KB of $(( $(stat -c %s "$D/Borne-linux-x86_64.tar.gz") / 1024 )) KB)"
OLD_API="$API"
curl -sf -X POST "$API/api/v1/update/apply" >/dev/null || fail "apply 102"
for _ in $(seq 1 40); do [ "$(api)" != "$OLD_API" ] && break; sleep 0.25; done
API=$(api)
for _ in $(seq 1 20); do curl -sf "$API/api/v1/hello" >/dev/null && break; sleep 0.25; done
curl -sf "$API/api/v1/hello" | grep -q '"build":102' || fail "build 102 not running"
[ "$("$WORK/install/Borne/bin/borne" --part-hashes "$WORK/install/Borne")" = "$("$WORK/install/Borne/bin/borne" --part-hashes "$WORK/new/Borne")" ] \
  || fail "the assembled package differs from the published one"
ok "restarted on build 102, package identical to the published one"
echo "Update test passed"
