#!/bin/sh
# Установка или обновление Stella на OpenWrt 25.12 — последний релиз с GitHub:
#   wget -qO- https://raw.githubusercontent.com/ExRyuske/Stella/main/install.sh | sh
# После пакета — `stella setup`, как и при обновлении Stella на самом роутере: dnsmasq-full и
# zapret (mwan3 ставится только кнопкой на «Обзоре»).
set -e

json=$(wget -qO- https://api.github.com/repos/ExRyuske/Stella/releases/latest)
# Пакет — через API GitHub (сразу с сервера файлов: у части провайдеров сам github.com
# недоступен), запасной путь — обычная ссылка на github.com.
api= url= i=0
for name in $(echo "$json" | jsonfilter -e '@.assets[*].name'); do
	case "$name" in
	*.apk)
		api=$(echo "$json" | jsonfilter -e "@.assets[$i].url")
		url=$(echo "$json" | jsonfilter -e "@.assets[$i].browser_download_url")
		break ;;
	esac
	i=$((i + 1))
done
[ -n "$api$url" ] || { echo "Не удалось найти релиз Stella на GitHub" >&2; exit 1; }

apk=/tmp/luci-app-stella.apk
{ [ -n "$api" ] && wget -qO "$apk" --header='Accept: application/octet-stream' "$api"; } ||
	wget -qO "$apk" "$url" || { echo "Не удалось скачать Stella с GitHub" >&2; rm -f "$apk"; exit 1; }
# Пакет не подписан; -U обновляет индексы репозиториев для зависимостей.
apk add -U --allow-untrusted "$apk"
rm -f "$apk"
/usr/bin/stella setup || echo "Не всё удалось поставить (см. выше) — это можно сделать позже на «Обзоре» в «Обновлениях»" >&2
echo "Готово: LuCI → Службы → Stella"
