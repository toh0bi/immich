#!/bin/bash
set -eo pipefail

# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

cd /opt/silverbullet

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] SilverBullet-Update fehlgeschlagen" \
    "Das automatische Update auf **${SERVER_NAME}** ist fehlgeschlagen (Exit: $?).\nBitte Server manuell prüfen!" \
    "urgent" "rotating_light"' ERR

ntfy_send "[SilverBullet] Update gestartet" \
    "SilverBullet wird auf ${SERVER_NAME} aktualisiert..." \
    "min" "arrows_counterclockwise"

echo "### 1. Neues Image laden ###"
docker compose pull

echo "### 2. Container mit neuem Image neu starten ###"
docker compose up -d --remove-orphans

echo "### 3. Verwaiste alte Images entfernen ###"
docker image prune -f

ntfy_send "[OK] SilverBullet-Update erfolgreich" \
    "SilverBullet auf **${SERVER_NAME}** wurde erfolgreich aktualisiert." \
    "default" "white_check_mark"

echo "### Update erfolgreich abgeschlossen! ###"
