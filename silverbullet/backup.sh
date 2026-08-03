#!/bin/bash
set -eo pipefail

# Sichert den SilverBullet Space (Markdown-Dateien) auf die Hetzner Storage Box.
# Der Space ist klein und rein textbasiert → tägliches rsync reicht.
#
# Cron-Empfehlung:
#   0 4 * * * /bin/bash /opt/silverbullet/backup.sh

# Config-Dateien ggf. von CRLF auf LF normalisieren (Windows-Editor-Fall)
sed -i 's/\r$//' "$(dirname "${BASH_SOURCE[0]}")/../config.sh" "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

require_nonempty() {
    local var_name="$1"
    local var_value="$2"
    if [[ -z "${var_value//[[:space:]]/}" ]]; then
        echo "FEHLER: ${var_name} ist leer oder nicht gesetzt." >&2
        exit 2
    fi
}

require_nonempty "STORAGEBOX_MOUNT" "${STORAGEBOX_MOUNT:-}"
require_nonempty "SB_SPACE_DIR" "${SB_SPACE_DIR:-}"

# Fallback fuer Alt-Setups: Falls /opt/config.sh noch keine ntfy_send-Funktion
# enthaelt, einfach stillschweigend ohne Benachrichtigung weiterlaufen.
if ! declare -F ntfy_send >/dev/null; then
    ntfy_send() { :; }
fi

SB_BACKUP_DIR="${STORAGEBOX_MOUNT}/silverbullet_space"

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] SilverBullet-Backup fehlgeschlagen" \
    "Das SilverBullet-Backup auf **${SERVER_NAME}** ist fehlgeschlagen (Exit: $?).\nBitte Server manuell prüfen!" \
    "urgent" "rotating_light"' ERR

echo "### SilverBullet Space sichern ###"

if ! mountpoint -q "${STORAGEBOX_MOUNT}"; then
    echo "FEHLER: Storage Box ist nicht gemountet!" >&2
    exit 1
fi

if [[ ! -d "${SB_SPACE_DIR}" ]]; then
    echo "FEHLER: SilverBullet-Space nicht gefunden: ${SB_SPACE_DIR}" >&2
    exit 3
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "FEHLER: rsync ist nicht installiert oder nicht im PATH." >&2
    exit 127
fi

mkdir -p "${SB_BACKUP_DIR}"

rsync -a --delete \
    --exclude="*.sock" \
    "${SB_SPACE_DIR}/" \
    "${SB_BACKUP_DIR}/"

ntfy_send "[OK] SilverBullet-Backup erfolgreich" \
    "SilverBullet Space auf **${SERVER_NAME}** wurde auf die Storage Box gesichert." \
    "min" "floppy_disk"

echo "### Backup abgeschlossen: ${SB_BACKUP_DIR} ###"
