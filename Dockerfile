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
             /etc/s6-overlay/s6-rc.d/xrdp/run \
             /etc/cont-init.d/01-user

# Allow xrdp to read its cert/key
RUN adduser xrdp ssl-cert || true

EXPOSE 3389
ENTRYPOINT ["/init"]
