#!/bin/bash
set -eo pipefail

# Richtet SilverBullet auf dem Server ein.
# Voraussetzung: setup.sh (Server-Basis) wurde bereits ausgeführt.
# Nach diesem Skript wird proxy/setup.sh automatisch aufgerufen.

# Shared server config (ADMIN_USER, NTFY, Storage Box, ...)
# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"

# SilverBullet-spezifische Config (SB_DOMAIN, SB_USER, SB_SPACE_DIR)
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Fallback fuer Alt-Setups: Falls /opt/config.sh noch keine ntfy_send-Funktion
# enthaelt, einfach stillschweigend ohne Benachrichtigung weiterlaufen.
if ! declare -F ntfy_send >/dev/null; then
    ntfy_send() { :; }
fi

SB_DIR="/opt/silverbullet"

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] SilverBullet-Setup fehlgeschlagen" \
    "Das SilverBullet-Setup auf **${SERVER_NAME}** ist fehlgeschlagen (Exit: $?).\nBitte Server manuell prüfen!" \
    "urgent" "rotating_light"' ERR

echo "### 1. SilverBullet Verzeichnis anlegen ###"
mkdir -p "${SB_SPACE_DIR}"

# docker-compose.yml ist Teil des Repos (silverbullet/docker-compose.yml) und liegt dank
# "scp -r silverbullet/ ... /opt/" bereits unter ${SB_DIR}/docker-compose.yml (Deploy-in-Place).
# Kein cp nötig (Quelle und Ziel wären nach dem Deploy derselbe Pfad).
if [[ ! -f "${SB_DIR}/docker-compose.yml" ]]; then
    echo "FEHLER: ${SB_DIR}/docker-compose.yml nicht gefunden." >&2
    echo "Bitte zuerst den silverbullet/-Ordner aus dem Repo nach /opt/ kopieren (siehe README.md)." >&2
    exit 1
fi

echo "### 2. Docker .env erzeugen ###"
# Dieses .env wird vom Container gelesen (nicht config.sh)
cat > "${SB_DIR}/.env" << EOF
SB_USER=${SB_USER}
SB_SPACE_DIR=${SB_SPACE_DIR}
EOF
chmod 600 "${SB_DIR}/.env"

echo "### 3. Eigentümer setzen ###"
# SilverBullet erkennt den UID-Eigentümer des /space-Ordners automatisch
# und läuft mit demselben UID – daher Admin-User als Eigentümer setzen.
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${SB_DIR}"

echo "### 4. SilverBullet Container starten ###"
cd "${SB_DIR}"

# Proxy erwartet ein externes Netzwerk; falls es noch nicht existiert,
# wird es hier idempotent angelegt.
docker network create silverbullet_net 2>/dev/null || true
docker compose up -d

echo "### 5. Reverse Proxy aktualisieren ###"
bash "$(dirname "${BASH_SOURCE[0]}")/../proxy/setup.sh"

ntfy_send "[OK] SilverBullet eingerichtet" \
    "SilverBullet auf **${SERVER_NAME}** wurde erfolgreich eingerichtet.\nErreichbar unter: https://${SB_DOMAIN}" \
    "default" "white_check_mark"

echo "=========================================================="
echo " SilverBullet Setup erfolgreich!"
echo " Erreichbar unter: https://${SB_DOMAIN}"
echo "=========================================================="
