#!/bin/bash
set -eo pipefail

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# --- Fehlerbehandlung via Trap --------------------------------
trap 'ntfy_send "[ALARM] OS-Update fehlgeschlagen" \
    "Das automatische OS-Update auf **${SERVER_NAME}** ist fehlgeschlagen (Exit: $?).\nBitte Server manuell prüfen!" \
    "urgent" "rotating_light"' ERR

ntfy_send "[OS] Update gestartet" \
    "OS-Updates werden auf **${SERVER_NAME}** eingespielt..." \
    "min" "arrows_counterclockwise"

echo "### 1. Paketlisten aktualisieren ###"
DEBIAN_FRONTEND=noninteractive apt-get update -q

# Zähle verfügbare Updates für die Benachrichtigung
UPDATE_COUNT=$(apt-get --just-print upgrade 2>/dev/null \
    | grep -c '^Inst ' || true)

echo "### 2. Updates einspielen (${UPDATE_COUNT} Pakete) ###"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

echo "### 3. Verwaiste Pakete aufräumen ###"
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q
apt-get autoclean -q

echo "### 4. Reboot-Status prüfen ###"
if [[ -f /var/run/reboot-required ]]; then
    REBOOT_PACKAGES=""
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        REBOOT_PACKAGES="\nPakete: $(cat /var/run/reboot-required.pkgs | tr '\n' ' ')"
    fi

    ntfy_send "[OS] Reboot erforderlich" \
        "OS-Update auf **${SERVER_NAME}** erfolgreich (${UPDATE_COUNT} Pakete).\n**Ein Neustart ist notwendig!**${REBOOT_PACKAGES}" \
        "high" "warning"

    echo "!!! REBOOT ERFORDERLICH – bitte manuell ausführen: sudo reboot !!!"
else
    ntfy_send "[OK] OS-Update erfolgreich" \
        "OS-Update auf **${SERVER_NAME}** erfolgreich abgeschlossen (${UPDATE_COUNT} Pakete).\nKein Neustart nötig." \
        "default" "white_check_mark"

    echo "### Update erfolgreich – kein Reboot nötig ###"
fi
