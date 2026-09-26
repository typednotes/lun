# syntax=docker/dockerfile:1
#
# lun compiles user projects at request time, so unlike liaison's image the
# runtime image is not slim: it carries elan and the Lean toolchain, git and
# tar (fetching), and every native build dependency of linen (a project's
# `require linen` builds linen's FFI: libpq, OpenSSL, zlib and libsecret
# headers, `unzip` for the DuckDB archive linen's lakefile downloads, and a
# C/C++ toolchain with static libstdc++ for sealing it).
#
#   podman build -t lun .
#   podman build --build-arg LINEN_REF=v1.3.0 -t lun .
#
# LINEN_REF is the linen version pre-built into the package cache. Projects
# locked to that exact revision start from it; any other revision builds its
# linen from scratch (slow, but correct). It must be >= v1.3.0, the first
# version with `Control.Reactive` and `Control.Monad.Effect.Handler`.

FROM docker.io/library/ubuntu:24.04 AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git tar gzip build-essential pkg-config unzip \
      libpq-dev libssl-dev zlib1g-dev libsecret-1-dev \
    && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan \
    PATH=/opt/elan/bin:${PATH} \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --no-modify-path --default-toolchain none
# The toolchain lun, the package cache and (typically) user projects share,
# installed once so a build does not download it.
COPY lean-toolchain /tmp/lean-toolchain
RUN elan toolchain install "$(cat /tmp/lean-toolchain)" \
    && elan default "$(cat /tmp/lean-toolchain)"

# ── lun itself ──────────────────────────────────────────────────────────────
FROM base AS builder
WORKDIR /src
COPY . .
RUN lake build lun

# ── The package cache: linen, built for the driver runtime's imports ─────────
FROM base AS cache
ARG LINEN_REF=v1.3.0
WORKDIR /warm
RUN cp /tmp/lean-toolchain lean-toolchain \
    && printf '%s\n' \
         'name = "warm"' 'defaultTargets = ["Warm"]' \
         '[[require]]' 'name = "linen"' 'git = "https://github.com/typednotes/linen"' \
         "rev = \"${LINEN_REF}\"" \
         '[[lean_lib]]' 'name = "Warm"' > lakefile.toml \
    && printf '%s\n' \
         'import Linen.Control.Reactive' \
         'import Linen.Control.Monad.Effect.Handler' \
         'import Linen.Control.Monad.Effect.Trace' \
         'import Linen.Control.Monad.Effect.Error' \
         'import Linen.Control.Monad.Effect.HTTP' \
         'import Linen.Control.Monad.Effect.FileSystem' > Warm.lean \
    && lake build \
    && rev="$(git -C .lake/packages/linen rev-parse HEAD)" \
    && mkdir -p /opt/lun/cache/linen \
    && mv .lake/packages/linen "/opt/lun/cache/linen/${rev}"

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM base AS runtime
RUN useradd --system --create-home --uid 10001 lun \
    && mkdir -p /var/lib/lun \
    && chown -R lun /var/lib/lun /opt/elan
COPY --from=cache --chown=lun /opt/lun/cache /opt/lun/cache
COPY --from=builder /src/.lake/build/bin/lun /usr/local/bin/lun
ENV LUN_WORKDIR=/var/lib/lun \
    LUN_PACKAGE_CACHE=/opt/lun/cache
USER lun
VOLUME /var/lib/lun
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/lun"]
