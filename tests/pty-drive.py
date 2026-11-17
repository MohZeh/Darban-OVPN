#!/usr/bin/env python3
"""Runs a command in a real terminal, answering it as a person would.

    pty-drive.py [--timeout SECONDS] SCRIPT -- COMMAND...

Each line of SCRIPT is "text to wait for => keys to press". In keys, \\r is Enter and \\e is Esc; an empty
right side only waits. {Label} in keys is the number the screen shows for the option that starts with Label, as
in "Choose [0-9] => {Share a profile}\\r", so a script does not break when a list changes order. The option must be
on the screen this step waited through, or the step fails as a text that did not appear does.

Where a step looks: after keys were pressed, only in what the command showed since then, so a screen from
before the keys never answers a step. After a step that pressed nothing, right after the text it matched, so
two texts that arrive in one read are both found. Prints everything the command showed, without colors. The exit status is the
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
# A numbered option as menus and choices show it: "    5  Share a profile", or " ❯ 2  Create a client".
OPTION = re.compile(r'^\s*(?:[❯>]\s*)?(\d+)\s{2,}(\S.*?)\s*$')
LABEL = re.compile(r'\{([^{}]+)\}')


def option_number(label, shown):
    """The number of the option in shown that label names, or None, with why. An option whose text is label wins;
    otherwise the one that starts with it. Two different options that both start with it are ambiguous, so the
    step fails rather than choose one of them."""
    found = [(match.group(1), match.group(2)) for line in ANSI.sub('', shown).replace('\r', '').split('\n')
             if (match := OPTION.match(line)) and match.group(2).startswith(label)]
    exact = [number for number, text in found if text == label]
    if exact:
        return exact[-1], ''
    texts = sorted({text for _, text in found})
    if len(texts) > 1:
        return None, 'more than one option on the screen starts with: ' + label + ' (' + '; '.join(texts) + ')'
    if not found:
        return None, 'no option on the screen starts with: ' + label
    return found[-1][0], ''


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

    def find(text, start):
        """Where text ends in seen, searching from start and ignoring colors; -1 when it is not there yet."""
        segment = seen[start:]
        plain, raw_at = '', []
        position = 0
        for match in ANSI.finditer(segment):
            for offset in range(position, match.start()):
                plain += segment[offset]
                raw_at.append(offset)
            position = match.end()
        for offset in range(position, len(segment)):
            plain += segment[offset]
            raw_at.append(offset)
        found = plain.find(text)
        if found < 0:
            return -1
        return start + raw_at[found + len(text) - 1] + 1

    start = 0
    for step in steps:
        text, keys = step[0], step[1] if len(step) > 1 else ''
        step_from = start
        end = time.time() + timeout
        while (found := find(text, start)) < 0:
            if time.time() > end or not read_some(0.1):
                if (found := find(text, start)) >= 0:
                    break
                print(f'pty-drive: did not see: {text}', file=sys.stderr)
                show()
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                return 3
        start = found
        # The prompts ignore keys pressed before they were visible, so give them a moment to appear fully.
        time.sleep(0.25)
        read_some(0)
        for label in LABEL.findall(keys):
            number, why = option_number(label, seen[step_from:])
            if number is None:
                print(f'pty-drive: {why}', file=sys.stderr)
                show()
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                return 3
            keys = keys.replace('{' + label + '}', number, 1)
        if keys:
            # What the keys cause comes after this point; nothing shown before it may answer the next step.
            start = len(seen)
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
