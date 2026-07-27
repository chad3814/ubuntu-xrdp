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
