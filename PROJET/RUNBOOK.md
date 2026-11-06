# Astreinte - Portail Helios

**Cible : srv-core.** Commandes sous root, ou via un administrateur sysops. Lea dispose seulement des cinq commandes de `92-helios-suivi`, avec authentification ; elle transmet les incidents reseau/sauvegarde a l'administrateur.

## 1. Le portail ne repond plus

- Symptome : `helios.suivi.http` vaut 000 ou autre chose que 200.
- Diagnostic : `systemctl --no-pager status helios-suivi.service` ; `journalctl --no-pager -n 100 -u helios-suivi.service`.
- Reparation : `systemctl restart helios-suivi.service` ; si echec, corriger la cause du journal sans desserrer le durcissement.
- Verification : `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/etat.json` doit donner 200.

## 2. etat.json est fige

- Symptome : `helios.suivi.age` depasse 300 secondes.
- Diagnostic : `systemctl list-timers helios-suivi-publish.timer` ; `journalctl --no-pager -n 100 -u helios-suivi-publish.service` ; `getfacl /var/lib/helios /var/lib/helios/telemetry.csv`.
- Reparation : corriger la source/les ACL selon INSTALLATION.md, puis `systemctl start helios-suivi-publish.service` et `systemctl start helios-suivi-publish.timer`.
- Verification : `zabbix_get -s 127.0.0.1 -k helios.suivi.age` donne un entier entre 0 et 299 ; le collecteur reste actif.

## 3. Le service tourne, mais le reseau metier n'y accede pas

- Symptome : HTTP local 200, echec depuis srv-edge sur 10.42.0.10:8080.
- Diagnostic : `firewall-cmd --get-active-zones` ; `firewall-cmd --zone=internal --query-port=8080/tcp` ; verifier bond0/bond0.42 dans internal.
- Reparation : remettre `8080/tcp` uniquement dans internal avec `firewall-cmd --zone=internal --add-port=8080/tcp` et la meme commande avec `--permanent`.
- Verification : depuis edge, curl sur `http://10.42.0.10:8080/etat.json` donne 200 ; `nc -zv -w2 192.168.56.10 8080` echoue.

## 4. Une suppression ou corruption impose une restauration

- Symptome : index absent (HTTP 404) ou contenu invalide ; ne pas ecraser les archives.
- Diagnostic : `cd /srv/helios/archives/suivi` ; `a=$(ls -1 suivi-*.tar.gz | sort | tail -1)` ; `sha256sum -c "$a.sha256"` doit reussir avant extraction.
- Reparation : pour index seul, `tar --acls --xattrs --selinux --numeric-owner -xzf "$a" -C / srv/helios/suivi/www/index.html` ; pour une reconstruction complete, suivre INSTALLATION.md et restaurer les membres necessaires apres extraction de test.
- Verification : `getfacl /srv/helios/suivi/www/index.html`, HTTP 200, puis `/usr/local/sbin/helios-suivi-audit.sh` donne **Bilan : 9/9**, rc 0.
