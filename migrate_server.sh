#!/bin/bash
set -eo pipefail
# =============================================================
# EINMALIGE SERVER-MIGRATION zur neuen Verzeichnisstruktur
#
# Was dieses Skript tut:
#   1. config.sh von /opt/immich/ nach /opt/ verschiebt und die
#      Immich-spezifischen Werte nach /opt/immich/config.sh abspaltet
#      (analog zu silverbullet/config.sh)
#   2. /opt/immich/docker-compose.yml ohne Caddy neu schreibt
#      (Caddy bekommt einen eigenen Compose unter /opt/proxy/)
#   3. Immich-Netzwerk (immich_net) anlegt und Container neu startet
#   4. Standalone Caddy-Proxy unter /opt/proxy/ startet
#   5. Log-Verzeichnis für SilverBullet anlegt
#   6. Die nötigen Crontab-Änderungen ausgibt
#
# Vorher auf dem Server scp'en (von lokalem Rechner):
#   ADMIN_USER hat i.d.R. keine Schreibrechte direkt unter /opt/ (nur in
#   /opt/immich/, das bereits ihm gehört) -- daher zuerst ins Home-Verzeichnis
#   kopieren und dann per sudo nach /opt/ übernehmen:
#   kopieren und dann per sudo nach /opt/ übernehmen. Falls ~/deploy noch
#   nicht existiert, zuerst anlegen:
#
#   ssh <ADMIN_USER>@<SERVER_IP> 'mkdir -p ~/deploy'
#   scp -r immich/ silverbullet/ proxy/ setup.sh config.example.sh \
#       migrate_server.sh <ADMIN_USER>@<SERVER_IP>:~/deploy/
#
# Dann auf dem Server ausführen:
#   rm -f ~/deploy/immich/config.sh ~/deploy/silverbullet/config.sh
#   sudo cp -r ~/deploy/* /opt/
#   sudo bash /opt/migrate_server.sh
# =============================================================

if [[ "$(id -u)" -ne 0 ]]; then
    echo "FEHLER: Dieses Skript muss als root ausgeführt werden." >&2
    exit 1
fi

# --- Config laden ---------------------------------------------
# Nach der Migration liegt config.sh unter /opt/; vorher unter /opt/immich/.
if [[ -f /opt/config.sh ]]; then
    source /opt/config.sh
    echo "  -> /opt/config.sh bereits vorhanden - kein Verschieben nötig."
elif [[ -f /opt/immich/config.sh ]]; then
    source /opt/immich/config.sh
else
    echo "FEHLER: Keine config.sh gefunden (weder /opt/ noch /opt/immich/)." >&2
    exit 1
fi

require_nonempty() {
    local var_name="$1"
    local var_value="$2"
    local hint_file="$3"
    if [[ -z "${var_value//[[:space:]]/}" ]]; then
        echo "FEHLER: ${var_name} ist leer oder nicht gesetzt." >&2
        echo "Bitte ${hint_file} korrigieren und Skript erneut starten." >&2
        exit 1
    fi
}

require_nonempty "ADMIN_USER" "${ADMIN_USER:-}" "/opt/config.sh"
require_nonempty "STORAGEBOX_MOUNT" "${STORAGEBOX_MOUNT:-}" "/opt/config.sh"

echo ""
echo "============================================================"
echo "  Server-Migration zur neuen Verzeichnisstruktur"
echo "============================================================"
echo ""

# =============================================================
# SCHRITT 1: config.sh nach /opt/ verschieben
# =============================================================
echo "### Schritt 1: config.sh nach /opt/ verschieben ###"

if [[ ! -f /opt/config.sh ]] && [[ -f /opt/immich/config.sh ]]; then
    cp /opt/immich/config.sh /opt/config.sh
    echo "  -> /opt/config.sh erstellt (Kopie von /opt/immich/config.sh)"
    echo "  -> Original /opt/immich/config.sh bleibt als Backup erhalten."
else
    echo "  -> Bereits erledigt, übersprungen."
fi

# =============================================================
# SCHRITT 1b: Immich-spezifische Werte nach /opt/immich/config.sh abspalten
# =============================================================
echo ""
echo "### Schritt 1b: Immich-spezifische Config abspalten (analog SilverBullet) ###"

# Extrahiert die Immich-spezifischen Werte aus der (bereits geladenen) alten,
# kombinierten config.sh in eine eigene Datei -- ersetzt dabei die alte
# /opt/immich/config.sh (die bis hierhin nur als Config-Quelle diente).
cat > /opt/immich/config.sh << EOF
#!/bin/bash
# Immich-spezifische Konfiguration (automatisch aus der alten
# kombinierten config.sh extrahiert). STORAGEBOX_MOUNT & Co. kommen
# weiterhin aus der gemeinsamen /opt/config.sh.
IMMICH_DOMAIN="${IMMICH_DOMAIN}"
IMMICH_DIR="${IMMICH_DIR}"
BACKUP_DIR="${STORAGEBOX_MOUNT}/immich_library/backups"
PCLOUD_BACKUP_SOURCE="${STORAGEBOX_MOUNT}/immich_library"
PCLOUD_BACKUP_CURRENT_REMOTE="${PCLOUD_BACKUP_CURRENT_REMOTE}"
PCLOUD_BACKUP_HISTORY_REMOTE="${PCLOUD_BACKUP_HISTORY_REMOTE}"
RETENTION_DAILY_DAYS="${RETENTION_DAILY_DAYS}"
RETENTION_MONTHLY_MONTHS="${RETENTION_MONTHLY_MONTHS}"
LOG_DIR="${LOG_DIR}"
PCLOUD_LOG="${PCLOUD_LOG}"
MONTHLY_REPORT_LOG="${MONTHLY_REPORT_LOG}"
EOF
echo "  -> /opt/immich/config.sh erstellt/aktualisiert (Immich-Werte, analog silverbullet/config.sh)."
echo "  -> Hinweis: /opt/config.sh darf die alten Immich-Zeilen (IMMICH_DOMAIN, BACKUP_DIR, PCLOUD_*, ...)"
echo "     behalten oder von Hand entfernen -- sie werden von den Skripten nicht mehr benutzt."

# =============================================================
# SCHRITT 2: SilverBullet-Config anlegen (falls noch nicht vorhanden)
# =============================================================
echo ""
echo "### Schritt 2: SilverBullet config.sh prüfen ###"

if [[ ! -f /opt/silverbullet/config.sh ]]; then
    mkdir -p /opt/silverbullet
    if [[ -f /opt/silverbullet/config.example.sh ]]; then
        cp /opt/silverbullet/config.example.sh /opt/silverbullet/config.sh
        echo "  -> /opt/silverbullet/config.sh aus config.example.sh erstellt."
        echo "  !! WICHTIG: Bitte vor dem nächsten Schritt anpassen:"
        echo "       nano /opt/silverbullet/config.sh"
        echo ""
        read -rp "  Drücke Enter, wenn config.sh angepasst wurde ..."
        # Falls die Datei mit Windows-Zeilenenden (CRLF) bearbeitet wurde,
        # vor dem source in LF normalisieren.
        sed -i 's/\r$//' /opt/silverbullet/config.sh
        source /opt/silverbullet/config.sh
    else
        echo "  FEHLER: /opt/silverbullet/config.example.sh nicht gefunden." >&2
        echo "  Bitte zuerst die neuen Repo-Dateien nach /opt/ kopieren." >&2
        exit 1
    fi
else
    # Falls die Datei mit Windows-Zeilenenden (CRLF) bearbeitet wurde,
    # vor dem source in LF normalisieren.
    sed -i 's/\r$//' /opt/silverbullet/config.sh
    source /opt/silverbullet/config.sh
    echo "  -> /opt/silverbullet/config.sh vorhanden, geladen."
fi

# =============================================================
# SCHRITT 2b: Eigentümer für neue Deploy-Dateien korrigieren
# =============================================================
echo ""
echo "### Schritt 2b: Eigentümer korrigieren ###"

# /opt/silverbullet und /opt/proxy wurden per sudo cp angelegt/aktualisiert
# und gehören sonst root. Für spätere Wartung sollen sie dem Admin-User
# gehören.
for dir in /opt/silverbullet /opt/proxy; do
    if [[ -d "${dir}" ]]; then
        chown -R "${ADMIN_USER}:${ADMIN_USER}" "${dir}"
        echo "  -> ${dir} Eigentümer auf ${ADMIN_USER} gesetzt."
    fi
done

# Bei Immich nur Steuerdateien zurück auf Admin-User setzen. Das Postgres-
# Datenverzeichnis wird bewusst nicht rekursiv angefasst.
if [[ -d /opt/immich ]]; then
    find /opt/immich -maxdepth 1 -type f \
        \( -name "*.sh" -o -name "docker-compose.yml" -o -name "config*.sh" -o -name ".env" \) \
        -exec chown "${ADMIN_USER}:${ADMIN_USER}" {} +
    echo "  -> Immich-Steuerdateien auf ${ADMIN_USER} gesetzt (ohne postgres/)."
fi

# =============================================================
# SCHRITT 3: Immich docker-compose.yml ohne Caddy neu schreiben
# =============================================================
echo ""
echo "### Schritt 3: Immich docker-compose.yml aktualisieren (Caddy entfernen) ###"

if docker ps -q -f name=immich_proxy 2>/dev/null | grep -q .; then
    echo "  -> Alten Caddy (immich_proxy) stoppen und entfernen..."
    cd /opt/immich
    docker compose stop caddy 2>/dev/null || true
    docker compose rm -f caddy 2>/dev/null || true
fi

# docker-compose.yml (ohne Caddy) ist Teil des Repos (immich/docker-compose.yml) und liegt
# dank "scp -r immich/ ... /opt/" bereits aktualisiert unter /opt/immich/docker-compose.yml.
if [[ ! -f /opt/immich/docker-compose.yml ]]; then
    echo "FEHLER: /opt/immich/docker-compose.yml nicht gefunden." >&2
    echo "Bitte zuerst die neuen Repo-Dateien nach /opt/ kopieren (siehe Skript-Kopf)." >&2
    exit 1
fi
echo "  -> /opt/immich/docker-compose.yml bereits per scp aktualisiert (ohne Caddy)."

cd /opt/immich
docker compose up -d --remove-orphans
echo "  -> Immich-Container neu gestartet (Caddy-Orphan entfernt)."

# =============================================================
# SCHRITT 4: Standalone Caddy-Proxy starten
# =============================================================
echo ""
echo "### Schritt 4: Standalone Caddy-Proxy einrichten ###"

# Netzwerke, docker-compose.yml-Check, Caddyfile-Generierung und Start/Reload
# sind identisch zu proxy/setup.sh -> nicht duplizieren, sondern aufrufen.
bash /opt/proxy/setup.sh

# =============================================================
# SCHRITT 5: Log-Verzeichnisse anlegen
# =============================================================
echo ""
echo "### Schritt 5: Log-Verzeichnisse ###"

mkdir -p /var/log/silverbullet
chown "${ADMIN_USER}:${ADMIN_USER}" /var/log/silverbullet
echo "  -> /var/log/silverbullet/ angelegt."

# Log-Rotation für SilverBullet
if [[ ! -f /etc/logrotate.d/silverbullet ]]; then
    cat > /etc/logrotate.d/silverbullet << 'EOF'
/var/log/silverbullet/*.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
    echo "  -> logrotate-Konfiguration angelegt."
fi

# =============================================================
# SCHRITT 6: Crontab-Hinweise ausgeben
# =============================================================
echo ""
echo "### Schritt 6: Crontab aktualisieren ###"
echo ""
echo "  Führe 'crontab -e' aus und ergänze folgende Zeilen:"
echo ""
echo "  # Bestehende Zeilen bleiben unverändert:"
echo "  # */10 * * * * /bin/bash /opt/immich/check_logs.sh"
echo "  # 20 */6 * * * /bin/bash /opt/immich/sync_pcloud.sh"
echo "  # 0 3 * * 0 /bin/bash /opt/immich/sys_report.sh"
echo "  # 0 4 * * 0 /bin/bash /opt/immich/update_os.sh >> /var/log/immich/update_os.log 2>&1"
echo ""
echo "  # NEU – SilverBullet:"
echo "  30 4 * * * /bin/bash /opt/silverbullet/backup.sh >> /var/log/silverbullet/backup.log 2>&1"
echo "  0 2 * * 0 /bin/bash /opt/silverbullet/update.sh >> /var/log/silverbullet/update.log 2>&1"
echo ""

# =============================================================
# Fertig
# =============================================================
echo "============================================================"
echo " Migration abgeschlossen!"
echo ""
echo " Nächster Schritt: SilverBullet einrichten"
echo "   sudo bash /opt/silverbullet/setup.sh"
echo ""
echo " Immich:        https://${IMMICH_DOMAIN}"
echo " SilverBullet:  https://${SB_DOMAIN} (nach setup.sh)"
echo "============================================================"
