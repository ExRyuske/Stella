#!/usr/bin/env python3
"""Вызовы функций до их объявления в файлах ucode.

ucode, в отличие от JavaScript, не поднимает объявления `function f()`: имя, которое
на момент компиляции ещё не объявлено, считается глобальным, и вызов падает уже при
работе — у rpcd это «Unknown error» без подробностей. Такие ошибки не раз доходили до
роутера, поэтому их ищет эта проверка.

Код сначала очищается от комментариев, строк и регулярных выражений настоящим
разбором по символам (регулярками это не сделать: `"'"` или `/['"]/` сбивали разбор и
выкидывали целые куски файла). Потом берутся объявления верхнего уровня
(`function имя(` и `export function имя(` в начале строки) и все вызовы `имя(` выше.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = [ROOT / 'root/usr/bin/stella', *sorted((ROOT / 'root/usr/share').rglob('*.uc'))]

DECL = re.compile(r'^(?:export\s+)?function\s+([A-Za-z_]\w*)\s*\(', re.M)
# После этих символов «/» начинает регулярное выражение, а не деление.
REGEX_AFTER = set('(,=:[!&|?{};+-*%<>~^') | {''}


def strip(src: str) -> str:
    out = []
    i, n = 0, len(src)
    tmpl = []          # глубина ${…} для каждого открытого шаблона `…`
    last = ''          # последний значимый символ кода (для различения / и регулярки)

    def blank(chunk: str) -> str:
        # Переводы строк сохраняем — по ним считаются номера строк.
        return re.sub(r'[^\n]', ' ', chunk)

    while i < n:
        c = src[i]
        if tmpl and tmpl[-1] == 0 and c == '`':
            tmpl.pop(); out.append('`'); i += 1; last = '`'; continue
        if tmpl and tmpl[-1] == 0:
            # Внутри текста шаблона: ищем ${ или конец.
            if src.startswith('${', i):
                tmpl[-1] = 1; out.append('${'); i += 2; last = '{'
            else:
                out.append(blank(c)); i += 1
            continue
        if c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(blank(src[i:j])); i = j; continue
        if c == '/' and src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(blank(src[i:j])); i = j; continue
        if c in '\'"':
            j = i + 1
            while j < n and src[j] != c and src[j] != '\n':
                j += 2 if src[j] == '\\' else 1
            out.append(blank(src[i:j + 1])); i = j + 1; last = c; continue
        if c == '/' and last in REGEX_AFTER:
            j, cls = i + 1, False
            while j < n and src[j] != '\n' and (cls or src[j] != '/'):
                if src[j] == '\\':
                    j += 1
                elif src[j] == '[':
                    cls = True
                elif src[j] == ']':
                    cls = False
                j += 1
            out.append(blank(src[i:j + 1])); i = j + 1; last = '/'; continue
        if c == '`':
            tmpl.append(0); out.append('`'); i += 1; continue
        if tmpl and c == '{':
            tmpl[-1] += 1
        elif tmpl and c == '}':
            tmpl[-1] -= 1
        out.append(c)
        if not c.isspace():
            last = c if not (c.isalnum() or c == '_') else 'a'
        i += 1
    return ''.join(out)


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
