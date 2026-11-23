#!/usr/bin/env python3
"""Fast repository checks: file modes, line endings, documentation links, documented commands, the Setup numbers
the guides give, claims the guides must not make, the commands, paths and versions both languages share, and shell
functions that hand back a value in a global but run where a subshell loses it.

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
ANCHOR = re.compile(r'<a id="([^"]+)"></a>')
HEADING = re.compile(r'^#{1,6}\s+(.+?)\s*$')
COMMAND = re.compile(r'\bsudo darban ([a-z][a-z-]*)')
USAGE_COMMAND = re.compile(r'^  ([a-z][a-z-]*)\s')
SETUP_ITEM = re.compile(r"menu_item (\d) \"?\$?\(?(?:printf '%-24s %s' )?'([^']+)'")
GUIDE_ITEM = re.compile(r'`(\d)`[^`*\n]{0,20}\*\*([A-Za-z ]+?)(?::)?\*\*')
# F04 and D1: no guide says only a hash of a link stays, or that an install is verified.
UNTRUE_CLAIM = re.compile(r'only a hash|verified install', re.IGNORECASE)
INLINE_CODE = re.compile(r'`([^`\n]+)`')


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
    text = path.read_text(encoding='utf-8')
    found = {slug(match.group(1)) for line in prose_lines(text) if (match := HEADING.match(line))}
    return found | set(ANCHOR.findall(text))


def documented_commands(root):
    usage = root / 'bin/darban'
    if not usage.exists():
        return None
    block = usage.read_text(encoding='utf-8').split('Commands:\n', 1)[-1].split('Options:\n', 1)[0]
    return {match.group(1) for line in block.splitlines() if (match := USAGE_COMMAND.match(line))}


def setup_items(root):
    """The Setup menu's items as {label: number}, read from bin/darban, or None when it has no Setup menu."""
    usage = root / 'bin/darban'
    if not usage.exists():
        return None
    code = usage.read_text(encoding='utf-8')
    if 'draw_setup() {' not in code or 'setup_menu() {' not in code:
        return None
    block = code[code.index('draw_setup() {'):code.index('setup_menu() {')]
    return {label: num for num, label in SETUP_ITEM.findall(block)}


def setup_problems(root, items):
    """Every "`N` ... **Label**" for a Setup item in the guides uses the number the Setup menu shows."""
    if items is None:
        return []
    if items.get('Check for updates') != '2':
        return [f'bin/darban: the Setup menu could not be read (items found: {items})']
    problems = []
    for path in sorted((root / 'docs').glob('*/usage.md')):
        for num, label in GUIDE_ITEM.findall(path.read_text(encoding='utf-8')):
            for name, real in items.items():
                if label.strip().startswith(name.split(' (')[0]) and num != real:
                    problems.append(f'{path.relative_to(root).as_posix()}: `{num}` {label.strip()} is {real} in the Setup menu')
    return problems


def code_parts(text):
    """The fenced blocks, in order, and the inline code that names a command, path, option or version."""
    blocks, inline, fence, lines = [], set(), False, []
    for line in text.splitlines():
        if line.lstrip().startswith('```'):
            if fence:
                blocks.append('\n'.join(lines).strip())
            fence, lines = not fence, []
        elif fence:
            lines.append(line.strip())
        else:
            # A plain word such as `apt`, or punctuation such as `:`, is wording, not a fact both must share.
            inline.update(code for code in INLINE_CODE.findall(line) if re.search(r'[/.=\d\s-]', code))
    return blocks, inline


def parity_problems(root, names):
    """Both languages of a guide show the same code blocks, and name the same commands, paths and versions."""
    problems = []
    for name in sorted(names):
        en_blocks, en_inline = code_parts((root / 'docs/en' / name).read_text(encoding='utf-8'))
        fa_blocks, fa_inline = code_parts((root / 'docs/fa' / name).read_text(encoding='utf-8'))
        if en_blocks != fa_blocks:
            first = next((i for i, (a, b) in enumerate(zip(en_blocks, fa_blocks)) if a != b), min(len(en_blocks), len(fa_blocks)))
            problems.append(f'docs/*/{name}: code block {first + 1} differs between en ({len(en_blocks)} blocks) and fa ({len(fa_blocks)} blocks)')
        for code in sorted(en_inline - fa_inline):
            problems.append(f'docs/fa/{name}: does not name `{code}`, which docs/en/{name} does')
        for code in sorted(fa_inline - en_inline):
            problems.append(f'docs/en/{name}: does not name `{code}`, which docs/fa/{name} does')
    return problems


FUNCTION = re.compile(r'^([a-z_][a-z0-9_]*)\(\)\s*\{')
# A global set as a statement of its own: NAME=value, then the end of that statement. NAME=value cmd only sets it
# for cmd, so it is not a value handed back.
GLOBAL_SET = re.compile(r'''(?:^|[;{(]|&&|\|\||\bthen\b|\bdo\b|\belse\b)\s*([A-Z][A-Z0-9_]{2,})\+?=("[^"]*"|'[^']*'|\$\([^()]*\)|[^\s;|&)]*)(?=\s*($|;|&&|\|\||\}|\)|#))''')
DECLARED = re.compile(r'\b(?:local|declare|readonly)\s+(?:-[a-zA-Z]+\s+)*([^;|&]+)')


def shell_functions(text):
    """Each function of a shell file, as name -> its lines, for functions that start at the left margin."""
    found, name, body = {}, None, []
    for line in text.splitlines():
        match = FUNCTION.match(line)
        if name is None and match:
            name, body = match.group(1), [line]
            if line.rstrip().endswith('}'):
                found[name], name = body, None
            continue
        if name is not None:
            body.append(line)
            if line == '}':
                found[name], name = body, None
    return found


def subshell_global_problems(root, paths):
    """A function that hands back a value in a global, such as PICKED or BACKUP_WHY, loses that value without a word
    when it runs in a subshell: inside $( ), or on either side of a pipe. Only direct calls are found."""
    texts = {path: (root / path).read_text(encoding='utf-8') for path in paths}
    setters = {}
    for text in texts.values():
        for name, body in shell_functions(text).items():
            declared = {word.split('=')[0] for line in body for match in DECLARED.finditer(line) for word in match.group(1).split()}
            names = {m.group(1) for line in body for m in GLOBAL_SET.finditer(line.split(' #', 1)[0])} - declared - {'IFS'}
            if names:
                setters[name] = names
    problems = []
    for path, text in sorted(texts.items()):
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split(' #', 1)[0]
            for name, names in setters.items():
                if (re.search(rf'\$\(\s*{name}\b', code) or re.search(rf'(?<!\|)\|\s*{name}\b', code)
                        or re.match(rf'\s*{name}\b[^|]*(?<!\|)\|(?!\|)', code)):
                    problems.append(f'{path}:{number}: {name} sets {", ".join(sorted(names))}, which a subshell here loses')
    return problems


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

    for path in sorted(p for p in tracked if p.endswith('.md') or re.fullmatch(r'docs/.*\.html', p)):
        for number, line in enumerate((root / path).read_text(encoding='utf-8').splitlines(), 1):
            if UNTRUE_CLAIM.search(line):
                problems.append(f'{path}:{number}: a claim the tool does not make true: {line.strip()}')

    problems += setup_problems(root, setup_items(root))
    problems += parity_problems(root, guides['en'] & guides['fa'])
    shell = [p for p in tracked if re.fullmatch(r'(bin/[^/]+|lib/(?:darban/(?:.+/)?)?[^/]+\.sh|setup/[^/]+\.sh)', p) and (root / p).is_file()
             and (p.endswith('.sh') or 'bash' in (root / p).read_text(encoding='utf-8', errors='replace').split('\n', 1)[0])]
    problems += subshell_global_problems(root, shell)

    for problem in problems:
        print(f'ERROR: {problem}', file=sys.stderr)
    print(f'{len(tracked)} files checked, {len(problems)} problem(s).')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
