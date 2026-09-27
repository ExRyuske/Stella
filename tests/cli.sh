#!/bin/sh
# Сквозная проверка CLI: подписка по HTTP -> update -> nodes -> gen -> xray run -test.
set -e
cd "$(dirname "$0")/.."
UCODE="${UCODE:-ucode}"
XRAY="${XRAY:-xray}"
UCODE_LIB="${UCODE_LIB:-$(dirname "$(command -v "$UCODE")")}"
T="$(mktemp -d)"
# Код остановленного сервера (143) не должен стать кодом всего скрипта.
trap 'rc=$?; kill $HTTP_PID 2>/dev/null; wait $HTTP_PID 2>/dev/null || true; rm -rf "$T"; exit $rc' EXIT

UUID=48b4e5f1-00ed-4c06-aa7d-e8890e1dcc5d
PBK=VaUOAQYUQAmBLwQ0NproXnB1vR_YNA9e3Pa9ghS72BY
printf '%s\n%s\n' \
	"vless://$UUID@1.2.3.4:443?type=xhttp&security=reality&pbk=$PBK&sni=yahoo.com#Sub%20XHTTP" \
	"hy2://pw@hy.example.com:443/?sni=hy.example.com#Sub%20HY2" | base64 > "$T/sub.txt"

python3 -m http.server 18765 --bind 127.0.0.1 -d "$T" >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1

cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "enabled": "1", "node": "", "socks_port": "10808" },
	"sub1": { ".type": "subscription", "name": "test", "url": "http://127.0.0.1:18765/sub.txt" },
	"bad": { ".type": "subscription", "name": "broken", "url": "http://127.0.0.1:18765/missing" },
	"n1": { ".type": "node", "name": "Manual", "link": "trojan://pw@tr.example.com:443#t" }
}
EOF

run() {
	STELLA_UCI_JSON="$T/uci.json" STELLA_CACHE_DIR="$T/cache" STELLA_RUN_DIR="$T/run" STELLA_LISTS_DIR="$T/lists" "$UCODE" -S \
		-L "$PWD/tests/mock/*.uc" -L "$UCODE_LIB/*.so" -L "$PWD/root/usr/share/ucode/*.uc" \
		root/usr/bin/stella "$@"
}

# broken подписка должна дать код 1, но sub1 обязана обновиться.
if run update; then echo "FAIL: update должен вернуть ошибку из-за broken"; exit 1; fi
test -s "$T/cache/sub1.json" || { echo "FAIL: кэш sub1 не записан"; exit 1; }

# Панель выдала другой shortId, остальное то же — кэш не меняется.
cp "$T/cache/sub1.json" "$T/sub1.before"
printf '%s\n%s\n' \
	"vless://$UUID@1.2.3.4:443?type=xhttp&security=reality&pbk=$PBK&sid=ab12&sni=yahoo.com#Sub%20XHTTP" \
	"hy2://pw@hy.example.com:443/?sni=hy.example.com#Sub%20HY2" | base64 > "$T/sub.txt"
run update >/dev/null 2>&1 || true
cmp -s "$T/sub1.before" "$T/cache/sub1.json" || { echo "FAIL: смена одного shortId переписала кэш"; exit 1; }
run nodes

ID=$(run nodes | awk '/Sub HY2/ {print $1}')
sed -i.bak "s/\"node\": \"\"/\"node\": \"$ID\"/" "$T/uci.json"
run gen "$T/config.json"
grep -q '"protocol": "hysteria"' "$T/config.json" || { echo "FAIL: выбранный узел не попал в конфиг"; exit 1; }
"$XRAY" run -test -c "$T/config.json" >/dev/null

# id узла Stella не должен затирать UUID пользователя VLESS.
VID=$(run nodes | awk '/Sub XHTTP/ {print $1}')
sed -i.bak "s/\"node\": \"$ID\"/\"node\": \"$VID\"/" "$T/uci.json"
run gen "$T/config.json"
grep -q "\"id\": \"$UUID\"" "$T/config.json" || { echo "FAIL: в конфиге не UUID пользователя"; exit 1; }
"$XRAY" run -test -c "$T/config.json" >/dev/null

# Несуществующий узел — gen обязан упасть, а не выдать direct.
sed -i.bak "s/\"node\": \"$VID\"/\"node\": \"nope\"/" "$T/uci.json"
if run gen "$T/c2.json" 2>/dev/null; then echo "FAIL: gen с неизвестным узлом"; exit 1; fi

# ping: узлы фиктивные, у каждого должен появиться результат -1.
PATH="$(dirname "$(command -v "$XRAY")"):$PATH" run ping >/dev/null
N=$(python3 -c "import json,sys; d=json.load(open('$T/run/ping.json')); print(sum(1 for v in d.values() if v == -1))")
[ "$N" = 3 ] || { echo "FAIL: ping записал $N результатов из 3"; exit 1; }

# Списки: скачивание по HTTP + записи вручную -> сет, правило и nftset для dnsmasq.
printf 'youtube.com\n+.googlevideo.com\n91.108.4.0/22\n' > "$T/list.txt"
cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "mode": "all", "default_action": "direct" },
	"list_yt": { ".type": "list", "name": "yt", "action": "zapret", "url": "http://127.0.0.1:18765/list.txt", "entry": [ "ytimg.com" ] },
	"list_off": { ".type": "list", "name": "off", "action": "vpn", "enabled": "0", "entry": [ "x.com" ] }
}
EOF
run lists >/dev/null
OUT=$(run fw show)
for want in 'set list_yt' 'elements = { 91.108.4.0/22 }' 'ip daddr @list_yt goto act_zapret' 'goto act_direct' \
	'nftset=/googlevideo.com/4#inet#stella#list_yt' 'nftset=/ytimg.com/4#inet#stella#list_yt' 'queue flags bypass to 202'; do
	echo "$OUT" | grep -qF "$want" || { echo "FAIL: fw show без «$want»"; exit 1; }
done
if echo "$OUT" | grep -q 'list_off'; then echo "FAIL: выключенный список попал в правила"; exit 1; fi

# migrate: анонимная подписка переименовывается, кэш и выбранный узел следуют за ней.
cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "node": "cfg0112ab_deadbeef" },
	"cfg0112ab": { ".type": "subscription", "name": "anon", "url": "http://example.com/s" }
}
EOF
echo '[{"id":"cfg0112ab_deadbeef","name":"x","protocol":"vless"}]' > "$T/cache/cfg0112ab.json"
run migrate >/dev/null
NEW=$(python3 -c "import json; d=json.load(open('$T/uci.json')); print([k for k,v in d.items() if v['.type']=='subscription'][0])")
SEL=$(python3 -c "import json; print(json.load(open('$T/uci.json'))['main']['node'])")
case "$NEW" in sub_????????) ;; *) echo "FAIL: migrate не переименовал секцию ($NEW)"; exit 1;; esac
[ "$SEL" = "${NEW}_deadbeef" ] || { echo "FAIL: migrate не обновил выбранный узел ($SEL)"; exit 1; }
grep -q "\"${NEW}_deadbeef\"" "$T/cache/$NEW.json" || { echo "FAIL: migrate не переименовал кэш"; exit 1; }
[ ! -e "$T/cache/cfg0112ab.json" ] || { echo "FAIL: старый кэш остался"; exit 1; }

echo "cli: OK"
