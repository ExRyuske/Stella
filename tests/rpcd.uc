// Смоук-тест плагина rpcd: загрузка, методы на чтение и основные на запись.
// Системные вызовы (pgrep, ps, /etc/init.d/…) на машине разработчика просто ничего не находят.

'use strict';

import { writefile, readfile, mkdir } from 'fs';
import { task_busy, task_script } from 'stella.store';

let path = getenv('STELLA_UCI_JSON');
writefile(path, sprintf('%J', {
	main: { '.type': 'stella', enabled: '0', mode: 'all', default_action: 'direct' },
	node_1: { '.type': 'node', name: 'n', link: 'trojan://pw@tr.example.com:443#t' },
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

for (let m in [ 'status', 'nodes', 'lists', 'devices', 'zapret_info', 'zapret_catalog', 'update_info', 'log' ]) {
	let r;
	try { r = methods[m].call({ args: {} }); }
	catch (e) { r = { exception: e.message }; }
	check(m, type(r) == 'object' && !r.exception && !r.error, r);
}

let r = methods.list_add.call({ args: { items: [ { name: 'Мои сайты', entries: [ 'https://2ip.io/x', 'example.com' ] } ], action: 'vpn' } });
check('list_add', r.added == 1, r);
let conf = json(readfile(path));
let lid = filter(keys(conf), (k) => conf[k]['.type'] == 'list')[0];
check('list_add section', match(lid, /^list_[0-9a-f]{8}$/), conf);

r = methods.list_edit.call({ args: { id: lid, devices_mode: 'only', macs: [ 'AA:BB:CC:DD:EE:FF', 'bad' ] } });
conf = json(readfile(path));
check('list_edit devices', r.ok && conf[lid].devices_mode == 'only' && sprintf('%J', conf[lid].mac) == '[ "aa:bb:cc:dd:ee:ff" ]', conf[lid]);

r = methods.list_edit.call({ args: { id: lid, devices_mode: 'only', macs: [] } });
conf = json(readfile(path));
check('list_edit devices → all', conf[lid].devices_mode == null && conf[lid].mac == null, conf[lid]);

r = methods.device_set.call({ args: { mac: 'AA:BB:CC:DD:EE:01', name: 'TV', policy: 'vpn' } });
conf = json(readfile(path));
check('device_set', r.ok && conf.dev_aabbccddee01?.policy == 'vpn' && conf.dev_aabbccddee01?.name == 'TV', conf);
check('device_set bad policy', methods.device_set.call({ args: { mac: 'aa:bb:cc:dd:ee:01', policy: 'custom' } }).error != null, null);

let l = methods.lists.call({ args: {} }).lists[0];
check('lists entry', l.domains == 2 && l.devices_mode == 'all', l);

check('settings default', methods.settings.call({ args: {} }).block_doh == '0', null);
check('settings_set bad', methods.settings_set.call({ args: { values: { dns_direct: 'https://dns.google/dns-query' } } }).error != null, null);
check('settings_set unknown', methods.settings_set.call({ args: { values: { enabled: '1' } } }).error != null, null);
r = methods.settings_set.call({ args: { values: { dns_direct: 'https://1.1.1.1/dns-query', block_doh: false, lan_ifname: [ 'br-lan', 'br-guest' ], sub_interval: '6' } } });
let st = methods.settings.call({ args: {} });
check('settings_set', r.ok && st.dns_direct == 'https://1.1.1.1/dns-query' && st.block_doh == '0' &&
	sprintf('%J', st.lan_ifname) == '[ "br-lan", "br-guest" ]' && st.sub_interval == '6' && st.lists_interval == '24', st);

// Резервный канал mwan3: в сети только он — в статусе его узел, подбор не запускается;
// удаление узла снимает его с резервного канала.
let ms = getenv('STELLA_MWAN3_STATE');
mkdir(ms);
writefile(`${ms}/wan`, 'offline\n');
writefile(`${ms}/wwan`, 'online\n');
check('backup bad iface', methods.settings_set.call({ args: { values: { backup_iface: 'w an' } } }).error != null, null);
check('backup_vpn bad', methods.settings_set.call({ args: { values: { backup_vpn: 'yes' } } }).error != null, null);
r = methods.settings_set.call({ args: { values: { backup_iface: 'wwan', backup_node: 'node_1' } } });
st = methods.status.call({ args: {} });
check('backup status', r.ok && st.backup == 'wwan' && st.node?.id == 'node_1', st);
let nd = methods.nodes.call({ args: {} });
check('backup nodes', nd.backup == 'wwan' && length(nd.mwan3) == 2 && nd.mwan3[1].online, nd.mwan3);
check('backup pick', methods.node_pick.call({ args: {} }).error != null, null);
writefile(`${ms}/wan`, 'online\n');
st = methods.status.call({ args: {} });
check('backup off', st.backup == null && st.node == null, st);
methods.remove.call({ args: { id: 'node_1' } });
check('remove clears backup node', json(readfile(path)).main.backup_node == null, json(readfile(path)).main);

// Флаги фоновых задач: «starting» — занято, PID живого процесса — занято, мёртвого — свободно.
let rd = getenv('STELLA_RUN_DIR');
task_script('t1', 'true');
check('task starting', task_busy('t1'), null);
writefile(`${rd}/t1.running`, '999999');
check('task dead pid', !task_busy('t1'), null);
check('task no flag', !task_busy('nope'), null);

// Имена наборов meta-rules-dat: нет файла — пусто, есть — из него.
r = methods.meta_index.call({ args: {} });
check('meta_index empty', length(r.geosite) == 0 && !r.loading, r);
writefile(`${rd}/meta-index.json`, sprintf('%J', { at: 1, geosite: [ 'youtube' ], geoip: [ 'ru' ] }));
r = methods.meta_index.call({ args: {} });
check('meta_index', r.geosite[0] == 'youtube' && r.geoip[0] == 'ru' && r.at == 1, r);

print(failed ? `rpcd: ${failed} FAIL\n` : 'rpcd: OK\n');
exit(failed ? 1 : 0);
