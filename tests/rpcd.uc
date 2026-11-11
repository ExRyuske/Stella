// Смоук-тест плагина rpcd: загрузка, методы на чтение и действия. Настройки, списки и устройства
// пишут сами страницы штатным UCI LuCI — здесь их меняет set_main.
// Системные вызовы (pgrep, ps, /etc/init.d/…) на машине разработчика просто ничего не находят.

'use strict';

import { writefile, readfile, mkdir } from 'fs';
import { task_busy, task_script } from 'stella.store';

let path = getenv('STELLA_UCI_JSON');
writefile(path, sprintf('%J', {
	main: { '.type': 'stella', enabled: '0', default_action: 'direct' },
	node_1: { '.type': 'node', name: 'n', link: 'trojan://pw@tr.example.com:443#t' },
	dev_aabbccddee01: { '.type': 'device', mac: 'aa:bb:cc:dd:ee:01', name: 'TV', policy: 'vpn' },
	list_1: { '.type': 'list', name: 'Мои сайты', entry: [ 'https://2ip.io/x', 'example.com' ], geo: [ 'geosite:youtube', 'geoip:ru' ] },
	// Интерфейсы mwan3 (заглушка uci не различает конфиги).
	wan: { '.type': 'interface', enabled: '1' },
	wwan: { '.type': 'interface', enabled: '1' }
}));

let methods = loadfile('root/usr/share/rpcd/ucode/stella.uc')().stella;
let failed = 0;

// Настройки main — как их записала бы страница.
function set_main(values) {
	let conf = json(readfile(path));
	for (let k, v in values)
		conf.main[k] = v;
	writefile(path, sprintf('%J', conf));
}

function check(name, cond, info) {
	if (!cond) {
		failed++;
		warn(`FAIL rpcd ${name}: ${sprintf('%J', info)}\n`);
	}
}

for (let m in [ 'status', 'nodes', 'lists', 'zapret_info', 'zapret_catalog', 'update_info' ]) {
	let r;
	try { r = methods[m].call({ args: {} }); }
	catch (e) { r = { exception: e.message }; }
	check(m, type(r) == 'object' && !r.exception && !r.error, r);
}

let r;
let l = methods.lists.call({ args: {} }).lists[0];
check('lists entry', l.domains == 2 && l.devices_mode == 'all' && length(l.geo) == 2, l);

// Методов записи в плагине нет.
check('no write methods', !length(filter([ 'select', 'auto_set', 'edit', 'remove', 'list_add', 'list_edit', 'list_remove', 'list_move',
	'set_default_action', 'device_set', 'device_remove', 'settings_set',
	'set_enabled', 'restart', 'devices', 'log' ], (m) => methods[m] != null)), keys(methods));
check('block_doh gone', methods.settings.call({ args: {} }).block_doh == null, null);
check('settings dns default', methods.settings.call({ args: {} }).dns_mode == 'geo', null);
set_main({ dns_mode: 'manual', dns_server: [ 'https://dns.comss.one/dns-query', 'https://1.1.1.1/dns-query' ],
	lan_ifname: [ 'br-lan', 'br-guest' ], update_interval: '6' });
let st = methods.settings.call({ args: {} });
check('settings', st.dns_mode == 'manual' && st.dns_server[1] == 'https://1.1.1.1/dns-query' &&
	sprintf('%J', st.lan_ifname) == '[ "br-lan", "br-guest" ]' && st.update_interval == '6' && st.best_interval == '6', st);


// Резервный канал mwan3: в сети только он — в статусе его узел, подбор не запускается.
let ms = getenv('STELLA_MWAN3_STATE');
mkdir(ms);
writefile(`${ms}/wan`, 'offline\n');
writefile(`${ms}/wwan`, 'online\n');
set_main({ backup_iface: 'wwan', backup_node: 'node_1' });
st = methods.status.call({ args: {} });
check('backup status', st.backup == 'wwan' && st.node?.id == 'node_1', st);
let nd = methods.nodes.call({ args: {} });
check('backup nodes', nd.backup == 'wwan' && length(nd.mwan3) == 2 && nd.mwan3[1].online, nd.mwan3);
check('backup pick', methods.node_pick.call({ args: {} }).error != null, null);
// Узел резервного канала подбирается через него — пока он работает, можно, без него — нет.
set_main({ backup_mode: 'best', backup_best_interval: '3' });
r = methods.node_pick.call({ args: { backup: true } });
check('backup pick on backup', r.error == null, r);
writefile(`${ms}/wan`, 'online\n');
check('backup pick off backup', methods.node_pick.call({ args: { backup: true } }).error != null, null);
st = methods.status.call({ args: {} });
check('backup off', st.backup == null && st.node == null, st);

// Флаги фоновых задач: «starting» — занято, PID живого процесса — занято, мёртвого — свободно.
let rd = getenv('STELLA_RUN_DIR');
task_script('t1', 'true');
check('task starting', task_busy('t1'), null);
writefile(`${rd}/t1.running`, '999999');
check('task dead pid', !task_busy('t1'), null);
check('task no flag', !task_busy('nope'), null);

// Скорость: итог из файла задачи — в статусе.
writefile(`${rd}/speed.json`, sprintf('%J', { at: 1, direct: 94.5, vpn_off: true }));
st = methods.status.call({ args: {} });
check('status speed', st.speed?.direct == 94.5 && st.speed.vpn_off && !st.speedtesting, st.speed);

// Имена наборов geosite и geoip: нет файла — пусто, есть — из него.
r = methods.geo_index.call({ args: {} });
check('geo_index empty', length(r.geosite) == 0 && !r.loading, r);
writefile(`${rd}/geo-index.json`, sprintf('%J', { at: 1, geosite: [ 'youtube' ], geoip: [ 'ru' ], itdog: [ { group: 'Services', files: [ 'Services/youtube.lst' ] } ] }));
r = methods.geo_index.call({ args: {} });
check('geo_index', r.geosite[0] == 'youtube' && r.geoip[0] == 'ru' && r.at == 1 && r.itdog[0].group == 'Services', r);

// DNS: без каталога — пусто, цепочка ручная — свои серверы (выше), DNS провайдера — массив; при
// подборе — только подобранные.
r = methods.dns_info.call({ args: {} });
check('dns_info', type(r.catalog) == 'array' && r.mode == 'manual' && length(r.chain) == 2 && type(r.isp) == 'array' && !r.checking, r);
let dd = getenv('STELLA_DNS_DIR');
mkdir(dd);
writefile(`${dd}/auto.json`, sprintf('%J', { servers: [ 'https://xbox-dns.ru/dns-query', 'bad' ], at: 5 }));
set_main({ dns_mode: 'geo' });
r = methods.dns_info.call({ args: {} });
check('dns_info geo', r.mode == 'geo' && sprintf('%J', r.chain) == '[ "https://xbox-dns.ru/dns-query" ]' && r.auto_at == 5, r);

// Подделки — массив путей (на машине разработчика может быть пустым); голос Discord — не стратегия.
let zd = getenv('STELLA_ZAPRET_DIR');
mkdir(zd);
mkdir(`${zd}/fake`);
writefile(`${zd}/fake/quic_x.bin`, 'x');
writefile(`${zd}/fake/stun.bin`, 'x');
writefile(`${zd}/catalog.json`, sprintf('%J', [ { name: 'voice', family: 'voice', args: [ '--a' ] }, { name: 'Gv1', family: 'gv', args: [ '--b' ] } ]));
r = methods.zapret_catalog.call({ args: {} });
check('zapret_catalog fakes', type(r.fakes) == 'array' && length(filter(r.fakes, (f) => match(f, /quic_x\.bin$/))) == 1 &&
	!length(filter(r.fakes, (f) => match(f, /\/stun\.bin$/))) && sprintf('%J', map(r.strategies, (x) => x.name)) == '[ "Gv1" ]', r);

print(failed ? `rpcd: ${failed} FAIL\n` : 'rpcd: OK\n');
exit(failed ? 1 : 0);
