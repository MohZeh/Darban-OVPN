#!/usr/bin/env python3
"""Serves temporary links to client profiles over HTTPS.

A link file is <sha256 of token>.meta plus <same>.ovpn in the store directory, so a token never rests on
disk. A link works until the client it was made for connects to the VPN for the first time, or until it
expires, whichever comes first. Until then the page and the file can be opened again, so a mistake on the
phone costs nothing. Opening the page never uses anything up: messengers fetch links for their previews.
Standard library only. The process ends by itself once no link is left.
"""
import argparse
import hashlib
import html
import http.server
import os
import re
import socket
import ssl
import sys
import threading
import time

TOKEN_RE = re.compile(r'^[0-9a-f]{64}$')
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$')
PATH_RE = re.compile(r'^/l/([0-9a-f]{64})(/file)?$')
LANG_RE = re.compile(r'^\s*([A-Za-z]{1,8})(?:-[A-Za-z0-9]{1,8})*\s*(?:;\s*q\s*=\s*([0-9.]{1,5}))?\s*$')
LOCAL_ADDRESSES = ('127.0.0.1', 'localhost', '::1')


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Store:
    def __init__(self, directory):
        self.directory = directory
        self.lock = threading.Lock()

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
        temp = self._path(key, '.tmp')
        with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w', encoding='ascii') as handle:
            for field in ('name', 'expires', 'created', 'downloads'):
                handle.write(f'{field}={meta[field]}\n')
        os.replace(temp, self._path(key, '.meta'))

    def _drop(self, key):
        for suffix in ('.meta', '.ovpn', '.tmp'):
            try:
                os.unlink(self._path(key, suffix))
            except FileNotFoundError:
                pass

    def find(self, token):
        with self.lock:
            return self._read(token_hash(token))

    def take(self, token):
        """Returns the profile of a link and counts the download. The link stays until the first connection."""
        key = token_hash(token)
        with self.lock:
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
        with self.lock:
            for entry in os.listdir(self.directory):
                if not entry.endswith('.meta'):
                    continue
                key = entry[:-len('.meta')]
                meta = self._read(key)
                if meta and connected.get(meta['name'], -1) >= meta['created']:
                    self._drop(key)
                    ended.append(meta['name'])
        return ended

    def purge(self):
        """Removes what has expired and returns how many links remain."""
        with self.lock:
            remaining = 0
            now = time.time()
            for entry in os.listdir(self.directory):
                if entry.endswith(('.ovpn', '.tmp')):
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
    """Persian when the device asks for it first, English otherwise."""
    best, best_q = 'en', -1.0
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
        'lasts': 'This link works until your device connects to the VPN for the first time. Until then you can open it again.',
        'install': '<a href="{app}">Install the OpenVPN Connect app</a>.',
        'download': 'Press <b>Download profile</b>, then open the downloaded file: it opens in OpenVPN Connect. '
                    'If it does not, open the app and import the file from your downloads.',
        'connect': 'In the app, press <b>Connect</b>.',
        'button': 'Download profile',
        'private': 'This file holds a private key. Do not share it.',
        'gone_heading': 'This link is no longer valid',
        'gone': 'It has expired or was cancelled, or the device it was made for has already connected. '
                'If you did not connect yourself, tell the server administrator right away.',
    },
    'fa': {
        'title': 'پروفایل VPN',
        'heading': 'پروفایل VPN برای {name}',
        'lasts': 'این لینک تا اولین باری که دستگاهت به VPN وصل شود کار می‌کند. تا آن موقع می‌توانی دوباره بازش کنی.',
        'install': '<a href="{app}">اپ OpenVPN Connect را نصب کن</a>.',
        'download': 'دکمهٔ <b>دریافت پروفایل</b> را بزن و بعد فایل دانلودشده را باز کن؛ در OpenVPN Connect باز می‌شود. '
                    'اگر باز نشد، اپ را باز کن و فایل را از پوشهٔ دانلودها وارد کن.',
        'connect': 'در اپ، <b>Connect</b> را بزن.',
        'button': 'دریافت پروفایل',
        'private': 'این فایل کلید خصوصی دارد. آن را به کسی نده.',
        'gone_heading': 'این لینک دیگر معتبر نیست',
        'gone': 'منقضی یا لغو شده، یا دستگاهی که برایش ساخته شده بود قبلاً وصل شده است. '
                'اگر خودت وصل نشده‌ای، فوراً به مدیر سرور خبر بده.',
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
            print(f'profile downloaded: {name} from {self.client_address[0]}', flush=True)
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

    def handle_error(self, *_):
        # Failed TLS handshakes from scanners are routine here; a traceback could also echo a path.
        pass


def watch(server, store, idle_exit, interval, management):
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
        elif time.time() - idle_since >= idle_exit:
            server.shutdown()
            return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dir', required=True)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    # The address in the links. The pages use relative paths, so it is only accepted, for the service's command line.
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--server-conf', default='/etc/openvpn/server/server.conf')
    parser.add_argument('--idle-exit', type=int, default=60)
    parser.add_argument('--interval', type=float, default=10)
    args = parser.parse_args()

    store = Store(args.dir)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server = Server(('0.0.0.0', args.port), Handler)
    server.store = store
    # The handshake waits for the first read inside a handler thread, under its timeout, so one
    # stalled client cannot hold up the accept loop.
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    management = management_address(args.server_conf)
    threading.Thread(target=watch, args=(server, store, args.idle_exit, args.interval, management), daemon=True).start()
    print(f'listening on TCP {args.port}', flush=True)
    server.serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main())
