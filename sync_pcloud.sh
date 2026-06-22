#!/bin/bash
set -eo pipefail

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

mkdir -p "${LOG_DIR}"

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] pCloud-Sync fehlgeschlagen" \
    "rclone-Sync auf ${SERVER_NAME} ist fehlgeschlagen (Exit: $?)."$'"'"'\n'"'"'"Details: ${PCLOUD_LOG}" \
    "high" "rotating_light"' ERR

# --- Voraussetzungen prüfen ----------------------------------
if ! mountpoint -q "${STORAGEBOX_MOUNT}"; then
    echo "ERROR: Storage Box nicht gemountet! Sync abgebrochen." | tee -a "${PCLOUD_LOG}" >&2
    exit 1
fi

START_LINE=0
if [[ -f "${PCLOUD_LOG}" ]]; then
    START_LINE=$(wc -l < "${PCLOUD_LOG}")
fi

echo "### Start pCloud Sync: $(date) ###" >> "${PCLOUD_LOG}"

# 1) Originaldateien: sync = 1:1-Spiegelung.
#    Löscht bei pCloud, wenn Datei in Immich gelöscht wird.
#    Für rein additives Backup stattdessen "copy" verwenden.
echo "  -> Originale: ${PCLOUD_SOURCE} → ${PCLOUD_REMOTE}" >> "${PCLOUD_LOG}"
rclone sync "${PCLOUD_SOURCE}" "${PCLOUD_REMOTE}" \
    --fast-list \
    --transfers 4 \
    --checkers 8 \
    --log-file="${PCLOUD_LOG}" \
    --log-level INFO

# 2) DB-Backups: copy (niemals remote löschen!)
#    Lokale Rotation (30 Tage) läuft in backup_db.sh – pCloud behält alles.
echo "  -> DB-Backups: ${BACKUP_DIR} → ${PCLOUD_DB_REMOTE}" >> "${PCLOUD_LOG}"
rclone copy "${BACKUP_DIR}" "${PCLOUD_DB_REMOTE}" \
    --fast-list \
    --transfers 2 \
    --log-file="${PCLOUD_LOG}" \
    --log-level INFO

echo "### Ende pCloud Sync: $(date) ###" >> "${PCLOUD_LOG}"

RUN_LOG=$(sed -n "$((START_LINE + 1)),\$p" "${PCLOUD_LOG}")

extract_metric() {
    local section_start="$1"
    local section_end="$2"
    local pattern="$3"

    awk -v start="${section_start}" -v end="${section_end}" -v pat="${pattern}" '
        $0 ~ start {in_section=1; next}
        $0 ~ end {if (in_section) in_section=0}
        in_section && $0 ~ pat {line=$0}
        END {print line}
    ' <<< "${RUN_LOG}"
}

ORIG_TRANSFERRED=$(extract_metric "^  -> Originale:" "^  -> DB-Backups:" "^Transferred:")
ORIG_CHECKS=$(extract_metric "^  -> Originale:" "^  -> DB-Backups:" "^Checks:")
ORIG_DELETED=$(extract_metric "^  -> Originale:" "^  -> DB-Backups:" "^Deleted:")
ORIG_ELAPSED=$(extract_metric "^  -> Originale:" "^  -> DB-Backups:" "^Elapsed time:")

DB_TRANSFERRED=$(awk '
    /^  -> DB-Backups:/ {in_section=1; next}
    in_section && /^Transferred:/ {line=$0}
    END {print line}
' <<< "${RUN_LOG}")
DB_CHECKS=$(awk '
    /^  -> DB-Backups:/ {in_section=1; next}
    in_section && /^Checks:/ {line=$0}
    END {print line}
' <<< "${RUN_LOG}")
DB_ELAPSED=$(awk '
    /^  -> DB-Backups:/ {in_section=1; next}
    in_section && /^Elapsed time:/ {line=$0}
    END {print line}
' <<< "${RUN_LOG}")

SUCCESS_MESSAGE="pCloud-Sync auf ${SERVER_NAME} erfolgreich abgeschlossen."

if [[ -n "${ORIG_TRANSFERRED}${ORIG_CHECKS}${ORIG_DELETED}${ORIG_ELAPSED}" ]]; then
    SUCCESS_MESSAGE="${SUCCESS_MESSAGE}

Originale:"
    [[ -n "${ORIG_TRANSFERRED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${ORIG_TRANSFERRED}"
    [[ -n "${ORIG_CHECKS}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${ORIG_CHECKS}"
    [[ -n "${ORIG_DELETED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${ORIG_DELETED}"
    [[ -n "${ORIG_ELAPSED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${ORIG_ELAPSED}"
fi

if [[ -n "${DB_TRANSFERRED}${DB_CHECKS}${DB_ELAPSED}" ]]; then
    SUCCESS_MESSAGE="${SUCCESS_MESSAGE}

DB-Backups:"
    [[ -n "${DB_TRANSFERRED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${DB_TRANSFERRED}"
    [[ -n "${DB_CHECKS}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${DB_CHECKS}"
    [[ -n "${DB_ELAPSED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${DB_ELAPSED}"
fi

SUCCESS_MESSAGE="${SUCCESS_MESSAGE}

Details: ${PCLOUD_LOG}"

ntfy_send "[OK] pCloud-Sync erfolgreich" \
    "${SUCCESS_MESSAGE}" \
    "low" "white_check_mark"