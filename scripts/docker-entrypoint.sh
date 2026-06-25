#!/bin/sh
# docker-entrypoint.sh — Baiak Thunder staging server
# Injects DB connection into config.lua via sed, waits for DB,
# imports schema on first boot, then starts TFS.
set -e

WORKDIR=/opt/otserver

# ---- Required env vars ----
: "${OT_DB_HOST:?OT_DB_HOST is required}"
: "${OT_DB_NAME:?OT_DB_NAME is required}"
: "${OT_DB_USER:?OT_DB_USER is required}"
: "${OT_DB_PASSWORD:?OT_DB_PASSWORD is required}"
OT_DB_PORT="${OT_DB_PORT:-3306}"
OT_SERVER_NAME="${OT_SERVER_NAME:-Baiak Thunder Staging}"
OT_SERVER_IP="${OT_SERVER_IP:-127.0.0.1}"

echo "[entrypoint] Baiak Thunder (staging) — TFS 1.5 / protocol 8.60"
echo "[entrypoint] DB: ${OT_DB_USER}@${OT_DB_HOST}:${OT_DB_PORT}/${OT_DB_NAME}"
echo "[entrypoint] serverName: ${OT_SERVER_NAME} | ip: ${OT_SERVER_IP}"

cd "$WORKDIR"

# ---- Patch config.lua with runtime values ----
# sed on a copy so the image layer stays clean for debugging.
cp config.lua config.lua.bak
sed -i "s|mysqlHost = \".*\"|mysqlHost = \"${OT_DB_HOST}\"|" config.lua
sed -i "s|mysqlUser = \".*\"|mysqlUser = \"${OT_DB_USER}\"|" config.lua
sed -i "s|mysqlPass = \".*\"|mysqlPass = \"${OT_DB_PASSWORD}\"|" config.lua
sed -i "s|mysqlDatabase = \".*\"|mysqlDatabase = \"${OT_DB_NAME}\"|" config.lua
sed -i "s|mysqlPort = [0-9]*|mysqlPort = ${OT_DB_PORT}|" config.lua
sed -i "s|serverName = \".*\"|serverName = \"${OT_SERVER_NAME}\"|" config.lua
sed -i "s|^ip = \".*\"|ip = \"${OT_SERVER_IP}\"|" config.lua

# Staging ports (offset +10 from live to avoid collision on same VPS)
sed -i "s|loginProtocolPort = [0-9]*|loginProtocolPort = 7181|" config.lua
sed -i "s|gameProtocolPort = [0-9]*|gameProtocolPort = 7182|" config.lua
sed -i "s|statusProtocolPort = [0-9]*|statusProtocolPort = 7181|" config.lua

echo "[entrypoint] config.lua patched"

# ---- Wait for MariaDB ----
echo "[entrypoint] waiting for DB at ${OT_DB_HOST}:${OT_DB_PORT}..."
i=0
until mysqladmin ping -h"${OT_DB_HOST}" -P"${OT_DB_PORT}" -u"${OT_DB_USER}" -p"${OT_DB_PASSWORD}" --connect-timeout=3 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge 40 ]; then
        echo "[entrypoint] ERROR: DB not reachable after ${i} attempts — aborting"
        exit 1
    fi
    echo "[entrypoint] DB not ready (attempt ${i}/40), retrying in 5s..."
    sleep 5
done
echo "[entrypoint] DB is up"

# ---- First-boot schema import ----
# Check if the 'accounts' table exists. If not, import schema + Thunder data.
TABLE_CHECK=$(mysql -h"${OT_DB_HOST}" -P"${OT_DB_PORT}" -u"${OT_DB_USER}" -p"${OT_DB_PASSWORD}" \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${OT_DB_NAME}' AND table_name='accounts';" \
    --skip-column-names 2>/dev/null || echo "0")

if [ "$TABLE_CHECK" = "0" ] || [ -z "$TABLE_CHECK" ]; then
    echo "[entrypoint] First boot detected — importing schema.sql + Thunder.sql into ${OT_DB_NAME}..."
    mysql -h"${OT_DB_HOST}" -P"${OT_DB_PORT}" -u"${OT_DB_USER}" -p"${OT_DB_PASSWORD}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${OT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1
    mysql -h"${OT_DB_HOST}" -P"${OT_DB_PORT}" -u"${OT_DB_USER}" -p"${OT_DB_PASSWORD}" \
        "${OT_DB_NAME}" < schema.sql 2>&1 && echo "[entrypoint] schema.sql imported"
    mysql -h"${OT_DB_HOST}" -P"${OT_DB_PORT}" -u"${OT_DB_USER}" -p"${OT_DB_PASSWORD}" \
        "${OT_DB_NAME}" < Thunder.sql 2>&1 && echo "[entrypoint] Thunder.sql imported"
    echo "[entrypoint] First-boot import complete"
else
    echo "[entrypoint] DB already initialized (accounts table exists) — skipping import"
fi

# ---- Start TFS ----
echo "[entrypoint] Starting ./tfs ..."
exec ./tfs
