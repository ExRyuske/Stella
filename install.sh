#!/bin/sh
# Установка или обновление Stella на OpenWrt 25.12 — последний релиз с GitHub:
#   wget -qO- https://raw.githubusercontent.com/ExRyuske/Stella/main/install.sh | sh
set -e

url=$(wget -qO- https://api.github.com/repos/ExRyuske/Stella/releases/latest |
	jsonfilter -e '@.assets[*].browser_download_url' | grep '\.apk$' | head -n 1)
[ -n "$url" ] || { echo "Не удалось найти релиз Stella на GitHub" >&2; exit 1; }

apk=/tmp/luci-app-stella.apk
wget -qO "$apk" "$url"
# Пакет не подписан; -U обновляет индексы репозиториев для зависимостей.
apk add -U --allow-untrusted "$apk"
rm -f "$apk"
echo "Готово: LuCI → Службы → Stella"
