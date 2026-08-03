#!/bin/bash
# =============================================================
# Gemeinsame Server-Konfiguration (Admin-User, ntfy, Storage Box).
# Dienst-spezifische Werte liegen bei den jeweiligen Diensten:
#   immich/config.sh       ← IMMICH_DOMAIN, Backup-/pCloud-Pfade, ...
#   silverbullet/config.sh ← SB_DOMAIN, SB_USER, ...
# Diese Datei ins Repo einchecken, lokal als config.sh kopieren
# und mit den echten Werten befüllen.
# =============================================================

# --- Server & Setup -----------------------------------------
ADMIN_USER="<ADMIN_USER>"                # SSH-Admin-User (nicht root!)
STORAGE_BOX_USER="<STORAGE_BOX_USER>"
STORAGE_BOX_HOST="<STORAGE_BOX_HOST>"
STORAGEBOX_MOUNT="/mnt/storagebox"

# --- ntfy Konfiguration --------------------------------------
# Eigene Instanz empfohlen: https://docs.ntfy.sh/install/
# Alternativ ntfy.sh SaaS (public topics niemals mit echten Namen nutzen!)
NTFY_URL="https://ntfy.sh"               # Basis-URL, kein Slash am Ende
NTFY_TOPIC="server-<zufall>"             # Schwer erratbares, eindeutiges Topic!
NTFY_TOKEN=""                            # Bearer-Token für private Topics (optional)
NTFY_MARKDOWN="yes"                      # Markdown-Rendering in ntfy explizit aktivieren

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