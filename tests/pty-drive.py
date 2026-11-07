#!/usr/bin/env python3
"""Runs a command in a real terminal, answering it as a person would.

    pty-drive.py [--timeout SECONDS] SCRIPT -- COMMAND...

Each line of SCRIPT is "text to wait for => keys to press". In keys, \\r is Enter and \\e is Esc; an empty
right side only waits. Prints everything the command showed, without colors. The exit status is the
command's own, or 3 if an expected text did not appear in time.
"""
import fcntl
import os
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time

ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def main():
    args = sys.argv[1:]
    timeout = 60.0
    if args[:1] == ['--timeout']:
        timeout = float(args[1])
        args = args[2:]
    separator = args.index('--')
    with open(args[0], encoding='utf-8') as handle:
        steps = [line.rstrip('\n').split(' => ', 1) for line in handle if line.strip()]
    command = args[separator + 1:]

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x18\x00\x78\x00\x00\x00\x00\x00')
    env = dict(os.environ, TERM='xterm-256color')
    proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
                            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    seen = ''

    def read_some(wait):
        nonlocal seen
        ready, _, _ = select.select([master], [], [], wait)
        if not ready:
            return True
        try:
            data = os.read(master, 65536)
        except OSError:
            return False
        if not data:
            return False
        seen += data.decode('utf-8', 'replace')
        return True

    def show():
        print(ANSI.sub('', seen).replace('\r', ''))

    start = 0
    for step in steps:
        text, keys = step[0], step[1] if len(step) > 1 else ''
        end = time.time() + timeout
        while ANSI.sub('', seen[start:]).find(text) < 0:
            if time.time() > end or not read_some(0.1):
                if ANSI.sub('', seen[start:]).find(text) >= 0:
                    break
                print(f'pty-drive: did not see: {text}', file=sys.stderr)
                show()
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                return 3
        start = len(seen)
        # The prompts ignore keys pressed before they were visible, so give them a moment to appear fully.
        time.sleep(0.25)
        read_some(0)
        if keys:
            os.write(master, keys.replace('\\r', '\r').replace('\\e', '\x1b').encode())

    end = time.time() + timeout
    while proc.poll() is None and time.time() < end:
        read_some(0.1)
    while read_some(0.1) and select.select([master], [], [], 0)[0]:
        pass
    show()
    if proc.poll() is None:
        print('pty-drive: the command did not finish', file=sys.stderr)
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        return 3
    return proc.returncode


if __name__ == '__main__':
    sys.exit(main())
