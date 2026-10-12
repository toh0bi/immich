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

# Fallback: Falls /opt/config.sh nicht existiert, aber /opt/immich/config.sh vorhanden ist
if [[ ! -f "${CONFIG_SHARED}" ]] && [[ -f "$(dirname "${BASH_SOURCE[0]}")/../immich/config.sh" ]]; then
    CONFIG_SHARED="$(dirname "${BASH_SOURCE[0]}")/../immich/config.sh"
fi

for cfg in "${CONFIG_SHARED}" "${CONFIG_IMMICH}" "${CONFIG_SB}"; do
    if [[ ! -f "${cfg}" ]]; then
        echo "FEHLER: Konfigurationsdatei nicht gefunden: ${cfg}" >&2
        echo "Bitte sicherstellen, dass die Datei existiert (siehe README.md)." >&2
        exit 1
    fi
    # Windows CRLF bereinigen, falls vorhanden
    sed -i 's/\r$//' "${cfg}"
done

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

# Tailscale-IP ermitteln, damit Caddy nur an das Tailscale-Interface gebunden wird
TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "${TAILSCALE_IP}" ]]; then
    echo "WARNUNG: 'tailscale ip -4' lieferte keine IP. Ist Tailscale installiert und verbunden?" >&2
    echo "Falle zurück auf 127.0.0.1 (Services nur lokal erreichbar)." >&2
    TAILSCALE_IP="127.0.0.1"
else
    echo "  -> Gefundene Tailscale-IP: ${TAILSCALE_IP}"
fi

# In .env fuer docker-compose schreiben
cat > "${PROXY_DIR}/.env" << EOF
TAILSCALE_IP=${TAILSCALE_IP}
EOF

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

# Container neu erstellen, damit geänderte Port-Bindings / Socket-Mounts greifen
docker compose up -d --force-recreate
echo "  -> Caddy gestartet/aktualisiert."

if ! docker ps -q -f name=caddy_proxy | grep -q .; then
    echo "FEHLER: Caddy läuft nach dem Start/Reload nicht stabil. Letzte Logs:" >&2
    docker logs --tail 100 caddy_proxy >&2 || true
    exit 1
fi
