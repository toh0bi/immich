# Immich VPS Setup

Dieses Repo enthält die Skripte für ein produktionsnahes Immich-Setup auf einem Hetzner VPS.
Es deckt Setup, Backups, pCloud-Sync, Log-Checks und Statusmeldungen ab.

## Schnellstart

1. `config.example.sh` nach `config.sh` kopieren und anpassen.
2. `immich/config.example.sh` nach `immich/config.sh` kopieren und anpassen.
3. `silverbullet/config.example.sh` nach `silverbullet/config.sh` kopieren und anpassen.
4. Alle Dateien auf den Server kopieren (siehe unten).
5. `setup.sh` auf dem Server ausführen.

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

**Server-Layout nach dem Deployment:**
```
/opt/
├── config.sh                  ← gemeinsame Server-Config (ADMIN_USER, NTFY, Storage Box)
├── setup.sh                   ← einmaliges Basis-Setup (frischer VPS)
├── immich/                    ← Immich-Skripte + App-Daten
│   ├── config.sh              ← Immich-eigene Config (IMMICH_DOMAIN, Backup-/pCloud-Pfade)
│   ├── docker-compose.yml, .env, postgres/, data/thumbs/
│   ├── backup_db.sh, check_logs.sh, sync_pcloud.sh
│   ├── sys_report.sh, update.sh, update_os.sh
├── silverbullet/              ← SilverBullet-Skripte + Space-Daten
│   ├── config.sh              ← SB-eigene Config (SB_DOMAIN, SB_USER, SB_AUTH_TOKEN)
│   ├── docker-compose.yml, .env, space/
│   ├── setup.sh, update.sh, backup.sh
└── proxy/
    ├── docker-compose.yml     ← Caddy, verbunden mit beiden App-Netzwerken
    ├── Caddyfile              ← generiert durch proxy/setup.sh
    └── setup.sh
```

**Repo-Dateien:**

| Pfad | Beschreibung |
|---|---|
| `setup.sh` | **Einmalig** auf frischem VPS ausführen |
| `migrate_server.sh` | **Einmalig** auf bestehendem Server – Migration zur neuen Struktur |
| `config.example.sh` | Vorlage für die gemeinsame Server-Konfiguration |
| `immich/config.example.sh` | Vorlage für die Immich-eigene Konfiguration |
| `immich/docker-compose.yml` | Immich-Container (Server, ML, Redis, Postgres) |
| `immich/backup_db.sh` | Optionaler manueller PostgreSQL-Dump (Fallback) |
| `immich/sync_pcloud.sh` | rclone Sync des Immich-Backup-Verzeichnisses nach pCloud |
| `immich/check_logs.sh` | Fehler-Scan mit Regex-Klassifizierung und ntfy-Alert |
| `immich/sys_report.sh` | Wöchentlicher Statusbericht via ntfy |
| `immich/update.sh` | Immich-Update ohne Downtime |
| `immich/update_os.sh` | `apt upgrade` mit ntfy-Alert bei Reboot-Bedarf |
| `silverbullet/config.example.sh` | Vorlage für die SilverBullet-Konfiguration |
| `silverbullet/docker-compose.yml` | SilverBullet-Container (1 Container, kein DB) |
| `silverbullet/setup.sh` | SilverBullet einrichten und Proxy aktualisieren |
| `silverbullet/update.sh` | SilverBullet-Container aktualisieren |
| `silverbullet/backup.sh` | Space auf Storage Box sichern |
| `proxy/docker-compose.yml` | Gemeinsamer Reverse Proxy (Caddy) |
| `proxy/setup.sh` | Proxy deployen / Caddyfile ohne Downtime neu laden |

---

## Ersteinrichtung

### 1. Voraussetzungen

- Hetzner VPS (**Ubuntu 24.04 LTS** empfohlen – 26.04 ist zu frisch, 22.04 läuft aus)
- Domain oder Subdomain, die auf die Server-IP zeigt
- Hetzner Storage Box
- pCloud-Account

### 2. Konfiguration vorbereiten

```bash
# Gemeinsame Server-Config
cp config.example.sh config.sh
nano config.sh   # ADMIN_USER, Storage Box eintragen

# Immich-eigene Config
cp immich/config.example.sh immich/config.sh
nano immich/config.sh   # IMMICH_DOMAIN eintragen

# SilverBullet-eigene Config
cp silverbullet/config.example.sh silverbullet/config.sh
nano silverbullet/config.sh   # SB_DOMAIN, SB_USER, optional SB_AUTH_TOKEN eintragen
```

### 3. Setup ausführen

```bash
# Frischer Server: als root direkt nach /opt/ kopieren
scp -r immich/ silverbullet/ proxy/ setup.sh config.example.sh config.sh \
    root@<SERVER_IP>:/opt/

# Setup starten (fragt Storage Box Passwort interaktiv ab)
chmod +x /opt/setup.sh /opt/immich/*.sh /opt/silverbullet/*.sh /opt/proxy/*.sh
/opt/setup.sh
```

Bei einer Migration auf einem bereits eingerichteten Server mit normalem Admin-User
funktioniert `scp ...:/opt/` meist nicht, weil nur `/opt/immich/` diesem User gehört,
nicht aber `/opt/` selbst. Dann stattdessen:

```bash
ssh <ADMIN_USER>@<SERVER_IP> 'mkdir -p ~/deploy'
scp -r immich/ silverbullet/ proxy/ setup.sh config.example.sh migrate_server.sh \
  <ADMIN_USER>@<SERVER_IP>:~/deploy/
ssh <ADMIN_USER>@<SERVER_IP>
# WICHTIG: Die bestehende /opt/immich/config.sh muss für die Migration erhalten bleiben.
rm -f ~/deploy/immich/config.sh ~/deploy/silverbullet/config.sh
sudo cp -r ~/deploy/* /opt/
sudo bash /opt/migrate_server.sh
```

Das Skript:
- Installiert Docker, UFW, rclone, curl, jq
- Konfiguriert die Firewall
- Mountet die Storage Box via CIFS
- Legt Split-Storage an: `upload/library/backups/...` auf Storage Box, `thumbs` auf SSD (`/opt/immich/data/thumbs`)
- Erstellt `.env` unter `/opt/immich/` (`docker-compose.yml` ist bereits Teil des Repos)
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
chmod +x /opt/immich/*.sh /opt/silverbullet/*.sh /opt/proxy/*.sh
```

---

## SilverBullet einrichten

SilverBullet ist eine selbst gehostete Markdown-Wissensdatenbank (1 Container, kein DB).

```bash
# SilverBullet-Config auf dem Server anpassen (falls nicht beim scp mitgegeben)
nano /opt/silverbullet/config.sh

# SilverBullet einrichten (startet Container + aktualisiert Proxy automatisch)
sudo bash /opt/silverbullet/setup.sh
```

Nach dem Setup erreichbar unter `https://<SB_DOMAIN>` (Login via SB_USER aus config.sh).

**Space-Backup:** täglich per Cron nach `/mnt/storagebox/silverbullet_space/` (rsync).

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

# --- Immich ---
# Log-Check alle 10 Minuten (ntfy-Alert bei Fehlern)
*/10 * * * * /bin/bash /opt/immich/check_logs.sh

# pCloud-Sync alle 6 Stunden
20 */6 * * * /bin/bash /opt/immich/sync_pcloud.sh

# Statusbericht sonntags um 03:00 Uhr
0 3 * * 0 /bin/bash /opt/immich/sys_report.sh

# OS-Updates sonntags um 04:00 Uhr (ntfy-Alert bei Reboot-Bedarf oder Fehler)
0 4 * * 0 /bin/bash /opt/immich/update_os.sh >> /var/log/immich/update_os.log 2>&1

# --- SilverBullet ---
# Space täglich um 04:30 Uhr auf Storage Box sichern
30 4 * * * /bin/bash /opt/silverbullet/backup.sh >> /var/log/silverbullet/backup.log 2>&1

# SilverBullet-Update sonntags um 02:00 Uhr
0 2 * * 0 /bin/bash /opt/silverbullet/update.sh >> /var/log/silverbullet/update.log 2>&1
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
