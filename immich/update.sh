#!/bin/bash
set -eo pipefail

# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

cd "${IMMICH_DIR}"

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] Immich-Update fehlgeschlagen" \
    "Das automatische Update auf ${SERVER_NAME} ist fehlgeschlagen (Exit: $?)."$'"'"'\n'"'"'"Bitte Server manuell prüfen!" \
    "urgent" "rotating_light"' ERR

ntfy_send "[Immich] Update gestartet" \
    "Immich wird auf ${SERVER_NAME} aktualisiert..." \
    "min" "arrows_counterclockwise"

echo "### 1. Neue Images laden ###"
# Pull läuft während die Container noch laufen → minimale Downtime
docker compose pull

echo "### 2. Container mit neuen Images neu starten ###"
# --remove-orphans entfernt Container von entfernten Services
docker compose up -d --remove-orphans

echo "### 3. Verwaiste alte Images entfernen ###"
docker image prune -f

ntfy_send "[OK] Immich-Update erfolgreich" \
    "Immich auf ${SERVER_NAME} wurde erfolgreich aktualisiert." \
    "default" "white_check_mark"

echo "### Update erfolgreich abgeschlossen! ###"