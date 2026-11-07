#!/usr/bin/env python3
"""Fast repository checks: file modes, line endings, documentation links and documented commands.

Run from anywhere inside the repository: python3 scripts/check-repo.py
"""
import pathlib
import re
import subprocess
import sys

EXECUTABLE = re.compile(r'^(setup/.*\.sh|bin/[^/]+|scripts/[^/]+|tests/.*\.(sh|py)|docs/assets/render\.sh)$')
BINARY = ('.png', '.jpg', '.gif', '.gz', '.ico')
LINK = re.compile(r'\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
HTML_LINK = re.compile(r'(?:src|srcset|href)="([^"]+)"')
HEADING = re.compile(r'^#{1,6}\s+(.+?)\s*$')
COMMAND = re.compile(r'\bsudo darban ([a-z][a-z-]*)')
USAGE_COMMAND = re.compile(r'^  ([a-z][a-z-]*)\s')


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, text=True, encoding='utf-8').stdout


def slug(heading):
    # The same idea as GitHub's heading anchors. A zero-width non-joiner does not change the meaning.
    text = re.sub(r'[`*]', '', heading).strip().lower()
    text = re.sub(r'\[([^]]*)\]\([^)]*\)', r'\1', text).replace('‌', '')
    return re.sub(r'[^\w\- ]', '', text).replace(' ', '-')


def prose_lines(text):
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith('```'):
            fenced = not fenced
        elif not fenced:
            yield line


def anchors(path):
    return {slug(match.group(1)) for line in prose_lines(path.read_text(encoding='utf-8'))
            if (match := HEADING.match(line))}


def documented_commands(root):
    usage = root / 'bin/darban'
    if not usage.exists():
        return None
    block = usage.read_text(encoding='utf-8').split('Commands:\n', 1)[-1].split('Options:\n', 1)[0]
    return {match.group(1) for line in block.splitlines() if (match := USAGE_COMMAND.match(line))}


def main():
    root = pathlib.Path(git('rev-parse', '--show-toplevel').strip())
    problems = []
    entries = [line.split('\t', 1) for line in git('-c', 'core.quotepath=false', 'ls-files', '-s').splitlines()]
    tracked = {path: meta.split()[0] for meta, path in entries}

    for path, mode in tracked.items():
        if EXECUTABLE.match(path) and mode != '100755':
            problems.append(f'{path}: must be executable (git add --chmod=+x)')
        file = root / path
        if not path.endswith(BINARY) and file.is_file() and b'\r\n' in file.read_bytes():
            problems.append(f'{path}: has CRLF line endings')

    guides = {lang: {p.split('/')[-1] for p in tracked if re.fullmatch(rf'docs/{lang}/[^/]+\.md', p)} for lang in ('en', 'fa')}
    for name in sorted(guides['en'] ^ guides['fa']):
        problems.append(f'docs: {name} exists in only one language')

    commands = documented_commands(root)
    for path in sorted(p for p in tracked if p.endswith('.md')):
        file = root / path
        for line in prose_lines(file.read_text(encoding='utf-8')):
            for target in LINK.findall(line) + HTML_LINK.findall(line):
                if re.match(r'^[a-z][a-z0-9+.-]*:', target):
                    continue
                relative, _, fragment = target.partition('#')
                linked = (file.parent / relative).resolve() if relative else file
                if not linked.exists():
                    problems.append(f'{path}: broken link: {target}')
                elif fragment and linked.suffix == '.md' and fragment.replace('‌', '') not in anchors(linked):
                    problems.append(f'{path}: no such heading: {target}')
        if commands is not None:
            for name in COMMAND.findall(file.read_text(encoding='utf-8')):
                if name not in commands:
                    problems.append(f'{path}: unknown command: sudo darban {name}')

    for problem in problems:
        print(f'ERROR: {problem}', file=sys.stderr)
    print(f'{len(tracked)} files checked, {len(problems)} problem(s).')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
