#!/usr/bin/env python3
"""Slow clients against the link service, for the acceptance test.

    slow-clients.py <link url> <connections> <seconds>

Opens up to <connections> TLS connections from 127.0.0.1, each sending its request one byte every five seconds
for <seconds>, so none of them ever finishes. Meanwhile a person opens <link url> from 127.0.0.2. Prints how many
connections were held, and exits 0 when the page still opened, 1 when it did not.
"""
import socket
import ssl
import sys
import threading
import time
import urllib.parse


def connect(context, host, port, source):
    raw = socket.create_connection((host, port), timeout=10, source_address=(source, 0))
    return context.wrap_socket(raw, server_hostname=host)


def main():
    url, count, seconds = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
    parts = urllib.parse.urlsplit(url)
    host, port = parts.hostname, parts.port or 443
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    held = []
    for _ in range(count):
        try:
            conn = connect(context, host, port, '127.0.0.1')
            conn.sendall(b'GET /l/')
            held.append(conn)
        except OSError:
            break
    stop = time.time() + seconds

    def drip():
        while time.time() < stop:
            for conn in list(held):
                try:
                    conn.sendall(b'0')
                except OSError:
                    held.remove(conn)
            time.sleep(5)

    threading.Thread(target=drip, daemon=True).start()
    time.sleep(3)
    opened = False
    try:
        with connect(context, host, port, '127.0.0.2') as conn:
            conn.settimeout(10)
            conn.sendall(f'GET {parts.path} HTTP/1.0\r\nHost: {host}\r\n\r\n'.encode())
            opened = conn.recv(64).startswith(b'HTTP/1.0 200')
    except OSError:
        opened = False
    print(f'held {len(held)} slow connections; the page opened: {"yes" if opened else "no"}', flush=True)
    for conn in held:
        conn.close()
    return 0 if opened else 1


if __name__ == '__main__':
    sys.exit(main())
