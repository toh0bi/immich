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

---

## Dateiübersicht

| Datei | Beschreibung |
|---|---|
| `setup.sh` | **Einmalig** ausführen – richtet den Server komplett ein |
| `config.example.sh` | **Vorlage** für die lokale Konfiguration |
| `config.sh` | **Lokale Konfiguration** – wird nicht ins Repo eingecheckt |
| `backup_db.sh` | PostgreSQL-Dump → Storage Box (täglich per Cron) |
| `sync_pcloud.sh` | rclone Sync Storage Box → pCloud (wöchentlich per Cron) |
| `check_logs.sh` | Fehler-Scan mit Regex-Klassifizierung und ntfy-Alert nur bei Handlungsbedarf |
| `sys_report.sh` | Statusbericht via ntfy (sonntags um 03:00 Uhr) |
| `update.sh` | Immich-Update ohne Downtime-Unterbrechung |

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
# DB-Backup täglich um 01:00 Uhr
0 1 * * * /bin/bash /opt/immich/backup_db.sh >> /var/log/immich/backup.log 2>&1

# Log-Check alle 10 Minuten (ntfy-Alert bei Fehlern)
*/10 * * * * /bin/bash /opt/immich/check_logs.sh

# pCloud-Sync täglich um 01:30 Uhr
30 1 * * * /bin/bash /opt/immich/sync_pcloud.sh

# Statusbericht nur sonntags um 03:00 Uhr
0 3 * * 0 /bin/bash /opt/immich/sys_report.sh
```

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
| DB-Backup | `/mnt/storagebox/immich_db_backups/` | `backup_db.sh` (täglich) |
| Off-Site | `pcloud:ImmichBackup/` | `sync_pcloud.sh` (wöchentlich) |

> Die Foto-Library selbst liegt bereits auf der Storage Box (externe Kopie).  
> Für vollständige Datensicherheit empfiehlt sich zusätzlich ein Snapshot  
> der Storage Box in der Hetzner-Konsole.
