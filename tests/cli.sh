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
	STELLA_UCI_JSON="$T/uci.json" STELLA_CACHE_DIR="$T/cache" STELLA_RUN_DIR="$T/run" STELLA_LISTS_DIR="$T/lists" STELLA_ZAPRET_DIR="$T/zapret" "$UCODE" -S \
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

# Правка настроек main в uci.json: uci_main ключ=значение-JSON…
uci_main() {
	python3 - "$T/uci.json" "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for kv in sys.argv[2:]:
    k, v = kv.split('=', 1)
    v = json.loads(v)
    if v is None:
        d['main'].pop(k, None)
    else:
        d['main'][k] = v
json.dump(d, open(sys.argv[1], 'w'))
PY
}

# Выбранный узел пропал, ★ нет: по умолчанию код 3 — init оставит прежний конфиг, а без
# него не запустит Stella (но не выдаст direct).
uci_main node='"sub1_00000000"'
rc=0; run gen "$T/c2.json" 2>/dev/null || rc=$?
[ "$rc" = 3 ] || { echo "FAIL: gen без узла и без ★ вернул $rc, а не 3"; exit 1; }

# Есть ★ — замена из избранного.
uci_main auto_node="[\"$VID\"]"
run gen "$T/config.json" 2>"$T/gen.err" || { echo "FAIL: gen с заменой из ★"; exit 1; }
grep -q 'временно работаю через «Sub XHTTP»' "$T/gen.err" || { echo "FAIL: замена не из ★: $(cat "$T/gen.err")"; exit 1; }
"$XRAY" run -test -c "$T/config.json" >/dev/null

# ★ нет, «лучший по проверке»: из итогов стабильности — у кого больше доля ответов.
uci_main auto_node=null node_missing='"best"'
printf '{"%s":{"ok":5,"n":5,"ms":300,"jit":20},"%s":{"ok":3,"n":5,"ms":50,"jit":1}}' "$ID" "$VID" > "$T/stability.json"
run gen "$T/config.json" 2>"$T/gen.err" || { echo "FAIL: gen с заменой по проверке"; exit 1; }
grep -q 'временно работаю через «Sub HY2»' "$T/gen.err" || { echo "FAIL: замена не лучшая по проверке: $(cat "$T/gen.err")"; exit 1; }
uci_main node_missing=null

# Несуществующий узел — gen обязан упасть, а не выдать direct.
uci_main node='"nope"'
if run gen "$T/c2.json" 2>/dev/null; then echo "FAIL: gen с неизвестным узлом"; exit 1; fi

# ping: узлы фиктивные, у каждого должен появиться результат -1.
PATH="$(dirname "$(command -v "$XRAY")"):$PATH" run ping >/dev/null
N=$(python3 -c "import json,sys; d=json.load(open('$T/run/ping.json')); print(sum(1 for v in d.values() if v == -1))")
[ "$N" = 3 ] || { echo "FAIL: ping записал $N результатов из 3"; exit 1; }

# pick: отдельная ссылка фиктивная — никто не ответил, выбор не меняется, итоги записаны.
uci_main best_from='"manual"'
if PATH="$(dirname "$(command -v "$XRAY")"):$PATH" run pick --apply >"$T/pick.out" 2>&1; then echo "FAIL: pick без ответивших узлов"; exit 1; fi
python3 - "$T" <<'PY' || exit 1
import json, sys
t = sys.argv[1]
st = json.load(open(t + '/stability.json')).get('n1')
node = json.load(open(t + '/uci.json'))['main']['node']
if not st or st['ok'] != 0 or st['n'] != 5 or node != 'nope':
    print('FAIL: pick', st, node, open(t + '/pick.out').read()); sys.exit(1)
PY
uci_main best_from=null

# Списки: скачивание по HTTP + записи вручную -> сет, правило и nftset для dnsmasq.
printf 'youtube.com\n+.googlevideo.com\n91.108.4.0/22\n' > "$T/list.txt"
cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "mode": "all", "default_action": "direct", "zapret_opts": "--filter-tcp=443 --dpi-desync=fake" },
	"list_yt": { ".type": "list", "name": "yt", "action": "zapret", "url": "http://127.0.0.1:18765/list.txt", "entry": [ "ytimg.com" ] },
	"list_off": { ".type": "list", "name": "off", "action": "vpn", "enabled": "0", "entry": [ "x.com" ] }
}
EOF
run lists >/dev/null
mkdir -p "$T/zapret" && printf 'ru\nsberbank.com\n' > "$T/zapret/hosts-exclude.txt"
OUT=$(run fw show)
for want in 'set list_yt' 'elements = { 91.108.4.0/22 }' 'ip daddr @list_yt goto act_zapret' 'goto act_direct' \
	'nftset=/googlevideo.com/4#inet#stella#list_yt' 'nftset=/ytimg.com/4#inet#stella#list_yt' 'queue flags bypass to 202' \
	'nftset=/sberbank.com/4#inet#stella#zapret_excl' 'ip daddr @zapret_excl accept'; do
	echo "$OUT" | grep -qF "$want" || { echo "FAIL: fw show без «$want»"; exit 1; }
done
if echo "$OUT" | grep -q 'list_off'; then echo "FAIL: выключенный список попал в правила"; exit 1; fi

# У стратегии Flowseal — свои исключения.
printf 'steampowered.com\ntwitch.tv\n' > "$T/zapret/hosts-exclude_fs.txt"
python3 - "$T/uci.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['main']['zapret_bin'] = '/bin/sh'; d['main']['zapret_opts'] = '--filter-tcp=443 --hostlist-exclude=/opt/zapret/ipset/zapret-hosts-flowseal-exclude.txt --dpi-desync=fake'
json.dump(d, open(sys.argv[1], 'w'))
PY
OUT=$(run fw show)
echo "$OUT" | grep -qF 'nftset=/twitch.tv/4#inet#stella#zapret_excl' || { echo "FAIL: нет исключений Flowseal"; exit 1; }
if echo "$OUT" | grep -qF 'nftset=/sberbank.com/4#inet#stella#zapret_excl'; then echo "FAIL: исключения ZMS у стратегии Flowseal"; exit 1; fi
ARGS=$(run zapret-cmd 2>/dev/null || true)
case "$ARGS" in *hosts-exclude_fs.txt*) ;; *) echo "FAIL: nfqws не получил свой файл исключений Flowseal: $ARGS"; exit 1 ;; esac

# Выбранные исключения: «все вместе» — оба списка и в сете, и в ключах nfqws.
python3 - "$T/uci.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['main']['zapret_exclude'] = 'all'
json.dump(d, open(sys.argv[1], 'w'))
PY
OUT=$(run fw show)
for want in 'nftset=/twitch.tv/4#inet#stella#zapret_excl' 'nftset=/sberbank.com/4#inet#stella#zapret_excl'; do
	echo "$OUT" | grep -qF "$want" || { echo "FAIL: «все вместе» без «$want»"; exit 1; }
done
ARGS=$(run zapret-cmd 2>/dev/null || true)
case "$ARGS" in *hosts-exclude.txt*hosts-exclude_fs.txt*) ;; *) echo "FAIL: nfqws не получил оба списка исключений: $ARGS"; exit 1 ;; esac

# Только Zapret Manager — даже у стратегии Flowseal.
python3 - "$T/uci.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['main']['zapret_exclude'] = 'zms'
json.dump(d, open(sys.argv[1], 'w'))
PY
OUT=$(run fw show)
echo "$OUT" | grep -qF 'nftset=/sberbank.com/4#inet#stella#zapret_excl' || { echo "FAIL: нет выбранных исключений ZMS"; exit 1; }
if echo "$OUT" | grep -qF 'nftset=/twitch.tv/4#inet#stella#zapret_excl'; then echo "FAIL: исключения Flowseal при выборе ZMS"; exit 1; fi
ARGS=$(run zapret-cmd 2>/dev/null || true)
case "$ARGS" in *hosts-exclude_fs.txt*) echo "FAIL: nfqws получил исключения Flowseal при выборе ZMS: $ARGS"; exit 1 ;; *hosts-exclude.txt*) ;; *) echo "FAIL: nfqws без исключений ZMS: $ARGS"; exit 1 ;; esac

# migrate: анонимная подписка переименовывается, кэш и выбранный узел следуют за ней.
cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "node": "cfg0112ab_deadbeef", "auto_node": [ "cfg0112ab_deadbeef", "node_keep" ] },
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
AUTO=$(python3 -c "import json; print(' '.join(json.load(open('$T/uci.json'))['main']['auto_node']))")
[ "$AUTO" = "${NEW}_deadbeef node_keep" ] || { echo "FAIL: migrate не обновил отметки автовыбора ($AUTO)"; exit 1; }

echo "cli: OK"
