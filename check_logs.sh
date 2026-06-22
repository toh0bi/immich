#!/bin/bash
# Prüft System- und Immich-Logs auf Fehler und schickt bei Befund
# eine ntfy-Benachrichtigung (max. einmal pro Stunde).
#
# Cron-Empfehlung:
#   */10 * * * * /bin/bash /opt/immich/check_logs.sh

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# --- Rate-Limiting: max. eine Benachrichtigung pro 2 Stunden ----
COOLDOWN_FILE="/tmp/immich_alert_cooldown"
COOLDOWN_SECS=7200

mkdir -p "${LOG_DIR}"

if [[ -f "${COOLDOWN_FILE}" ]]; then
    last_alert=$(cat "${COOLDOWN_FILE}")
    now=$(date +%s)
    if (( now - last_alert < COOLDOWN_SECS )); then
        exit 0
    fi
fi

# --- System-Logs (letzte 10 Min) – nur echte Kritikalitäten -----
# "error" allein erzeugt zu viele False Positives; explizite Schlüsselwörter nutzen
SYS_ERRORS=$(journalctl --since "10 minutes ago" --no-pager -q \
    | grep -Ei "\b(critical|emerg|alert|kernel: BUG|oom-killer)\b" \
    | tail -n 5 || true)

# --- Immich Container-Logs (letzte 10 Min) --------------------
# Caddy schreibt JSON-Logs: "level":"warn" mit "error"-Feld ist kein Alarm.
# Nur echte Fehler melden: level error/fatal/panic, oder non-JSON Zeilen mit error/critical/fatal.
IMMICH_ERRORS=$(docker compose -f "${IMMICH_DIR}/docker-compose.yml" logs --since 10m 2>&1 \
    | grep -Ev '"level":"(warn|info|debug)"' \
    | grep -Ei "\b(error|critical|fatal|panic)\b" \
    | grep -v "^[[:space:]]*$" \
    | tail -n 10 || true)

# --- Klassischer Regex-Classifier (Bash-only) ----------------
# Regeln gezielt hier pflegen/erweitern.
BENIGN_PATTERNS=(
    'client.*(closed|disconnect|abort)'
    '(broken pipe|connection reset by peer).*(client|upload|request)'
    '(request|upload).*(cancelled|canceled|aborted)'
    'context canceled'
    '(^|[^0-9])499([^0-9]|$)'
    'socket hang up'
)

CRITICAL_PATTERNS=(
    'panic'
    'fatal'
    'oom-killer'
    'kernel: BUG'
    'no space left on device'
    'read-only file system'
    'database .* unavailable'
    'failed to connect'
    'segmentation fault'
)

match_any() {
    local line="$1"
    shift
    local pattern
    for pattern in "$@"; do
        if [[ "${line}" =~ ${pattern} ]]; then
            return 0
        fi
    done
    return 1
}

sev_rank() {
    case "$1" in
        ignore) echo 0 ;;
        low) echo 2 ;;
        medium) echo 3 ;;
        high) echo 4 ;;
        critical) echo 5 ;;
        *) echo 0 ;;
    esac
}

if [[ -z "${SYS_ERRORS}" && -z "${IMMICH_ERRORS}" ]]; then
    exit 0
fi

mapfile -t CANDIDATE_LINES < <(
    printf '%s\n%s\n' "${SYS_ERRORS}" "${IMMICH_ERRORS}" \
        | sed '/^[[:space:]]*$/d' \
        | awk '!seen[$0]++'
)

shopt -s nocasematch
SEVERITY="ignore"
declare -a RELEVANT_LINES=()
declare -a IGNORED_LINES=()

for line in "${CANDIDATE_LINES[@]}"; do
    is_benign=0
    is_critical=0

    if match_any "${line}" "${BENIGN_PATTERNS[@]}"; then
        is_benign=1
    fi
    if match_any "${line}" "${CRITICAL_PATTERNS[@]}"; then
        is_critical=1
    fi

    if [[ ${is_benign} -eq 1 && ${is_critical} -eq 0 ]]; then
        IGNORED_LINES+=("${line}")
        continue
    fi

    RELEVANT_LINES+=("${line}")

    candidate="medium"
    if [[ ${is_critical} -eq 1 ]]; then
        candidate="critical"
    elif [[ "${line}" =~ (error|critical|fatal|panic) ]]; then
        candidate="high"
    fi

    if (( $(sev_rank "${candidate}") > $(sev_rank "${SEVERITY}") )); then
        SEVERITY="${candidate}"
    fi
done
shopt -u nocasematch

if [[ ${#RELEVANT_LINES[@]} -eq 0 ]]; then
    exit 0
fi

PRIORITY="high"
ACTION="Logs pruefen und Ursache eingrenzen."
SUMMARY="Relevante Fehler im Log gefunden."
REASON="Treffer enthalten keine reinen Client-Abbrueche."
if [[ "${SEVERITY}" == "critical" ]]; then
    PRIORITY="urgent"
    ACTION="Sofort handeln: Storage/DB/Container-Status pruefen."
    SUMMARY="Kritische Fehler im Log gefunden."
fi

MESSAGE="**Einstufung:** ${SEVERITY}"$'\n'
MESSAGE+="**Kurzdiagnose:** ${SUMMARY}"$'\n'
MESSAGE+="**Warum:** ${REASON}"$'\n'
MESSAGE+="**Aktion:** ${ACTION}"$'\n'
MESSAGE+="**Quelle:** regex-heuristic"
MESSAGE+=$'\n\n'"**Relevante Logs:**"

for line in "${RELEVANT_LINES[@]:0:8}"; do
    MESSAGE+=$'\n'"- ${line}"
done

ntfy_send "[ALARM:${SEVERITY}] Fehler auf ${SERVER_NAME}" \
    "${MESSAGE}" \
    "${PRIORITY}" "rotating_light"

# Cooldown-Zeitstempel aktualisieren
date +%s > "${COOLDOWN_FILE}"