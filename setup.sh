#!/bin/bash
set -eo pipefail

# Konfiguration zentral in config.sh pflegen!
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Passwort interaktiv abfragen (nicht im Skript speichern!)
read -rsp "Storage Box Passwort: " STORAGE_BOX_PASS
echo

if [[ -z "${STORAGE_BOX_PASS}" ]]; then
  echo "FEHLER: Storage Box Passwort darf nicht leer sein." >&2
  exit 1
fi

echo "### 1. System aktualisieren und Tools installieren ###"
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y curl cifs-utils keyutils wget ufw jq fail2ban \
    linux-modules-extra-"$(uname -r)"

# rclone direkt von rclone.org – apt-Version ist zu alt für pCloud OAuth
curl https://rclone.org/install.sh | bash

echo "### 2. Server-Hardening ###"

# Neuen Admin-User anlegen und SSH-Key von root übernehmen
if ! id "${ADMIN_USER}" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "${ADMIN_USER}"
    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${ADMIN_USER}"
    chmod 440 "/etc/sudoers.d/${ADMIN_USER}"
fi

# SSH authorized_keys von root kopieren
mkdir -p "/home/${ADMIN_USER}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "/home/${ADMIN_USER}/.ssh/authorized_keys"
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
chmod 700 "/home/${ADMIN_USER}/.ssh"
chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"

# SSH absichern: kein Root-Login, kein Passwort
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHEOF'
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
AllowUsers ADMIN_PLACEHOLDER
SSHEOF
sed -i "s/ADMIN_PLACEHOLDER/${ADMIN_USER}/" /etc/ssh/sshd_config.d/99-hardening.conf
systemctl reload ssh

echo "  -> SSH-Hardening abgeschlossen. Ab jetzt nur noch: ssh ${ADMIN_USER}@<IP>"

# fail2ban: SSH-Brute-Force-Schutz
cat > /etc/fail2ban/jail.d/sshd.local << 'F2BEOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 5
bantime  = 1h
findtime = 10m
F2BEOF
systemctl enable --now fail2ban

echo "### 3. Firewall (UFW) einrichten ###"
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

echo "### 4. Docker installieren ###"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

echo "### 5. Hetzner Storage Box mounten ###"
mkdir -p /mnt/storagebox

# CIFS-Kernelmodul explizit laden (Ubuntu 24.04 lädt es nicht automatisch)
modprobe cifs

# Zugangsdaten sicher speichern
{
  printf 'username=%s\n' "${STORAGE_BOX_USER}"
  printf 'password=%s\n' "${STORAGE_BOX_PASS}"
} > /etc/storagebox_creds
chmod 600 /etc/storagebox_creds

# fstab Eintrag erstellen falls nicht vorhanden
if ! grep -q "/mnt/storagebox" /etc/fstab; then
  # x-systemd.automount vermeidet Boot-Race: Zugriff auf den Pfad triggert Mount bei Bedarf.
  echo "//${STORAGE_BOX_HOST}/backup /mnt/storagebox cifs credentials=/etc/storagebox_creds,uid=0,gid=0,file_mode=0777,dir_mode=0777,nofail,_netdev,x-systemd.automount,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,vers=3.0,sec=ntlmssp 0 0" >> /etc/fstab
fi

# Nur mounten, wenn nicht bereits gemountet
if ! mountpoint -q /mnt/storagebox; then
    mount -a
fi

# Ordnerstruktur auf Storage Box anlegen
# Immich-Upload-Root liegt auf der Storage Box, nur thumbs liegen auf SSD.
mkdir -p /mnt/storagebox/immich_library
mkdir -p /mnt/storagebox/immich_db_backups
mkdir -p /mnt/storagebox/takeout

# Lokaler SSD-Pfad fuer Thumbnails
mkdir -p /opt/immich/data/thumbs

# Immich prüft beim Start ob .immich-Sentinel-Dateien lesbar sind – vorab anlegen
for dir in upload backups library profile encoded-video; do
    mkdir -p /mnt/storagebox/immich_library/${dir}
    touch /mnt/storagebox/immich_library/${dir}/.immich
done

# Thumbs bewusst auf SSD halten
touch /opt/immich/data/thumbs/.immich

echo "### 6. Immich Verzeichnis & Konfiguration aufsetzen ###"
mkdir -p /opt/immich
cd /opt/immich

# .env Datei erstellen
curl -L https://github.com/immich-app/immich/releases/latest/download/example.env -o .env
# Upload-Root auf Storage Box, Thumbs werden separat auf SSD eingebunden.
sed -i 's|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/mnt/storagebox/immich_library|' .env
sed -i 's|DB_DATA_LOCATION=.*|DB_DATA_LOCATION=./postgres|' .env

JWT_SECRET=$(openssl rand -base64 32)
sed -i "s|JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" .env

# IMMICH_DOMAIN in .env eintragen (wird von docker-compose und caddy genutzt)
if grep -q "^IMMICH_DOMAIN=" .env; then
    sed -i "s|IMMICH_DOMAIN=.*|IMMICH_DOMAIN=${IMMICH_DOMAIN}|" .env
else
    echo "" >> .env
    echo "# Reverse Proxy" >> .env
    echo "IMMICH_DOMAIN=${IMMICH_DOMAIN}" >> .env
fi
# Eine saubere, kombinierte docker-compose.yml schreiben (Immich + Caddy)
cat << 'EOF' > docker-compose.yml
# info: https://immich.app/docs/deployment/docker-compose

name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:release
    depends_on:
      redis:
        condition: service_healthy
      database:
        condition: service_healthy
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      - /opt/immich/data/thumbs:/usr/src/app/upload/thumbs
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    restart: always

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:release
    volumes:
      - model-cache:/cache
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    restart: always

  redis:
    container_name: immich_redis
    image: docker.io/redis:6.2-alpine
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    healthcheck:
      test: pg_isready --dbname='${DB_DATABASE_NAME}' --username='${DB_USERNAME}' || exit 1
    restart: always

  caddy:
    image: caddy:2-alpine
    container_name: immich_proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - immich-server

volumes:
  model-cache:
  caddy_data:
  caddy_config:
EOF

# Caddyfile erzeugen (Domain ist hier direkt eingetragen)
cat > Caddyfile << EOF
${IMMICH_DOMAIN} {
    reverse_proxy immich-server:2283
}
EOF

echo "### 7. Immich-Infrastruktur starten ###"
# Log-Verzeichnis für Wartungsskripte anlegen
mkdir -p /var/log/immich

# /opt/immich dem Admin-User übergeben (scp/sftp ohne sudo)
# Postgres-Datenverzeichnis explizit ausnehmen – muss UID 999 (postgres im Container) gehören
chown -R "${ADMIN_USER}:${ADMIN_USER}" /opt/immich
chown -R "${ADMIN_USER}:${ADMIN_USER}" /opt/immich/data
# Postgres-Verzeichnis existiert erst nach erstem Container-Start, daher mit -f prüfen
if [[ -d /opt/immich/postgres ]]; then
    chown -R 999:999 /opt/immich/postgres
fi

docker compose up -d

echo "=========================================================="
echo " Setup erfolgreich!"
echo " Sobald deine Domain auf diese IP zeigt, erreichbar unter:"
echo " https://${IMMICH_DOMAIN}"
echo ""
echo " WICHTIG: Root-SSH ist deaktiviert. Zukünftig einloggen mit:"
echo "  ssh ${ADMIN_USER}@<IP>"
echo ""
echo " Nächste Schritte:"
echo "  1. config.example.sh nach config.sh kopieren und anpassen (ntfy!)"
echo "  2. rclone konfigurieren (siehe README.md)"
echo "  3. Cron-Jobs einrichten (siehe README.md)"
echo "=========================================================="