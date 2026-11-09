// Смоук-тест плагина rpcd: загрузка, методы на чтение и основные на запись. Настройки страницы
// пишут в UCI сами (формы LuCI), у плагина — только состояние и действия.
// Системные вызовы (pgrep, ps, /etc/init.d/…) на машине разработчика просто ничего не находят.

'use strict';

import { writefile, readfile, mkdir } from 'fs';
import { task_busy, task_script } from 'stella.store';

let path = getenv('STELLA_UCI_JSON');
let ld = getenv('STELLA_LISTS_DIR');
writefile(path, sprintf('%J', {
	main: { '.type': 'stella', enabled: '0', default_action: 'direct' },
	node_1: { '.type': 'node', name: 'n', link: 'trojan://pw@tr.example.com:443#t' },
	list_a: { '.type': 'list', name: 'Мои сайты', action: 'vpn', entry: [ 'https://2ip.io/x', 'example.com' ] },
	// Интерфейсы mwan3 (заглушка uci не различает конфиги).
	wan: { '.type': 'interface', enabled: '1' },
	wwan: { '.type': 'interface', enabled: '1' }
}));

let methods = loadfile('root/usr/share/rpcd/ucode/stella.uc')().stella;
let failed = 0;

function check(name, cond, info) {
	if (!cond) {
		failed++;
		warn(`FAIL rpcd ${name}: ${sprintf('%J', info)}\n`);
	}
}

for (let m in [ 'status', 'nodes', 'lists', 'zapret_info', 'zapret_catalog', 'update_info', 'log' ]) {
	let r;
	try { r = methods[m].call({ args: {} }); }
	catch (e) { r = { exception: e.message }; }
	check(m, type(r) == 'object' && !r.exception && !r.error, r);
}

// Списки: только счётчики — сами настройки страница читает из UCI.
mkdir(ld);
writefile(`${ld}/list_a.json`, sprintf('%J', { domains: [ 'youtube.com' ], cidrs: [ '1.2.3.0/24' ] }));
let l = methods.lists.call({ args: {} }).lists[0];
check('lists entry', l.id == 'list_a' && l.domains == 3 && l.cidrs == 1 && l.updated > 0, l);

// Каталог Zapret: у основных стратегий — параметры (форма копирует их в zapret_opts).
let zd = getenv('STELLA_ZAPRET_DIR');
mkdir(zd);
writefile(`${zd}/catalog.json`, sprintf('%J', [
	{ name: 'v1', family: 'v', args: [ '--filter-tcp=443', '--dpi-desync=fake' ] },
	{ name: 'Yv01', family: 'yv', args: [ '--filter-tcp=443' ] }
]));
let zc = methods.zapret_catalog.call({ args: {} });
check('zapret_catalog text', zc.strategies[0].text == '#v1\n--filter-tcp=443\n--dpi-desync=fake' && zc.strategies[1].text == null, zc.strategies);

// Резервный канал mwan3: в сети только он — в статусе его узел, подбор только для него.
let ms = getenv('STELLA_MWAN3_STATE');
mkdir(ms);
writefile(`${ms}/wan`, 'offline\n');
writefile(`${ms}/wwan`, 'online\n');
let conf = json(readfile(path));
conf.main.backup_iface = 'wwan';
conf.main.backup_node = 'node_1';
writefile(path, sprintf('%J', conf));
let st = methods.status.call({ args: {} });
check('backup status', st.backup == 'wwan' && st.node?.id == 'node_1', st);
let nd = methods.nodes.call({ args: {} });
check('backup nodes', nd.backup == 'wwan' && length(nd.mwan3) == 2 && nd.mwan3[1].online, nd.mwan3);
check('backup pick', methods.node_pick.call({ args: {} }).error != null, null);
let r = methods.node_pick.call({ args: { backup: true } });
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
writefile(`${rd}/geo-index.json`, sprintf('%J', { at: 1, geosite: [ 'youtube' ], geoip: [ 'ru' ] }));
r = methods.geo_index.call({ args: {} });
check('geo_index', r.geosite[0] == 'youtube' && r.geoip[0] == 'ru' && r.at == 1, r);

print(failed ? `rpcd: ${failed} FAIL\n` : 'rpcd: OK\n');
exit(failed ? 1 : 0);
