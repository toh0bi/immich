#!/bin/bash
# =============================================================
# Beispielkonfiguration für alle Immich-Wartungsskripte.
# Diese Datei ins Repo einchecken, lokal als config.sh kopieren
# und mit den echten Werten befüllen.
# =============================================================

# --- Server & Setup -----------------------------------------
ADMIN_USER="<ADMIN_USER>"                # SSH-Admin-User (nicht root!)
IMMICH_DOMAIN="<IMMICH_DOMAIN>"          # Deine echte (Sub-)Domain
STORAGE_BOX_USER="<STORAGE_BOX_USER>"
STORAGE_BOX_HOST="<STORAGE_BOX_HOST>"

# --- ntfy Konfiguration --------------------------------------
# Eigene Instanz empfohlen: https://docs.ntfy.sh/install/
# Alternativ ntfy.sh SaaS (public topics niemals mit echten Namen nutzen!)
NTFY_URL="https://ntfy.sh"               # Basis-URL, kein Slash am Ende
NTFY_TOPIC="immich-<zufall>"             # Schwer erratbares, eindeutiges Topic!
NTFY_TOKEN=""                            # Bearer-Token für private Topics (optional)
NTFY_MARKDOWN="yes"                      # Markdown-Rendering in ntfy explizit aktivieren

# --- Pfade ---------------------------------------------------
IMMICH_DIR="/opt/immich"
STORAGEBOX_MOUNT="/mnt/storagebox"
# Native Immich-Dumps liegen in ${UPLOAD_LOCATION}/backups.
# Quelle fuer Off-Site ist das gesamte Immich-Verzeichnis auf der Storage Box.
BACKUP_DIR="${STORAGEBOX_MOUNT}/immich_library/backups"
PCLOUD_BACKUP_SOURCE="${STORAGEBOX_MOUNT}/immich_library"
PCLOUD_BACKUP_CURRENT_REMOTE="pcloud:ImmichBackup/current"
PCLOUD_BACKUP_HISTORY_REMOTE="pcloud:ImmichBackup/history"
RETENTION_DAILY_DAYS="30"            # tägliche Medien-Stände in history/
RETENTION_MONTHLY_MONTHS="12"        # Monatsstände (Tag 01) zusätzlich behalten
LOG_DIR="/var/log/immich"
PCLOUD_LOG="${LOG_DIR}/pcloud_sync.log"
MONTHLY_REPORT_LOG="${LOG_DIR}/monthly_reports.log"

# --- Allgemein -----------------------------------------------
SERVER_NAME="$(hostname)"

# =============================================================
# Hilfsfunktion: ntfy-Benachrichtigung senden
# =============================================================
ntfy_send() {
    local title="${1:-}"
    local message="${2:-}"
    local priority="${3:-default}"
    local tags="${4:-loudspeaker}"
    local click_url="${5:-}"

    local -a args=(
        -s --max-time 10
        -H "Title: ${title}"
        -H "Priority: ${priority}"
        -H "Tags: ${tags}"
        -H "Markdown: ${NTFY_MARKDOWN:-yes}"
        -d "${message}"
    )
    [[ -n "${NTFY_TOKEN}" ]] && args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    [[ -n "${click_url}" ]] && args+=(-H "Click: ${click_url}")

    curl "${args[@]}" "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}