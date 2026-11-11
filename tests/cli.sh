#!/bin/sh
# Сквозная проверка CLI: подписка по HTTP -> update -> nodes -> gen -> xray run -test.
set -e
cd "$(dirname "$0")/.."
UCODE="${UCODE:-ucode}"
XRAY="${XRAY:-xray}"
UCODE_LIB="${UCODE_LIB:-$(dirname "$(command -v "$UCODE")")}"
T="$(mktemp -d)"
# Код остановленного сервера (143) не должен стать кодом всего скрипта.
trap 'rc=$?; kill $HTTP_PID $WARP_PID 2>/dev/null; wait $HTTP_PID 2>/dev/null || true; rm -rf "$T"; exit $rc' EXIT

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

# dnsmasq как на роутере: строки nftset= Stella пишет, только если dnsmasq их понимает
# (dnsmasq-full), — обычный с ними не запустился бы. На раннере dnsmasq нет — подставляем.
mkdir -p "$T/dnsmasq-full" "$T/dnsmasq-plain"
printf '#!/bin/sh\necho "Compile time options: IPv6 GNU-getopt UBus DHCP nftset auth"\n' > "$T/dnsmasq-full/dnsmasq"
printf '#!/bin/sh\necho "Compile time options: IPv6 GNU-getopt UBus DHCP no-nftset auth"\n' > "$T/dnsmasq-plain/dnsmasq"
chmod +x "$T/dnsmasq-full/dnsmasq" "$T/dnsmasq-plain/dnsmasq"
DNSMASQ="$T/dnsmasq-full"

# «--» перед скриптом: getopt из glibc переставляет аргументы и принял бы «--apply» команды
# за ключ самого ucode (на роутере musl так не делает, а в CI — glibc).
run() {
	PATH="$DNSMASQ:$PATH" STELLA_UCI_JSON="$T/uci.json" STELLA_CACHE_DIR="$T/cache" STELLA_RUN_DIR="$T/run" STELLA_LISTS_DIR="$T/lists" STELLA_ZAPRET_DIR="$T/zapret" STELLA_MWAN3_STATE="$T/mwan3" STELLA_WARP_DATA="$T/warp.json" "$UCODE" -S \
		-L "$PWD/tests/mock/*.uc" -L "$UCODE_LIB/*.so" -L "$PWD/root/usr/share/ucode/*.uc" \
		-- root/usr/bin/stella "$@"
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

# Резервный канал mwan3: в сети только он (IPv6-интерфейсы не в счёт) — xray через его узел;
# подбор на нём не идёт; uplink перезапускает Stella, только когда канал сменился.
mkdir -p "$T/mwan3" "$T/bin"
printf '#!/bin/sh\necho "$*" >> "%s/reload.log"\n' "$T" > "$T/bin/setsid"
printf '#!/bin/sh\n' > "$T/bin/logger"
chmod +x "$T/bin/setsid" "$T/bin/logger"
python3 - "$T/uci.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['wan'] = { '.type': 'interface', 'enabled': '1', 'family': 'ipv4' }
d['wwan'] = { '.type': 'interface', 'enabled': '1' }
d['wan6'] = { '.type': 'interface', 'enabled': '1', 'family': 'ipv6' }
json.dump(d, open(sys.argv[1], 'w'))
PY
uci_main node="\"$VID\"" backup_iface='"wwan"' backup_node='"n1"'
echo offline > "$T/mwan3/wan"; echo online > "$T/mwan3/wwan"; echo online > "$T/mwan3/wan6"
run gen "$T/config.json"
grep -q '"protocol": "trojan"' "$T/config.json" || { echo "FAIL: на резервном канале не его узел"; exit 1; }
"$XRAY" run -test -c "$T/config.json" >/dev/null
if run pick --apply 2>"$T/pick.err"; then echo "FAIL: подбор на резервном канале"; exit 1; fi
grep -q 'резервный канал' "$T/pick.err" || { echo "FAIL: подбор на резервном канале: $(cat "$T/pick.err")"; exit 1; }
# Подбор узла резервного канала — наоборот, только на нём: меряет через него и пишет свои
# итоги (отдельная ссылка фиктивная — никто не ответил, узел не меняется).
uci_main backup_best_from='"manual"'
cp "$T/stability.json" "$T/stability.before"
if PATH="$(dirname "$(command -v "$XRAY")"):$PATH" run pick --backup --apply >"$T/pick.out" 2>&1; then echo "FAIL: подбор для резервного канала без ответивших узлов"; exit 1; fi
cmp -s "$T/stability.before" "$T/stability.json" || { echo "FAIL: подбор для резервного канала изменил основные итоги"; exit 1; }
python3 - "$T" <<'PY' || exit 1
import json, sys
t = sys.argv[1]
st = json.load(open(t + '/stability-backup.json')).get('n1')
node = json.load(open(t + '/uci.json'))['main']['backup_node']
if not st or st['ok'] != 0 or st['n'] != 5 or node != 'n1':
    print('FAIL: pick --backup', st, node, open(t + '/pick.out').read()); sys.exit(1)
PY
uci_main backup_best_from=null
# «Всё через VPN»: на резервном канале списки не действуют.
run fw show | grep -q 'goto pol_global' || { echo "FAIL: на резервном канале без «всё через VPN» не действуют списки"; exit 1; }
uci_main backup_vpn='"1"'
if run fw show | grep -q 'goto pol_global'; then echo "FAIL: на резервном канале с «всё через VPN» действуют списки"; exit 1; fi
# reload uplink запускает в фоне — его след появляется не сразу.
PATH="$T/bin:$PATH" run uplink
sleep 1
[ ! -e "$T/reload.log" ] || { echo "FAIL: uplink перезапустил Stella без смены канала"; exit 1; }
echo online > "$T/mwan3/wan"
PATH="$T/bin:$PATH" run uplink
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/reload.log" ] && break; sleep 0.2; done
grep -q 'stella reload' "$T/reload.log" 2>/dev/null || { echo "FAIL: основной канал вернулся, а uplink не перезапустил Stella"; exit 1; }
run gen "$T/config.json"
grep -q '"protocol": "vless"' "$T/config.json" || { echo "FAIL: основной канал вернулся, а узел не основной"; exit 1; }
if run pick --backup --apply 2>"$T/pick.err"; then echo "FAIL: подбор для резервного канала без него"; exit 1; fi
grep -q 'резервный канал сейчас не работает' "$T/pick.err" || { echo "FAIL: подбор для резервного канала без него: $(cat "$T/pick.err")"; exit 1; }
run fw show | grep -q 'goto pol_global' || { echo "FAIL: основной канал вернулся, а списки не действуют"; exit 1; }

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
for want in 'set list_yt {' 'elements = { 91.108.4.0/22 }' 'ip daddr @list_yt goto act_zapret' 'goto act_direct' \
	'set list_yt_dns {' 'ip daddr @list_yt_dns update @list_yt_dns { ip daddr } goto act_zapret' 'max-cache-ttl=300' \
	'nftset=/googlevideo.com/4#inet#stella#list_yt_dns' 'nftset=/ytimg.com/4#inet#stella#list_yt_dns' 'queue flags bypass to 202' \
	'nftset=/sberbank.com/4#inet#stella#zapret_excl' 'ip daddr @zapret_excl update @zapret_excl { ip daddr } accept'; do
	echo "$OUT" | grep -qF "$want" || { echo "FAIL: fw show без «$want»"; exit 1; }
done
if echo "$OUT" | grep -q 'list_off'; then echo "FAIL: выключенный список попал в правила"; exit 1; fi
if echo "$OUT" | grep -q 'dport 853'; then echo "FAIL: в правилах осталась блокировка DoT"; exit 1; fi
# Обычный dnsmasq: строк nftset= нет (с ними он не запустился бы), DNS через xray — есть.
DNSMASQ="$T/dnsmasq-plain"; OUT=$(run fw show 2>/dev/null); DNSMASQ="$T/dnsmasq-full"
if echo "$OUT" | grep -q '^nftset='; then echo "FAIL: nftset= для dnsmasq без nftset"; exit 1; fi
echo "$OUT" | grep -qF 'server=127.0.0.1#10853' || { echo "FAIL: без nftset пропал DNS через xray"; exit 1; }

# Имена наборов russia-v2ray-rules-dat: только файлы .srs своего вида, без подкаталогов;
# не скачалось — прежние имена остаются.
mkdir -p "$T/trees"
echo '{"tree":[{"path":"geosite-youtube.srs","type":"blob"},{"path":"geosite-ru-blocked.srs","type":"blob"},{"path":"geosite-geolocation-!cn.srs","type":"blob"},{"path":"geoip-ru.srs","type":"blob"},{"path":"youtube.json","type":"blob"},{"path":"geosite-x","type":"tree"}]}' > "$T/trees/rule-set-geosite"
echo '{"tree":[{"path":"geoip-ru.srs","type":"blob"}]}' > "$T/trees/rule-set-geoip"
cp tests/fixtures/itdog-tree.json "$T/itdog-tree.json"
# Списки itdoginfo — по именам файлов архива репозитория (без API GitHub); архива нет — по дереву API.
python3 - "$T/itdog.tgz" tests/fixtures/itdog-tree.json <<'PY' || exit 1
import io, json, sys, tarfile
with tarfile.open(sys.argv[1], 'w:gz') as tar:
    for e in json.load(open(sys.argv[2]))['tree']:
        if e['type'] == 'blob':
            tar.addfile(tarfile.TarInfo('allow-domains-main/' + e['path']), io.BytesIO(b''))
PY
export STELLA_ITDOG_TGZ=http://127.0.0.1:18765/itdog.tgz STELLA_ITDOG_TREE=http://127.0.0.1:18765/missing
STELLA_GEO_TREES=http://127.0.0.1:18765/trees/rule-set- run geo-index >/dev/null
python3 - "$T/run/geo-index.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
if len(d['itdog']) != 7 or d['itdog'][2]['files'] != ['Services/discord.lst', 'Subnets/IPv4/discord.lst']:
    print('FAIL: geo-index по архиву itdoginfo', d['itdog']); sys.exit(1)
PY
rm -f "$T/run/geo-index.json"
export STELLA_ITDOG_TGZ=http://127.0.0.1:18765/missing.tgz STELLA_ITDOG_TREE=http://127.0.0.1:18765/itdog-tree.json
STELLA_GEO_TREES=http://127.0.0.1:18765/trees/rule-set- run geo-index >/dev/null
# Сервер наборов не ответил — прежние имена и списки itdoginfo остаются, отметка времени — прежняя.
if STELLA_GEO_TREES=http://127.0.0.1:18765/missing/ run geo-index 2>/dev/null; then echo "FAIL: geo-index без ответа сервера"; exit 1; fi
python3 - "$T/run/geo-index.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
if d['geosite'] != ['geolocation-!cn', 'ru-blocked', 'youtube'] or d['geoip'] != ['ru'] or len(d['itdog']) != 7 or \
   d['itdog'][2]['files'] != ['Services/discord.lst', 'Subnets/IPv4/discord.lst'] or not d['at']:
    print('FAIL: geo-index', d); sys.exit(1)
PY
unset STELLA_ITDOG_TREE STELLA_ITDOG_TGZ

# Исключения Zapret — всегда оба списка (Zapret Manager и Flowseal), какой бы ни была стратегия:
# и в сете, и в ключах nfqws вместо заложенных в стратегию.
printf 'steampowered.com\ntwitch.tv\n' > "$T/zapret/hosts-exclude_fs.txt"
python3 - "$T/uci.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['main']['zapret_bin'] = '/bin/sh'; d['main']['zapret_opts'] = '--filter-tcp=443 --hostlist-exclude=/opt/zapret/ipset/zapret-hosts-flowseal-exclude.txt --dpi-desync=fake'
json.dump(d, open(sys.argv[1], 'w'))
PY
OUT=$(run fw show)
for want in 'nftset=/twitch.tv/4#inet#stella#zapret_excl' 'nftset=/sberbank.com/4#inet#stella#zapret_excl'; do
	echo "$OUT" | grep -qF "$want" || { echo "FAIL: «все вместе» без «$want»"; exit 1; }
done
ARGS=$(run zapret-cmd 2>/dev/null || true)
case "$ARGS" in *hosts-exclude.txt*hosts-exclude_fs.txt*) ;; *) echo "FAIL: nfqws не получил оба списка исключений: $ARGS"; exit 1 ;; esac

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

# Наборы geosite и geoip (опция geo) в списке — вместе с обычным текстом по ссылке; не
# скачавшийся список не мешает остальным. Откуда скачано — в .src рядом.
mkdir -p "$T/geo/rule-set-geosite" "$T/geo/rule-set-geoip"
cp tests/fixtures/geosite-telegram.srs "$T/geo/rule-set-geosite/"
cp tests/fixtures/geoip-telegram.srs "$T/geo/rule-set-geoip/"
cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "default_action": "direct", "enabled": "1" },
	"list_tg": { ".type": "list", "name": "tg", "action": "vpn", "geo": [ "geosite:telegram", "geoip:telegram", "bad" ], "url": "http://127.0.0.1:18765/list.txt" },
	"list_gone": { ".type": "list", "name": "gone", "action": "vpn", "geo": "geosite:missing" }
}
EOF
export STELLA_GEO_BASE=http://127.0.0.1:18765/geo/
if run lists >"$T/lists.out" 2>&1; then echo "FAIL: список с несуществующим набором обновился"; exit 1; fi
python3 - "$T" <<'PY' || exit 1
import json, sys
t = sys.argv[1]
d = json.load(open(t + '/lists/list_tg.json'))
if len(d['domains']) != 23 or 't.me' not in d['domains'] or 'youtube.com' not in d['domains'] or \
   d['cidrs'][:2] != ['149.154.160.0/20', '185.76.151.0/24'] or len(d['cidrs']) != 8:
    print('FAIL: список из наборов', d, open(t + '/lists.out').read()); sys.exit(1)
if open(t + '/lists/list_tg.src').read().split('\n')[1:] != ['http://127.0.0.1:18765/geo/rule-set-geosite/geosite-telegram.srs', 'http://127.0.0.1:18765/geo/rule-set-geoip/geoip-telegram.srs']:
    print('FAIL: .src', open(t + '/lists/list_tg.src').read()); sys.exit(1)
PY

# stale: скачивается то, что добавили или поменяли (у list_gone .src нет, list_new новый), и по
# одному разу — неудачная попытка не повторяется до перезагрузки.
python3 - "$T/uci.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['list_new'] = { '.type': 'list', 'name': 'new', 'entry': 'x.com', 'url': 'http://127.0.0.1:18765/list.txt' }
d['list_entries'] = { '.type': 'list', 'name': 'only entries', 'entry': 'y.com' }
d['sub_new'] = { '.type': 'subscription', 'name': 's', 'url': 'http://127.0.0.1:18765/sub.txt' }
d['main']['default_action'] = 'zapret'
json.dump(d, open(sys.argv[1], 'w'))
PY
rm -f "$T/reload.log"
# Файлы удалённого со страницы списка (секции нет) — убираются; у живых — остаются.
touch "$T/lists/list_dead.json" "$T/lists/list_dead.src"
PATH="$T/bin:$PATH" run stale
[ ! -e "$T/lists/list_dead.json" ] && [ ! -e "$T/lists/list_dead.src" ] && [ -e "$T/lists/list_tg.json" ] ||
	{ echo "FAIL: stale не убрал файлы удалённого списка"; exit 1; }
grep -qx 'sh .*/lists.sh' "$T/reload.log" && grep -qx 'sh .*/update.sh' "$T/reload.log" || { echo "FAIL: stale не запустил задачи: $(cat "$T/reload.log")"; exit 1; }
# Каталогов ещё нет: Zapret выбран («остальной трафик») — его каталог, DNS — всегда.
grep -q '/usr/bin/stella zapret-catalog; /etc/init.d/stella reload' "$T/run/zcatalog.sh" && grep -q '/usr/bin/stella dns-catalog' "$T/run/dnscat.sh" ||
	{ echo "FAIL: stale не скачивает каталоги: $(cat "$T/reload.log")"; exit 1; }
grep -q '/usr/bin/stella lists list_gone list_new; /etc/init.d/stella reload' "$T/run/lists.sh" ||
	{ echo "FAIL: stale: $(cat "$T/run/lists.sh")"; exit 1; }
grep -q '/usr/bin/stella update sub_new; /etc/init.d/stella reload' "$T/run/update.sh" || { echo "FAIL: stale: $(cat "$T/run/update.sh")"; exit 1; }
rm -f "$T/reload.log" "$T/run/lists.running" "$T/run/update.running" "$T/run/zcatalog.running" "$T/run/dnscat.running"
PATH="$T/bin:$PATH" run stale
[ ! -s "$T/reload.log" ] || { echo "FAIL: stale повторил попытку: $(cat "$T/reload.log")"; exit 1; }
unset STELLA_GEO_BASE

# DNS: каталог DoH — из массива PROVIDERS панели Zapret Manager (выдержка). Режим «вручную» — без
# проверки серверов (иначе запросы в сеть).
cp tests/fixtures/zms-doh-providers.txt "$T/zm-luci.sh"
uci_main dns_mode='"manual"' 'dns_server=["https://dns.google/dns-query", "https://dns.comss.one/dns-query"]' dns_hijack='"1"'
STELLA_DNS_DIR="$T/dns" STELLA_DNS_CATALOG=http://127.0.0.1:18765/zm-luci.sh run dns-catalog >/dev/null ||
	{ echo "FAIL: dns-catalog"; exit 1; }
STELLA_DNS_DIR="$T/dns" run gen "$T/config.json"
STELLA_DNS_DIR="$T/dns" run fw show > "$T/fw.txt"
python3 - "$T" <<'PY' || exit 1
import json, sys
t = sys.argv[1]
cat = json.load(open(t + '/dns/catalog.json'))
c = json.load(open(t + '/config.json'))
fw = open(t + '/fw.txt').read()
if len(cat) != 7 or cat[3]['kind'] != 'geo':
    print('FAIL: каталог DNS', cat); sys.exit(1)
srv = [s['address'] for s in c['dns']['servers']]
if srv[:2] != ['https://dns.google/dns-query', 'https://dns.comss.one/dns-query'] or c['dns']['hosts'].get('dns.google') != ['8.8.8.8', '8.8.4.4']:
    print('FAIL: цепочка DNS в конфиге', c['dns']); sys.exit(1)
# Запасные по умолчанию — Cloudflare и Google из каталога (Google уже в цепочке — не повторяется).
if srv[2:] != ['https://cloudflare-dns.com/dns-query']:
    print('FAIL: запасные DNS по умолчанию', srv); sys.exit(1)
if 'doh4' in fw or 'address=/' in fw:
    print('FAIL: осталась блокировка DoH', fw); sys.exit(1)
PY
# Каталог не скачался — прежний остаётся.
if STELLA_DNS_DIR="$T/dns" STELLA_DNS_CATALOG=http://127.0.0.1:18765/missing run dns-catalog >/dev/null 2>&1; then
	echo "FAIL: dns-catalog без ответа сервера"; exit 1
fi
[ "$(python3 -c "import json; print(len(json.load(open('$T/dns/catalog.json'))))")" = 7 ] || { echo "FAIL: каталог DNS пропал"; exit 1; }

# setup: всё нужное уже стоит (dnsmasq-full, zapret) — ничего не ставится; mwan3 не трогается.
printf '#!/bin/sh\necho "apk $*" >> "%s/apk.log"\n[ "$1 $2 $3" = "list -I zapret" ] && echo "zapret-72.20251103-r1 aarch64 {zapret} (MIT) [installed]"\nexit 0\n' "$T" > "$T/bin/apk"
chmod +x "$T/bin/apk"
rm -f "$T/apk.log"
PATH="$T/bin:$PATH" run setup > "$T/setup.out" 2>&1 || { echo "FAIL: setup: $(cat "$T/setup.out")"; exit 1; }
! grep -q 'add\|mwan3\|upgrade' "$T/apk.log" || { echo "FAIL: setup поставил лишнее: $(cat "$T/apk.log")"; exit 1; }

export STELLA_TRACE_URL=http://127.0.0.1:18765/missing-trace
# WARP: ключи от xray, регистрация в API (здесь — поддельном), узел — отдельная ссылка; занятое
# название получает номер. Адреса фиктивные — никто не отвечает, остаётся адрес из ответа API.
cat > "$T/warp_api.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log = open(sys.argv[2], 'a')
class H(BaseHTTPRequestHandler):
    def reply(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
    def do_POST(self):
        b = self.body()
        log.write('POST %s %s %s %s\n' % (self.path, b.get('key'), b.get('tos', '')[:4], self.headers.get('User-Agent')))
        log.flush()
        self.reply({'result': {'id': 'abc', 'token': 'tok'}})
    def do_PATCH(self):
        b = self.body()
        log.write('PATCH %s %s %s\n' % (self.path, b.get('warp_enabled'), self.headers.get('Authorization')))
        log.flush()
        self.reply({'result': {'config': {'client_id': 'AQID',
            'peers': [{'public_key': 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=', 'endpoint': {'v4': '162.159.192.1:0', 'host': 'engage.cloudflareclient.com:2408'}}],
            'interface': {'addresses': {'v4': '172.16.0.2', 'v6': '2606:4700:110:8a36::1'}}}}})
    def log_message(self, *a):
        pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$T/warp_api.py" 18766 "$T/warp_api.log" &
WARP_PID=$!
sleep 1
cat > "$T/uci.json" <<EOF
{
	"main": { ".type": "stella", "node": "" },
	"node_a": { ".type": "node", "name": "WARP", "link": "trojan://pw@tr.example.com:443#t" }
}
EOF
# Данные WARP — с «GitHub генератора» (выдержки его файлов); не скачались — прежние остаются.
mkdir -p "$T/wg/builders"
cp tests/fixtures/warp-endpoint-pool.ts "$T/wg/endpoint-pool.ts"
cp tests/fixtures/warp-shared.ts "$T/wg/builders/shared.ts"
cp tests/fixtures/warp-cloudflare-client.ts "$T/wg/cloudflare-client.ts"
STELLA_WARP_SOURCE=http://127.0.0.1:18765/wg/ run warp-data >/dev/null 2>&1 || { echo "FAIL: warp-data"; exit 1; }
if STELLA_WARP_SOURCE=http://127.0.0.1:18765/missing/ run warp-data >/dev/null 2>&1; then echo "FAIL: warp-data без ответа сервера"; exit 1; fi
python3 - "$T/warp.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
if len(d.get('hosts', [])) != 14 or len(d.get('ports', [])) != 54 or len(d.get('masks', [])) != 2 or d.get('ua') != 'okhttp/3.12.1' or not d.get('api'):
    print('FAIL: данные WARP', {k: (len(v) if isinstance(v, list) else v) for k, v in d.items()}, file=sys.stderr); sys.exit(1)
PY
STELLA_WARP_API=http://127.0.0.1:18766/v0 PATH="$(dirname "$(command -v "$XRAY")"):$PATH" run warp >"$T/warp.out" 2>&1 || { echo "FAIL: warp: $(cat "$T/warp.out")"; exit 1; }
grep -Eqx 'POST /v0/reg [A-Za-z0-9+/]{43}= 20[0-9]{2} okhttp/3.12.1' "$T/warp_api.log" && grep -qxF 'PATCH /v0/reg/abc True Bearer tok' "$T/warp_api.log" ||
	{ echo "FAIL: запросы к API WARP: $(cat "$T/warp_api.log")"; exit 1; }
WID=$(python3 - "$T" <<'PY'
import json, sys
t = sys.argv[1]
d = json.load(open(t + '/uci.json'))
w = [k for k, v in d.items() if v.get('name') == 'WARP 2']
link = d[w[0]]['link'] if w else ''
if not link.startswith('wireguard://') or '@162.159.192.1:2408?' not in link or 'reserved=1,2,3' not in link or 'noise=quic' not in link:
    print('FAIL: узел WARP', d, open(t + '/warp.out').read(), file=sys.stderr); sys.exit(1)
print(w[0])
PY
) || exit 1
uci_main node="\"$WID\""
run gen "$T/config.json"
grep -q '"protocol": "wireguard"' "$T/config.json" || { echo "FAIL: узел WARP не попал в конфиг"; exit 1; }
"$XRAY" run -test -c "$T/config.json" >/dev/null || { echo "FAIL: xray отклонил конфиг WARP"; exit 1; }

# Первое включение: WARP уже есть — заново не регистрируется, становится узлом, warp_auto снимается.
uci_main node='""' warp_auto='"1"'
N=$(wc -l < "$T/warp_api.log")
run warp --first >"$T/warp.out" 2>&1 || { echo "FAIL: warp --first: $(cat "$T/warp.out")"; exit 1; }
python3 - "$T/uci.json" "$WID" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1]))['main']
if m.get('node') != sys.argv[2] or 'warp_auto' in m:
    print('FAIL: warp --first', m, file=sys.stderr); sys.exit(1)
PY
[ "$(wc -l < "$T/warp_api.log")" = "$N" ] || { echo "FAIL: warp --first зарегистрировал WARP заново"; exit 1; }
# Без warp_auto — ничего не делает.
run warp --first >/dev/null 2>&1 && [ "$(wc -l < "$T/warp_api.log")" = "$N" ] || { echo "FAIL: warp --first без warp_auto"; exit 1; }
kill $WARP_PID 2>/dev/null; WARP_PID=

# API недоступен: Zapret не установлен — путь пропускается, в ошибке — испробованные пути.
if STELLA_WARP_API=http://127.0.0.1:18766/v0 PATH="$(dirname "$(command -v "$XRAY")"):$PATH" run warp >"$T/warp.out" 2>&1; then
	echo "FAIL: warp без API завершился успешно"; exit 1
fi
grep -qF 'API Cloudflare не отвечает (напрямую, через VPN)' "$T/warp.out" || { echo "FAIL: warp без API: $(cat "$T/warp.out")"; exit 1; }

echo "cli: OK"
