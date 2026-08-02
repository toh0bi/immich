# Immich VPS Setup

Dieses Repo enthält die Skripte für ein produktionsnahes Immich-Setup auf einem Hetzner VPS.
Es deckt Setup, Backups, pCloud-Sync, Log-Checks und Statusmeldungen ab.

## Schnellstart

1. `config.example.sh` nach `config.sh` kopieren und lokal anpassen.
2. Die Skripte nach `/opt/immich/` auf den Server kopieren.
3. `setup.sh` auf dem Server ausführen.

Das Setup arbeitet mit:

- **Immich** (Foto-Server) via Docker Compose
- **Caddy** als Reverse Proxy mit automatischem TLS
- **Hetzner Storage Box** (CIFS) als primärer Foto-Speicher + DB-Backup-Ziel
- **SSD lokal** für `thumbs` (schnelleres UI-Scrolling/Face-Thumbs)
- **pCloud** als sekundäres Backup via rclone
- **ntfy** für alle Benachrichtigungen (kein Mail-Server nötig)
- **Regex-basierter Klassifizierer (Bash-only)** zur Unterdrückung von Bagatellen

RPO/RTO-Zielwerte in diesem Setup:
- **RPO DB:** 6 Stunden
- **RPO Medien:** 6 Stunden
- **RTO:** 2-8 Stunden (abhängig von Datenmenge und Leitung)

---

## Dateiübersicht

| Datei | Beschreibung |
|---|---|
| `setup.sh` | **Einmalig** ausführen – richtet den Server komplett ein |
| `config.example.sh` | **Vorlage** für die lokale Konfiguration |
| `config.sh` | **Lokale Konfiguration** – wird nicht ins Repo eingecheckt |
| `backup_db.sh` | Optionaler manueller PostgreSQL-Dump (Fallback) |
| `sync_pcloud.sh` | rclone Sync des kompletten Immich-Backup-Verzeichnisses nach pCloud |
| `check_logs.sh` | Fehler-Scan mit Regex-Klassifizierung und ntfy-Alert nur bei Handlungsbedarf |
| `sys_report.sh` | Statusbericht via ntfy (sonntags um 03:00 Uhr) |
| `update.sh` | Immich-Update ohne Downtime-Unterbrechung |
| `update_os.sh` | `apt upgrade` mit ntfy-Alert bei Reboot-Bedarf (sonntags per Cron) |

---

## Ersteinrichtung

### 1. Voraussetzungen

- Hetzner VPS (**Ubuntu 24.04 LTS** empfohlen – 26.04 ist zu frisch, 22.04 läuft aus)
- Domain oder Subdomain, die auf die Server-IP zeigt
- Hetzner Storage Box
- pCloud-Account

### 2. Skripte und Konfiguration vorbereiten

```bash
# Lokale Konfiguration aus der Vorlage erzeugen und anpassen
cp config.example.sh config.sh
```

### 3. Setup ausführen

```bash
# Skripte auf den Server kopieren
scp *.sh *.py *.md root@<SERVER_IP>:/opt/immich/

# Setup starten (fragt Passwort interaktiv ab)
chmod +x /opt/immich/setup.sh
/opt/immich/setup.sh
```

Das Skript:
- Installiert Docker, UFW, rclone, curl, jq
- Konfiguriert die Firewall
- Mountet die Storage Box via CIFS
- Legt Split-Storage an: `upload/library/backups/...` auf Storage Box, `thumbs` auf SSD (`/opt/immich/data/thumbs`)
- Erstellt `.env` und `docker-compose.yml` unter `/opt/immich/`
- Generiert ein `Caddyfile` mit deiner Domain
- Startet alle Container

### 4. Lokale config.sh anpassen

Bearbeite die lokale Kopie `config.sh` und trage ein:

```bash
NTFY_URL="https://ntfy.sh"        # oder deine eigene Instanz
NTFY_TOPIC="immich-XXXXXXXX"      # schwer erratbares Topic!
NTFY_TOKEN=""                      # nur nötig bei private Topics
```

**Tipp:** Eigene ntfy-Instanz ist sicherer als ntfy.sh (public topics sind öffentlich lesbar).
Selbst-gehostete ntfy-Instanz: https://docs.ntfy.sh/install/

### 5. Warum Bash-only fuer die Logklassifizierung?

Der Scheduler, die Logsammlung und die Einordnung laufen bewusst in Bash, weil Cron, `journalctl` und `docker compose logs` dort direkt und robust sind.
`check_logs.sh` nutzt erweiterbare Regex-Regeln und vermeidet zusätzliche Laufzeitabhängigkeiten.

Kurz gesagt:
- **Bash** fuer Sammeln, Klassifizieren und Versand
- **Regex-Regeln** fuer transparente, lokal pflegbare Alert-Logik

### 6. Skripte ausführbar machen

```bash
chmod +x /opt/immich/*.sh
```

---

## ntfy einrichten

### Option A: ntfy.sh (schnell, kein eigener Server)

```bash
# Topic-URL: https://ntfy.sh/dein-topic
# App: ntfy iOS/Android, einfach das Topic abonnieren
```

⚠️ Public Topics sind für jeden lesbar! Ein langer, zufälliger Topic-Name ist Pflicht:
`immich-$(openssl rand -hex 8)` – diesen Wert in `config.sh` eintragen.

### Option B: Eigene ntfy-Instanz (empfohlen)

```bash
docker run -d --name ntfy \
  -p 8080:80 \
  -v /opt/ntfy/cache:/var/cache/ntfy \
  -v /opt/ntfy/config:/etc/ntfy \
  --restart always \
  binwiederhier/ntfy serve
```

Danach in `config.sh`:
```bash
NTFY_URL="https://ntfy.deinedomain.de"
NTFY_TOKEN="dein-bearer-token"
```

---

## rclone für pCloud einrichten

rclone muss einmalig auf dem Server konfiguriert werden:

```bash
rclone config
```

1. `n` → New remote, Name: `pcloud`
2. Storage-Typ: pcloud (Zahl aus der Liste wählen)
3. Client-ID und Secret leer lassen
4. `n` bei "Use web browser to authenticate" (VPS ist headless!)
5. Den angezeigten Link am **lokalen PC** im Browser öffnen → Token kopieren
6. Token ins VPS-Terminal einfügen

**Wichtig für EU-Nutzer:** pCloud hat US- und EU-Server. Nach der Konfiguration in `~/.config/rclone/rclone.conf` den EU-Hostname eintragen:

```ini
[pcloud]
type = pcloud
token = {...}
hostname = eapi.pcloud.com
```

Danach testen:
```bash
rclone ls pcloud:
```

---

## Google Takeout Import

ZIP-Dateien nach `/mnt/storagebox/takeout/` hochladen, dann:

```bash
# immich-go installieren
cd /opt/immich
wget https://github.com/simulot/immich-go/releases/latest/download/immich-go_Linux_x86_64.tar.gz
tar -xzf immich-go_Linux_x86_64.tar.gz
mv immich-go /usr/local/bin/ && chmod +x /usr/local/bin/immich-go
rm immich-go_Linux_x86_64.tar.gz LICENSE README.md
```

API-Key in der Immich Web-Oberfläche erstellen, dann:

```bash
# --concurrent-tasks 2: weniger parallele Uploads → Immich hat Zeit zum Verarbeiten
# --pause-immich-jobs: pausiert ML/Thumbnail-Jobs automatisch während des Uploads
# --no-ui: kein interaktives Terminal nötig (läuft im Hintergrund)
nohup immich-go upload from-google-photos \
  --server=https://immich.tsued.de \
  --api-key=<DEIN_IMMICH_API_KEY> \
  --concurrent-tasks 2 \
  --pause-immich-jobs \
  --no-ui \
  --log-file=/opt/immich/import.log \
  /mnt/storagebox/takeout/*.zip &

# Fortschritt beobachten
tail -f /opt/immich/import.log

# RAM-Auslastung während Import im Auge behalten
watch -n 5 'free -h && docker stats --no-stream --format "{{.Name}}: {{.MemUsage}}"'
```

---

## Cron-Jobs einrichten

```bash
crontab -e
```

```cron
# DB-Backups per Immich nativ planen:
# Administration -> Settings -> Backup (z.B. alle 6h, passende Retention)

# Log-Check alle 10 Minuten (ntfy-Alert bei Fehlern)
*/10 * * * * /bin/bash /opt/immich/check_logs.sh

# pCloud-Sync alle 6 Stunden
20 */6 * * * /bin/bash /opt/immich/sync_pcloud.sh

# Statusbericht nur sonntags um 03:00 Uhr
0 3 * * 0 /bin/bash /opt/immich/sys_report.sh

# OS-Updates sonntags um 04:00 Uhr (ntfy-Alert bei Reboot-Bedarf oder Fehler)
0 4 * * 0 /bin/bash /opt/immich/update_os.sh >> /var/log/immich/update_os.log 2>&1
```

---

## Backup-Logik mit rclone (sync + backup-dir)

`sync_pcloud.sh` sichert **einmalig das gesamte Immich-Backup-Verzeichnis** (`UPLOAD_LOCATION`):

- **Current:** `rclone sync` nach `pcloud:ImmichBackup/current`
- **History:** geänderte/gelöschte Dateien werden via `--backup-dir` in
  `pcloud:ImmichBackup/history/<timestamp>` verschoben

Damit sind **Assets und native Immich-DB-Dumps (`backups/`)** in einem Lauf enthalten.

Retention in `history/`:
- tägliche Stände: 30 Tage
- Monatsstände (Tag `01`): 12 Monate

Konfiguration in `config.sh`:

```bash
BACKUP_DIR="/mnt/storagebox/immich_library/backups"
PCLOUD_BACKUP_SOURCE="/mnt/storagebox/immich_library"
PCLOUD_BACKUP_CURRENT_REMOTE="pcloud:ImmichBackup/current"
PCLOUD_BACKUP_HISTORY_REMOTE="pcloud:ImmichBackup/history"
RETENTION_DAILY_DAYS="30"
RETENTION_MONTHLY_MONTHS="12"
```

---

## Restore-Kurzablauf

1. **Medien wiederherstellen**
  - letzter Stand: aus `current`
  - älterer Stand: benötigte Dateien aus `history/<timestamp>`
2. **DB-Dump wiederherstellen**
  - bevorzugt über Immich-UI: `Administration -> Maintenance -> Restore database backup`
  - alternativ per CLI gemäß offizieller Immich-Doku
3. **Validieren**
  - Admin-Login, zufällige Assets, Alben, Personen, Freigaben prüfen

Empfehlung: monatlicher Restore-Drill auf Testinstanz.

---

## Log-Rotation einrichten

Damit die Log-Dateien unter `/var/log/immich/` nicht unbegrenzt wachsen:

```bash
cat > /etc/logrotate.d/immich << 'EOF'
/var/log/immich/*.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
```

Wenn nur harmlose Client-Abbrueche oder aehnliche Bagatellen erkannt werden, wird **keine** `ntfy`-Benachrichtigung verschickt.

---

## Troubleshooting: 502 nach Reboot

Symptom in Immich-Logs:
- `Failed to read (/usr/src/app/upload/encoded-video/.immich)`
- Web-UI zeigt `502`

Typische Ursache:
- Storage Box war beim Boot noch nicht gemountet.
- Docker startet dann mit leerem lokalem Host-Pfad unter `/mnt/storagebox/immich_library`.

Sonderfall bei `mount error(79)`:
- In `dmesg` steht `CIFS mount error: iocharset utf8 not found`.
- Dann die Option `iocharset=utf8` aus dem fstab-Eintrag entfernen und erneut mounten.

Sofort-Fix auf dem Server:

```bash
sudo mount -a
mountpoint -q /mnt/storagebox || { echo "Storage Box nicht gemountet"; exit 1; }

sudo mkdir -p /mnt/storagebox/immich_library/{upload,backups,library,profile,encoded-video}
for d in upload backups library profile encoded-video; do
  sudo touch "/mnt/storagebox/immich_library/${d}/.immich"
done
sudo touch /opt/immich/data/thumbs/.immich

cd /opt/immich
sudo docker compose up -d
```

Hinweis:
- `setup.sh` schreibt den fstab-Eintrag mit `x-systemd.automount`, damit der Mount bei Zugriff automatisch und robuster erfolgt.

---

## Immich aktualisieren

```bash
/opt/immich/update.sh
```

Das Skript zieht neue Images und startet Container neu – ohne komplettes `docker compose down`,
also mit minimaler Unterbrechung. Vor und nach dem Update kommt eine ntfy-Benachrichtigung.

---

## Backup-Strategie (3-2-1)

| Kopie | Ort | Skript |
|---|---|---|
| Live | `/mnt/storagebox/immich_library/` | – (Primär) |
| DB-Backup (nativ) | `/mnt/storagebox/immich_library/backups/` | Immich Backup Scheduler |
| Off-Site (current + history) | `pcloud:ImmichBackup/current` + `pcloud:ImmichBackup/history/` | `sync_pcloud.sh` (alle 6h) |

> Die Foto-Library selbst liegt bereits auf der Storage Box (externe Kopie).  
> Für vollständige Datensicherheit empfiehlt sich zusätzlich ein Snapshot  
> der Storage Box in der Hetzner-Konsole.
