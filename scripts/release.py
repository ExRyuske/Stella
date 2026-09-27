#!/usr/bin/env python3
"""Поднять версию пакета перед выпуском.

    python3 scripts/release.py bump --part patch     # печатает «v0.1.0 -> v0.1.1»
    python3 scripts/release.py version               # текущая, «v0.1.0»

Версия живёт в одном месте — PKG_VERSION в Makefile: из него её берут и сборка
пакета в SDK, и тег релиза. PKG_RELEASE при новой версии сбрасывается в 1 —
он для пересборки той же версии, а не для счёта выпусков.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAKEFILE = ROOT / 'Makefile'
VERSION = re.compile(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')


# Кодировку и перевод строки задаём явно: иначе Python берёт их из локали, и
# русский комментарий в Makefile на чужой системе ломает чтение или запись.
def read(path: pathlib.Path) -> str:
    return path.read_text(encoding='utf-8')


def write(path: pathlib.Path, text: str) -> None:
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def current(text: str) -> str:
    match = re.search(r'^PKG_VERSION:=(\S+)$', text, re.M)
    if not match:
        raise ValueError('в Makefile нет PKG_VERSION')
    return match.group(1)


def next_version(version: str, part: str) -> str:
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError(f'нужна версия вида X.Y.Z, получено: {version}')
    major, minor, patch = map(int, match.groups())
    if part == 'major':
        major, minor, patch = major + 1, 0, 0
    elif part == 'minor':
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f'{major}.{minor}.{patch}'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='cmd', required=True)
    bump = sub.add_parser('bump')
    bump.add_argument('--part', choices=('patch', 'minor', 'major'), default='patch')
    sub.add_parser('version')
    args = parser.parse_args()

    text = read(MAKEFILE)
    old = current(text)
    if args.cmd == 'version':
        print(f'v{old}')
        return 0

    new = next_version(old, args.part)
    text = re.sub(r'^PKG_VERSION:=\S+$', f'PKG_VERSION:={new}', text, flags=re.M)
    text = re.sub(r'^PKG_RELEASE:=\S+$', 'PKG_RELEASE:=1', text, flags=re.M)
    write(MAKEFILE, text)
    print(f'v{old} -> v{new}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
