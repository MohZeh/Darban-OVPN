#!/usr/bin/env python3
"""A request that waits half sent, for the tests of the link service.

    held-request.py <link url> <go file>

Opens a TLS connection to <link url> and sends the first line of a request for it. It then creates <go file>.ready
and waits, up to 60 seconds, for <go file>. Then it sends the rest and prints the answer. A service restarted in
the meantime has dropped the connection, so there is no answer. Exits 0 for an answer of 200, else 1.
"""
import os
import socket
import ssl
import sys
import time
import urllib.parse


def main():
    url, go = sys.argv[1], sys.argv[2]
    parts = urllib.parse.urlsplit(url)
    host, port = parts.hostname, parts.port or 443
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    answer = b''
    try:
        with socket.create_connection((host, port), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname=host) as conn:
                conn.sendall(f'GET {parts.path} HTTP/1.0\r\n'.encode())
                open(go + '.ready', 'w').close()
                stop = time.time() + 60
                while not os.path.exists(go) and time.time() < stop:
                    time.sleep(0.1)
                conn.sendall(f'Host: {host}\r\n\r\n'.encode())
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    answer += chunk
    except OSError as error:
        print(f'no answer: {error}', flush=True)
    sys.stdout.write(answer.decode('utf-8', 'replace'))
    return 0 if answer.startswith(b'HTTP/1.0 200') else 1


if __name__ == '__main__':
    sys.exit(main())
