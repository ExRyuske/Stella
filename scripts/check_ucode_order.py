#!/usr/bin/env python3
"""Вызовы функций до их объявления в файлах ucode.

ucode, в отличие от JavaScript, не поднимает объявления `function f()`: имя, которое
на момент компиляции ещё не объявлено, считается глобальным, и вызов падает уже при
работе — у rpcd это «Unknown error» без подробностей. Такие ошибки дважды доходили до
роутера, поэтому их ищет эта проверка.

Проверка грубая, но без ложных срабатываний на практике: объявления верхнего уровня
(`function имя(` в начале строки, в том числе `export function`) и все вызовы `имя(`
выше строки объявления.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = [ROOT / 'root/usr/bin/stella', *sorted((ROOT / 'root/usr/share').rglob('*.uc'))]

DECL = re.compile(r'^(?:export\s+)?function\s+([A-Za-z_]\w*)\s*\(', re.M)


def strip(text: str) -> str:
    # Комментарии и строки не должны давать совпадений.
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    return text


def main() -> int:
    bad = 0
    for path in FILES:
        text = strip(path.read_text(encoding='utf-8'))
        decls = {m.group(1): text.count('\n', 0, m.start()) + 1 for m in DECL.finditer(text)}
        for name, line in decls.items():
            for m in re.finditer(r'(?<![\w.])' + name + r'\s*\(', text):
                use = text.count('\n', 0, m.start()) + 1
                if use < line:
                    print(f'{path.relative_to(ROOT)}:{use}: {name}() вызвана до объявления (строка {line})')
                    bad += 1
    print('ucode order: OK' if not bad else f'ucode order: {bad} FAIL')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
