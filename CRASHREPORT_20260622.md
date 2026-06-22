# Crash Report 2026-06-22 (Immich 502 nach Reboot)

## Kurzfassung
Nach einem VPS-Reboot trat bei Immich ein 502 auf. Ursache war eine fehlerhafte Storage-Box-Einbindung (CIFS-Mount), wodurch Immich die Sentinel-Datei unter `encoded-video/.immich` nicht lesen konnte. Nach Korrektur der Mount-Optionen, erfolgreichem Remount und erneuter Initialisierung der Sentinel-Dateien startete Immich wieder stabil.

## Symptome
- Web-UI zeigte `502`.
- ntfy-Alarm aus `check_logs.sh` mit Severity `high`.
- Immich-Logs meldeten wiederholt:
  - `Failed to read (/usr/src/app/upload/encoded-video/.immich)`
  - `microservices worker error ... system-integrity#folder-checks`

## Technische Ursachenfolge
1. Nach Reboot war die Storage Box nicht sauber gemountet.
2. Zusätzlich schlug `mount -a` zeitweise fehl:
   - zuerst mit `mount error(79)` und
   - in `dmesg`: `CIFS mount error: iocharset utf8 not found`.
3. Nach Entfernen von `iocharset=utf8` trat `Permission denied` auf, bis SMB-Optionen/Credentials konsistent gesetzt wurden.
4. Ohne korrektes Mount sah Immich unter `UPLOAD_LOCATION` kein gültiges `encoded-video/.immich` und beendete den Worker zyklisch.

## Durchgeführte Maßnahmen
1. `/etc/fstab` auf robusten CIFS-Eintrag umgestellt:
   - `vers=3.0`
   - `sec=ntlmssp`
   - `x-systemd.automount`
   - `x-systemd.requires=network-online.target`
   - `x-systemd.after=network-online.target`
   - kein `iocharset=utf8`
2. Credentials-Datei `/etc/storagebox_creds` neu gesetzt und Rechte auf `600` fixiert.
3. Mount erfolgreich verifiziert (`mountpoint -q /mnt/storagebox`).
4. Immich-Sentinel-Dateien erneut angelegt:
   - `/mnt/storagebox/immich_library/{upload,backups,library,profile,encoded-video}/.immich`
   - `/opt/immich/data/thumbs/.immich`
5. `docker compose up -d` ausgeführt und Logs geprüft.

## Ergebnis
- Containerstatus: `immich_server` wieder `Up (healthy)`.
- Log-Übergang sichtbar: erst alte Fehler-Resets, danach:
  - `Successfully verified system mount folder checks`
  - `Immich Microservices is running`
  - `Immich Server is listening`
- 502 ist behoben.

## Dauerhafte Absicherung im Repo
Folgende Änderungen wurden in diesem Repo umgesetzt:
- `setup.sh`:
  - installiert `keyutils` explizit,
  - schreibt Credentials robust per `printf`,
  - verwendet CIFS-Optionen ohne `iocharset=utf8`, mit `vers=3.0,sec=ntlmssp`,
  - enthält systemd-Automount-Optionen gegen Boot-Race.
- `README.md`:
  - Troubleshooting-Abschnitt für `502`/`.immich` ergänzt,
  - Sonderfall `iocharset utf8 not found` dokumentiert.

## Offene Nacharbeiten (empfohlen)
1. Einmalig die aktuelle `setup.sh` auf den VPS kopieren (damit bei künftiger Neuinitialisierung derselbe Stand gilt).
2. Optional: alten lokalen Fallback-Ordner prüfen/aufräumen, falls vorhanden
   - z. B. `/mnt/storagebox/immich_library.local.*`.
3. Optional Funktionscheck nach dem nächsten geplanten Reboot:
   - `sudo mount -a`
   - `mountpoint -q /mnt/storagebox`
   - `sudo docker compose ps`

## Fazit
Der Vorfall ist technisch verstanden und behoben. Mit den neuen Mount-Optionen und den Repo-Änderungen ist das Setup deutlich robuster gegen Reboot-Rennen und CIFS-Optionseffekte.