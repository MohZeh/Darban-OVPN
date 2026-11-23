#!/usr/bin/env python3
"""Checks how bin/darban is put together from its modules in lib/darban. It reads files; it runs no test.

1. bin/darban sources every module of lib/darban once, paths.sh first, by its absolute path where setup/install.sh
   places it (/usr/local/lib/darban/modules), each with a "# shellcheck source=" line naming the module.
2. No function is defined twice in the manager (bin/darban and its modules) and the libraries it sources
   (lib/common.sh, lib/ui.sh), except darban_error, which lib/ui.sh defines again on purpose.
3. A change whose title is a refactor ("refactor: ..." or "refactor(scope): ...") keeps the same set of functions as
   the commit it starts from: code moved between files, nothing gained or lost. This needs that commit and the
   title: TITLE='refactor: ...' python3 scripts/check-modules.py <base>. Without them, only 1 and 2 run.
"""
import collections
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANAGER = 'bin/darban'
MODULES = 'lib/darban'
INSTALLED = '/usr/local/lib/darban/modules/'
LIBRARIES = ('lib/common.sh', 'lib/ui.sh')
OVERRIDDEN = {'darban_error'}
SOURCE = re.compile(r'^source ' + re.escape(INSTALLED) + r'(\S+\.sh)$')
FUNCTION = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')
REFACTOR = re.compile(r'^refactor(\([^)]*\))?!?:')


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True, encoding='utf-8')


def functions(text):
    return [match.group(1) for line in text.splitlines() if (match := FUNCTION.match(line))]


def module_paths():
    return sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / MODULES).rglob('*.sh'))


def source_problems():
    problems = []
    lines = (ROOT / MANAGER).read_text(encoding='utf-8').splitlines()
    sourced = []
    for number, line in enumerate(lines):
        if (match := SOURCE.match(line)):
            name = match.group(1)
            sourced.append(name)
            if number == 0 or lines[number - 1] != f'# shellcheck source={MODULES}/{name}':
                problems.append(f'{MANAGER}:{number + 1}: no "# shellcheck source={MODULES}/{name}" line above it')
    on_disk = [path[len(MODULES) + 1:] for path in module_paths()]
    for name, count in collections.Counter(sourced).items():
        if count > 1:
            problems.append(f'{MANAGER}: sources {name} {count} times')
    for name in sorted(set(sourced) - set(on_disk)):
        problems.append(f'{MANAGER}: sources {INSTALLED}{name}, which {MODULES} does not have')
    for name in sorted(set(on_disk) - set(sourced)):
        problems.append(f'{MODULES}/{name}: {MANAGER} never sources it from {INSTALLED}')
    if on_disk and (not sourced or sourced[0] != 'paths.sh'):
        problems.append(f'{MANAGER}: paths.sh must be the first module it sources')
    return problems, len(sourced)


def duplicate_problems(files):
    where = collections.defaultdict(list)
    for path, text in files.items():
        for name in functions(text):
            where[name].append(path)
    problems = []
    for name, paths in sorted(where.items()):
        if len(paths) > 1 and not (name in OVERRIDDEN and set(paths) <= set(LIBRARIES)):
            problems.append(f'{name}() is defined {len(paths)} times: {", ".join(paths)}')
    return problems, set(where)


def base_functions(base):
    listed = git('ls-tree', '-r', '--name-only', base, '--', MANAGER, MODULES, *LIBRARIES)
    if listed.returncode != 0:
        return None
    names = set()
    for path in listed.stdout.split():
        if path == MANAGER or path in LIBRARIES or path.endswith('.sh'):
            names.update(functions(git('show', f'{base}:{path}').stdout))
    return names


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else ''
    title = os.environ.get('TITLE', '').strip().splitlines()[0:1]
    title = title[0] if title else ''
    problems, sourced = source_problems()
    files = {path: (ROOT / path).read_text(encoding='utf-8') for path in (MANAGER, *module_paths(), *LIBRARIES)}
    found, names = duplicate_problems(files)
    problems += found
    compared = 'not compared with a base'
    if base and not re.fullmatch(r'0+', base) and REFACTOR.match(title):
        before = base_functions(base)
        if before is None:
            problems.append(f'no commit {base} in this clone, so the functions of this refactor cannot be compared')
        else:
            compared = f'as a refactor, compared with the {len(before)} of {base[:12]}'
            for name in sorted(before - names):
                problems.append(f'{name}() is gone: a refactor keeps every function')
            for name in sorted(names - before):
                problems.append(f'{name}() is new: a refactor adds no function')
    elif base:
        compared = 'not compared: the title is not a refactor'
    for problem in problems:
        print(f'ERROR: {problem}', file=sys.stderr)
    print(f'Modules: {sourced} sourced, {len(names)} functions, {compared}; {len(problems)} problem(s).')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
