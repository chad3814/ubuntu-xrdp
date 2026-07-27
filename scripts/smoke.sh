#!/usr/bin/env bash
set -euo pipefail

# Smoke tests run in an isolated compose project on a non-default host
# port so they don't collide with a real xrdp on the host or with the
# user's own `docker compose up`.
export COMPOSE_PROJECT_NAME=ubuntu-xrdp-lxqt-smoke
export HOST_RDP_PORT=13389

CID=""
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
  esac
done

cleanup() {
  if [[ $KEEP -eq 0 ]]; then
    "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

COMPOSE=(docker compose -f docker-compose.yml -f scripts/compose.smoke.yml)

echo "==> docker compose up"
"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build

echo "==> assert container is running"
sleep 2
CID=$("${COMPOSE[@]}" ps -q desktop)
if [[ -z "$CID" ]]; then
  echo "FAIL: no desktop container from compose" >&2
  "${COMPOSE[@]}" logs >&2 || true
  exit 1
fi
if [[ "$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null)" != "true" ]]; then
  echo "FAIL: container exited immediately" >&2
  "${COMPOSE[@]}" logs >&2 || true
  exit 1
fi
echo "OK: container is running ($CID)"

echo "==> wait for xrdp process to appear inside the container"
for i in $(seq 1 30); do
  if docker exec "$CID" pgrep -x xrdp >/dev/null 2>&1; then
    echo "OK: xrdp process running (after ${i}s)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "FAIL: xrdp process never appeared within 30s" >&2
    "${COMPOSE[@]}" logs >&2 || true
    exit 1
  fi
  sleep 1
done

echo "==> assert host can reach xrdp on $HOST_RDP_PORT"
if ! (echo > /dev/tcp/127.0.0.1/"$HOST_RDP_PORT") >/dev/null 2>&1; then
  echo "FAIL: cannot reach xrdp on host port $HOST_RDP_PORT" >&2
  exit 1
fi
echo "OK: xrdp reachable at 127.0.0.1:$HOST_RDP_PORT"

echo "==> assert user exists with expected shell and sudo"
docker exec "$CID" id ubuntu >/dev/null
docker exec "$CID" getent passwd ubuntu | grep -q ':/bin/bash$' \
  || { echo "FAIL: ubuntu shell is not /bin/bash" >&2; exit 1; }
docker exec "$CID" sudo -l -U ubuntu | grep -q 'NOPASSWD: ALL' \
  || { echo "FAIL: ubuntu lacks passwordless sudo" >&2; exit 1; }
echo "OK: user ubuntu has bash + passwordless sudo"

echo "==> assert xrdp cert is not the packaged default"
PACKAGED_FP=$(docker exec "$CID" cat /etc/xrdp/.packaged-cert-fingerprint)
CURRENT_FP=$(docker exec "$CID" openssl x509 -in /etc/xrdp/cert.pem -noout -fingerprint -sha256 | cut -d= -f2)
if [ "$PACKAGED_FP" = "$CURRENT_FP" ]; then
  echo "FAIL: xrdp cert fingerprint matches packaged default" >&2
  exit 1
fi
echo "OK: xrdp cert regenerated (packaged=$PACKAGED_FP current=$CURRENT_FP)"

echo "==> assert LXQt + dev tools"
docker exec "$CID" sh -c 'command -v startlxqt >/dev/null' \
  || { echo "FAIL: startlxqt missing" >&2; exit 1; }
# LXQt is only a desktop shell; it needs an X window manager to actually
# run. lxqt-core Recommends openbox, but we build --no-install-recommends,
# so we install openbox explicitly. Without it, first-connect prompts the
# user to pick a WM from an empty list.
docker exec "$CID" sh -c 'command -v openbox >/dev/null' \
  || { echo "FAIL: openbox (X window manager) missing" >&2; exit 1; }
# lxqt-core Recommends breeze-icon-theme; without recommends the panel and
# menus render with blank icons. hicolor is the base fallback theme.
for theme in breeze hicolor Adwaita; do
  docker exec "$CID" test -d "/usr/share/icons/$theme" \
    || { echo "FAIL: icon theme $theme missing" >&2; exit 1; }
done
# Curated LXQt extras that Recommends would normally pull in; without
# them the desktop feels half-installed (no notifications, no launcher,
# no gvfs, etc.).
for pkg in lxqt-notificationd lxqt-qtplugin lxqt-runner lxqt-about lxqt-sudo \
           lxqt-powermanagement \
           gvfs-backends gvfs-fuse ffmpegthumbnailer qt6-image-formats-plugins; do
  docker exec "$CID" dpkg -s "$pkg" >/dev/null 2>&1 \
    || { echo "FAIL: $pkg missing" >&2; exit 1; }
done
for tool in git curl wget vim nano gcc python3 pip3 ssh; do
  docker exec "$CID" sh -c "command -v $tool >/dev/null" \
    || { echo "FAIL: $tool missing" >&2; exit 1; }
done
docker exec "$CID" sh -c '! dpkg -s light-locker >/dev/null 2>&1' \
  || { echo "FAIL: light-locker is installed" >&2; exit 1; }
docker exec "$CID" sh -c '! dpkg -s xscreensaver >/dev/null 2>&1' \
  || { echo "FAIL: xscreensaver is installed" >&2; exit 1; }
echo "OK: LXQt + dev tools + no locker/screensaver"

echo "==> assert Firefox from Mozilla APT repo"
docker exec "$CID" sh -c 'command -v firefox >/dev/null' \
  || { echo "FAIL: firefox missing" >&2; exit 1; }
docker exec "$CID" dpkg -s firefox | grep -q '^Maintainer: Mozilla <release@mozilla.com>' \
  || { echo "FAIL: firefox is not the Mozilla-maintained package" >&2; \
       docker exec "$CID" dpkg -s firefox | grep -E '^(Maintainer|Version)' >&2; \
       exit 1; }
docker exec "$CID" test -f /etc/apt/sources.list.d/mozilla.list \
  || { echo "FAIL: Mozilla apt source missing" >&2; exit 1; }
echo "OK: firefox from Mozilla APT repo"

echo "==> assert home volume and shm_size"
docker exec "$CID" sh -c 'stat -c %m /home' | grep -q '^/home$' \
  || { echo "FAIL: /home is not its own mount point" >&2; exit 1; }
SHM_BYTES=$(docker exec "$CID" sh -c 'df -B1 /dev/shm | awk "NR==2 {print \$2}"')
if [[ -z "$SHM_BYTES" || "$SHM_BYTES" -lt 1000000000 ]]; then
  echo "FAIL: /dev/shm smaller than 1GB (got $SHM_BYTES bytes)" >&2
  exit 1
fi
echo "OK: home volume mounted, shm=${SHM_BYTES} bytes"
