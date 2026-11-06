# Projet final - Portail Helios

**Antoine Wexsteen-Bezu - BTC2 - 6 novembre 2026**

- [Rapport de conformite et tests](RAPPORT.md)
- [Runbook d'astreinte](RUNBOOK.md)
- [Installation et reconstruction](INSTALLATION.md)
- [Configurations exportees](configs/)
- [Preuves reelles](preuves/)
- [Sujet et guide Zabbix](sujet/)

Le portail est installe sur srv-core, accessible depuis srv-edge a `http://10.42.0.10:8080/`. Le reseau d'administration filtre ce port. L'audit root est `/usr/local/sbin/helios-suivi-audit.sh`.

Version publique du projet, publiee a la demande de l'utilisateur. Les outils d'administration et la cle privee restent dans `lab-private/`, exclu du depot et du rendu.
