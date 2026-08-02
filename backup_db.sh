#!/bin/bash
set -eo pipefail

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/immich_db_${DATE}.sql.gz"

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] DB-Backup fehlgeschlagen" \
    "Immich-DB-Backup auf ${SERVER_NAME} ist fehlgeschlagen (Exit: $?)." \
    "urgent" "rotating_light"' ERR

# --- DB-Zugangsdaten aus .env laden --------------------------
# shellcheck source=/dev/null
source "${IMMICH_DIR}/.env"
DB_USER="${DB_USERNAME:-postgres}"
DB_NAME="${DB_DATABASE_NAME:-immich}"

# --- Voraussetzungen prüfen ----------------------------------
if ! mountpoint -q "${STORAGEBOX_MOUNT}"; then
    echo "ERROR: Storage Box nicht gemountet! Backup abgebrochen." >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

# --- Backup erstellen ----------------------------------------
echo "Erstelle DB-Backup: ${BACKUP_FILE}"
docker exec -t immich_postgres pg_dump \
    --clean \
    --if-exists \
    --dbname="${DB_NAME}" \
    --username="${DB_USER}" | gzip > "${BACKUP_FILE}"

# --- Alte Backups aufräumen (>30 Tage) -----------------------
find "${BACKUP_DIR}" -type f -name "immich_db_*.sql.gz" -mtime +30 -delete

# --- Erfolgsbenachrichtigung ---------------------------------
BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
BACKUP_COUNT=$(find "${BACKUP_DIR}" -name "immich_db_*.sql.gz" | wc -l)

ntfy_send "[OK] DB-Backup erfolgreich" \
    "Backup auf ${SERVER_NAME} abgeschlossen."$'\n'"Datei: $(basename "${BACKUP_FILE}") (${BACKUP_SIZE})"$'\n'"Gespeicherte Backups: ${BACKUP_COUNT}" \
    "low" "white_check_mark"

echo "Backup abgeschlossen: ${BACKUP_FILE} (${BACKUP_SIZE})"