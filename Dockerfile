# The cid server as an image: the binary with the dashboard embedded,
# libduckdb beside it, and the programs it calls (git, ffmpeg, vips).
# Built by deploy/compose/docker-compose.yml; deploy/compose/README.md
# says how to run it.
#
#   docker build -t cid .

# 1. The dashboard: static files, embedded by `zig build`.
FROM node:24-bookworm-slim AS web
RUN npm install -g pnpm@12.16.1
WORKDIR /src/web
COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm build

# 2. The binary. The Zig version is the one build.zig.zon pins.
FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.1
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN case "${TARGETARCH:-amd64}" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; \
        *) echo "cid is built for amd64 and arm64, not ${TARGETARCH}" >&2; exit 1 ;; esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
# The dependencies first, in a step of their own: a change to the source
# never downloads them again. Zig reads /etc/resolv.conf itself; if this
# step stops with ResolvConfParseFailed (a name server written as a
# link-local IPv6 address, `fe80::1%2`), build with the host's network:
#   docker build --network host -t cid:local .
COPY build.zig build.zig.zon ./
RUN zig build --fetch
COPY src/ src/
COPY sql/ sql/
COPY tests/ tests/
COPY --from=web /src/web/dist web/dist
RUN zig build -Doptimize=ReleaseFast --prefix /opt/cid

# 3. What runs: the binary and its library, and the programs it calls.
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git openssh-client ffmpeg libvips-tools \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /var/lib/cid --shell /usr/sbin/nologin cid \
    && mkdir -p /var/lib/cid/git-work /var/lib/cid/browse /var/lib/cid/work /git \
    && chown -R cid:cid /var/lib/cid /git
COPY --from=build /opt/cid/bin/ /opt/cid/bin/
RUN ln -s /opt/cid/bin/cid /usr/local/bin/cid
USER cid
WORKDIR /var/lib/cid
ENV CID_GIT_WORKDIR=/var/lib/cid/git-work \
    CID_BROWSE_DIR=/var/lib/cid/browse \
    CID_WORK_DIR=/var/lib/cid/work
EXPOSE 7070
# The schema first (it applies only what is new), then the server.
CMD ["sh", "-c", "cid admin setup && exec cid admin serve --host 0.0.0.0"]
