#!/usr/bin/bash
set -Eeuo pipefail
readonly TAG=helios-suivi-backup
readonly DEST=/srv/helios/archives/suivi
tmp=''; sumtmp=''
log() { /usr/bin/logger -t "$TAG" -- "$*"; }
cleanup() { [[ -z "$tmp" ]] || /usr/bin/rm -f -- "$tmp"; [[ -z "$sumtmp" ]] || /usr/bin/rm -f -- "$sumtmp"; }
trap cleanup EXIT
trap 'log "interruption par signal"; exit 1' HUP INT TERM
trap 'log "erreur interne ligne $LINENO"; exit 1' ERR
[[ $EUID -eq 0 && -d "$DEST" && -w "$DEST" ]] || { log 'prerequis manquant'; exit 3; }
exec 9<"$DEST"
/usr/bin/flock -n 9 || { log 'sauvegarde deja en cours'; exit 2; }
umask 077
name="suivi-$(/usr/bin/date +%Y%m%d-%H%M%S).tar.gz"
[[ ! -e "$DEST/$name" ]] || { log 'collision de nom : reessayer dans une seconde'; exit 1; }
paths=(srv/helios/suivi etc/sudoers.d/92-helios-suivi etc/zabbix/zabbix_agent2.d/helios-suivi.conf
    usr/local/sbin/helios-suivi-publish.sh usr/local/sbin/helios-suivi-backup.sh
    etc/systemd/system/helios-suivi.service etc/systemd/system/helios-suivi-publish.service
    etc/systemd/system/helios-suivi-publish.timer etc/systemd/system/helios-suivi-backup.service
    etc/systemd/system/helios-suivi-backup.timer)
for path in "${paths[@]}"; do [[ -e "/$path" ]] || { log "prerequis absent : /$path"; exit 3; }; done
[[ ! -f /usr/local/sbin/helios-suivi-audit.sh ]] || paths+=(usr/local/sbin/helios-suivi-audit.sh)
# Conserver le correctif d'integration TP3 et les empreintes de non-regression.
paths+=(usr/local/sbin/helios-watch-auth.sh root/projet-baseline)
tmp=$(/usr/bin/mktemp "$DEST/.archive.XXXXXXXX")
# Partage le verrou du publisher pour figer etat.json pendant tar.
exec 8</srv/helios/suivi/www
/usr/bin/flock -s -w 30 8
/usr/bin/tar --acls --xattrs --selinux --numeric-owner -czf "$tmp" -C / "${paths[@]}"
/usr/bin/flock -u 8
/usr/bin/mv -T "$tmp" "$DEST/$name"; tmp=''
sumtmp=$(/usr/bin/mktemp "$DEST/.sha256.XXXXXXXX")
(cd "$DEST"; /usr/bin/sha256sum "$name") > "$sumtmp"
/usr/bin/mv -T "$sumtmp" "$DEST/$name.sha256"; sumtmp=''
# Tri lexical identique au tri chronologique des noms imposes.
mapfile -t archives < <(/usr/bin/find "$DEST" -maxdepth 1 -type f -name 'suivi-????????-??????.tar.gz' -printf '%f\n' | /usr/bin/sort -r)
for ((i=7; i<${#archives[@]}; i++)); do
    /usr/bin/rm -f -- "$DEST/${archives[i]}" "$DEST/${archives[i]}.sha256"
done
log "sauvegarde terminee : $name ; retention 7"
exit 0
