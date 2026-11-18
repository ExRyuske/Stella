#!/bin/sh
# Проверка веб-части без браузера: синтаксис видов LuCI и JSON меню и прав.
#
# Виды LuCI исполняются как тело функции (там `return view.extend(...)` на верхнем
# уровне), поэтому перед проверкой каждый заворачивается в функцию — иначе node
# ругался бы на return вне функции, а не на настоящую ошибку.
#
# При сборке пакета LuCI прогоняет виды через свой jsmin, а тот понимает JavaScript
# не весь (например, регулярку сразу после «=>» принимает за деление) и молча портит
# файл. Если задан JSMIN — путь к jsmin из luci-base, — проверяется и сжатый вид.
set -e
cd "$(dirname "$0")/.."
dir="$(mktemp -d)"
tmp="$dir/view.js"
trap 'rm -rf "$dir"' EXIT

for f in htdocs/luci-static/resources/view/stella/*.js htdocs/luci-static/resources/stella/*.js; do
	{ echo '(function(){'; cat "$f"; echo '})'; } > "$tmp"
	node --check "$tmp" || { echo "FAIL: $f"; exit 1; }
	if [ -n "$JSMIN" ]; then
		{ echo '(function(){'; "$JSMIN" < "$f"; echo '})'; } > "$tmp"
		node --check "$tmp" || { echo "FAIL: $f после jsmin"; exit 1; }
	fi
done

python3 - <<'PY'
import glob, re, sys
bad = 0
for path in sorted(glob.glob('htdocs/**/*.js', recursive=True)):
    src = open(path).read()
    nc = re.sub(r'//.*', '', src)
    nc = re.sub(r'/\*.*?\*/', '', nc, flags=re.S)
    reqs = { (m.group(2) or m.group(1).split('.')[-1]) for m in re.finditer(r"'require\s+([a-zA-Z0-9_.]+)(?:\s+as\s+([a-zA-Z0-9_]+))?';", src) }
    rest = re.sub(r"'require\s+[^']+';", '', nc)
    rest = re.sub(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|`(?:\\.|[^`\\])*`", "''", rest)
    for g in ('ui', 'poll', 'dom', 'uci', 'rpc', 'fs', 'view', 'form', 'sui', 'baseclass'):
        if re.search(r'(?:^|[^.\w]|\.\.\.)' + g + r'\s*\.', rest) and g not in reqs:
            print(f'FAIL: {path}: {g} используется без require', file=sys.stderr)
            bad = 1
sys.exit(bad)
PY

node tests/devices.js

for f in root/usr/share/luci/menu.d/*.json root/usr/share/rpcd/acl.d/*.json; do
	python3 -m json.tool "$f" >/dev/null || { echo "FAIL: $f"; exit 1; }
done

# Список по умолчанию — ссылки на списки itdoginfo в формате, который понимает окно списка.
ITD=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/
for u in $(sed -n "s/^[[:space:]]*list url '\(.*\)'$/\1/p" root/etc/config/stella); do
	case "$u" in "$ITD"*.lst) ;; *) echo "FAIL: $u — не список itdoginfo"; exit 1 ;; esac
done

echo "web: OK"
