# Projet - Portail de suivi des tournees Helios

**Antoine Wexsteen-Bezu - BTC2 - 6 novembre 2026**

Realisation sur les VM Rocky Linux `srv-core` et `srv-edge` des TP1 a TP3. Les transcriptions liees ci-dessous contiennent les commandes et leurs sorties reelles. Les premiers essais en echec sont conserves et distingues des validations finales. Version publique publiee sur GitHub a la demande de l'utilisateur, apres validation du rendu local.

## 1. Tableau de conformite

| Exigence | Commandes de preuve | Resultat utile et preuve complete |
|---|---|---|
| E1 - Comptes | `id lea`, `getent passwd lea helios-suivi`, `chage -l lea` | Lea : UID 5104, groupe primaire suivi 5003, aucun groupe wheel/ssh-admins ; compte service UID 992, `/sbin/nologin`, domicile impose. Vieillissement 1/90/14/7 jours. [Comptes](preuves/02-comptes-droits.txt). |
| E2 - ACL | `ls -ld`, `getfacl`, `su - lea`, `runuser -u zabbix -- stat ...` | `www` root:suivi 2770 ; fichier de Lea cree avec umask 077 en 0660, groupe suivi. Service : lecture/ecriture ; nadia : refus ; Zabbix : stat accepte, liste refusee. [Tests](preuves/05-droits-acl.txt), [correction de l'ACL source](preuves/11-correction-acl-telemetrie.txt). |
| E3 - Publication | `runuser -u helios-suivi -- /usr/local/sbin/helios-suivi-publish.sh`, `flock`, lancement par nadia, `python3 -m json.tool`, `journalctl -t helios-suivi-publish` | Codes successivement **0 / 2 / 3**, JSON valide avec les six champs imposes, ecriture atomique. [Validation](preuves/12-publication-codes-valides.txt). Une source invalide dans un espace de montage isole donne **1**, conserve le JSON precedent et nettoie le temporaire : [test complementaire](preuves/20-audit-rapide-et-code1.txt). |
| E4 - systemd | `systemctl show`, `kill -9`, `curl`, `systemctl list-dependencies`, `systemd-analyze security` | Nouveau PID apres 4 s ; HTTP 200 sur les deux URL ; MemoryMax 134217728, quota 500 ms/s ; rattachement a helios.target ; score **1.2**. Publication toutes les 2 min. [Crash et units](preuves/07-crash-et-units.txt), [isolation finale](preuves/13-isolation-ecriture.txt). |
| E5 - sudo | `visudo -c`, `sudo -l -U lea`, essai reel `sudo -S` en Lea | Syntaxe valide, root:root 0440 ; redemarrage du portail accepte, redemarrage SSH et option journalctl ajoutee refuses (rc 1). Essai authentifie en Lea rc 0. [Preuve](preuves/08-sudo.txt). |
| E6 - Pare-feu | `firewall-cmd --zone=internal --list-all`, inspection de toutes les zones runtime/permanent, `nft list ruleset`, `curl` et `nc` depuis edge | 8080/tcp uniquement internal ; defaut drop ; HTTP metier **200 / rc 0** ; connexion administration **rc 1**, filtree. [Pare-feu](preuves/10-parefeu-ssh-supervision.txt), [edge](preuves/09-tests-edge.txt). |
| E7 - Non-regression | `sshd -T`, `journalctl -u sshd`, `systemctl is-active`, `sha256sum -c` | SSH 2242, root no, password no, AllowGroups ssh-admins. Refus de Lea journalise. Surveillance active, journal persistant, SELinux Enforcing, empreintes des sept units precedentes identiques. [SSH et journaux](preuves/10-parefeu-ssh-supervision.txt), [empreintes](preuves/11-correction-acl-telemetrie.txt). |
| E8 - Supervision | `rpm -q`, `systemctl is-active/is-enabled`, `zabbix_get -s 127.0.0.1 -k helios.suivi.http` et `...age` | Agent/get 7.0.32 et sysstat installes ; services/timers actives au boot ; agent sous zabbix, Server=127.0.0.1 ; sondes 200 et age < 300. [Installation](preuves/01-installation-e8.txt), [sondes](preuves/10-parefeu-ssh-supervision.txt). |
| E9 - Sauvegarde | `systemctl start helios-suivi-backup.service`, `sha256sum -c`, `tar --acls`, `diff` d'ACL | Sept archives et sept empreintes verifiees ; calendrier quotidien 03:15 avec rattrapage ; restauration d'index avec ACL, sans modifier les autres fichiers, en **1 s**. [Retention](preuves/15-retention.txt), [restauration](preuves/17-restauration-validee.txt). |
| E10 - Audit (bonus) | `/usr/local/sbin/helios-suivi-audit.sh` | Une ligne par E1 a E9, bilan et code de sortie ; controles de pannes documentes dans [les essais](preuves/18-audit-pannes.txt). La sortie definitive se trouve dans [audit.txt](preuves/audit.txt). |

L'instantane **04-debut-projet** a ete pris avant les changements sur les deux VM. L'etat reel de fin de TP3 a ete conserve : les prerequis etaient conformes ([controle initial](preuves/00-prerequis.txt)). Le nom `03-fin-TP3` n'existait pas dans la liste d'instantanes ; aucun retour a `02-fin-TP2` n'a ete effectue.

Apres arret et redemarrage, les neuf services/timers controles sont actifs, le portail repond 200, les sondes fonctionnent, les ACL restent presentes apres execution du watcher, le port 8080 reste ouvert dans internal et SSH demeure durci : [controle apres boot](preuves/22-apres-reboot.txt). L'audit definitif est celui de cet etat. Le test reseau est egalement rejoue depuis [srv-edge apres boot](preuves/24-edge-apres-reboot.txt).

## 2. Justifications

### a. Durcissement du portail

Le processus tourne en helios-suivi, sans capacites, avec NoNewPrivileges, filtrage des appels systeme, espaces de noms restreints, protection noyau et systeme en lecture seule. Le reseau reste disponible pour HTTP ; les adresses sont limitees a localhost et au reseau metier. Le score obtenu est **1.2**. Aucune directive du portail n'a du etre retiree pour obtenir HTTP 200. `PrivateTmp=yes` a ete complete par `ReadOnlyPaths=/tmp /var/tmp /dev/shm` : les quatre essais d'ecriture, dont www, echouent avec « Read-only file system ». Le publisher a seulement www en ReadWritePaths ; son verrou sur le repertoire et son temporaire y fonctionnent.

### b. ACL Zabbix et lecture de la telemetrie

`--x` sur www permet de traverser le repertoire pour faire stat sur un nom connu ; `r-x` permettrait aussi d'en enumerer les noms. Zabbix n'a aucun droit de lecture sur les fichiers eux-memes. Sans l'entree zabbix sur www, stat renvoie Permission denied (rc 1) ; avec elle, stat fonctionne mais ls echoue (rc 2). Le service dispose separement de la traversee sur `/var/lib/helios` et de la lecture sur telemetry.csv, sans droit d'ecriture sur cette source.

### c. Delegation sans joker

Un `*` en fin de regle journalctl accepterait des arguments supplementaires tels que `--vacuum-time=1s`, permettant de purger les journaux avec les droits root. Les cinq commandes sont ecrites avec leurs arguments exacts ; aucune option supplementaire n'est autorisee. `--no-pager` empeche aussi l'ouverture d'un pager interactif privilegie. Aucun NOPASSWD n'est utilise pour suivi ; Lea doit fournir son mot de passe. Les tests refusent l'option de purge et `systemctl restart sshd`.

### Integration avec le TP3

Le premier audit a trouve la telemetrie illisible apres un passage du watcher. La cause etait `install -d -m 0700 /var/lib/helios` dans `helios-watch-auth.sh` : meme sur un repertoire existant, cette commande reinitialisait le masque ACL. Le [correctif minimal](configs/helios-watch-auth-acl.patch) cree ce dossier uniquement s'il manque. Le script conserve sa logique de detection/blocage et sa creation initiale en 0700 ; aucune unit ni regle de pare-feu precedente n'a ete remplacee. Le test relance explicitement le watcher puis verifie la lecture du service. Ce correctif est exporte et le script corrige est inclus dans la sauvegarde.

## 3. Restauration verifiee

La transcription complete, sans retouche des sorties, est dans [17-restauration-validee.txt](preuves/17-restauration-validee.txt).

1. Demarrage de la sauvegarde par son unit, choix de la derniere archive, verification `sha256sum -c` : **OK**.
2. Extraction dans un repertoire temporaire avec `tar --acls --xattrs --selinux --numeric-owner -xzf "$archive" -C "$testdir"` ; comparaison de `getfacl -cp` pour www : **ACL www identiques rc=0**.
3. Enregistrement des ACL et de l'empreinte d'index ; suspension du timer de publication et enregistrement des empreintes des autres fichiers. Suppression du seul index : **HTTP 404** sur `/index.html`.
4. `tar --acls --xattrs --selinux --numeric-owner -xzf "$archive" -C / srv/helios/suivi/www/index.html` ; ACL identiques, empreinte d'index **OK**, empreintes d'etat.json et du fichier temoin **OK**, proprietaire **lea:suivi**, retour **HTTP 200**. Timer remis en service.

**Temps mesure pour extraction de test, incident, restauration et controles : 1 seconde**, a la resolution de `date +%s` dans ce laboratoire. Ce chiffre ne mesure pas une restauration complete sur une machine neuve. Un premier essai par unit avait echoue car ProtectHome masquait les empreintes de non-regression sous /root ; l'unit de sauvegarde utilise desormais `ProtectHome=read-only`, sans donner de droit d'ecriture a cet emplacement.

## 4. Mesure sous charge

Commande imposee : `for i in $(seq 2000); do curl -s -o /dev/null http://127.0.0.1:8080/etat.json; done`. `sar -u 1` tourne pendant cette fenetre ; les mesures brutes se trouvent dans [16-charge.txt](preuves/16-charge.txt).

| Mesure | Avant | Apres |
|---|---:|---:|
| CPUUsageNSec | 143758000 | 1922386000 |
| MemoryCurrent (octets) | 10047488 | 10178560 |
| cgroup nr_throttled | 0 | 0 |
| cgroup throttled_usec | 0 | 0 |

Les 2 000 requetes durent **34,409 s** ; le service consomme **1,779 s CPU** (environ 5,17 % d'un coeur sur cette fenetre), sa memoire augmente de **128 Kio**. `sar` mesure en moyenne 43,01 % user, 0,51 % nice, 51,01 % system et 5,47 % idle sur l'ensemble de la capture.

**Le quota de 50 % n'a pas bride le service sur cet essai** : aucun evenement ni temps de throttling ; la consommation CPU du portail reste bien sous le quota.
Le CPU global est charge notamment par les lancements repetes de curl ; ce total machine ne doit pas etre attribue au seul processus HTTP.

## 5. Limites connues

- Le serveur Python impose est adapte a ce laboratoire ; pas de TLS, d'authentification applicative ni de montee en charge etudiee. Le compte de publication peut ecrire www, celui du processus HTTP en est empeche par son espace de montage.
- Les droits herites couvrent la creation normale de fichiers (mode demande 0666), quel que soit l'umask. Un programme qui impose explicitement 0600 ou appelle chmod apres creation peut reduire les droits : une ACL par defaut ne peut pas l'en empecher.
- Le collecteur et son archiveur preexistants ne partagent pas de verrou avec le publisher. Une source vide/invalide laisse la derniere publication intacte et fait echouer le script ; une nouvelle tentative arrive au prochain passage du timer. Une journee supplementaire permettrait de definir un protocole de snapshot commun, avec accord pour modifier les scripts precedents.
- Les sauvegardes sont locales a la VM. Elles n'assurent pas la survie a la perte du disque. Pour une machine neuve, les comptes, paquets, ACL du chemin de telemetrie et la configuration reseau se recreent selon [INSTALLATION.md](INSTALLATION.md), puis les fichiers sont restaures. Une copie externe chiffree et un exercice de reconstruction complet seraient les prochaines etapes.
- Lors du test `systemctl reboot`, Linux a termine proprement son arret mais VirtualBox est reste sur un ecran noir. Un `VBoxManage controlvm srv-core reset` a ete necessaire pour relancer le demarrage ; les controles de persistance ont ensuite ete executes sans correction des services. Le redemarrage autonome de l'hyperviseur reste donc une limite de cet environnement.
- L'audit controle l'etat courant et des proprietes statiques ; les preuves separees etablissent le crash, la creation de fichiers et la restauration. Il ne provoque aucune panne. Il depend des outils systeme et du fichier d'empreintes initiales ; s'ils manquent ou qu'une commande echoue, l'exigence concernée devient KO. Les tests de pannes suspendent temporairement les timers, ce qui explique leurs KO supplementaires pendant ces essais.
- Le bonus frontend Zabbix/declencheurs n'est pas realise : le guide fourni demande uniquement l'agent, sans serveur Zabbix ni MariaDB. Le bonus audit E10 et le runbook sont livres.
- Le projet a d'abord ete prepare localement, puis publie dans un nouveau depot public a la demande de l'utilisateur. Les preuves techniques originales sont conservees.
