#!/bin/bash
set -eo pipefail

# Konfiguration zentral in config.sh pflegen!
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# Immich-spezifische Werte (IMMICH_DOMAIN, ...)
# shellcheck source=immich/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/immich/config.sh"

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
# Immich-Upload-Root liegt auf der Storage Box, inkl. native DB-Dumps in backups/.
# Nur thumbs liegen auf SSD.
mkdir -p /mnt/storagebox/immich_library
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
# v3-Major-Tag erzwingen, damit kein versehentlicher Downgrade/Alt-Tag genutzt wird.
sed -i 's|^IMMICH_VERSION=.*|IMMICH_VERSION=v3|' .env

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
# docker-compose.yml ist bereits Teil des Repos (immich/docker-compose.yml) und
# liegt dank "scp -r immich/ ... /opt/" schon an dieser Stelle (/opt/immich/docker-compose.yml).
# Single Source of Truth: hier wird nichts mehr generiert, nur geprüft.
if [[ ! -f docker-compose.yml ]]; then
    echo "FEHLER: /opt/immich/docker-compose.yml nicht gefunden." >&2
    echo "Bitte zuerst den immich/-Ordner aus dem Repo nach /opt/ kopieren (siehe README.md)." >&2
    exit 1
fi

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

echo "### 8. Reverse Proxy (Caddy) aufsetzen ###"
bash "$(dirname "${BASH_SOURCE[0]}")/proxy/setup.sh"

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