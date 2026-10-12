#!/bin/bash
# =============================================================
# SilverBullet – eigene Konfiguration (getrennt von Immich!)
# Diese Datei nach silverbullet/config.sh kopieren und anpassen.
# config.sh wird NICHT ins Repo eingecheckt.
# =============================================================

# Domain, unter der SilverBullet erreichbar sein soll
# Bei Tailscale z. B. <server>.<tailnet>.ts.net:8443
SB_DOMAIN="mein-server.dein-tailnet.ts.net:8443"

# Login-Credentials im Format user:passwort (Single-Space-Modus)
SB_USER="<user>:<passwort>"

# Optionaler API-Token fuer Bearer-Auth am SilverBullet HTTP-API-Endpunkt
# (z. B. fuer Webhooks wie Pebble Brain Dump)
SB_AUTH_TOKEN="<lange-zufaellige-zeichenkette>"

# Pfad zum Space-Verzeichnis (Markdown-Dateien) auf dem Host
SB_SPACE_DIR="/opt/silverbullet/space"
