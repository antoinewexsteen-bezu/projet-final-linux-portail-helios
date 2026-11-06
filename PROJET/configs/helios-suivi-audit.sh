#!/usr/bin/bash
# Audit en lecture seule. Les essais destructifs sont documentes dans preuves/.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '[KO] root requis'; exit 1; }
exec /usr/bin/python3 - <<'PY'
import datetime, grp, json, math, os, pathlib, pwd, re, shlex, stat, subprocess, time, xml.etree.ElementTree as ET

WWW = pathlib.Path('/srv/helios/suivi/www')
BIN = '/usr/local/sbin/'
SYSTEM = '/etc/systemd/system/'
failures = []
score = 0

def command(args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
    return result.returncode, result.stdout.strip(), result.stderr.strip()

def output(args):
    rc, out, err = command(args)
    if rc:
        raise RuntimeError(' '.join(args) + ': ' + (err or out))
    return out

def require(condition, message):
    if not condition:
        raise ValueError(message)

def active(*units):
    for unit in units:
        require(output(['systemctl', 'is-active', unit]) == 'active', unit + ' inactif')

def enabled(*units):
    for unit in units:
        require(output(['systemctl', 'is-enabled', unit]) == 'enabled', unit + ' non active au boot')

def property_of(unit, name):
    return output(['systemctl', 'show', '--value', '-p', name, unit])

def as_user(user, *args):
    return command(['runuser', '-u', user, '--', *args])

def secure_file(path, mode):
    entry = pathlib.Path(path)
    info = entry.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and
            stat.S_IMODE(info.st_mode) == mode, path + ': proprietaire/type/mode incorrect')

def e1():
    lea, service = pwd.getpwnam('lea'), pwd.getpwnam('helios-suivi')
    require(grp.getgrnam('suivi').gr_gid == 5003 and lea.pw_uid == 5104 and
            lea.pw_gid == 5003 and lea.pw_gecos == 'Lea Fabre - responsable suivi des tournees', 'identifiants Lea/suivi')
    require(not set(os.getgrouplist('lea', lea.pw_gid)) &
            {grp.getgrnam(name).gr_gid for name in ('wheel', 'ssh-admins')}, 'groupes interdits')
    shadow = output(['getent', 'shadow', 'lea']).split(':')
    require(shadow[3:7] == ['1', '90', '14', '7'], 'expiration du mot de passe')
    require(0 < service.pw_uid < 1000 and service.pw_shell in ('/sbin/nologin', '/usr/sbin/nologin') and
            service.pw_dir == '/srv/helios/suivi' and not pathlib.Path('/home/helios-suivi').exists(), 'compte service')

def e2():
    info = WWW.stat()
    require(info.st_uid == 0 and info.st_gid == 5003 and stat.S_IMODE(info.st_mode) == 0o2770, 'www root:suivi 2770')
    acl = output(['getfacl', '-cp', str(WWW)])
    for expected in ('user:helios-suivi:rwx', 'user:zabbix:--x', 'default:user::rwx',
                     'default:user:helios-suivi:rwx', 'default:group::rwx', 'default:mask::rwx', 'default:other::---'):
        require(expected in acl.splitlines(), 'ACL absente : ' + expected)
    for permission in ('-r', '-w', '-x'):
        require(as_user('helios-suivi', 'test', permission, str(WWW))[0] == 0, 'droits service ' + permission)
    require(as_user('zabbix', 'stat', str(WWW / 'etat.json'))[0] == 0, 'stat zabbix refuse')
    require(as_user('zabbix', 'ls', str(WWW))[0] != 0, 'zabbix peut lister www')
    require(as_user('nadia', 'cat', str(WWW / 'index.html'))[0] != 0, 'nadia peut lire index')
    require((WWW / 'index.html').stat().st_uid == 5104, 'index ne provient pas de Lea')

def e3():
    secure_file(BIN + 'helios-suivi-publish.sh', 0o755)
    output(['bash', '-n', BIN + 'helios-suivi-publish.sh'])
    text = pathlib.Path(BIN + 'helios-suivi-publish.sh').read_text()
    for token in ('set -Eeuo pipefail', 'flock -n', 'trap cleanup EXIT', 'logger', 'exit 2', 'exit 3', 'mv -fT'):
        require(token in text, 'publication : ' + token)
    require(as_user('helios-suivi', 'test', '-r', '/var/lib/helios/telemetry.csv')[0] == 0, 'telemetrie illisible')
    state = json.loads((WWW / 'etat.json').read_text())
    require(set(('genere', 'hote', 'derniere_mesure', 'charge_1min', 'mem_dispo_ko', 'mesures')) <= state.keys(), 'champs JSON')
    require(state['hote'] == output(['hostname']) and isinstance(state['mesures'], int) and state['mesures'] > 0 and
            isinstance(state['mem_dispo_ko'], int) and state['mem_dispo_ko'] >= 0 and
            isinstance(state['charge_1min'], (float, int)) and math.isfinite(state['charge_1min']), 'valeurs JSON')
    generated = datetime.datetime.fromisoformat(state['genere']).timestamp()
    datetime.datetime.fromisoformat(state['derniere_mesure'])
    require(0 <= time.time() - generated < 300 and 0 <= time.time() - (WWW / 'etat.json').stat().st_mtime < 300, 'etat.json trop ancien/futur')

def e4():
    unit = 'helios-suivi.service'
    active(unit, 'helios-suivi-publish.timer')
    enabled(unit, 'helios-suivi-publish.timer')
    require(property_of(unit, 'User') == 'helios-suivi', 'identite HTTP')
    require(property_of(unit, 'MemoryMax') == '134217728' and property_of(unit, 'CPUQuotaPerSecUSec') == '500ms', 'limites ressources')
    require(property_of(unit, 'Restart') == 'on-failure' and property_of(unit, 'ProtectSystem') == 'strict' and
            not property_of(unit, 'ReadWritePaths') and property_of(unit, 'ReadOnlyPaths') == '/tmp /var/tmp /dev/shm', 'durcissement HTTP')
    require('/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/helios/suivi/www' in
            pathlib.Path(SYSTEM + unit).read_text(), 'commande HTTP')
    require('helios-suivi.service' in output(['systemctl', 'list-dependencies', '--plain', 'helios.target']), 'rattachement cible')
    result = output(['systemd-analyze', 'security', '--no-pager', unit])
    match = re.search(r'Overall exposure level.*?:\s*([0-9.]+)', result)
    require(match and float(match.group(1)) <= 4, 'exposition systemd > 4 ou inconnue')
    for url in ('/', '/etat.json'):
        require(output(['curl', '--max-time', '5', '-s', '-o', '/dev/null', '-w', '%{http_code}', 'http://127.0.0.1:8080' + url]) == '200', 'HTTP ' + url)
    require(property_of('helios-suivi-publish.service', 'User') == 'helios-suivi' and
            property_of('helios-suivi-publish.service', 'Type') == 'oneshot' and
            property_of('helios-suivi-publish.service', 'ProtectSystem') == 'strict' and
            property_of('helios-suivi-publish.service', 'ReadWritePaths') == str(WWW), 'unit publication')
    require('OnUnitActiveSec=2min' in pathlib.Path(SYSTEM + 'helios-suivi-publish.timer').read_text(), 'periode publication')

def e5():
    path = '/etc/sudoers.d/92-helios-suivi'
    secure_file(path, 0o440)
    require(pathlib.Path(path).stat().st_gid == 0, 'groupe sudoers')
    output(['visudo', '-c'])
    listing = output(['sudo', '-l', '-U', 'lea'])
    require('NOPASSWD' not in listing and '*' not in pathlib.Path(path).read_text().splitlines()[-1], 'sudo trop permissif')
    allowed = [('/usr/bin/systemctl', 'restart', 'helios-suivi.service'),
               ('/usr/bin/systemctl', '--no-pager', 'status', 'helios-suivi.service'),
               ('/usr/bin/systemctl', 'start', 'helios-suivi-publish.service'),
               ('/usr/bin/journalctl', '--no-pager', '-n', '100', '-u', 'helios-suivi.service'),
               ('/usr/bin/journalctl', '--no-pager', '-n', '100', '-u', 'helios-suivi-publish.service')]
    forbidden = [('/usr/bin/systemctl', 'restart', 'sshd'), ('/usr/bin/systemctl', 'restart', 'sshd.service'),
                 ('/usr/bin/journalctl', '--vacuum-time=1s'), ('/bin/bash',),
                 ('/usr/bin/systemctl', 'status', 'helios-suivi.service')]
    forbidden += [args + ('--help',) for args in allowed]
    for args in allowed:
        require(command(['sudo', '-l', '-U', 'lea', *args])[0] == 0, 'sudo refuse ' + ' '.join(args))
    for args in forbidden:
        require(command(['sudo', '-l', '-U', 'lea', *args])[0] != 0, 'sudo autorise ' + ' '.join(args))

def e6():
    active('firewalld')
    require(output(['firewall-cmd', '--get-default-zone']) == 'drop', 'zone par defaut runtime')
    require(re.search(r'^DefaultZone=drop$', pathlib.Path('/etc/firewalld/firewalld.conf').read_text(), re.M), 'zone par defaut persistante')
    def has_8080(port, protocol):
        bounds = port.split('-')
        return protocol == 'tcp' and int(bounds[0]) <= 8080 <= int(bounds[-1])
    def service_8080(name, seen=None):
        seen = set() if seen is None else seen
        require(name not in seen, 'inclusion cyclique de services firewalld')
        seen = seen | {name}
        files = [pathlib.Path(root) / (name + '.xml') for root in ('/etc/firewalld/services', '/usr/lib/firewalld/services')]
        path = next((path for path in files if path.is_file()), None)
        require(path is not None, 'service firewalld introuvable : ' + name)
        tree = ET.parse(path).getroot()
        return any(has_8080(port.attrib['port'], port.attrib['protocol']) for port in tree.findall('port')) or any(
            service_8080(include.attrib['service'], seen) for include in tree.findall('include'))
    for scope in ([], ['--permanent']):
        text = output(['firewall-cmd', *scope, '--list-all-zones'])
        zones = {}
        zone = None
        for line in text.splitlines():
            if line and not line[0].isspace():
                zone = line.split()[0]
                zones[zone] = []
            elif zone is not None:
                zones[zone].append(line)
        require('internal' in zones, 'zone internal absente')
        for zone, lines in zones.items():
            section = '\n'.join(lines)
            ports = re.search(r'^  ports:[ \t]*(.*)$', section, re.M)
            contains = any(has_8080(*port.split('/')) for port in (ports.group(1).split() if ports else []))
            require(contains == (zone == 'internal'), '8080 incorrect dans ' + zone)
            require(not re.search(r'port="(?:8080|[0-9]+-[0-9]+)"', section), 'regle riche a verifier dans ' + zone)
            if zone != 'internal':
                services = re.search(r'^  services:[ \t]*(.*)$', section, re.M)
                for service in (services.group(1).split() if services else []):
                    require(not service_8080(service), 'service exposant 8080 dans ' + zone)
    interfaces = output(['firewall-cmd', '--zone=internal', '--list-interfaces']).split()
    require({'bond0', 'bond0.42'} <= set(interfaces), 'interfaces metier')

def e7():
    values = output(['sshd', '-T']).splitlines()
    for expected in ('port 2242', 'permitrootlogin no', 'passwordauthentication no', 'allowgroups ssh-admins'):
        require(expected in values, 'SSH : ' + expected)
    active('helios-watch-auth.timer', 'helios-collect.service', 'systemd-journald')
    enabled('helios-watch-auth.timer')
    require(pathlib.Path('/var/log/journal').is_dir(), 'journal non persistant')
    journal = output(['systemd-analyze', 'cat-config', 'systemd/journald.conf'])
    require('Storage=persistent' in journal, 'Storage persistent absent')
    require(output(['getenforce']) == 'Enforcing', 'SELinux non enforcing')
    output(['sha256sum', '-c', '/root/projet-baseline/units.sha256'])

def e8():
    for package in ('zabbix-agent2', 'zabbix-get', 'sysstat'):
        version = output(['rpm', '-q', package])
        require(package == 'sysstat' or '-7.0.' in version, 'version Zabbix')
    active('zabbix-agent2', 'sysstat.service', 'sysstat-collect.timer', 'sysstat-summary.timer')
    enabled('zabbix-agent2', 'sysstat.service', 'sysstat-collect.timer', 'sysstat-summary.timer')
    config = pathlib.Path('/etc/zabbix/zabbix_agent2.conf').read_text().splitlines()
    require('Server=127.0.0.1' in config, 'Server Zabbix')
    require(output(['zabbix_get', '-s', '127.0.0.1', '-k', 'helios.suivi.http']) == '200', 'sonde HTTP')
    age = int(output(['zabbix_get', '-s', '127.0.0.1', '-k', 'helios.suivi.age']))
    require(0 <= age < 300, 'sonde age >= 300 ou futur')

def e9():
    root = pathlib.Path('/srv/helios/archives')
    info = root.stat()
    require(info.st_uid == pwd.getpwnam('helios').pw_uid and info.st_gid == grp.getgrnam('helios').gr_gid and
            stat.S_IMODE(info.st_mode) == 0o750, 'repertoire archives')
    dest = root / 'suivi'
    archives = sorted(dest.glob('suivi-????????-??????.tar.gz'))
    require(1 <= len(archives) <= 7, 'nombre archives hors 1..7')
    archive = archives[-1]
    result = subprocess.run(['sha256sum', '-c', archive.name + '.sha256'], cwd=str(dest),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    require(result.returncode == 0, 'empreinte sauvegarde invalide/absente')
    members = output(['tar', '-tzf', str(archive)]).splitlines()
    for member in ('srv/helios/suivi/www/index.html', 'srv/helios/suivi/www/etat.json',
                   'etc/sudoers.d/92-helios-suivi', 'etc/zabbix/zabbix_agent2.d/helios-suivi.conf',
                   *('etc/systemd/system/' + name for name in ('helios-suivi.service', 'helios-suivi-publish.service',
                      'helios-suivi-publish.timer', 'helios-suivi-backup.service', 'helios-suivi-backup.timer')),
                   'usr/local/sbin/helios-suivi-publish.sh', 'usr/local/sbin/helios-suivi-backup.sh'):
        require(member in members, 'archive incomplete : ' + member)
    secure_file(BIN + 'helios-suivi-backup.sh', 0o755)
    output(['bash', '-n', BIN + 'helios-suivi-backup.sh'])
    active('helios-suivi-backup.timer')
    enabled('helios-suivi-backup.timer')
    timer = pathlib.Path(SYSTEM + 'helios-suivi-backup.timer').read_text()
    require('OnCalendar=*-*-* 03:15:00' in timer and 'Persistent=true' in timer, 'timer sauvegarde')

for number, check in enumerate((e1,e2,e3,e4,e5,e6,e7,e8,e9), 1):
    try:
        check()
        print('[OK] E' + str(number), flush=True)
        score += 1
    except Exception as error:
        print('[KO] E' + str(number) + ' : ' + str(error).replace('\n', ' ')[:500], flush=True)
print('Bilan : ' + str(score) + '/9', flush=True)
raise SystemExit(0 if score == 9 else 1)
PY
