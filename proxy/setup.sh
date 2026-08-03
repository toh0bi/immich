#!/bin/bash
set -eo pipefail

# Richtet den gemeinsamen Reverse Proxy (Caddy) ein und startet ihn.
# Kann wiederholt ausgeführt werden (idempotent) – z.B. nach dem Hinzufügen
# eines neuen Services wie SilverBullet.
#
# Voraussetzung: immich und silverbullet Container laufen bereits,
# damit die Docker-Netzwerke immich_net und silverbullet_net existieren.

CONFIG_SHARED="$(dirname "${BASH_SOURCE[0]}")/../config.sh"
CONFIG_IMMICH="$(dirname "${BASH_SOURCE[0]}")/../immich/config.sh"
CONFIG_SB="$(dirname "${BASH_SOURCE[0]}")/../silverbullet/config.sh"

# Falls Config-Dateien mit Windows-Zeilenenden (CRLF) bearbeitet wurden,
# vor dem source in LF normalisieren.
sed -i 's/\r$//' "${CONFIG_SHARED}" "${CONFIG_IMMICH}" "${CONFIG_SB}"

# shellcheck source=../config.sh
source "${CONFIG_SHARED}"
# IMMICH_DOMAIN kommt aus der Immich-eigenen Config
# shellcheck source=../immich/config.sh
source "${CONFIG_IMMICH}"
# SB_DOMAIN kommt aus der SilverBullet-eigenen Config
# shellcheck source=../silverbullet/config.sh
source "${CONFIG_SB}"

require_nonempty() {
    local var_name="$1"
    local var_value="$2"
    local hint_file="$3"
    if [[ -z "${var_value//[[:space:]]/}" ]]; then
        echo "FEHLER: ${var_name} ist leer oder nicht gesetzt." >&2
        echo "Bitte in ${hint_file} einen gueltigen Domain-Wert setzen." >&2
        exit 1
    fi
}

require_nonempty "IMMICH_DOMAIN" "${IMMICH_DOMAIN:-}" "/opt/immich/config.sh"
require_nonempty "SB_DOMAIN" "${SB_DOMAIN:-}" "/opt/silverbullet/config.sh"

PROXY_DIR="/opt/proxy"

echo "### Proxy: Docker-Netzwerke sicherstellen ###"
# proxy/docker-compose.yml erwartet beide Netzwerke als "external" –
# sie müssen also existieren, auch wenn immich/silverbullet noch nicht
# (neu) gestartet wurden. Idempotent: schlägt nur fehl, wenn schon vorhanden.
docker network create immich_net 2>/dev/null && echo "  -> immich_net angelegt." \
    || echo "  -> immich_net bereits vorhanden."
docker network create silverbullet_net 2>/dev/null && echo "  -> silverbullet_net angelegt." \
    || echo "  -> silverbullet_net bereits vorhanden."

echo "### Proxy: Verzeichnis vorbereiten ###"
mkdir -p "${PROXY_DIR}"

# docker-compose.yml ist Teil des Repos (proxy/docker-compose.yml) und liegt dank
# "scp -r proxy/ ... /opt/" bereits unter ${PROXY_DIR}/docker-compose.yml (Deploy-in-Place).
# Kein cp nötig (Quelle und Ziel wären nach dem Deploy derselbe Pfad).
if [[ ! -f "${PROXY_DIR}/docker-compose.yml" ]]; then
    echo "FEHLER: ${PROXY_DIR}/docker-compose.yml nicht gefunden." >&2
    echo "Bitte zuerst den proxy/-Ordner aus dem Repo nach /opt/ kopieren (siehe README.md)." >&2
    exit 1
fi

echo "### Proxy: Caddyfile erzeugen ###"
cat > "${PROXY_DIR}/Caddyfile" << EOF
${IMMICH_DOMAIN} {
    reverse_proxy immich-server:2283
}

${SB_DOMAIN} {
    reverse_proxy silverbullet:3000
}
EOF

echo "### Proxy: Caddyfile validieren ###"
docker run --rm \
    -v "${PROXY_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile

echo "### Proxy: Eigentümer setzen ###"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${PROXY_DIR}"

echo "### Proxy: Caddy starten (oder neu laden) ###"
cd "${PROXY_DIR}"

if docker ps -a --format '{{.Names}}' | grep -Fxq caddy_proxy; then
    if [[ "$(docker inspect -f '{{.State.Running}}' caddy_proxy 2>/dev/null || echo false)" == "true" ]]; then
        # Caddy läuft bereits → Konfiguration neu laden (kein Neustart nötig)
        if docker exec caddy_proxy caddy reload --config /etc/caddy/Caddyfile; then
            echo "  -> Caddy-Konfiguration neu geladen."
        else
            echo "  -> Reload fehlgeschlagen, Container wird neu erstellt..."
            docker compose up -d --force-recreate
        fi
    else
        echo "  -> Caddy-Container existiert, läuft aber nicht stabil. Starte neu..."
        docker compose up -d --force-recreate
    fi
else
    docker compose up -d
    echo "  -> Caddy gestartet."
fi

if ! docker ps -q -f name=caddy_proxy | grep -q .; then
    echo "FEHLER: Caddy läuft nach dem Start/Reload nicht stabil. Letzte Logs:" >&2
    docker logs --tail 100 caddy_proxy >&2 || true
    exit 1
fi
