#!/bin/sh
# Запуск тестов локально. Нужны ucode (UCODE=путь к бинарнику) и xray (XRAY=...).
set -e
cd "$(dirname "$0")/.."
UCODE="${UCODE:-ucode}"
UCODE_LIB="${UCODE_LIB:-$(dirname "$(command -v "$UCODE")")}"

uc() {
	"$UCODE" -L "$UCODE_LIB/*.so" -L "$PWD/tests/mock/*.uc" -L "$PWD/root/usr/share/ucode/*.uc" "$@"
}

# Вызовы функций до объявления: ucode их не поднимает, и ошибка всплывает только при работе.
python3 scripts/check_ucode_order.py

# Компиляция точек входа (CLI и плагин rpcd) — ловит синтаксис, несовместимый с ucode роутера.
for f in root/usr/bin/stella root/usr/share/rpcd/ucode/stella.uc; do
	uc -c -o /dev/null "$f" || { echo "FAIL: $f не компилируется"; exit 1; }
done
uc -S tests/test.uc

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
STELLA_UCI_JSON="$T/uci.json" STELLA_CACHE_DIR="$T/subs" STELLA_RUN_DIR="$T/run" STELLA_LISTS_DIR="$T/lists" \
	uc -S tests/rpcd.uc
