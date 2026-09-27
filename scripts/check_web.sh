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

for f in root/usr/share/luci/menu.d/*.json root/usr/share/rpcd/acl.d/*.json; do
	python3 -m json.tool "$f" >/dev/null || { echo "FAIL: $f"; exit 1; }
done

echo "web: OK"
