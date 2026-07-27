# Ubuntu-xrdp-LXQt Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Docker image that boots an LXQt desktop reachable via RDP on port 3389, built from `ubuntu:26.04` and supervised by s6-overlay, along with a `docker-compose.yml` and a smoke test.

**Architecture:** Single-stage Dockerfile that layers packages, s6-overlay, and a `rootfs/` overlay onto `ubuntu:26.04`. `s6-overlay` supervises `dbus` → `xrdp-sesman` → `xrdp`. `cont-init.d` scripts create the runtime user and regenerate the xrdp TLS cert on first boot. `docker-compose.yml` exposes 3389 and mounts a named volume at `/home`.

**Tech Stack:** Docker (buildx for multi-arch), Ubuntu 26.04, xrdp + xorgxrdp, LXQt, s6-overlay v3, Firefox from `packages.mozilla.org`, plain POSIX shell for init scripts and smoke test.

## Global Constraints

- Base image: `ubuntu:26.04` (Resolute Rhino LTS).
- Init system: **s6-overlay v3** (no supervisord, no systemd, no display manager).
- Desktop: **LXQt** only (no XFCE, no LXDE, no GNOME).
- Default user/password: `ubuntu` / `ubuntu`, overrideable via `USER` / `PASSWORD` env at run time.
- Passwordless sudo by default; `SUDO=no` disables.
- RDP port: `3389` (fixed inside container; remap externally if needed).
- Persistent home: named volume mounted at `/home`.
- `shm_size: 1gb` in the compose file (Firefox/Qt need it).
- Multi-arch: `linux/amd64` + `linux/arm64` via buildx; s6-overlay tarball picked by `$TARGETARCH`.
- Firefox: from **Mozilla's official APT repo**, NOT the Ubuntu archive package (26.04 ships a snap transitional stub).
- Remove `light-locker` and `xscreensaver` from the image (they fight headless X).
- No language packs beyond `en_US`.
- Repo layout: everything at repo root (`Dockerfile`, `docker-compose.yml`, `.dockerignore`, `README.md`, `rootfs/`, `scripts/`).
- Working directory for all commits: `/home/chad/Projects/ubuntu-xrdp/worktrees/main` on branch `main`.

## File Structure

```
Dockerfile                              # Single-stage build, arch-aware
docker-compose.yml                      # Named home volume, shm=1gb, 3389 exposed
.dockerignore                           # Keep build context small
README.md                               # How to build + run
scripts/
└── smoke.sh                            # Build, boot, assert
rootfs/
└── etc/
    ├── s6-overlay/s6-rc.d/
    │   ├── user/contents.d/
    │   │   ├── dbus                    # Empty marker: enable dbus
    │   │   ├── xrdp                    # Empty marker: enable xrdp
    │   │   └── xrdp-sesman             # Empty marker: enable xrdp-sesman
    │   ├── dbus/
    │   │   ├── type                    # "longrun"
    │   │   └── run                     # exec dbus-daemon --system --nofork
    │   ├── xrdp-sesman/
    │   │   ├── type                    # "longrun"
    │   │   ├── dependencies.d/dbus     # Empty marker: after dbus
    │   │   └── run                     # exec xrdp-sesman --nodaemon
    │   └── xrdp/
    │       ├── type                    # "longrun"
    │       ├── dependencies.d/xrdp-sesman   # Empty marker
    │       └── run                     # cleanup + exec xrdp --nodaemon
    ├── cont-init.d/
    │   ├── 01-user                     # useradd, chpasswd, sudoers
    │   └── 02-xrdp-cert                # regen cert if packaged default
    └── xrdp/
        └── startwm.sh                  # exec startlxqt for the session
```

Each rootfs file has a single, focused responsibility. Tasks below add these files incrementally so each commit produces a demonstrably-better image.

---

### Task 1: Repo scaffolding and empty-image build

**Files:**
- Create: `.dockerignore`
- Create: `Dockerfile`
- Create: `scripts/smoke.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `smoke.sh` accepts `--keep` to skip teardown; exits 0 on success, non-zero on failure.
  - Image tag `ubuntu-xrdp-lxqt:test` for smoke runs.

- [ ] **Step 1: Write the failing smoke script**

Create `scripts/smoke.sh`:

```bash
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
```

Make it executable: `chmod +x scripts/smoke.sh`.

- [ ] **Step 2: Run smoke to verify it fails (no Dockerfile yet)**

Run: `scripts/smoke.sh`
Expected: FAIL with "Dockerfile: no such file or directory".

- [ ] **Step 3: Write minimal Dockerfile**

Create `Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

CMD ["/bin/bash"]
```

Create `.dockerignore`:

```
.git
docs
scripts
README.md
*.md
```

Create `README.md`:

```markdown
# ubuntu-xrdp-lxqt

An Ubuntu 26.04 desktop-in-a-container that speaks RDP.

## Quickstart

    docker compose up -d
    # Connect any RDP client to localhost:3389 with ubuntu / ubuntu

See `docs/superpowers/specs/2026-07-27-ubuntu-xrdp-lxqt-design.md` for the design.
```

- [ ] **Step 4: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS ("OK: build succeeded").

- [ ] **Step 5: Commit**

```bash
git add Dockerfile .dockerignore README.md scripts/smoke.sh
git commit -m "Scaffold repo with empty ubuntu:26.04 Dockerfile and smoke test"
```

---

### Task 2: xrdp + s6-overlay boots and listens on 3389

**Files:**
- Modify: `Dockerfile`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/dbus/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/dbus/run`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/xrdp-sesman/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/xrdp-sesman/run`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/xrdp-sesman/dependencies.d/dbus`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/xrdp/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/xrdp/run`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/xrdp/dependencies.d/xrdp-sesman`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/dbus`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/xrdp-sesman`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/xrdp`
- Create: `rootfs/etc/xrdp/startwm.sh`
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - Container `ENTRYPOINT` is `/init` (s6-overlay stage 1).
  - Longruns `dbus`, `xrdp-sesman`, `xrdp` supervised.
  - TCP port 3389 accepts connections within 30 s of container start.
  - `startwm.sh` execs `startlxqt` (still absent at this task; harmless — the RDP session just won't launch a desktop yet, but the daemon comes up).

- [ ] **Step 1: Write the failing test**

Append to `scripts/smoke.sh` after the build line:

```bash
echo "==> docker run"
CID=$(docker run -d --rm -p 13389:3389 "$IMAGE")

echo "==> wait for xrdp on 3389"
for i in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/13389) >/dev/null 2>&1; then
    echo "OK: xrdp accepting on 3389 (after ${i}s)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "FAIL: xrdp did not accept on 3389 within 30s" >&2
    docker logs "$CID" >&2 || true
    exit 1
  fi
  sleep 1
done
```

- [ ] **Step 2: Run smoke to verify it fails**

Run: `scripts/smoke.sh`
Expected: FAIL — image runs `bash` and exits; no listener on 3389.

- [ ] **Step 3: Write s6 longrun definitions**

Create `rootfs/etc/s6-overlay/s6-rc.d/dbus/type` with contents:

```
longrun
```

Create `rootfs/etc/s6-overlay/s6-rc.d/dbus/run`:

```bash
#!/command/execlineb -P
foreground { mkdir -p /run/dbus }
foreground { chmod 755 /run/dbus }
exec dbus-daemon --system --nofork --nopidfile
```

Create `rootfs/etc/s6-overlay/s6-rc.d/xrdp-sesman/type`:

```
longrun
```

Create empty file `rootfs/etc/s6-overlay/s6-rc.d/xrdp-sesman/dependencies.d/dbus`.

Create `rootfs/etc/s6-overlay/s6-rc.d/xrdp-sesman/run`:

```bash
#!/command/execlineb -P
exec /usr/sbin/xrdp-sesman --nodaemon
```

Create `rootfs/etc/s6-overlay/s6-rc.d/xrdp/type`:

```
longrun
```

Create empty file `rootfs/etc/s6-overlay/s6-rc.d/xrdp/dependencies.d/xrdp-sesman`.

Create `rootfs/etc/s6-overlay/s6-rc.d/xrdp/run`:

```bash
#!/command/execlineb -P
foreground { rm -rf /tmp/.X11-unix }
foreground { mkdir -p /tmp/.X11-unix }
foreground { chmod 1777 /tmp/.X11-unix }
exec /usr/sbin/xrdp --nodaemon
```

Create empty marker files (enable longruns in the user bundle):
- `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/dbus`
- `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/xrdp-sesman`
- `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/xrdp`

Create `rootfs/etc/xrdp/startwm.sh`:

```bash
#!/bin/sh
if [ -r /etc/profile ]; then
  . /etc/profile
fi
if [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi
exec startlxqt
```

- [ ] **Step 4: Extend the Dockerfile to install xrdp + s6-overlay and copy rootfs**

Replace the Dockerfile body with:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    S6_OVERLAY_VERSION=3.2.0.2

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils \
      dbus dbus-x11 \
      xrdp xorgxrdp \
      openssl sudo tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) s6_arch=x86_64 ;; \
      arm64) s6_arch=aarch64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/s6-noarch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL -o /tmp/s6-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz"; \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz; \
    rm -f /tmp/s6-*.tar.xz

COPY rootfs/ /

RUN chmod +x /etc/xrdp/startwm.sh \
             /etc/s6-overlay/s6-rc.d/dbus/run \
             /etc/s6-overlay/s6-rc.d/xrdp-sesman/run \
             /etc/s6-overlay/s6-rc.d/xrdp/run

# Allow xrdp to read its cert/key
RUN adduser xrdp ssl-cert || true

EXPOSE 3389
ENTRYPOINT ["/init"]
```

- [ ] **Step 5: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS — xrdp accepts on 3389 within 30 s.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile rootfs
git add scripts/smoke.sh
git commit -m "Boot xrdp via s6-overlay, listening on 3389"
```

---

### Task 3: `01-user` creates the runtime user with sudo

**Files:**
- Create: `rootfs/etc/cont-init.d/01-user`
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: env vars `USER` (default `ubuntu`), `PASSWORD` (default `ubuntu`), `SUDO` (default `yes`), `TZ` (optional).
- Produces:
  - Unix user `${USER}` with home `/home/${USER}`, shell `/bin/bash`, groups `audio,video` (+ `sudo` when `SUDO=yes`).
  - `/etc/sudoers.d/${USER}` granting `NOPASSWD:ALL` when `SUDO=yes`.
  - Idempotent: on subsequent boots with a persistent `/home`, updates password and preserves the home directory.

- [ ] **Step 1: Write the failing test**

Extend `scripts/smoke.sh` (append after the port-open check):

```bash
echo "==> assert user exists with expected shell and sudo"
docker exec "$CID" id ubuntu >/dev/null
docker exec "$CID" getent passwd ubuntu | grep -q ':/bin/bash$' \
  || { echo "FAIL: ubuntu shell is not /bin/bash" >&2; exit 1; }
docker exec "$CID" sudo -l -U ubuntu | grep -q 'NOPASSWD: ALL' \
  || { echo "FAIL: ubuntu lacks passwordless sudo" >&2; exit 1; }
echo "OK: user ubuntu has bash + passwordless sudo"
```

- [ ] **Step 2: Run smoke to verify it fails**

Run: `scripts/smoke.sh`
Expected: FAIL — no `ubuntu` user exists yet.

- [ ] **Step 3: Write the init script**

Create `rootfs/etc/cont-init.d/01-user`:

```bash
#!/command/with-contenv sh
set -eu

USER="${USER:-ubuntu}"
PASSWORD="${PASSWORD:-ubuntu}"
SUDO="${SUDO:-yes}"
TZ="${TZ:-}"

if [ -n "$TZ" ]; then
  echo "$TZ" > /etc/timezone
  ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
fi

if ! id "$USER" >/dev/null 2>&1; then
  echo "creating user: $USER"
  useradd --create-home --shell /bin/bash --user-group \
          --groups audio,video "$USER"
fi

echo "$USER:$PASSWORD" | chpasswd

if [ "$SUDO" = "yes" ]; then
  usermod -aG sudo "$USER"
  install -m 0440 /dev/stdin "/etc/sudoers.d/90-$USER" <<EOF
$USER ALL=(ALL) NOPASSWD:ALL
EOF
else
  rm -f "/etc/sudoers.d/90-$USER"
  gpasswd -d "$USER" sudo >/dev/null 2>&1 || true
fi

chown -R "$USER:$USER" "/home/$USER"
```

Also add a chmod for it in the Dockerfile — extend the existing `chmod +x` line:

Modify the Dockerfile chmod block to include the new script:

```dockerfile
RUN chmod +x /etc/xrdp/startwm.sh \
             /etc/s6-overlay/s6-rc.d/dbus/run \
             /etc/s6-overlay/s6-rc.d/xrdp-sesman/run \
             /etc/s6-overlay/s6-rc.d/xrdp/run \
             /etc/cont-init.d/01-user
```

- [ ] **Step 4: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS — user `ubuntu` exists with `/bin/bash` and `NOPASSWD:ALL`.

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/cont-init.d/01-user Dockerfile scripts/smoke.sh
git commit -m "Create runtime user via cont-init.d with configurable sudo"
```

---

### Task 4: `02-xrdp-cert` regenerates the TLS cert on first boot

**Files:**
- Create: `rootfs/etc/cont-init.d/02-xrdp-cert`
- Modify: `Dockerfile` (capture packaged fingerprint, add chmod)
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: `/etc/xrdp/.packaged-cert-fingerprint` (SHA-256 of the packaged cert, captured at build time).
- Produces:
  - `/etc/xrdp/cert.pem` and `/etc/xrdp/key.pem` fresh 4096-bit RSA self-signed pair when the packaged cert is still in place.
  - Cert files mode `640`, owned by `xrdp:ssl-cert`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/smoke.sh`:

```bash
echo "==> assert xrdp cert is not the packaged default"
PACKAGED_FP=$(docker exec "$CID" cat /etc/xrdp/.packaged-cert-fingerprint)
CURRENT_FP=$(docker exec "$CID" openssl x509 -in /etc/xrdp/cert.pem -noout -fingerprint -sha256 | cut -d= -f2)
if [ "$PACKAGED_FP" = "$CURRENT_FP" ]; then
  echo "FAIL: xrdp cert fingerprint matches packaged default" >&2
  exit 1
fi
echo "OK: xrdp cert regenerated (packaged=$PACKAGED_FP current=$CURRENT_FP)"
```

- [ ] **Step 2: Run smoke to verify it fails**

Run: `scripts/smoke.sh`
Expected: FAIL — `/etc/xrdp/.packaged-cert-fingerprint` does not exist.

- [ ] **Step 3: Capture the packaged fingerprint at build time**

In the Dockerfile, after the initial apt install of xrdp (in the same layer that already installs xrdp), append this to that same `RUN`:

```dockerfile
    && openssl x509 -in /etc/xrdp/cert.pem -noout -fingerprint -sha256 \
         | cut -d= -f2 > /etc/xrdp/.packaged-cert-fingerprint
```

I.e. the full apt block becomes:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils \
      dbus dbus-x11 \
      xrdp xorgxrdp \
      openssl sudo tzdata \
    && openssl x509 -in /etc/xrdp/cert.pem -noout -fingerprint -sha256 \
         | cut -d= -f2 > /etc/xrdp/.packaged-cert-fingerprint \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 4: Write the init script**

Create `rootfs/etc/cont-init.d/02-xrdp-cert`:

```bash
#!/command/with-contenv sh
set -eu

CERT=/etc/xrdp/cert.pem
KEY=/etc/xrdp/key.pem
PKG_FP_FILE=/etc/xrdp/.packaged-cert-fingerprint

need_regen=0
if [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
  need_regen=1
elif [ -r "$PKG_FP_FILE" ]; then
  packaged=$(cat "$PKG_FP_FILE")
  current=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)
  if [ "$packaged" = "$current" ]; then
    need_regen=1
  fi
fi

if [ "$need_regen" -eq 1 ]; then
  echo "generating fresh xrdp TLS cert"
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
    -subj "/CN=ubuntu-xrdp-lxqt" \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
  chown xrdp:ssl-cert "$CERT" "$KEY"
  chmod 640 "$CERT" "$KEY"
fi
```

Add it to the Dockerfile chmod list:

```dockerfile
RUN chmod +x /etc/xrdp/startwm.sh \
             /etc/s6-overlay/s6-rc.d/dbus/run \
             /etc/s6-overlay/s6-rc.d/xrdp-sesman/run \
             /etc/s6-overlay/s6-rc.d/xrdp/run \
             /etc/cont-init.d/01-user \
             /etc/cont-init.d/02-xrdp-cert
```

- [ ] **Step 5: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS — fingerprint differs.

- [ ] **Step 6: Commit**

```bash
git add rootfs/etc/cont-init.d/02-xrdp-cert Dockerfile scripts/smoke.sh
git commit -m "Regenerate xrdp TLS cert on first boot"
```

---

### Task 5: Install LXQt + fonts + dev tools; wire `startwm.sh` to `startlxqt`

**Files:**
- Modify: `Dockerfile`
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: apt archive.
- Produces:
  - `startlxqt` on `PATH`.
  - `light-locker` and `xscreensaver` are NOT installed.
  - Dev CLI (`git`, `curl`, `wget`, `vim`, `nano`, `build-essential`, `python3`, `python3-pip`, `openssh-client`) present.
  - Fonts `fonts-dejavu`, `fonts-liberation`, `fonts-noto-core` installed.

- [ ] **Step 1: Write the failing test**

Append to `scripts/smoke.sh`:

```bash
echo "==> assert LXQt + dev tools"
docker exec "$CID" sh -c 'command -v startlxqt >/dev/null' \
  || { echo "FAIL: startlxqt missing" >&2; exit 1; }
for tool in git curl wget vim nano gcc python3 pip3 ssh; do
  docker exec "$CID" sh -c "command -v $tool >/dev/null" \
    || { echo "FAIL: $tool missing" >&2; exit 1; }
done
docker exec "$CID" sh -c '! dpkg -s light-locker >/dev/null 2>&1' \
  || { echo "FAIL: light-locker is installed" >&2; exit 1; }
docker exec "$CID" sh -c '! dpkg -s xscreensaver >/dev/null 2>&1' \
  || { echo "FAIL: xscreensaver is installed" >&2; exit 1; }
echo "OK: LXQt + dev tools + no locker/screensaver"
```

- [ ] **Step 2: Run smoke to verify it fails**

Run: `scripts/smoke.sh`
Expected: FAIL — `startlxqt` missing.

- [ ] **Step 3: Add LXQt + dev tools to the Dockerfile**

Insert a new `RUN apt-get install` block after the xrdp block and before the s6-overlay download:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      lxqt-core lxqt-config lxqt-panel lxqt-policykit \
      pcmanfm-qt qterminal lximage-qt \
      fonts-dejavu fonts-liberation fonts-noto-core \
      build-essential git curl wget vim nano \
      openssh-client python3 python3-pip \
    && apt-get purge -y light-locker xscreensaver 2>/dev/null || true \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
```

(`curl` is already installed from the earlier layer; listing it again is fine — apt no-ops on already-installed packages, and this keeps each layer self-describing.)

- [ ] **Step 4: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile scripts/smoke.sh
git commit -m "Install LXQt, dev tooling, and fonts; purge locker/screensaver"
```

---

### Task 6: Firefox from Mozilla's APT repo

**Files:**
- Modify: `Dockerfile`
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: `https://packages.mozilla.org/apt`.
- Produces:
  - `/usr/bin/firefox` present.
  - `apt-cache policy firefox` shows `packages.mozilla.org` as the preferred origin.

- [ ] **Step 1: Write the failing test**

Append to `scripts/smoke.sh`:

```bash
echo "==> assert Firefox from Mozilla APT repo"
docker exec "$CID" sh -c 'command -v firefox >/dev/null' \
  || { echo "FAIL: firefox missing" >&2; exit 1; }
docker exec "$CID" apt-cache policy firefox | grep -q 'packages.mozilla.org' \
  || { echo "FAIL: firefox not from packages.mozilla.org" >&2; exit 1; }
echo "OK: firefox from Mozilla APT repo"
```

- [ ] **Step 2: Run smoke to verify it fails**

Run: `scripts/smoke.sh`
Expected: FAIL — no firefox installed yet.

- [ ] **Step 3: Add the Mozilla APT repo and install firefox**

Insert this block AFTER the LXQt+dev-tools block and BEFORE the s6-overlay download in the Dockerfile:

```dockerfile
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
      | tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null && \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
      > /etc/apt/sources.list.d/mozilla.list && \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
      > /etc/apt/preferences.d/mozilla && \
    apt-get update && apt-get install -y --no-install-recommends firefox && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 4: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile scripts/smoke.sh
git commit -m "Install Firefox from Mozilla APT repo"
```

---

### Task 7: docker-compose.yml with named home volume and shm 1gb

**Files:**
- Create: `docker-compose.yml`
- Modify: `scripts/smoke.sh` (switch to `docker compose up`)

**Interfaces:**
- Consumes: `Dockerfile` in the same directory.
- Produces:
  - `docker compose up -d` produces a running container publishing 3389.
  - Named volume `home` mounted at `/home` inside the container.
  - `shm_size: 1gb` on the service.

- [ ] **Step 1: Write the failing test**

Rewrite `scripts/smoke.sh` to use compose. Remove the `IMAGE=…` variable, the `docker build …` line, and the `docker run …` line. Replace the build+run+wait section with:

```bash
echo "==> docker compose up"
docker compose down -v >/dev/null 2>&1 || true
docker compose up -d --build

echo "==> wait for xrdp on 3389"
for i in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/3389) >/dev/null 2>&1; then
    echo "OK: xrdp accepting on 3389 (after ${i}s)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "FAIL: xrdp did not accept on 3389 within 30s" >&2
    docker compose logs >&2 || true
    exit 1
  fi
  sleep 1
done

CID=$(docker compose ps -q desktop)
```

Update `cleanup()` to use compose too:

```bash
cleanup() {
  if [[ $KEEP -eq 0 ]]; then
    docker compose down -v >/dev/null 2>&1 || true
  fi
}
```

Also append a compose-specific assertion at the end of the script:

```bash
echo "==> assert home volume and shm_size"
docker exec "$CID" sh -c '[ -d /home ] && stat -c %m /home' \
  | grep -q '^/home$' \
  || { echo "FAIL: /home is not its own mount point" >&2; exit 1; }
docker exec "$CID" sh -c 'df -B1 /dev/shm | awk "NR==2 {print \$2}"' \
  | awk '$1 < 1000000000 { exit 1 }' \
  || { echo "FAIL: /dev/shm smaller than 1GB" >&2; exit 1; }
echo "OK: home volume mounted, shm >= 1GB"
```

- [ ] **Step 2: Run smoke to verify it fails**

Run: `scripts/smoke.sh`
Expected: FAIL — no `docker-compose.yml`.

- [ ] **Step 3: Write the compose file**

Create `docker-compose.yml`:

```yaml
services:
  desktop:
    build: .
    image: ubuntu-xrdp-lxqt:local
    ports:
      - "3389:3389"
    environment:
      USER: ubuntu
      PASSWORD: ubuntu
    volumes:
      - home:/home
    shm_size: "1gb"
    restart: unless-stopped

volumes:
  home: {}
```

- [ ] **Step 4: Run smoke to verify it passes**

Run: `scripts/smoke.sh`
Expected: PASS — all previous assertions still green plus the new volume/shm checks.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml scripts/smoke.sh
git commit -m "Add docker-compose.yml with named home volume and 1GB shm"
```

---

### Task 8: README documents the real usage

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Replace README stub with real usage**

Overwrite `README.md`:

````markdown
# ubuntu-xrdp-lxqt

An Ubuntu 26.04 desktop-in-a-container that speaks RDP.

- Base: `ubuntu:26.04`
- Desktop: LXQt
- RDP: `xrdp` + `xorgxrdp` on port 3389
- Init: `s6-overlay`
- Firefox: from Mozilla's official APT repo (not the snap transitional)

## Quickstart

```
docker compose up -d
```

Point any RDP client at `localhost:3389`. Default credentials: `ubuntu` /
`ubuntu`.

## Configuration

Environment variables (set in `docker-compose.yml` or `docker run -e`):

| Var | Default | Purpose |
|---|---|---|
| `USER` | `ubuntu` | Login username (also the Unix user). |
| `PASSWORD` | `ubuntu` | Login password. |
| `SUDO` | `yes` | Set `no` to skip the passwordless sudoers file. |
| `TZ` | *(unset)* | IANA timezone (e.g. `America/Los_Angeles`). |

Home directory (`/home`) is a named volume, so files survive `docker
compose down`. Use `docker compose down -v` to wipe it.

## Build (multi-arch)

```
docker buildx build --platform linux/amd64,linux/arm64 -t ubuntu-xrdp-lxqt:local .
```

## Smoke test

```
scripts/smoke.sh          # build, boot, assert, teardown
scripts/smoke.sh --keep   # skip teardown for interactive inspection
```

## Design

See `docs/superpowers/specs/2026-07-27-ubuntu-xrdp-lxqt-design.md`.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Document usage in README"
```

---

## Post-plan checklist

- [ ] `scripts/smoke.sh` passes end-to-end on the host arch.
- [ ] `git log --oneline` shows one commit per task.
- [ ] Working tree clean.

