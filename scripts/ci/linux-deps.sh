#!/usr/bin/env bash
# Installs the Linux build dependencies on a GitHub runner, without getting stuck on a stalled
# Ubuntu mirror: several mirrors in turn, short network timeouts, bounded attempts, and the
# downloaded packages kept in a cache directory ($APT_CACHE) so that later runs install them
# without the network at all.
#   scripts/ci/linux-deps.sh <package>...
set -uo pipefail
CACHE="${APT_CACHE:-$HOME/apt-cache}"
mkdir -p "$CACHE"
export DEBIAN_FRONTEND=noninteractive

# Offline first: the cached packages, when they are all there.
if [ -f "$CACHE/list" ] && [ "$(cat "$CACHE/list")" = "$*" ] && ls "$CACHE"/*.deb >/dev/null 2>&1; then
  if sudo dpkg -i "$CACHE"/*.deb >/dev/null; then echo "installed from the cache"; exit 0; fi
  echo "cache unusable, going online"
fi

# Mirrors tried by apt in priority order (mirror+file sources on ubuntu-24.04 runners); each
# attempt puts another one first.
MIRRORS=(http://azure.archive.ubuntu.com/ubuntu/ http://mirrors.edge.kernel.org/ubuntu/
         https://archive.ubuntu.com/ubuntu/ http://mirror.math.princeton.edu/pub/ubuntu/)
mirrors() {
  local n=${#MIRRORS[@]} i
  for ((i = 0; i < n; i++)); do printf '%s\tpriority:%d\n' "${MIRRORS[$(((i + $1) % n))]}" $((i + 1)); done \
    | sudo tee /etc/apt/apt-mirrors.txt >/dev/null
}
sudo rm -f /etc/apt/sources.list.d/microsoft-prod.list /etc/apt/sources.list.d/microsoft-prod.sources
APT=(-o Acquire::Retries=0 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15
     -o Acquire::http::Pipeline-Depth=0 -o Dpkg::Use-Pty=0)

for attempt in 1 2 3 4; do
  echo "attempt $attempt"
  mirrors $((attempt - 1))
  sudo timeout 120 apt-get "${APT[@]}" update || true
  sudo rm -f /var/cache/apt/archives/*.deb
  if sudo timeout 240 apt-get "${APT[@]}" install -y --no-install-recommends "$@"; then
    rm -f "$CACHE"/*.deb
    cp /var/cache/apt/archives/*.deb "$CACHE/" 2>/dev/null || true
    echo "$*" > "$CACHE/list"
    exit 0
  fi
done
echo "could not install the build dependencies"; exit 1
