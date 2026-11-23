#!/usr/bin/env python3
"""Serves temporary links to client profiles over HTTPS.

A link file is <sha256 of token>.meta plus <same>.ovpn in the store directory, so this service finds a link
without keeping its token. darban keeps the whole address in <same>.url, readable by root only, so it can show
a link again; this service never reads that file, and removes it with the link. A link works until the client it
was made for connects to the VPN for the first time, or until it expires, whichever comes first. With connection
events on, darban sees that connection and ends the link itself. Without them, this service looks in OpenVPN's
management interface when it can read server.conf. Its unit hides that file and allows no unix socket, so on a
server this tool installed, darban's five-minute check does that instead; when that misses a short connection, or
there is no interface, the link lasts until it expires. Until then the page and the file can be opened again, so a mistake on the phone costs nothing.
Opening the page never uses anything up: messengers fetch links for their previews.
Standard library only. The process ends by itself once no link is left. SIGHUP reads the certificate again:
new connections get the new one, and a download in progress finishes on the old one. While it runs, .serving
says so, with the source it runs, so darban adds a link without a restart, which would end a download in
progress; it takes that back, under the link lock, the moment it decides to end.
"""
import argparse
import contextlib
import fcntl
import hashlib
import html
import http.server
import ipaddress
import os
import re
import signal
import socket
import ssl
import stat
import sys
import threading
import time

TOKEN_RE = re.compile(r'^[0-9a-f]{64}$')
FIELD_RE = re.compile(r'^[a-z][a-z0-9_]{0,31}$')
KNOWN_FIELDS = ('name', 'expires', 'created', 'downloads')
EVENT_SCRIPT = '/usr/local/libexec/darban-ovpn-event'
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$')
PATH_RE = re.compile(r'^/l/([0-9a-f]{64})(/file)?$')
LANG_RE = re.compile(r'^\s*([A-Za-z]{1,8})(?:-[A-Za-z0-9]{1,8})*\s*(?:;\s*q\s*=\s*([0-9.]{1,5}))?\s*$')
LOCAL_ADDRESSES = ('127.0.0.1', 'localhost', '::1')
# What OpenVPN's port-share writes in each file: the address of the client it hands over, as [AF_INET]a.b.c.d:port.
SHARED_RE = re.compile(r'^\[AF_INET6?\]([0-9A-Fa-f.:]{2,45}):[0-9]{1,5}$')


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Store:
    def __init__(self, directory):
        self.directory = directory
        self.lock = threading.Lock()

    @contextlib.contextmanager
    def locked(self):
        """The threads of this service, and darban removing a link, take turns on the link files. Without the
        file lock, a download could write back the record of a link that darban was removing at that moment."""
        with self.lock:
            fd = os.open(os.path.join(self.directory, '.lock'), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                os.close(fd)

    def _path(self, key, suffix):
        return os.path.join(self.directory, key + suffix)

    def _read(self, key):
        try:
            with open(self._path(key, '.meta'), encoding='ascii') as handle:
                meta = dict(line.rstrip('\n').split('=', 1) for line in handle if '=' in line)
            meta['expires'] = int(meta['expires'])
            meta['created'] = int(meta.get('created', 0))
            meta['downloads'] = int(meta.get('downloads', 0))
        except (OSError, ValueError, KeyError):
            return None
        if not NAME_RE.match(meta.get('name', '')) or meta['expires'] <= time.time():
            return None
        return meta

    def _write(self, key, meta):
        """Writes the record back with every field it had: darban adds fields this version may not know, such as
        when a link was made by a clock NTP cannot move, and a download must not lose them."""
        temp = self._path(key, '.tmp')
        with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w', encoding='ascii') as handle:
            for field in KNOWN_FIELDS:
                handle.write(f'{field}={meta[field]}\n')
            for field, value in meta.items():
                if field not in KNOWN_FIELDS and FIELD_RE.match(field) and '\n' not in str(value):
                    handle.write(f'{field}={value}\n')
        os.replace(temp, self._path(key, '.meta'))

    def _drop(self, key):
        for suffix in ('.meta', '.ovpn', '.tmp', '.url'):
            try:
                os.unlink(self._path(key, suffix))
            except FileNotFoundError:
                pass

    def find(self, token):
        with self.locked():
            return self._read(token_hash(token))

    def take(self, token):
        """Returns the profile of a link and counts the download. The link stays until the first connection."""
        key = token_hash(token)
        with self.locked():
            meta = self._read(key)
            if not meta:
                return None, None
            try:
                with open(self._path(key, '.ovpn'), 'rb') as handle:
                    data = handle.read()
            except OSError:
                return None, None
            meta['downloads'] += 1
            self._write(key, meta)
            return meta['name'], data

    def end_connected(self, connected):
        """Removes each link whose client has connected since the link was made, and returns their names."""
        ended = []
        with self.locked():
            for entry in os.listdir(self.directory):
                if not entry.endswith('.meta'):
                    continue
                key = entry[:-len('.meta')]
                meta = self._read(key)
                if meta and connected.get(meta['name'], -1) >= meta['created']:
                    self._drop(key)
                    ended.append(meta['name'])
        return ended

    def leave_if_empty(self, serving):
        """True when no link is left, and then .serving is gone. darban writes a link, then reads .serving under
        the same lock: either this sees that link and stays, or .serving is gone and darban starts the service."""
        with self.locked():
            for entry in os.listdir(self.directory):
                if entry.endswith('.meta') and self._read(entry[:-len('.meta')]):
                    return False
            try:
                os.unlink(serving)
            except FileNotFoundError:
                pass
            return True

    def purge(self):
        """Removes what has expired and returns how many links remain."""
        with self.locked():
            remaining = 0
            now = time.time()
            for entry in os.listdir(self.directory):
                if entry.endswith(('.ovpn', '.tmp', '.url')):
                    # A link is written profile first, so a profile with no record for a while is left over.
                    path = os.path.join(self.directory, entry)
                    try:
                        if not os.path.exists(self._path(entry.rsplit('.', 1)[0], '.meta')) and now - os.path.getmtime(path) > 60:
                            os.unlink(path)
                    except FileNotFoundError:
                        pass
                    continue
                if not entry.endswith('.meta'):
                    continue
                key = entry[:-len('.meta')]
                if self._read(key):
                    remaining += 1
                else:
                    self._drop(key)
            return remaining


def events_on(server_conf, script=EVENT_SCRIPT):
    """True when server.conf runs darban's connection event script, by the same rule darban uses: one
    client-connect and one client-disconnect line, each with exactly that script. darban then ends a link at the
    first connection itself, and this service stays away from the management interface. Anything else, such as one
    of the two lines alone or another path, leaves the link service watching that interface as before."""
    try:
        with open(server_conf, encoding='utf-8', errors='replace') as handle:
            words = [line.split() for line in handle]
    except OSError:
        return False
    for directive in ('client-connect', 'client-disconnect'):
        lines = [w for w in words if w[:1] == [directive]]
        if len(lines) != 1 or lines[0] != [directive, script]:
            return False
    return True


def management_address(server_conf):
    """The management interface of server.conf: a unix socket path, or a localhost (host, port); else None."""
    try:
        with open(server_conf, encoding='utf-8', errors='replace') as handle:
            lines = [line.split() for line in handle if line.split()[:1] == ['management']]
    except OSError:
        return None
    if len(lines) != 1 or len(lines[0]) != 3:
        return None
    _, address, port = lines[0]
    if port == 'unix':
        return address if os.path.isabs(address) else os.path.join(os.path.dirname(server_conf), address)
    if address in LOCAL_ADDRESSES and port.isdigit():
        return (address, int(port))
    return None


def connected_clients(address, timeout=3):
    """Maps each connected client name to when its newest session began, or returns None if OpenVPN cannot say."""
    if address is None:
        return None
    try:
        if isinstance(address, str):
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        else:
            conn = socket.socket(socket.AF_INET6 if ':' in address[0] else socket.AF_INET, socket.SOCK_STREAM)
        with conn:
            conn.settimeout(timeout)
            conn.connect(address)
            conn.sendall(b'status 3\n')
            reply = b''
            deadline = time.time() + timeout
            while b'\nEND' not in reply and time.time() < deadline:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                reply += chunk
            # Quit only after the reply: OpenVPN drops the answer to a command that arrives together with it.
            try:
                conn.sendall(b'quit\n')
            except OSError:
                pass
    except OSError:
        return None
    if b'\nEND' not in reply:
        return None
    since = {}
    for line in reply.decode('utf-8', 'replace').splitlines():
        fields = line.split('\t')
        if len(fields) > 8 and fields[0] == 'CLIENT_LIST' and fields[8].isdigit():
            since[fields[1]] = max(since.get(fields[1], -1), int(fields[8]))
    return since


def language(header):
    """Persian when the language the device prefers most is Persian, English otherwise. q=0 means "not this one"."""
    best, best_q = 'en', 0.0
    for part in (header or '').split(',')[:20]:
        match = LANG_RE.match(part)
        if not match:
            continue
        try:
            q = float(match.group(2)) if match.group(2) else 1.0
        except ValueError:
            continue
        if q > best_q:
            best, best_q = match.group(1).lower(), q
    return 'fa' if best == 'fa' else 'en'


STYLE = """body{font-family:system-ui,sans-serif;background:#f4f5f7;color:#1c2024;margin:0;padding:24px}
main{max-width:30rem;margin:auto;background:#fff;border-radius:12px;padding:24px;box-shadow:0 1px 4px #0002}
h1{font-size:1.25rem;margin-top:0}li{margin:.5rem 0}
a.button{display:block;box-sizing:border-box;width:100%;padding:14px;margin:16px 0;border:0;border-radius:8px;
background:#1a5fb4;color:#fff;font-size:1rem;text-align:center;text-decoration:none}
p.small{font-size:.875rem;color:#555}
@media(prefers-color-scheme:dark){body{background:#17191c;color:#e6e8eb}main{background:#23262a}p.small{color:#aab}}"""

APPS = {
    'android': 'https://play.google.com/store/apps/details?id=net.openvpn.openvpn',
    'ios': 'https://apps.apple.com/app/openvpn-connect/id590379981',
    'desktop': 'https://openvpn.net/client/',
}

TEXT = {
    'en': {
        'title': 'VPN profile',
        'heading': 'VPN profile for {name}',
        'lasts': 'This link works until its time is up, or until a connection with this profile is seen, whichever '
                 'comes first. Until then you can open it again.',
        'install': '<a href="{app}">Install the OpenVPN Connect app</a>.',
        'download': 'Press <b>Download profile</b>, then open the downloaded file: it opens in OpenVPN Connect. '
                    'If it does not, open the app and import the file from your downloads.',
        'connect': 'In the app, press <b>Connect</b>.',
        'button': 'Download profile',
        'private': 'This file holds a private key. Do not share it.',
        'gone_heading': 'This link is no longer valid',
        'gone': 'Its time is up, it was cancelled, or a connection with this profile was already seen. '
                'If you did not connect yourself, tell the server administrator right away.',
    },
    'fa': {
        'title': 'پروفایل VPN',
        'heading': 'پروفایل VPN برای {name}',
        'lasts': 'این لینک تا پایان مهلتش کار می‌کند، یا تا وقتی که اتصالی با این پروفایل دیده شود؛ هر کدام زودتر باشد. '
                 'تا آن زمان می‌توانید دوباره بازش کنید.',
        'install': '<a href="{app}">برنامهٔ OpenVPN Connect را نصب کنید</a>.',
        'download': 'روی <b>دانلود پروفایل</b> بزنید و فایل دانلودشده را باز کنید تا در OpenVPN Connect باز شود. '
                    'اگر باز نشد، برنامه را باز کنید و فایل را از پوشهٔ دانلودها وارد کنید.',
        'connect': 'در برنامه روی <b>Connect</b> بزنید.',
        'button': 'دانلود پروفایل',
        'private': 'این فایل کلید خصوصی دارد. آن را برای کسی نفرستید.',
        'gone_heading': 'این لینک دیگر کار نمی‌کند',
        'gone': 'مهلت آن تمام شده، لغو شده، یا اتصالی با این پروفایل دیده شده است. '
                'اگر خودتان وصل نشده‌اید، فوراً به مدیر سرور خبر دهید.',
    },
}


def page(lang, body):
    direction = 'rtl' if lang == 'fa' else 'ltr'
    return (f'<!doctype html><html lang="{lang}" dir="{direction}"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<meta name="robots" content="noindex"><title>{TEXT[lang]["title"]}</title>'
            f'<style>{STYLE}</style></head><body><main>{body}</main></body></html>').encode()


def device(agent):
    agent = agent.lower()
    if 'android' in agent:
        return 'android'
    if 'iphone' in agent or 'ipad' in agent:
        return 'ios'
    return 'desktop'


def shared_address(directory, peer, tries=25, pause=0.02):
    """With port-share, OpenVPN hands this service each connection to its TCP port that is not OpenVPN, from
    127.0.0.1, and writes a file named by the address this service sees as its peer, which holds the client's real
    address. It is read while the connection is open, since OpenVPN removes it when the connection closes; it may
    come a moment after the connection, so it is looked for a few times. Only that file counts, never a header.
    None when there is no file, or it holds no address."""
    path = os.path.join(directory, '[AF_INET]%s:%d' % (peer[0], peer[1]))
    for _ in range(tries):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            time.sleep(pause)
            continue
        except OSError:
            return None
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return None
            data = os.read(fd, 128)
        except OSError:
            return None
        finally:
            os.close(fd)
        match = SHARED_RE.match(data.decode('ascii', 'replace').strip())
        if not match:
            # Not written whole yet: OpenVPN writes it right after the connection.
            time.sleep(pause)
            continue
        try:
            return str(ipaddress.ip_address(match.group(1)))
        except ValueError:
            return None
    return None


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'darban'
    sys_version = ''
    timeout = 15

    def log_message(self, *_):
        # The default log would write each path, and the paths hold the tokens.
        pass

    def _send(self, status, body, content_type='text/html; charset=utf-8', extra=()):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Robots-Tag', 'noindex')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'")
        self.send_header('Vary', 'Accept-Language, User-Agent')
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _lang(self):
        return language(self.headers.get('Accept-Language', ''))

    def _gone(self):
        # The same answer for used, expired and unknown links: it reveals nothing about any of them.
        text = TEXT[self._lang()]
        self._send(410, page(self._lang(), f'<h1>{text["gone_heading"]}</h1><p>{text["gone"]}</p>'))

    def do_GET(self):
        match = PATH_RE.match(self.path)
        if not match or not TOKEN_RE.match(match.group(1)):
            return self._gone()
        token, is_file = match.group(1), bool(match.group(2))
        store = self.server.store
        if is_file:
            name, data = store.take(token)
            if name is None:
                return self._gone()
            print(f'profile downloaded: {name} from {self.server.address_of(self.request, self.client_address)}', flush=True)
            return self._send(200, data, 'application/x-openvpn-profile',
                              [('Content-Disposition', f'attachment; filename="{name}.ovpn"')])
        meta = store.find(token)
        if not meta:
            return self._gone()
        lang = self._lang()
        text = TEXT[lang]
        app = APPS[device(self.headers.get('User-Agent', ''))]
        return self._send(200, page(lang,
            f'<h1>{text["heading"].format(name=html.escape(meta["name"]))}</h1>'
            f'<p>{text["lasts"]}</p><ol>'
            f'<li>{text["install"].format(app=app)}</li>'
            f'<li>{text["download"]}</li>'
            f'<li>{text["connect"]}</li></ol>'
            f'<a class="button" href="/l/{token}/file">{text["button"]}</a>'
            f'<p class="small">{text["private"]}</p>'))

    def do_POST(self):
        self._gone()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    context = None
    # Each connection has a thread of its own, and the unit allows 64 tasks. A client that sends its request a byte at
    # a time keeps its thread, so without a limit one address could hold them all and no link would open for anyone.
    per_address = 8
    # With port-share: the folder of OpenVPN's files, which give the real address of a connection it hands over.
    port_share_dir = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.open_from = {}
        self.counted = {}
        self.count_lock = threading.Lock()

    def _shared(self, client_address):
        return self.port_share_dir is not None and client_address[0] == '127.0.0.1'

    def _count(self, request, address):
        with self.count_lock:
            if self.open_from.get(address, 0) >= self.per_address:
                return False
            self.open_from[address] = self.open_from.get(address, 0) + 1
            self.counted[id(request)] = address
        return True

    def address_of(self, request, client_address):
        """The address a connection is counted for: the real one of a client OpenVPN handed over, else the peer."""
        with self.count_lock:
            return self.counted.get(id(request), client_address[0])

    def verify_request(self, request, client_address):
        # A connection OpenVPN hands over is counted in its own thread, once its file is read: the accept loop never
        # waits for it.
        if self._shared(client_address):
            return True
        return self._count(request, client_address[0])

    def process_request_thread(self, request, client_address):
        if self._shared(client_address):
            address = shared_address(self.port_share_dir, client_address) or client_address[0]
            if not self._count(request, address):
                self.shutdown_request(request)
                return
        super().process_request_thread(request, client_address)

    def shutdown_request(self, request):
        # Also called for a connection verify_request refused, which was never counted.
        with self.count_lock:
            address = self.counted.pop(id(request), None)
            if address is not None:
                left = self.open_from.get(address, 1) - 1
                if left > 0:
                    self.open_from[address] = left
                else:
                    self.open_from.pop(address, None)
        super().shutdown_request(request)

    def get_request(self):
        # Each connection is wrapped with the certificate of the moment, so a reload reaches the next one. The
        # handshake waits for the first read inside a handler thread, under its timeout, so one stalled client
        # cannot hold up the accept loop.
        sock, address = self.socket.accept()
        try:
            return self.context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), address
        except (OSError, ValueError):
            sock.close()
            raise

    def handle_error(self, *_):
        # Failed TLS handshakes from scanners are routine here; a traceback could also echo a path.
        pass


def watch(server, store, idle_exit, interval, management, serving):
    idle_since = None
    while True:
        time.sleep(interval)
        if store.purge() > 0:
            idle_since = None
            connected = connected_clients(management)
            if connected:
                for name in store.end_connected(connected):
                    print(f'link ended: {name} connected', flush=True)
        elif idle_since is None:
            idle_since = time.time()
        elif idle_exit and time.time() - idle_since >= idle_exit:
            if store.leave_if_empty(serving):
                server.shutdown()
                return
            idle_since = None


def pair_paths(cert, key):
    """The certificate and key of one pair. darban keeps each pair in a folder of its own and points the names
    through a link it changes in one rename, so the folder is found once and both files are read from it: a change
    between the two reads cannot give the certificate of one pair with the key of another. Other files are read as
    they are named."""
    real = os.path.realpath(cert)
    folder = os.path.dirname(real)
    if os.path.basename(real) == 'fullchain.pem' and os.path.isfile(os.path.join(folder, 'privkey.pem')):
        return real, os.path.join(folder, 'privkey.pem')
    return cert, key


def tls_context(cert, key):
    cert, key = pair_paths(cert, key)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context


def reload_on_hangup(server, cert, key, marker):
    """SIGHUP puts a new certificate in place for new connections; one that does not load leaves the old one."""
    def reload(*_):
        try:
            server.context = tls_context(cert, key)
            print('certificate reloaded', flush=True)
        except (OSError, ssl.SSLError) as error:
            print(f'certificate not reloaded, the previous one stays: {error}', flush=True)
    signal.signal(signal.SIGHUP, reload)
    # darban reloads only a process that says it can: an older one would end on SIGHUP.
    try:
        with open(marker, 'w') as handle:
            handle.write(f'{os.getpid()}\n')
    except OSError:
        pass


def say_serving(serving):
    """Writes .serving: this process, and the source it runs, so darban counts on it only while that source is
    the one installed. After an update the next link starts the new one."""
    source = os.path.realpath(__file__)
    try:
        with open(source, 'rb') as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        with open(serving, 'w', encoding='utf-8') as handle:
            handle.write(f'{os.getpid()}\n{digest}\n{source}\n')
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dir', required=True)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    # The address in the links. The pages use relative paths, so it is only accepted, for the service's command line.
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--server-conf', default='/etc/openvpn/server/server.conf')
    # 0: never ends by itself, while port-share sends the TCP port of OpenVPN here.
    parser.add_argument('--idle-exit', type=int, default=60)
    parser.add_argument('--bind', default='0.0.0.0', choices=('0.0.0.0', '127.0.0.1'))
    parser.add_argument('--port-share-dir', default='')
    parser.add_argument('--interval', type=float, default=10)
    parser.add_argument('--event-script', default=EVENT_SCRIPT)
    args = parser.parse_args()

    store = Store(args.dir)
    server = Server((args.bind, args.port), Handler)
    # The files of OpenVPN count only for a service that only OpenVPN reaches.
    if args.port_share_dir and args.bind == '127.0.0.1':
        server.port_share_dir = args.port_share_dir
    server.store = store
    server.context = tls_context(args.cert, args.key)
    reload_on_hangup(server, args.cert, args.key, os.path.join(args.dir, '.reloadable'))
    management = None if events_on(args.server_conf, args.event_script) else management_address(args.server_conf)
    serving = os.path.join(args.dir, '.serving')
    say_serving(serving)
    threading.Thread(target=watch, args=(server, store, args.idle_exit, args.interval, management, serving), daemon=True).start()
    print(f'listening on TCP {args.bind}:{args.port}' + (', behind OpenVPN port-share' if server.port_share_dir else ''), flush=True)
    server.serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main())
