# Crash Report 2026-07-03 (Immich Restart-Loop nach Update auf v3)

## Kurzfassung
Nach dem Update auf Immich `v3.0.1` lief `immich_server` dauerhaft in `Restarting`.
Die Ursache war ein Datenbank-Image/Extension-Mismatch: Die DB lief noch auf dem alten
`pgvecto-rs`-Image (`vectors`), Immich v3 erwartet aber eine verfügbare und installierte
`vector`- oder `vchord`-Extension.

Durch Umstellung auf das offizielle Immich-Postgres-Image mit VectorChord-Migrationspfad,
Anlegen der `vector`-Extension und Neustart der Services wurde der Loop beendet.

## Symptome
- `docker compose ps`: `immich_server` in `Restarting (1)`
- Immich-Logs zeigten wiederholt:
  - `Error: No vector extension found. Available extensions: vchord, vector`
  - `microservices worker exited with code 1`

## Technische Ursachenfolge
1. Immich wurde auf v3 aktualisiert (`immich-server` startete als `v3.0.1`).
2. Die Datenbank lief weiterhin auf `docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0`.
3. In der DB war nur `vectors` installiert, aber nicht `vector`.
4. `CREATE EXTENSION vector;` schlug auf dem alten Image fehl, weil `vector.control`
   nicht vorhanden war.
5. Dadurch konnte Immich beim Start keine gültige Vector-Extension aktiv nutzen und
   der Microservice-Worker crashte zyklisch.

## Durchgeführte Maßnahmen
1. Compose-DB-Image umgestellt auf:
   - `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`
2. DB neu gestartet und Health geprüft.
3. Extension in der Immich-DB angelegt:
   - `CREATE EXTENSION IF NOT EXISTS vector;`
4. Immich-Services neu gestartet (`immich-server`, `immich-machine-learning`, `caddy`).
5. Status und Logs verifiziert.

## Ergebnis
- Containerstatus:
  - `immich_server` -> `Up (healthy)`
  - `database` -> `Up (healthy)`
- Immich-Logs zeigen erfolgreichen Start statt Restart-Loop:
  - `Nest application successfully started`
  - `Immich Server is listening ... [v3.0.1]`
- DB-Extensions vorhanden:
  - `vchord`, `vector`, `vectors`

## Bezug zu v3.0.0 Release-Hinweisen
Die Anpassung folgt dem Breaking-Change aus v3:
- pgvecto.rs wird nicht mehr als Zielplattform verwendet,
- Migration auf VectorChord/kompatible Vector-Extensions ist erforderlich.

## Ist das in setup.sh berücksichtigt?
Ja, jetzt schon.

Folgende Anpassungen wurden im Repo an `setup.sh` vorgenommen:
1. Das erzeugte `docker-compose.yml` nutzt jetzt das v3-kompatible Postgres-Image:
   - `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`
2. In der generierten `.env` wird `IMMICH_VERSION` auf `v3` gesetzt.

Damit ist das Basis-Setup auf den aktuellen v3-Migrationspfad ausgerichtet und die
heute aufgetretene Ursache bei Neu-Setups nicht mehr zu erwarten.

## Empfohlene Nacharbeiten
1. `setup.sh` bei Bedarf auf den Server kopieren, damit Neuaufsetzungen denselben Stand haben.
2. Nach künftigen Major-Upgrades immer die Immich-Release-Notes auf Breaking Changes prüfen.
3. Optional ein frisches DB-Backup nach erfolgreicher v3-Migration erstellen.