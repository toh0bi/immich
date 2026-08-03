#!/bin/bash
# =============================================================
# Immich – eigene Konfiguration (getrennt von der gemeinsamen
# Server-Config in ../config.sh).
# Diese Datei nach immich/config.sh kopieren und anpassen.
# config.sh wird NICHT ins Repo eingecheckt.
# =============================================================

# Domain, unter der Immich erreichbar sein soll
IMMICH_DOMAIN="<IMMICH_DOMAIN>"

# --- Pfade ---------------------------------------------------
IMMICH_DIR="/opt/immich"
# Native Immich-Dumps liegen in ${UPLOAD_LOCATION}/backups.
# Quelle fuer Off-Site ist das gesamte Immich-Verzeichnis auf der Storage Box.
# STORAGEBOX_MOUNT kommt aus der gemeinsamen ../config.sh.
BACKUP_DIR="${STORAGEBOX_MOUNT}/immich_library/backups"
PCLOUD_BACKUP_SOURCE="${STORAGEBOX_MOUNT}/immich_library"
PCLOUD_BACKUP_CURRENT_REMOTE="pcloud:ImmichBackup/current"
PCLOUD_BACKUP_HISTORY_REMOTE="pcloud:ImmichBackup/history"
RETENTION_DAILY_DAYS="30"            # tägliche Medien-Stände in history/
RETENTION_MONTHLY_MONTHS="12"        # Monatsstände (Tag 01) zusätzlich behalten
LOG_DIR="/var/log/immich"
PCLOUD_LOG="${LOG_DIR}/pcloud_sync.log"
MONTHLY_REPORT_LOG="${LOG_DIR}/monthly_reports.log"
