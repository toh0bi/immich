#!/bin/bash
# Erstellt einen Sonntagsbericht und schickt eine
# Zusammenfassung via ntfy. Der vollständige Bericht wird lokal
# in eine Log-Datei geschrieben.
#
# Cron-Empfehlung:
#   0 3 * * 0 /bin/bash /opt/immich/sys_report.sh

# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

mkdir -p "${LOG_DIR}"

# --- Storage Box ---------------------------------------------
if mountpoint -q "${STORAGEBOX_MOUNT}"; then
    STORAGEBOX_USAGE=$(df -h "${STORAGEBOX_MOUNT}" | awk 'NR==2 {print $5 " belegt (" $3 " von " $2 ")"}')
else
    STORAGEBOX_USAGE="WARNUNG: NICHT GEMOUNTET!"
fi

# --- Systemwerte ---------------------------------------------
CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
RAM_USAGE=$(free -h | awk 'NR==2{print $3 " von " $2}')
SSD_USAGE=$(df -h / | awk 'NR==2 {print $5 " belegt (" $3 " von " $2 ")"}')
DOCKER_STATUS=$(docker ps --format "{{.Names}}: {{.Status}}" | sed 's/^/  /')
if [[ -z "${DOCKER_STATUS}" ]]; then
    DOCKER_STATUS="  keine laufenden Container"
fi
MONTH=$(date +"%B %Y")
REPORT_DATE=$(date +"%Y-%m-%d")

# --- Immich Update-Check ------------------------------------
LATEST_RELEASE_JSON=$(curl -fsSL --max-time 10 "https://api.github.com/repos/immich-app/immich/releases/latest" 2>/dev/null || true)
LATEST_TAG=$(jq -r '.tag_name // empty' <<<"${LATEST_RELEASE_JSON}")
CHANGELOG_URL=$(jq -r '.html_url // "https://github.com/immich-app/immich/releases"' <<<"${LATEST_RELEASE_JSON}")

RUNNING_VERSION=""
if docker ps --format '{{.Names}}' | grep -q '^immich_server$'; then
    RUNNING_IMAGE_ID=$(docker inspect --format '{{.Image}}' immich_server 2>/dev/null || true)
    if [[ -n "${RUNNING_IMAGE_ID}" ]]; then
        RUNNING_VERSION=$(docker image inspect "${RUNNING_IMAGE_ID}" \
            --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
    fi
fi

normalize_version() {
    sed 's/^v//' <<<"${1:-}"
}

UPDATE_STATUS="nicht pruefbar"
if [[ -n "${LATEST_TAG}" && -n "${RUNNING_VERSION}" ]]; then
    if [[ "$(normalize_version "${RUNNING_VERSION}")" == "$(normalize_version "${LATEST_TAG}")" ]]; then
        UPDATE_STATUS="aktuell (${RUNNING_VERSION})"
    else
        UPDATE_STATUS="Update verfuegbar (aktuell: ${RUNNING_VERSION}, latest: ${LATEST_TAG})"
    fi
elif [[ -n "${LATEST_TAG}" ]]; then
    UPDATE_STATUS="latest bekannt (${LATEST_TAG}), lokale Version unbekannt"
fi

# --- Vollständigen Bericht in Log-Datei schreiben ------------
REPORT=$(cat <<EOF
=== Sonntagsbericht ${REPORT_DATE} | Server: ${SERVER_NAME} ===
Monat:        ${MONTH}
CPU:          ${CPU_LOAD}
RAM:          ${RAM_USAGE}
SSD (/):      ${SSD_USAGE}
Storage Box:  ${STORAGEBOX_USAGE}
Container:
${DOCKER_STATUS}
Immich Update: ${UPDATE_STATUS}
Changelog: ${CHANGELOG_URL}
EOF
)

echo "${REPORT}" >> "${MONTHLY_REPORT_LOG}"
echo "Bericht gespeichert unter: ${MONTHLY_REPORT_LOG}"

# --- Kompakte ntfy-Benachrichtigung --------------------------
NTFY_MESSAGE="**Datum:** ${REPORT_DATE}"
NTFY_MESSAGE+=$'\n'"**CPU:** ${CPU_LOAD}"
NTFY_MESSAGE+=$'\n'"**RAM:** ${RAM_USAGE}"
NTFY_MESSAGE+=$'\n'"**SSD:** ${SSD_USAGE}"
NTFY_MESSAGE+=$'\n'"**Storage:** ${STORAGEBOX_USAGE}"
NTFY_MESSAGE+=$'\n'"**Container:**"
NTFY_MESSAGE+=$'\n'"${DOCKER_STATUS}"
NTFY_MESSAGE+=$'\n'"**Update:** ${UPDATE_STATUS}"
NTFY_MESSAGE+=$'\n'"**Changelog:** [Release Notes](${CHANGELOG_URL})"

ntfy_send "[Immich] Sonntagsbericht ${REPORT_DATE}" \
    "${NTFY_MESSAGE}" \
    "low" "chart_with_upwards_trend" "${CHANGELOG_URL}"