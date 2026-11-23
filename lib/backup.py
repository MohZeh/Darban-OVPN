#!/usr/bin/env python3
"""Darban OVPN backup archives of the CA: what goes in, how it is checked before anything is restored, and how
server.conf is written again from the template of this tool's setup.

  backup.py pack --out <tar> --inner <json> --pki <dir> --server <dir> --config <dir> --ledger <dir>
                 --host <name> --version <v>
      Writes the archive and its inner manifest; prints content=<hash> and the facts the outer manifest needs.
  backup.py outer --inner <json> --archive <file> --encryption <recipient|passphrase>
      Prints the manifest kept beside an encrypted archive.
  backup.py check --archive <tar> --stage <empty dir>
      Checks every member against the closed list, extracts into <stage> and checks each against the manifest
      inside. Prints key=value lines. Exit 2 with the reason when the archive is refused.
  backup.py conf --conf <server.conf> --server-dir <dir>
      Prints server.conf written again from the template, with only the allowed parameters read from the old one.
      Notes go to stderr. Exit 2, naming the lines, when one of them is not allowed.

Nothing here runs anything from an archive, and nothing is written outside the paths given.
"""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import time

SCHEMA = 1
MAX_MEMBERS = 2000
MAX_FILE = 1024 * 1024
MAX_TOTAL = 20 * 1024 * 1024
NAME = r'[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}'
# The closed list of what an archive may hold. Anything else refuses the whole archive.
FILES = [re.compile('^' + p + '$') for p in (
    r'manifest\.json',
    r'pki/ca\.crt', r'pki/private/ca\.key', r'pki/index\.txt', r'pki/index\.txt\.attr', r'pki/serial', r'pki/crl\.pem',
    r'pki/issued/' + NAME + r'\.crt', r'pki/private/' + NAME + r'\.key', r'pki/reqs/' + NAME + r'\.req',
    r'server/ca\.crt', r'server/server\.crt', r'server/server\.key', r'server/tls-crypt\.key', r'server/crl\.pem',
    r'server/server\.conf',
    r'darban/config', r'darban/domain',
    r'clients/' + NAME,
)]
DIRS = {'pki', 'pki/private', 'pki/issued', 'pki/reqs', 'server', 'darban', 'clients'}
REQUIRED = ('pki/ca.crt', 'pki/private/ca.key', 'pki/index.txt', 'server/server.conf', 'server/server.crt',
            'server/server.key', 'server/tls-crypt.key')
MARK = '# Created by Darban OVPN server-setup.'


class Refused(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(65536), b''):
            digest.update(block)
    return digest.hexdigest()


def ca_fingerprint(pem_path):
    """SHA-256 of the DER of the first certificate in the file, as lowercase hex."""
    with open(pem_path, 'r', encoding='ascii', errors='replace') as handle:
        text = handle.read()
    match = re.search(r'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', text, re.S)
    if not match:
        raise Refused('pki/ca.crt holds no certificate')
    return hashlib.sha256(base64.b64decode(''.join(match.group(1).split()))).hexdigest()


def index_counts(path):
    valid = revoked = 0
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            fields = line.rstrip('\n').split('\t')
            if len(fields) < 6 or '/CN=' not in fields[5]:
                continue
            if fields[0] == 'V':
                valid += 1
            elif fields[0] == 'R':
                revoked += 1
    return valid, revoked


def collect(args):
    """The files of this server the closed list allows, as (archive path, source path)."""
    found = []

    def add(member, source):
        if os.path.isfile(source) and not os.path.islink(source) and any(p.match(member) for p in FILES):
            found.append((member, source))

    for name in ('ca.crt', 'index.txt', 'index.txt.attr', 'serial', 'crl.pem'):
        add('pki/' + name, os.path.join(args.pki, name))
    add('pki/private/ca.key', os.path.join(args.pki, 'private', 'ca.key'))
    for folder, suffix in (('issued', '.crt'), ('private', '.key'), ('reqs', '.req')):
        directory = os.path.join(args.pki, folder)
        if os.path.isdir(directory):
            for name in sorted(os.listdir(directory)):
                if name.endswith(suffix):
                    add('pki/%s/%s' % (folder, name), os.path.join(directory, name))
    for name in ('ca.crt', 'server.crt', 'server.key', 'tls-crypt.key', 'crl.pem', 'server.conf'):
        add('server/' + name, os.path.join(args.server, name))
    for name in ('config', 'domain'):
        add('darban/' + name, os.path.join(args.config, name))
    if os.path.isdir(args.ledger):
        for name in sorted(os.listdir(args.ledger)):
            add('clients/' + name, os.path.join(args.ledger, name))
    return sorted(set(found))


def pack(args):
    members = collect(args)
    paths = {m for m, _ in members}
    for need in REQUIRED:
        if need not in paths:
            raise Refused('%s is missing on this server' % need)
    listed = {}
    for member, source in members:
        size = os.path.getsize(source)
        if size > MAX_FILE:
            raise Refused('%s is larger than %d bytes' % (member, MAX_FILE))
        listed[member] = {'sha256': sha256_file(source), 'size': size}
    content = hashlib.sha256(''.join('%s %s\n' % (m, listed[m]['sha256']) for m in sorted(listed)).encode()).hexdigest()
    valid, revoked = index_counts(os.path.join(args.pki, 'index.txt'))
    inner = {
        'schema': SCHEMA, 'tool': 'darban-ovpn', 'version': args.version,
        'created': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'host': args.host,
        'ca_fingerprint': ca_fingerprint(os.path.join(args.pki, 'ca.crt')),
        'clients': {'valid': valid, 'revoked': revoked}, 'content': content, 'members': listed,
    }
    data = json.dumps(inner, indent=1, sort_keys=True).encode()
    with tarfile.open(args.out, 'w', format=tarfile.PAX_FORMAT) as tar:
        info = tarfile.TarInfo('manifest.json')
        info.size, info.mode, info.mtime = len(data), 0o600, int(time.time())
        tar.addfile(info, io.BytesIO(data))
        for member, source in members:
            info = tar.gettarinfo(source, member)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            with open(source, 'rb') as handle:
                tar.addfile(info, handle)
    with open(args.inner, 'w', encoding='utf-8') as handle:
        json.dump(inner, handle, indent=1, sort_keys=True)
    print('content=%s' % content)
    print('created=%s' % inner['created'])
    print('ca_fingerprint=%s' % inner['ca_fingerprint'])
    print('valid=%d' % valid)
    print('revoked=%d' % revoked)


def outer(args):
    with open(args.inner, 'r', encoding='utf-8') as handle:
        inner = json.load(handle)
    manifest = {k: v for k, v in inner.items() if k != 'members'}
    manifest['paths'] = sorted(inner['members'])
    manifest['archive'] = os.path.basename(args.archive)
    manifest['archive_sha256'] = sha256_file(args.archive)
    manifest['encryption'] = args.encryption
    print(json.dumps(manifest, indent=1, sort_keys=True))


def check(args):
    stage = args.stage
    if os.listdir(stage):
        raise Refused('the staging folder is not empty')
    seen = set()
    regular = []
    total = 0
    with tarfile.open(args.archive, 'r:') as tar:
        count = 0
        while True:
            member = tar.next()
            if member is None:
                break
            count += 1
            if count > MAX_MEMBERS:
                raise Refused('more than %d members' % MAX_MEMBERS)
            name = member.name
            if name.startswith('./'):
                name = name[2:]
            name = name.rstrip('/') if member.isdir() else name
            if not name or name.startswith('/') or '\\' in name or any(p in ('', '.', '..') for p in name.split('/')):
                raise Refused('member %r has a path that is not allowed' % member.name)
            if name in seen:
                raise Refused('member %s appears twice' % name)
            seen.add(name)
            if member.isdir():
                if name not in DIRS:
                    raise Refused('folder %s is not one a backup holds' % name)
                continue
            if not member.isreg():
                raise Refused('member %s is not a regular file (links and devices are refused)' % name)
            if not any(p.match(name) for p in FILES):
                raise Refused('member %s is not one a backup holds' % name)
            if member.size > MAX_FILE:
                raise Refused('member %s is larger than %d bytes' % (name, MAX_FILE))
            total += member.size
            if total > MAX_TOTAL:
                raise Refused('the members together are larger than %d bytes' % MAX_TOTAL)
            member.name = name
            regular.append(member)
        for need in REQUIRED:
            if need not in seen:
                raise Refused('%s is missing' % need)
        tar.extractall(stage, members=regular, filter='data')
    schema = 0
    created = host = version = ''
    # C.16.4: an archive whose schema is not known is never restored.
    if 'manifest.json' not in seen:
        raise Refused('the archive has no manifest.json, so its schema is not known')
    if 'manifest.json' in seen:
        with open(os.path.join(stage, 'manifest.json'), 'r', encoding='utf-8') as handle:
            try:
                inner = json.load(handle)
            except ValueError:
                raise Refused('manifest.json is not valid')
        if inner.get('schema') != SCHEMA or not isinstance(inner.get('members'), dict):
            raise Refused('manifest.json has a schema this version does not know')
        schema = SCHEMA
        listed = inner['members']
        files = {m.name for m in regular} - {'manifest.json'}
        if set(listed) != files:
            raise Refused('the members do not match manifest.json: %s' % ', '.join(sorted(set(listed) ^ files)))
        for name in sorted(files):
            if sha256_file(os.path.join(stage, name)) != listed[name].get('sha256'):
                raise Refused('%s does not match its checksum in manifest.json' % name)
        created = str(inner.get('created', ''))
        host = str(inner.get('host', ''))
        version = str(inner.get('version', ''))
    if not re.fullmatch(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)?', created):
        created = ''
    if not re.fullmatch(r'[A-Za-z0-9.-]{0,64}', host):
        host = ''
    if not re.fullmatch(r'[0-9A-Za-z.+-]{0,40}', version):
        version = ''
    valid, revoked = index_counts(os.path.join(stage, 'pki', 'index.txt'))
    print('schema=%d' % schema)
    print('created=%s' % created)
    print('host=%s' % host)
    print('version=%s' % version)
    print('ca_fingerprint=%s' % ca_fingerprint(os.path.join(stage, 'pki', 'ca.crt')))
    print('valid=%d' % valid)
    print('revoked=%d' % revoked)


# server.conf. Lines of the template are written as the template has them; their value is never read, and a
# difference is only reported. The parameters below are read, each with a strict pattern. Any other line refuses
# the restore. The listeners come in one of three forms: "port N" with "proto udp4" (UDP only) or "proto tcp4-server"
# (TCP only), or two lines "local * N udp" and "local * M tcp" without either (both). explicit-exit-notify is
# written with a UDP listener only. A port-share line is not restored: the link service it needs is set up again in
# Settings.
TEMPLATE = ('dev', 'topology', 'ca', 'cert', 'key', 'tls-crypt', 'crl-verify', 'dh', 'tls-version-min',
            'explicit-exit-notify', 'persist-key', 'persist-tun', 'user', 'group', 'management',
            'script-security', 'client-connect', 'client-disconnect')
OCTET = r'(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
IPV4 = r'%s(\.%s){3}' % (OCTET, OCTET)
CIPHERS = {'AES-256-GCM', 'AES-128-GCM', 'CHACHA20-POLY1305'}


def private_net(value):
    parts = [int(p) for p in value.split('.')]
    if parts[3] != 0:
        return False
    return parts[0] == 10 or (parts[0] == 172 and 16 <= parts[1] <= 31) or (parts[0] == 192 and parts[1] == 168)


def conf(args):
    with open(args.conf, 'r', encoding='utf-8', errors='replace') as handle:
        lines = handle.read().splitlines()
    if not lines or lines[0].strip() != MARK:
        raise Refused('server.conf in the backup was not made by this tool\'s setup')
    canonical = {
        'dev': 'dev tun', 'topology': 'topology subnet', 'ca': 'ca ca.crt',
        'cert': 'cert server.crt', 'key': 'key server.key', 'tls-crypt': 'tls-crypt tls-crypt.key',
        'crl-verify': 'crl-verify %s/crl.pem' % args.server_dir.rstrip('/'), 'dh': 'dh none',
        'tls-version-min': 'tls-version-min 1.2', 'explicit-exit-notify': 'explicit-exit-notify 1',
        'persist-key': 'persist-key', 'persist-tun': 'persist-tun', 'user': 'user nobody', 'group': 'group nogroup',
        'management': 'management /run/openvpn-server/darban.sock unix',
    }
    values = {}
    push = []
    local = {}
    refused = []
    notes = []
    for number, raw in enumerate(lines[1:], start=2):
        line = raw.strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        word = line.split()[0]
        rest = line[len(word):].strip()
        if word in TEMPLATE:
            if word in canonical and line.split() != canonical[word].split():
                notes.append('line %d, %s, differs from the template; the template is used' % (number, word))
            continue
        ok = False
        if word == 'local':
            match = re.fullmatch(r'\* (\d{1,5}) (udp|tcp)', rest)
            if match and 1 <= int(match.group(1)) <= 65535 and match.group(2) not in local:
                local[match.group(2)] = str(int(match.group(1)))
            elif match and match.group(2) in local:
                refused.append('line %d, local, names %s twice' % (number, match.group(2)))
            else:
                refused.append('line %d, local' % number)
            continue
        if word == 'port-share':
            if re.fullmatch(r'127\.0\.0\.1 \d{1,5} /[A-Za-z0-9/_.-]{1,200}', rest):
                notes.append('line %d, port-share, is not restored; turn it on again in Settings > 2' % number)
                continue
        elif word == 'proto':
            ok = rest in ('udp4', 'tcp4-server')
            if not ok and re.fullmatch(r'udp[46]?', rest):
                notes.append('line %d, proto, differs from the template; proto udp4 is used' % number)
                rest, ok = 'udp4', True
        elif word == 'port':
            ok = re.fullmatch(r'\d{1,5}', rest) is not None and 1 <= int(rest) <= 65535
        elif word == 'server':
            match = re.fullmatch(r'(%s) 255\.255\.255\.0' % IPV4, rest)
            ok = match is not None and private_net(match.group(1))
        elif word == 'data-ciphers':
            ok = bool(rest) and all(c in CIPHERS for c in rest.split(':'))
        elif word == 'keepalive':
            match = re.fullmatch(r'(\d{1,4}) (\d{1,4})', rest)
            ok = match is not None and 1 <= int(match.group(1)) and int(match.group(2)) >= 2 * int(match.group(1))
        elif word == 'verb':
            ok = re.fullmatch(r'\d|1[01]', rest) is not None
        elif word == 'push':
            if rest == '"redirect-gateway def1 bypass-dhcp"' or re.fullmatch(r'"dhcp-option DNS %s"' % IPV4, rest):
                push.append(line)
                continue
        if ok and word in values:
            refused.append('line %d, %s, is there twice' % (number, word))
        elif ok:
            values[word] = rest
        else:
            refused.append('line %d, %s' % (number, word))
    if local:
        if 'port' in values or 'proto' in values or len(local) != 2:
            refused.append('the listeners are neither one port and proto, nor two local lines, one udp and one tcp')
        listeners = ['local * %s udp' % local.get('udp', ''), 'local * %s tcp' % local.get('tcp', '')]
        udp = True
    else:
        # A backup from before TCP may lack proto: the template had it, and it was never read.
        if 'port' not in values:
            refused.append('port is missing')
        proto = values.get('proto', 'udp4')
        listeners = ['port ' + values.get('port', ''), 'proto ' + proto]
        udp = proto == 'udp4'
    if 'server' not in values:
        refused.append('server is missing')
    if refused:
        raise Refused('server.conf in the backup has lines this tool does not restore: ' + '; '.join(refused))
    out = [MARK] + listeners + [canonical['dev'], canonical['topology'],
           'server ' + values['server'], canonical['ca'], canonical['cert'], canonical['key'], canonical['tls-crypt'],
           canonical['crl-verify'], canonical['dh'], canonical['tls-version-min'],
           'data-ciphers ' + values.get('data-ciphers', 'AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305'),
           'keepalive ' + values.get('keepalive', '10 60')] + ([canonical['explicit-exit-notify']] if udp else []) + [
           canonical['persist-key'], canonical['persist-tun'], canonical['user'], canonical['group'],
           canonical['management'], 'verb ' + values.get('verb', '3')] + push
    for note in notes:
        print('NOTE: ' + note, file=sys.stderr)
    print('\n'.join(out))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('pack')
    for name in ('out', 'inner', 'pki', 'server', 'config', 'ledger', 'host', 'version'):
        p.add_argument('--' + name, required=True)
    p = sub.add_parser('outer')
    for name in ('inner', 'archive', 'encryption'):
        p.add_argument('--' + name, required=True)
    p = sub.add_parser('check')
    p.add_argument('--archive', required=True)
    p.add_argument('--stage', required=True)
    p = sub.add_parser('conf')
    p.add_argument('--conf', required=True)
    p.add_argument('--server-dir', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        {'pack': pack, 'outer': outer, 'check': check, 'conf': conf}[args.command](args)
    except Refused as error:
        print('REFUSED: %s' % error, file=sys.stderr)
        return 2
    except (OSError, tarfile.TarError) as error:
        print('REFUSED: the archive cannot be read: %s' % error, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
