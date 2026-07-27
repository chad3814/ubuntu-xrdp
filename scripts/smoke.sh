#!/usr/bin/env bash
set -euo pipefail

IMAGE=ubuntu-xrdp-lxqt:test
CID=""
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
  esac
done

cleanup() {
  if [[ -n "$CID" && $KEEP -eq 0 ]]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> docker build"
docker build -t "$IMAGE" .

echo "OK: build succeeded"

echo "==> docker run"
CID=$(docker run -d --rm -p 13389:3389 "$IMAGE")

echo "==> assert container is running"
sleep 2
if [[ "$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null)" != "true" ]]; then
  echo "FAIL: container exited immediately" >&2
  docker logs "$CID" >&2 || true
  exit 1
fi
echo "OK: container is running"

echo "==> wait for xrdp process to appear inside the container"
for i in $(seq 1 30); do
  if docker exec "$CID" pgrep -x xrdp >/dev/null 2>&1; then
    echo "OK: xrdp process running (after ${i}s)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "FAIL: xrdp process never appeared within 30s" >&2
    docker logs "$CID" >&2 || true
    exit 1
  fi
  sleep 1
done

echo "==> assert host can reach xrdp on 3389"
if ! (echo > /dev/tcp/127.0.0.1/13389) >/dev/null 2>&1; then
  echo "FAIL: cannot reach xrdp on host port 13389" >&2
  exit 1
fi
echo "OK: xrdp reachable at 127.0.0.1:13389"
