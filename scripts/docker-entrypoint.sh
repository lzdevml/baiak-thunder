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
echo "[entrypoint] PORTAS REAIS: $(grep -E 'loginProtocolPort|gameProtocolPort|statusProtocolPort|^ip =' config.lua | tr '\n' ' ')"

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

# ---- DB import (Thunder.sql = dump COMPLETO baiakthunder: schema certo + dados + conta 1/god) ----
# NAO usar schema.sql (TFS vanilla): ele cria tabelas com estrutura diferente, o Thunder.sql
# (sem DROP TABLE) entao falha por "table already exists" e os dados/contas nao entram.
# Gatilho: se accounts tiver 0 linhas (ou nao existir) -> wipe tabelas + importa Thunder.sql limpo.
MYSQL="mysql -h${OT_DB_HOST} -P${OT_DB_PORT} -u${OT_DB_USER} -p${OT_DB_PASSWORD}"
ACC_COUNT=$($MYSQL -N -e "SELECT COUNT(*) FROM \`${OT_DB_NAME}\`.accounts;" 2>/dev/null || echo "0")
[ -z "$ACC_COUNT" ] && ACC_COUNT="0"
echo "[entrypoint] accounts existentes: ${ACC_COUNT}"

if [ "$ACC_COUNT" = "0" ]; then
    echo "[entrypoint] DB vazia/invalida — limpando tabelas e importando Thunder.sql..."
    $MYSQL -e "CREATE DATABASE IF NOT EXISTS \`${OT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1
    # dropa todas as tabelas existentes (do schema.sql vanilla) sem DROP DATABASE
    DROPS=$($MYSQL -N -e "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema='${OT_DB_NAME}';" 2>/dev/null)
    if [ -n "$DROPS" ]; then
        { echo "SET FOREIGN_KEY_CHECKS=0;"; echo "$DROPS"; echo "SET FOREIGN_KEY_CHECKS=1;"; } | $MYSQL "${OT_DB_NAME}" 2>&1
        echo "[entrypoint] tabelas antigas removidas"
    fi
    $MYSQL "${OT_DB_NAME}" < Thunder.sql 2>&1 | tail -5 && echo "[entrypoint] Thunder.sql importado"
    NEW_ACC=$($MYSQL -N -e "SELECT COUNT(*) FROM \`${OT_DB_NAME}\`.accounts;" 2>/dev/null || echo "0")
    echo "[entrypoint] contas apos import: ${NEW_ACC}"
else
    echo "[entrypoint] DB ja inicializada (${ACC_COUNT} contas) — pula import"
fi

# ---- Start TFS ----
# (sem exec) pra capturar o exit code se o engine cair (diagnostico crash vs hang).
echo "[entrypoint] Starting ./tfs ..."
./tfs
echo "[entrypoint] !!! tfs SAIU com codigo $? !!! (se cair ao entrar no mundo = crash de player-load)"
sleep 3
