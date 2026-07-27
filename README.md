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

If port 3389 is already in use on the host (e.g. a real xrdp is running),
set a different host port:

```
HOST_RDP_PORT=13389 docker compose up -d
```

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

Local `--load` only supports the current architecture; publishing
multi-arch to a registry needs `--push`.

## Smoke test

```
scripts/smoke.sh          # build, boot, assert, teardown
scripts/smoke.sh --keep   # skip teardown for interactive inspection
```

The smoke test runs in an isolated compose project on host port 13389
so it doesn't collide with a normal `docker compose up`.

## Design

See `docs/superpowers/specs/2026-07-27-ubuntu-xrdp-lxqt-design.md` for
the design and `docs/superpowers/plans/2026-07-27-ubuntu-xrdp-lxqt.md`
for the implementation plan.
