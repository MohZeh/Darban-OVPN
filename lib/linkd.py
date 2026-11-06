#!/usr/bin/env python3
"""Serves temporary, one-time links to client profiles over HTTPS.

A link file is <sha256 of token>.meta plus <same>.ovpn in the store directory, so a token never rests on
disk. Opening a link only shows a page: messengers fetch links for previews, and that must not use it up.
Pressing the button claims the link once and moves the profile behind a second, short-lived address.
Standard library only. The process ends by itself once no link is left.
"""
import argparse
import hashlib
import html
import http.server
import os
import re
import secrets
import ssl
import sys
import threading
import time

CLAIM_SECONDS = 600
CLAIM_DOWNLOADS = 3
TOKEN_RE = re.compile(r'^[0-9a-f]{64}$')
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$')
PATH_RE = re.compile(r'^/(l|c)/([0-9a-f]{64})(/file)?$')


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
            meta['uses'] = int(meta.get('uses', 1))
        except (OSError, ValueError, KeyError):
            return None
        if not NAME_RE.match(meta.get('name', '')) or meta['expires'] <= time.time():
            return None
        return meta

    def _write(self, key, meta):
        temp = self._path(key, '.tmp')
        with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w', encoding='ascii') as handle:
            for field in ('name', 'expires', 'created', 'state', 'uses'):
                handle.write(f'{field}={meta[field]}\n')
        os.replace(temp, self._path(key, '.meta'))

    def _drop(self, key):
        for suffix in ('.meta', '.ovpn', '.tmp'):
            try:
                os.unlink(self._path(key, suffix))
            except FileNotFoundError:
                pass

    def waiting(self, token):
        with self.lock:
            meta = self._read(token_hash(token))
        return meta if meta and meta.get('state') == 'waiting' else None

    def claimed(self, token):
        with self.lock:
            meta = self._read(token_hash(token))
        return meta if meta and meta.get('state') == 'claimed' else None

    def claim(self, token):
        """Uses up a waiting link once and returns the token of its short-lived address."""
        key = token_hash(token)
        with self.lock:
            meta = self._read(key)
            if not meta or meta.get('state') != 'waiting':
                return None, None
            second = secrets.token_hex(32)
            new_key = token_hash(second)
            os.replace(self._path(key, '.ovpn'), self._path(new_key, '.ovpn'))
            self._write(new_key, {'name': meta['name'], 'expires': int(time.time()) + CLAIM_SECONDS,
                                  'created': meta.get('created', '0'), 'state': 'claimed', 'uses': CLAIM_DOWNLOADS})
            self._drop(key)
            return second, meta['name']

    def take(self, token):
        """Returns the profile of a claimed link and counts the download."""
        key = token_hash(token)
        with self.lock:
            meta = self._read(key)
            if not meta or meta.get('state') != 'claimed' or meta['uses'] < 1:
                return None, None
            with open(self._path(key, '.ovpn'), 'rb') as handle:
                data = handle.read()
            meta['uses'] -= 1
            if meta['uses'] < 1:
                self._drop(key)
            else:
                self._write(key, meta)
            return meta['name'], data

    def purge(self):
        """Removes what has expired and returns how many links remain."""
        with self.lock:
            remaining = 0
            for entry in os.listdir(self.directory):
                if not entry.endswith('.meta'):
                    continue
                key = entry[:-len('.meta')]
                if self._read(key):
                    remaining += 1
                else:
                    self._drop(key)
            return remaining


STYLE = """body{font-family:system-ui,sans-serif;background:#f4f5f7;color:#1c2024;margin:0;padding:24px}
main{max-width:30rem;margin:auto;background:#fff;border-radius:12px;padding:24px;box-shadow:0 1px 4px #0002}
h1{font-size:1.25rem;margin-top:0}.fa{direction:rtl;text-align:right;margin-bottom:1.5rem}
a.button,button{display:block;box-sizing:border-box;width:100%;padding:14px;margin:12px 0;border:0;border-radius:8px;
background:#1a5fb4;color:#fff;font-size:1rem;text-align:center;text-decoration:none;cursor:pointer}
a.other{background:#e8eaed;color:#1c2024}p.small{font-size:.875rem;color:#555}
@media(prefers-color-scheme:dark){body{background:#17191c;color:#e6e8eb}main{background:#23262a}
a.other{background:#363a40;color:#e6e8eb}p.small{color:#aab}}"""


def page(body):
    return ('<!doctype html><html><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta name="robots" content="noindex"><title>VPN profile</title>'
            f'<style>{STYLE}</style></head><body><main>{body}</main></body></html>').encode()


GONE = page('<div class="fa"><h1>این لینک دیگر معتبر نیست</h1><p>منقضی شده یا قبلاً استفاده شده است. '
            'اگر خودت از آن استفاده نکرده‌ای، فوراً به مدیر سرور خبر بده.</p></div>'
            '<h1>This link is no longer valid</h1><p>It has expired or was already used. '
            'If you did not use it yourself, tell the server administrator right away.</p>')


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
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _gone(self):
        # The same answer for used, expired and unknown links: it reveals nothing about any of them.
        self._send(410, GONE)

    def _route(self):
        match = PATH_RE.match(self.path)
        if not match or not TOKEN_RE.match(match.group(2)):
            return None, None, None
        return match.group(1), match.group(2), bool(match.group(3))

    def do_GET(self):
        kind, token, is_file = self._route()
        store = self.server.store
        if kind == 'l' and not is_file:
            meta = store.waiting(token)
            if not meta:
                return self._gone()
            name = html.escape(meta['name'])
            return self._send(200, page(
                f'<div class="fa"><h1>پروفایل VPN برای {name}</h1>'
                '<p>این لینک فقط یک‌بار کار می‌کند. وقتی آماده بودی، دکمه را بزن.</p></div>'
                f'<h1>VPN profile for {name}</h1><p>This link works once. Press the button when you are ready.</p>'
                '<form method="post"><button type="submit">دریافت پروفایل / Get my profile</button></form>'))
        if kind == 'c' and not is_file:
            meta = store.claimed(token)
            if not meta:
                return self._gone()
            url = f'https://{self.server.public_host}/c/{token}/file'
            return self._send(200, page(
                '<div class="fa"><h1>پروفایل آماده است</h1><p>تا ۱۰ دقیقه می‌توانی آن را بگیری. '
                'اگر اپ OpenVPN Connect باز نشد، فایل را دانلود کن و داخل اپ وارد کن.</p></div>'
                '<h1>Your profile is ready</h1><p>Available for 10 minutes. If OpenVPN Connect does not open, '
                'download the file and import it in the app.</p>'
                f'<a class="button" href="openvpn://import-profile/{html.escape(url)}">OpenVPN Connect</a>'
                f'<a class="button other" href="/c/{token}/file">دانلود فایل / Download .ovpn</a>'
                '<p class="small">این فایل کلید خصوصی دارد؛ آن را منتشر نکن. '
                'This file holds a private key; do not share it.</p>'))
        if kind == 'c' and is_file:
            name, data = store.take(token)
            if name is None:
                return self._gone()
            print(f'profile downloaded: {name} from {self.client_address[0]}', flush=True)
            return self._send(200, data, 'application/x-openvpn-profile',
                              [('Content-Disposition', f'attachment; filename="{name}.ovpn"')])
        return self._gone()

    def do_POST(self):
        kind, token, is_file = self._route()
        if kind != 'l' or is_file:
            return self._gone()
        second, name = self.server.store.claim(token)
        if not second:
            return self._gone()
        print(f'link used: {name} from {self.client_address[0]}', flush=True)
        return self._send(303, b'', extra=[('Location', f'/c/{second}')])


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        # Failed TLS handshakes from scanners are routine here; a traceback could also echo a path.
        pass


def watch(server, store, idle_exit, interval):
    idle_since = None
    while True:
        time.sleep(interval)
        if store.purge() > 0:
            idle_since = None
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
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--idle-exit', type=int, default=60)
    parser.add_argument('--interval', type=float, default=10)
    args = parser.parse_args()

    store = Store(args.dir)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server = Server(('0.0.0.0', args.port), Handler)
    server.store = store
    server.public_host = args.host if args.port == 443 else f'{args.host}:{args.port}'
    # The handshake waits for the first read inside a handler thread, under its timeout, so one
    # stalled client cannot hold up the accept loop.
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=watch, args=(server, store, args.idle_exit, args.interval), daemon=True).start()
    print(f'listening on TCP {args.port}', flush=True)
    server.serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main())
