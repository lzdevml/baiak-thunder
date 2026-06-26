# =============================================================
# Dockerfile — Baiak Thunder (TFS-1.5-Downgrades-8.60)
# Multi-stage: builder compiles engine from LOCAL source;
# runner is a lean Alpine 3.18 image.
#
# IMPORTANT: Alpine 3.18 is pinned intentionally.
# Alpine 3.19+ ships fmt 10, which removes implicit enum formatting
# that the engine uses in iomapserialize.cpp — hard static_assert failure.
# Do NOT bump the Alpine version without verifying fmt compatibility.
#
# Differences from live baiak-server Dockerfile:
#   - Engine source is COPIED from engine/ (no git clone at build time)
#   - Ports shifted: 7181/7182 (login/game) to avoid conflict with live (7171/7172)
#   - No mounts patch (baiakthunder does not use that client flag)
#   - DB name: thunder (not tibia)
# =============================================================

# ---- Stage 1: Builder ----------------------------------------
FROM alpine:3.18 AS builder

RUN apk add --no-cache \
    binutils \
    boost-dev \
    build-base \
    clang \
    cmake \
    crypto++-dev \
    fmt-dev \
    gcc \
    gmp-dev \
    luajit-dev \
    make \
    mariadb-connector-c-dev \
    pugixml-dev

# Copy local engine source (TFS-1.5-Downgrades-8.60)
COPY engine/ /src/engine/

WORKDIR /src/engine

# Apply u32 patch (level/hp/mana in 4 bytes to match mehah client)
COPY infra/docker/engine-u32.sh /tmp/engine-u32.sh
RUN sh /tmp/engine-u32.sh

# Build with CMake.
# IMPORTANTE: -j2 (nao -j$(nproc)) — compilar com paralelismo total estoura a RAM da VPS
# de 8GB (server.cpp+luascript.cpp pesados) e o build morre por OOM (exit 255 ~80%).
# -j2 limita a ~2 compiles simultaneos. Mais lento (~20min) mas estavel.
RUN mkdir build \
    && cd build \
    && cmake .. \
    && make -j2

# Confirm binary
RUN ls build/tfs && echo "Build OK"

# ---- Stage 2: Runner ----------------------------------------
FROM alpine:3.18 AS runner

RUN apk add --no-cache \
    boost-iostreams \
    boost-system \
    boost-filesystem \
    crypto++ \
    fmt \
    gmp \
    luajit \
    mariadb-connector-c \
    pugixml \
    curl \
    netcat-openbsd \
    mariadb-client

# Non-root user
RUN addgroup -S otserver && adduser -S -G otserver otserver

WORKDIR /opt/otserver

# Copy binary from builder
COPY --from=builder /src/engine/build/tfs ./tfs

# RSA key (esta na raiz do contexto do build, nao no source do engine)
COPY key.pem ./key.pem

# Baiakthunder datapack
COPY data/ ./data/

# config.lua — engine loads ./config.lua from CWD.
# Env vars are injected at runtime by entrypoint via sed.
COPY config.lua ./config.lua

# SQL schemas for first-boot import
COPY schema.sql ./schema.sql
COPY Thunder.sql ./Thunder.sql

# Entrypoint
COPY scripts/docker-entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Ownership
RUN chown -R otserver:otserver /opt/otserver

USER otserver

# STAGING ports: 7181 (login+status) / 7182 (game)
# Offset +10 from live (7171/7172) to avoid conflict on same host.
EXPOSE 7181 7182

# Healthcheck: TCP connect to login port.
# start-period=120s covers world load time (large map).
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 7181 || exit 1

ENTRYPOINT ["./entrypoint.sh"]
