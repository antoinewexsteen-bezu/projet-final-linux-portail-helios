#!/usr/bin/bash
set -Eeuo pipefail
readonly TAG=helios-suivi-publish
readonly SOURCE=/var/lib/helios/telemetry.csv
readonly WWW=/srv/helios/suivi/www
tmp=''
log() { /usr/bin/logger -t "$TAG" -- "$*"; }
cleanup() { [[ -z "$tmp" ]] || /usr/bin/rm -f -- "$tmp"; }
trap cleanup EXIT
trap 'log "interruption par signal"; exit 1' HUP INT TERM
trap 'log "erreur interne ligne $LINENO"; exit 1' ERR
if [[ ! -r "$SOURCE" || ! -d "$WWW" || ! -w "$WWW" || ! -x "$WWW" ]]; then
    log 'prerequis manquant : telemetrie illisible ou www non inscriptible'; exit 3
fi
# Le verrou porte sur le repertoire : aucun fichier de verrou exposé par HTTP.
exec 9<"$WWW"
if ! /usr/bin/flock -n 9; then log 'publication deja en cours'; exit 2; fi
tmp=$(/usr/bin/mktemp "$WWW/.etat.XXXXXXXX")
/usr/bin/python3 - "$SOURCE" "$tmp" <<'PY'
import csv, datetime, json, math, socket, sys
with open(sys.argv[1], newline='') as stream:
    rows = list(csv.reader(stream))
if not rows or any(len(row) != 3 for row in rows):
    raise ValueError('telemetrie vide ou ligne invalide')
stamp, load, memory = rows[-1]
datetime.datetime.fromisoformat(stamp)
load, memory = float(load), int(memory)
if not math.isfinite(load) or load < 0 or memory < 0:
    raise ValueError('mesure invalide')
with open(sys.argv[2], 'w') as stream:
    json.dump(dict(genere=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   hote=socket.gethostname(), derniere_mesure=stamp,
                   charge_1min=load, mem_dispo_ko=memory, mesures=len(rows)), stream,
              ensure_ascii=False, allow_nan=False)
    stream.write('\n')
PY
# mktemp cree en 0600 ; rendre la publication lisible au groupe avant renommage.
/usr/bin/chmod 0660 "$tmp"
/usr/bin/mv -fT -- "$tmp" "$WWW/etat.json"
tmp=''
log 'etat.json publie atomiquement'
exit 0
