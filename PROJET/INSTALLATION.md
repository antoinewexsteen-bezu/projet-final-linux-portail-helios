# Installation et reconstruction

Les VM fournies sont deja configurees. Ce document explique les changements pour les rejouer sur un socle **TP3 conforme**, en root. Ne pas l'executer sans controle sur un serveur quelconque : UID/GID, adresses et noms sont imposes par le laboratoire. Les fichiers a installer sont dans `configs/`. Les commandes supposent que le repertoire courant est `PROJET/` transfere sur srv-core.

## 1. Socle et supervision, avant les ACL

Verifier les cinq prerequis de l'enonce ; prendre un instantane VirtualBox avant les changements. Ne pas restaurer un ancien TP2 si les changements du TP3 sont presents. Conserver les empreintes **avant** installation :

```bash
mkdir -p /root/projet-baseline
find /etc/systemd/system -maxdepth 2 -type f -name 'helios*' -exec sha256sum {} + > /root/projet-baseline/units.sha256
```

Installer l'agent selon `sujet/GUIDE-E8-agent-zabbix.pdf` :

```bash
if test -f /etc/yum.repos.d/epel.repo; then
  grep -q '^excludepkgs=zabbix' /etc/yum.repos.d/epel.repo ||
    sed -i '/^\[epel\]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
fi
rpm -q zabbix-release || rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rocky/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm
dnf -y install zabbix-agent2 zabbix-get sysstat acl patch
systemctl enable --now zabbix-agent2 sysstat.service sysstat-collect.timer sysstat-summary.timer
```

EPEL etait absent lors de la realisation. L'agent garde `Server=127.0.0.1`. Aucun serveur Zabbix ni MariaDB n'est necessaire.

## 2. Comptes et droits

Verifier d'abord que les identifiants 5003 et 5104 sont libres, ou correspondent deja aux comptes attendus. Pour une premiere installation :

```bash
groupadd -g 5003 suivi
useradd -u 5104 -g suivi -c 'Lea Fabre - responsable suivi des tournees' -m lea
printf '%s\n' 'lea:Helios-Suivi-2026' | chpasswd
chage -M 90 -m 1 -W 14 -I 7 lea
useradd -r -g suivi -d /srv/helios/suivi -s /sbin/nologin -M helios-suivi
install -d -o root -g suivi -m 2750 /srv/helios/suivi
install -d -o root -g suivi -m 2770 /srv/helios/suivi/www
setfacl -m u:zabbix:--x /srv/helios/suivi
setfacl -m u:helios-suivi:rwx,u:zabbix:--x,m::rwx,o::--- /srv/helios/suivi/www
setfacl -d -m u::rwx,u:helios-suivi:rwx,g::rwx,m::rwx,o::--- /srv/helios/suivi/www
setfacl -m u:helios-suivi:--x /var/lib/helios
setfacl -m u:helios-suivi:r-- /var/lib/helios/telemetry.csv
su - lea -c 'umask 077; printf "Portail de suivi Helios - Lea Fabre\n" > /srv/helios/suivi/www/index.html'
install -d -o helios -g helios -m 0750 /srv/helios/archives
install -d -o root -g root -m 0700 /srv/helios/archives/suivi
```

Ne pas ajouter Lea a wheel ou ssh-admins. L'UID du compte systeme est attribue par useradd ; il vaut 992 sur la VM livree, mais seul UID < 1000 est impose. Pour restaurer ailleurs une archive a proprietaires numeriques, recreer le meme UID (ou adapter les proprietaires avant remise en service).

Le script TP3 fourni dans ce laboratoire reappliquait 0700 sur `/var/lib/helios` a chaque passage, effacant le masque ACL. Appliquer une seule fois le correctif exporte, puis reposer l'ACL et verifier apres un passage du watcher :

```bash
cp -a /usr/local/sbin/helios-watch-auth.sh /root/projet-baseline/helios-watch-auth.sh.orig
patch --forward /usr/local/sbin/helios-watch-auth.sh < configs/helios-watch-auth-acl.patch
bash -n /usr/local/sbin/helios-watch-auth.sh
setfacl -m u:helios-suivi:--x /var/lib/helios
systemctl start helios-watch-auth.service
runuser -u helios-suivi -- test -r /var/lib/helios/telemetry.csv
```

## 3. Fichiers de production et activation

```bash
for f in configs/helios-suivi*.sh; do
  install -o root -g root -m 0755 "$f" /usr/local/sbin/
done
for f in configs/helios-suivi*.service configs/helios-suivi*.timer; do
  install -o root -g root -m 0644 "$f" /etc/systemd/system/
done
visudo -cf configs/92-helios-suivi
install -o root -g root -m 0440 configs/92-helios-suivi /etc/sudoers.d/92-helios-suivi
install -o root -g root -m 0644 configs/helios-suivi.conf /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
restorecon -RF /srv/helios/suivi /usr/local/sbin/helios-suivi* /etc/systemd/system/helios-suivi* /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
systemd-analyze verify /etc/systemd/system/helios-suivi*.service /etc/systemd/system/helios-suivi*.timer
systemctl daemon-reload
systemctl enable --now helios-suivi.service helios-suivi-publish.timer helios-suivi-backup.timer
systemctl start helios-suivi-publish.service
firewall-cmd --zone=internal --add-port=8080/tcp
firewall-cmd --permanent --zone=internal --add-port=8080/tcp
systemctl restart zabbix-agent2
systemctl start helios-suivi-backup.service
/usr/local/sbin/helios-suivi-audit.sh
```

L'audit doit conclure 9/9 et renvoyer 0. Depuis srv-edge, tester le reseau metier et le refus sur le reseau d'administration comme dans le rapport. Ne pas ouvrir de port Zabbix supplementaire : les sondes passent localement.

## 4. Reconstruction depuis une archive

Verifier l'empreinte depuis le repertoire des archives. Extraire d'abord dans un repertoire de test avec `tar --acls --xattrs --selinux --numeric-owner`. Comparer contenu et ACL. Sur un socle TP3 reconstruit, recreer les comptes/paquets, puis restaurer les chemins necessaires de l'archive. Elle contient les cinq units, les trois scripts, www et ses ACL, sudoers, la sonde, le watcher corrige et les empreintes initiales.

Reposer les ACL du chemin de telemetrie (hors de www), controler les proprietaires numeriques et `visudo -c`, effectuer `systemctl daemon-reload`, reactiver les services/timers et les regles runtime/permanentes. Les liens d'activation systemd et la configuration reseau ne sont pas reconstruits par la seule extraction de tar. Pour index seul, utiliser la commande selective du RUNBOOK, sans extraire le reste.
