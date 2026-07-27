# Ubuntu 26.04 + xrdp + LXQt container — design

**Status:** Draft
**Date:** 2026-07-27
**Owner:** Chad Walker

## Summary

A Docker image based on `ubuntu:26.04` that exposes an LXQt desktop over RDP.
Combines the RDP mechanism from
[danchitnis/container-xrdp](https://github.com/danchitnis/container-xrdp) with
the "full desktop in a container" shape of
[fcwu/docker-ubuntu-vnc-desktop](https://github.com/fcwu/docker-ubuntu-vnc-desktop),
but uses LXQt (not LXDE/XFCE) and RDP (not VNC/noVNC). Aimed at a single
local-dev "throwaway desktop" workflow, with a persistent home volume so
work survives container rebuilds.

## Goals

- One `docker compose up` yields a working LXQt desktop reachable at
  `rdp://localhost:3389`.
- Sensible defaults (`ubuntu` / `ubuntu`) with env-var overrides.
- Persistent `/home` via a named volume.
- Multi-arch: `linux/amd64` + `linux/arm64` via buildx.
- Small enough to iterate on; large enough to actually be usable as a dev box
  (dev CLI toolchain + Firefox pre-installed).

## Non-goals

- No VNC / noVNC / web UI / nginx.
- No Chromium (Firefox only).
- No systemd or any display manager (xrdp launches the DE directly).
- No language packs beyond `en_US`.
- No CI wiring in v1 — smoke tests are local-only.

## Architecture

Single-stage `Dockerfile` FROM `ubuntu:26.04`. Installs LXQt, xrdp,
xorgxrdp, dev tools, Firefox (from Mozilla's APT repo), and s6-overlay.
s6-overlay supervises three long-lived services:

- `dbus` — system bus for xrdp + desktop apps
- `xrdp-sesman` — session manager (spawns per-user X)
- `xrdp` — RDP listener on 3389 (depends on `xrdp-sesman`)

Xrdp launches an X session that execs `startlxqt` via `/etc/xrdp/startwm.sh`.
`docker-compose.yml` exposes 3389 and mounts a named volume at `/home`.

## File layout (repo root)

```
Dockerfile
docker-compose.yml
.dockerignore
README.md
scripts/
└── smoke.sh
rootfs/
└── etc/
    ├── s6-overlay/s6-rc.d/
    │   ├── dbus/                 (longrun)
    │   ├── xrdp-sesman/          (longrun)
    │   ├── xrdp/                 (longrun; depends on xrdp-sesman)
    │   └── user/contents.d/      (enables the three)
    ├── cont-init.d/
    │   ├── 01-user               (creates $USER, sudoers, chowns /home)
    │   └── 02-xrdp-cert          (generates fresh cert/key if absent)
    └── xrdp/
        └── startwm.sh            (execs startlxqt)
```

`rootfs/` is a filesystem overlay copied into the image with a single
`COPY rootfs/ /`, keeping the Dockerfile short and letting the config live
under version control as ordinary files.

## Runtime flow

1. Container starts. `s6-overlay` init runs `cont-init.d/` scripts in
   lexical order:
   - **`01-user`** — reads `USER` (default `ubuntu`), `PASSWORD` (default
     `ubuntu`), `SUDO` (default `yes`), `TZ` (optional). Runs `useradd -m
     -s /bin/bash -G audio,video ${USER}`, `chpasswd`, and — if `SUDO=yes`
     — writes `/etc/sudoers.d/${USER}` granting `NOPASSWD:ALL`. **Idempotent:**
     if the user already exists (persistent-home case), the script updates
     the password to match `PASSWORD` and no-ops the rest. Sets `TZ` via
     `/etc/timezone` + `dpkg-reconfigure -f noninteractive tzdata` when
     provided.
   - **`02-xrdp-cert`** — if `/etc/xrdp/cert.pem` is missing OR its
     fingerprint matches the fingerprint of the packaged default (captured
     at build time in `/etc/xrdp/.packaged-cert-fingerprint`), generate a
     fresh 4096-bit RSA self-signed cert into `/etc/xrdp/cert.pem` +
     `/etc/xrdp/key.pem` (mode 640, owned by `xrdp:xrdp`).
2. s6-overlay starts the longruns in dependency order: `dbus` →
   `xrdp-sesman` → `xrdp`. Each is a foreground process; s6 restarts a
   longrun that exits, but repeated crashes surface via `docker logs`.
3. RDP client connects to `host:3389`. `xrdp-sesman` authenticates the
   user via PAM (`common-auth`), spawns an Xorg backend via `xorgxrdp`,
   and execs `/etc/xrdp/startwm.sh`. `startwm.sh` sources
   `/etc/profile` and `~/.profile`, then `exec startlxqt`.

## Configuration surface

Environment variables read by `cont-init.d`:

| Var | Default | Purpose |
|---|---|---|
| `USER` | `ubuntu` | RDP + Unix username created on first boot. |
| `PASSWORD` | `ubuntu` | Login password (also updated on subsequent boots to allow rotation). |
| `SUDO` | `yes` | Set to `no` to skip the sudoers drop-in. |
| `TZ` | *(unset)* | Optional IANA timezone (e.g. `America/Los_Angeles`). |

Not exposed:
- **Resolution / color depth / keyboard** — negotiated by the RDP client
  at connect time; no server-side configuration needed.
- **Xrdp port** — fixed at 3389 inside the container; remap via Docker
  publish (`-p 13389:3389`) if a different host port is wanted.

## Bundled packages

- **Desktop core:** `lxqt-core`, `lxqt-config`, `lxqt-panel`,
  `lxqt-policykit`, `pcmanfm-qt`, `qterminal`, `lximage-qt`, `dbus-x11`
- **Xrdp:** `xrdp`, `xorgxrdp`. After install, the Dockerfile captures
  the packaged cert's SHA-256 fingerprint into
  `/etc/xrdp/.packaged-cert-fingerprint` so `02-xrdp-cert` can detect
  it at runtime.
- **Fonts:** `fonts-dejavu`, `fonts-liberation`, `fonts-noto-core`
- **Dev tooling:** `build-essential`, `git`, `curl`, `wget`, `vim`,
  `nano`, `ca-certificates`, `openssh-client`, `python3`, `python3-pip`
- **Firefox:** installed from **Mozilla's official APT repo**
  (`packages.mozilla.org/apt`), NOT the Ubuntu archive package — the
  archive's `firefox` package on 26.04 is still a snap transitional
  stub, and snaps don't work inside containers. Steps:
  1. `install -d -m 0755 /etc/apt/keyrings`
  2. Download and dearmor Mozilla's signing key to
     `/etc/apt/keyrings/packages.mozilla.org.asc`
  3. Write `/etc/apt/sources.list.d/mozilla.list` with the Mozilla repo
     line and `Signed-By=/etc/apt/keyrings/packages.mozilla.org.asc`
  4. Pin `packages.mozilla.org` above the Ubuntu archive in
     `/etc/apt/preferences.d/mozilla` (priority 1000) so `firefox`
     resolves to the Mozilla build.
  5. `apt-get install -y firefox`
- **Removed post-install:** `light-locker`, `xscreensaver` (both fight
  headless X sessions and pop lock prompts inside RDP).

## s6-overlay integration

- Install s6-overlay v3 via `curl | tar xz -C /` for the target arch
  (amd64 uses `s6-overlay-x86_64.tar.xz`; arm64 uses
  `s6-overlay-aarch64.tar.xz`). Version pinned in the Dockerfile.
- `ENTRYPOINT ["/init"]` (s6-overlay's stage-1 init).
- Each longrun directory contains a `type` file (`longrun`) and a `run`
  script that `exec`s the daemon in the foreground. Ordering is enforced
  with `dependencies.d/` entries.
- `cont-init.d` scripts are plain shell, executable, exit non-zero to
  abort the container on misconfiguration.

## docker-compose.yml

```yaml
services:
  desktop:
    build: .
    image: ubuntu-xrdp-lxqt:local
    ports: ["3389:3389"]
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

`shm_size: 1gb` because Firefox and modern Qt apps segfault on the
Docker default 64 MB `/dev/shm`.

## Error handling

- **Bad config in `cont-init.d`** → script exits non-zero → s6-overlay
  aborts container startup → surfaces as `docker logs` output.
- **Xrdp/sesman crash** → s6 restarts the longrun automatically. Repeated
  restarts are visible via `docker logs` (s6 logs each restart).
- **Stale `/tmp/.X11-unix`** → a small `up` hook on the `xrdp` longrun
  removes any stale sockets before starting the daemon.
- **Missing xrdp cert on rebuild** → `02-xrdp-cert` regenerates
  automatically; no manual intervention needed.

## Testing

`scripts/smoke.sh` — a bash script suitable to run locally after a
build:

1. `docker buildx build --load -t ubuntu-xrdp-lxqt:test .` (host arch).
2. `docker compose up -d` (or `docker run -d --rm -p 3389:3389 ...`).
3. Poll TCP `localhost:3389` until it accepts, timeout 60s.
4. `docker exec` assertions:
   - `id ubuntu` returns a valid uid.
   - `command -v startlxqt` is non-empty.
   - `openssl x509 -in /etc/xrdp/cert.pem -noout -fingerprint` differs
     from the captured packaged fingerprint.
   - `su ubuntu -c 'true'` returns 0 (user shell works).
5. Teardown: `docker compose down -v` (unless `--keep` passed).

Optional deeper test (documented in README, not automated): connect
with `xfreerdp /v:localhost /u:ubuntu /p:ubuntu +auth-only` to verify
the RDP handshake end-to-end.

CI wiring is deferred to a follow-up.

## Multi-arch build

Buildx-driven. Dockerfile is arch-agnostic except for the s6-overlay
download, which uses `${TARGETARCH}` to pick between
`s6-overlay-x86_64.tar.xz` and `s6-overlay-aarch64.tar.xz`.

Build commands:

```
docker buildx build --platform linux/amd64,linux/arm64 -t ubuntu-xrdp-lxqt:local .
```

Local `--load` only supports the current arch; publishing multi-arch to
a registry needs `--push` (out of scope for v1, but the Dockerfile
supports it).

## What's explicitly out of scope for v1

- Any VNC / noVNC path, web UI, nginx.
- Chromium (Firefox only).
- systemd.
- Any display manager (lxdm, sddm, lightdm) — xrdp launches LXQt
  directly.
- Language packs beyond `en_US`.
- GitHub Actions CI wiring (deferred).
- Publishing to a registry (deferred).
