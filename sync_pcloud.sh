#!/bin/bash
set -eo pipefail

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

mkdir -p "${LOG_DIR}"

RUN_ID=$(date +%Y%m%d_%H%M%S)
CURRENT_REMOTE="${PCLOUD_BACKUP_CURRENT_REMOTE}"
HISTORY_BASE_REMOTE="${PCLOUD_BACKUP_HISTORY_REMOTE}"
RUN_HISTORY_REMOTE="${HISTORY_BASE_REMOTE}/${RUN_ID}"

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

# 1) Komplettes Immich-Backup-Verzeichnis syncen (inkl. backups/).
#    current spiegelt den aktuellen Stand.
#    Überschriebene/gelöschte Dateien werden nach history/<timestamp> verschoben.
echo "  -> Backup-Dir: ${PCLOUD_BACKUP_SOURCE} → ${CURRENT_REMOTE} (history: ${RUN_HISTORY_REMOTE})" >> "${PCLOUD_LOG}"
rclone sync "${PCLOUD_BACKUP_SOURCE}" "${CURRENT_REMOTE}" \
    --backup-dir "${RUN_HISTORY_REMOTE}" \
    --fast-list \
    --transfers 4 \
    --checkers 8 \
    --log-file="${PCLOUD_LOG}" \
    --log-level INFO

# 1b) Retention auf history anwenden:
#     - tägliche Stände fuer RETENTION_DAILY_DAYS
#     - Monatsstände (Tag 01) fuer RETENTION_MONTHLY_MONTHS
cleanup_history() {
    local cutoff
    local current_year current_month

    cutoff=$(date -d "-${RETENTION_DAILY_DAYS} days" +%Y%m%d_%H%M%S)
    current_year=$(date +%Y)
    current_month=$(date +%m)

    while IFS= read -r dir; do
        local snapshot_id snapshot_day snapshot_year snapshot_month
        local months_diff

        snapshot_id="${dir%/}"
        [[ "${snapshot_id}" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue

        # Zu jung: immer behalten.
        if [[ "${snapshot_id}" > "${cutoff}" ]]; then
            continue
        fi

        snapshot_day="${snapshot_id:6:2}"
        if [[ "${snapshot_day}" == "01" ]]; then
            snapshot_year="${snapshot_id:0:4}"
            snapshot_month="${snapshot_id:4:2}"
            months_diff=$(( (10#${current_year} - 10#${snapshot_year}) * 12 + (10#${current_month} - 10#${snapshot_month}) ))
            if (( months_diff < RETENTION_MONTHLY_MONTHS )); then
                continue
            fi
        fi

        echo "  -> Retention: entferne history/${snapshot_id}" >> "${PCLOUD_LOG}"
        rclone purge "${HISTORY_BASE_REMOTE}/${snapshot_id}" \
            --log-file="${PCLOUD_LOG}" \
            --log-level INFO
    done < <(rclone lsf "${HISTORY_BASE_REMOTE}" --dirs)
}

cleanup_history

echo "### Ende pCloud Sync: $(date) ###" >> "${PCLOUD_LOG}"

RUN_LOG=$(sed -n "$((START_LINE + 1)),\$p" "${PCLOUD_LOG}")

extract_metric() {
    local section_start="$1"
    local pattern="$2"

    awk -v start="${section_start}" -v pat="${pattern}" '
        $0 ~ start {in_section=1; next}
        /^### Ende pCloud Sync:/ {if (in_section) in_section=0}
        in_section && $0 ~ pat {line=$0}
        END {print line}
    ' <<< "${RUN_LOG}"
}

SYNC_TRANSFERRED=$(extract_metric "^  -> Backup-Dir:" "^Transferred:")
SYNC_CHECKS=$(extract_metric "^  -> Backup-Dir:" "^Checks:")
SYNC_DELETED=$(extract_metric "^  -> Backup-Dir:" "^Deleted:")
SYNC_ELAPSED=$(extract_metric "^  -> Backup-Dir:" "^Elapsed time:")

SUCCESS_MESSAGE="pCloud-Sync auf ${SERVER_NAME} erfolgreich abgeschlossen."

if [[ -n "${SYNC_TRANSFERRED}${SYNC_CHECKS}${SYNC_DELETED}${SYNC_ELAPSED}" ]]; then
    SUCCESS_MESSAGE="${SUCCESS_MESSAGE}

Backup-Dir:"
    [[ -n "${SYNC_TRANSFERRED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${SYNC_TRANSFERRED}"
    [[ -n "${SYNC_CHECKS}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${SYNC_CHECKS}"
    [[ -n "${SYNC_DELETED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${SYNC_DELETED}"
    [[ -n "${SYNC_ELAPSED}" ]] && SUCCESS_MESSAGE="${SUCCESS_MESSAGE}
${SYNC_ELAPSED}"
fi

SUCCESS_MESSAGE="${SUCCESS_MESSAGE}

Details: ${PCLOUD_LOG}"

ntfy_send "[OK] pCloud-Sync erfolgreich" \
    "${SUCCESS_MESSAGE}" \
    "low" "white_check_mark"