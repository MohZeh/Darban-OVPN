#!/usr/bin/env python3
"""Seconds from starting a command in a real terminal until a text appears on its screen.

    time-to-text.py TIMEOUT TEXT KEYS -- COMMAND...

Prints the seconds, with three decimals, on a line of its own, then presses KEYS (\\r is Enter) and waits for
the command to end. What the command showed goes to SCREEN_LOG when that is set. The exit status is 0, or 3 if
the text did not appear in TIMEOUT seconds or the command did not end within TIMEOUT seconds of the keys.
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
    separator = args.index('--')
    timeout, text, keys = float(args[0]), args[1], args[2]
    command = args[separator + 1:]

    master, slave = pty.openpty()
    # 24 rows of 120 columns, as tests/pty-drive.py uses.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x18\x00\x78\x00\x00\x00\x00\x00')
    env = dict(os.environ, TERM='xterm-256color')
    started = time.monotonic()
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

    def finish(status):
        if os.environ.get('SCREEN_LOG'):
            with open(os.environ['SCREEN_LOG'], 'w', encoding='utf-8') as log:
                log.write(ANSI.sub('', seen).replace('\r', ''))
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        return status

    while text not in ANSI.sub('', seen):
        if time.monotonic() - started > timeout or not read_some(0.05):
            if text in ANSI.sub('', seen):
                break
            print(f'time-to-text: did not see: {text}', file=sys.stderr)
            return finish(3)
    print(f'{time.monotonic() - started:.3f}', flush=True)
    # The prompts ignore keys pressed before they were visible, so give them a moment to appear fully.
    time.sleep(0.25)
    read_some(0)
    os.write(master, keys.replace('\\r', '\r').encode())
    end = time.monotonic() + timeout
    while proc.poll() is None and time.monotonic() < end:
        read_some(0.1)
    if proc.poll() is None:
        print('time-to-text: the command did not finish', file=sys.stderr)
        return finish(3)
    while read_some(0.05) and select.select([master], [], [], 0)[0]:
        pass
    return finish(0)


if __name__ == '__main__':
    sys.exit(main())
