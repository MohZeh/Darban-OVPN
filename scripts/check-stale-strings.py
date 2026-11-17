#!/usr/bin/env python3
"""Finds tests that still expect screen text the code no longer has. It reads files; it runs no test.

1. Every quoted text this change removed from bin/, lib/ or setup/ that a test still contains, while the code no
   longer does. This needs the commit the change starts from: python3 scripts/check-stale-strings.py <base>
2. Every "Enter: <label> =>" answer in the scripted terminal tests whose label is nowhere in the code.

The tests are the four that hold screen text: tests/run-tests.sh, tests/run-tty-tests.py, tests/pty-drive.py and
the key scripts in tests/acceptance-ci.sh. Without a base, or with one this clone does not have, only part 2 runs.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
QUOTED = re.compile(r"""'([^'\n]{12,})'|"([^"\n]{12,})\"""")
ENTER = re.compile(r'Enter: (.+?) =>')


def read(paths):
    return '\n'.join(p.read_text(encoding='utf-8', errors='replace') for p in paths)


def literal_parts(text):
    # The fixed pieces of a quoted text: a variable or a command substitution splits it.
    for part in re.split(r'\$\(.*?\)|\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\\n|%s', text):
        part = part.strip()
        if len(part) >= 12 and ' ' in part and re.search(r'[A-Za-z]{3}', part):
            yield part


def removed_texts(base):
    """The quoted texts the change removed, or None when there is no base to compare with."""
    if not base or re.fullmatch(r'0+', base):
        return None
    diff = subprocess.run(['git', '-C', str(ROOT), 'diff', '--unified=0', f'{base}...HEAD', '--', 'bin', 'lib', 'setup'],
                          capture_output=True, text=True, encoding='utf-8')
    if diff.returncode != 0:
        print(f'No commit {base} in this clone to compare with: only the scripted answers are checked.')
        return None
    found = set()
    for line in diff.stdout.splitlines():
        if line.startswith('-') and not line.startswith('---'):
            for match in QUOTED.finditer(line):
                found.update(literal_parts(match.group(1) or match.group(2)))
    return found


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else ''
    code = read(p for d in ('bin', 'lib', 'setup', 'systemd') for p in sorted((ROOT / d).glob('*')) if p.is_file())
    tests = read(sorted(p for p in (ROOT / 'tests').glob('*') if p.suffix in ('.sh', '.py')))
    removed = removed_texts(base)
    stale = sorted(t for t in removed or () if t not in code and t in tests)
    labels = sorted({m.group(1) for m in ENTER.finditer(tests)
                     if '$' not in m.group(1) and m.group(1) not in code and m.group(1).split(' ')[0] != 'Install'})
    for text in stale:
        print(f'ERROR: removed from the code, still in a test: {text!r}', file=sys.stderr)
    for label in labels:
        print(f'ERROR: a scripted answer for a label the code does not have: Enter: {label}', file=sys.stderr)
    compared = 'no base to compare with' if removed is None else f'{len(removed)} removed text(s) compared'
    print(f'Stale test text: {compared}, {len(stale) + len(labels)} problem(s).')
    if stale or labels:
        print('Also check option numbers in menu() answers and key scripts, when a list changed order or length.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
