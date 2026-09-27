// ubus-объект stella для LuCI. Всё долгое (обновление подписок, проверка задержки)
// запускается в фоне: rpcd однопоточный, блокировать его нельзя.

'use strict';

import { cursor as uci_cursor } from 'uci';
import { readfile, writefile, popen, stat, unlink } from 'fs';
import { RUN_DIR, CACHE_DIR, LISTS_DIR, load_nodes, sub_label, load_lists, load_devices } from 'stella.store';
import { parse } from 'stella.uri';
import { fnv1a } from 'stella.util';

// Без явного load() первый add() молча ничего не делает.
function cursor() {
	let c = uci_cursor();
	c.load('stella');
	return c;
}

// Постоянное имя секции: анонимные cfgXXXX зависят от позиции и меняются при удалении
// соседних секций, а на имени держатся id узлов и файл кэша.
function new_section(uci, type, prefix, seed) {
	let name;
	for (let i = 0; !name || uci.get('stella', name); i++)
		name = `${prefix}_${fnv1a(`${seed}|${time()}|${i}`)}`;
	uci.set('stella', name, type);
	return name;
}

const XRAY_CONF = '/var/etc/stella/config.json';
const ZAPRET_DIR = getenv('STELLA_ZAPRET_DIR') || '/etc/stella/zapret';

function shq(s) {
	return "'" + replace(`${s}`, "'", "'\\''") + "'";
}

function running() {
	return system(`pgrep -f '^/usr/bin/xray run -c ${XRAY_CONF}' >/dev/null`) == 0;
}

function busy(name) {
	let st = stat(`${RUN_DIR}/${name}.running`);
	// Зависший флаг (например, процесс убит) не должен блокировать навсегда.
	return st != null && time() - st.mtime < 600;
}

function spawn(name, cmd) {
	if (busy(name))
		return false;
	let lock = `${RUN_DIR}/${name}.running`;
	system(`mkdir -p ${RUN_DIR}; ( touch ${lock}; { ${cmd}; } >${RUN_DIR}/${name}.log 2>&1; rm -f ${lock} ) </dev/null >/dev/null 2>&1 &`);
	return true;
}

const ACTIONS = { vpn: true, zapret: true, direct: true, block: true };

function cmd_output(cmd) {
	let p = popen(cmd, 'r');
	if (!p)
		return null;
	let out = p.read('all');
	p.close();
	return out;
}

const IPV4_DNS = (v) => match(v, /^([a-z+]+:\/\/)?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) != null;
const PORTS = (v) => v == '' || match(v, /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) != null;
const HOURS = (v) => match(v, /^[0-9]{1,4}$/) != null && +v <= 8760;

// apply: restart — меняется конфиг xray; reload — только правила, nfqws, расписание.
const SETTINGS = {
	dns_remote: { title: 'DNS через VPN', def: 'https://1.1.1.1/dns-query', apply: 'restart', check: (v) => v != '' },
	dns_direct: { title: 'DNS напрямую', def: 'https://77.88.8.8/dns-query', apply: 'restart', check: IPV4_DNS },
	dns_hijack: { title: 'Перехват DNS', def: '1', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	block_doh: { title: 'Блокировка DoH', def: '1', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	log_level: { title: 'Лог xray', def: 'warning', apply: 'restart', check: (v) => v in [ 'error', 'warning', 'info', 'debug' ] },
	sub_interval: { title: 'Обновление подписок', def: '12', apply: 'reload', check: HOURS },
	lists_interval: { title: 'Обновление списков', def: '24', apply: 'reload', check: HOURS },
	lan_ifname: { title: 'Интерфейсы LAN', def: [ 'br-lan' ], apply: 'reload',
		check: (v) => type(v) == 'array' && length(v) && length(filter(v, (i) => !match(i, /^[A-Za-z0-9._-]+$/))) == 0 },
	zapret_bin: { title: 'Программа nfqws', def: '', apply: 'reload', check: (v) => v == '' || match(v, /^\/[A-Za-z0-9._\/-]+$/) != null },
	zapret_opts: { title: 'Стратегия', def: '', apply: 'reload' },
	zapret_strategy: { title: 'Стратегия из каталога', def: '', apply: 'reload' },
	zapret_yt: { title: 'Стратегия для YouTube', def: '', apply: 'reload' },
	zapret_discord: { title: 'Discord', def: '0', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	zapret_games: { title: 'Игры', def: '0', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	zapret_test_interval: { title: 'Автоподбор по расписанию', def: '0', apply: 'reload', check: (v) => v in [ '0', '7', '30' ] },
	zapret_tcp_ports: { title: 'Порты TCP', def: '80,443', apply: 'reload', check: PORTS },
	zapret_udp_ports: { title: 'Порты UDP', def: '443', apply: 'reload', check: PORTS }
};

// Работает ли чужой nfqws (отдельная служба zapret), а не запущенный Stella (--qnum=202).
function zapret_foreign_nfqws() {
	for (let line in split(cmd_output('ps w') || '', '\n'))
		if (match(line, /nfqws/) && !match(line, /--qnum=202/) && !match(line, /ps w/))
			return true;
	return false;
}

function str_list(v) {
	return filter(map((type(v) == 'array') ? v : [], (x) => trim(`${x}`)), (x) => x != '');
}

// Изменились списки или устройства: xray не трогаем (procd оставит процесс, если его
// команда не изменилась), пересобираются только правила и nfqws.
function reload_if_enabled(uci) {
	if (uci.get('stella', 'main', 'enabled') == '1')
		system('/etc/init.d/stella reload </dev/null >/dev/null 2>&1 &');
}

function lists_update_bg(uci, id) {
	let apply = (uci.get('stella', 'main', 'enabled') == '1') ? '; /etc/init.d/stella reload' : '';
	return spawn('lists', `/usr/bin/stella lists ${id || ''}${apply}`);
}

function restart_if_enabled(uci) {
	if (uci.get('stella', 'main', 'enabled') == '1')
		system('/etc/init.d/stella restart </dev/null >/dev/null 2>&1 &');
}

// Источники узлов для группировки в интерфейсе: подписки (даже пустые) и отдельные ссылки.
function sources(uci, nodes) {
	let count = {};
	for (let n in nodes)
		count[n.source_id] = (count[n.source_id] || 0) + 1;

	let res = [];
	uci.foreach('stella', 'subscription', (s) => {
		let st = stat(`${CACHE_DIR}/${s['.name']}.json`);
		push(res, {
			id: s['.name'],
			kind: 'subscription',
			name: sub_label(s),
			url: s.url,
			user_agent: s.user_agent || '',
			enabled: s.enabled != '0',
			updated: st?.mtime,
			count: count[s['.name']] || 0
		});
	});
	if (count.manual)
		push(res, { id: 'manual', kind: 'manual', name: 'manual', enabled: true, count: count.manual });
	return res;
}

function host_of(url) {
	let m = match(url, /^https?:\/\/([^\/:?#]+)/);
	return m ? m[1] : url;
}

const methods = {
	status: {
		call: function() {
			let uci = cursor();
			let sel = uci.get('stella', 'main', 'node');
			let node = null;
			if (sel)
				for (let n in load_nodes(uci))
					if (n.id == sel)
						node = { id: n.id, name: n.name, protocol: n.protocol, source: n.source };

			return {
				enabled: uci.get('stella', 'main', 'enabled') == '1',
				running: running(),
				node_id: sel,
				node,
				updating: busy('update'),
				pinging: busy('ping'),
				update_log: readfile(`${RUN_DIR}/update.log`) || ''
			};
		}
	},

	nodes: {
		call: function() {
			let uci = cursor();
			let errors = [];
			let all = load_nodes(uci, errors);
			let nodes = map(all, (n) => ({
				id: n.id,
				name: n.name,
				protocol: n.protocol,
				network: n.network,
				security: n.security,
				source: n.source_id,
				warnings: n.warnings
			}));

			let auto = uci.get('stella', 'main', 'auto_node') || [];
			return {
				selected: uci.get('stella', 'main', 'node'),
				select_mode: uci.get('stella', 'main', 'select_mode') || 'single',
				auto_nodes: (type(auto) == 'array') ? auto : [ auto ],
				sources: sources(uci, all),
				nodes,
				errors,
				ping: json(readfile(`${RUN_DIR}/ping.json`) || '{}'),
				pinging: busy('ping'),
				updating: busy('update'),
				update_log: readfile(`${RUN_DIR}/update.log`) || ''
			};
		}
	},

	select: {
		args: { id: 'id' },
		call: function(req) {
			let uci = cursor();
			let id = req.args?.id;
			let found = false;
			for (let n in load_nodes(uci))
				if (n.id == id)
					found = true;
			if (!found)
				return { error: 'узел не найден' };

			uci.set('stella', 'main', 'node', id);
			uci.commit('stella');
			restart_if_enabled(uci);
			return { ok: true };
		}
	},

	// Автовыбор: mode — single/auto; id + on — отметить узел звёздочкой или снять.
	auto_set: {
		args: { mode: 'mode', id: 'id', on: true },
		call: function(req) {
			let uci = cursor();
			let a = req.args || {};
			if (a.mode != null) {
				if (!(a.mode in [ 'single', 'auto' ]))
					return { error: 'некорректный режим' };
				uci.set('stella', 'main', 'select_mode', a.mode);
			}
			if (a.id != null) {
				let ids = str_list(uci.get('stella', 'main', 'auto_node'));
				ids = filter(ids, (x) => x != a.id);
				if (a.on) {
					if (length(ids) >= 30)
						return { error: 'в автовыборе не больше 30 узлов' };
					push(ids, a.id);
				}
				length(ids) ? uci.set('stella', 'main', 'auto_node', ids) : uci.delete('stella', 'main', 'auto_node');
			}
			uci.commit('stella');
			if (uci.get('stella', 'main', 'select_mode') == 'auto' || a.mode != null)
				restart_if_enabled(uci);
			return { ok: true };
		}
	},

	update: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args?.id;
			if (id && !match(id, /^[A-Za-z0-9_]+$/))
				return { error: 'некорректный id' };
			return { started: spawn('update', `/usr/bin/stella update ${id || ''}`) };
		}
	},

	// Вставленный текст: строки http(s):// — подписки, остальное — ссылки на узлы.
	add: {
		args: { text: 'text', name: 'name' },
		call: function(req) {
			let uci = cursor();
			let lines = filter(map(split(req.args?.text || '', /\r?\n/), (l) => trim(l)), (l) => l != '');
			let subs = 0, links = 0, errors = [];

			for (let l in lines) {
				if (match(l, /^https?:\/\/\S+$/)) {
					let sid = new_section(uci, 'subscription', 'sub', l);
					uci.set('stella', sid, 'name', (length(lines) == 1 && req.args.name) ? req.args.name : host_of(l));
					uci.set('stella', sid, 'url', l);
					uci.set('stella', sid, 'enabled', '1');
					subs++;
					continue;
				}
				let n = parse(l);
				if (n.error) {
					push(errors, { line: substr(l, 0, 48), error: n.error });
					continue;
				}
				let sid = new_section(uci, 'node', 'node', l);
				uci.set('stella', sid, 'name', (length(lines) == 1 && req.args.name) ? req.args.name : n.name);
				uci.set('stella', sid, 'link', l);
				links++;
			}

			if (subs || links)
				uci.commit('stella');
			if (subs)
				spawn('update', '/usr/bin/stella update');
			return { subscriptions: subs, links, errors };
		}
	},

	// Изменение подписки: название, URL, User-Agent, вкл/выкл.
	edit: {
		args: { id: 'id', name: 'name', url: 'url', user_agent: 'user_agent', enabled: true },
		call: function(req) {
			let uci = cursor();
			let a = req.args || {};
			if (uci.get('stella', a.id) != 'subscription')
				return { error: 'подписка не найдена' };
			if (a.url != null && !match(a.url, /^https?:\/\/\S+$/))
				return { error: 'нужна ссылка http(s)://' };
			for (let k in [ 'name', 'url', 'user_agent' ])
				if (a[k] != null)
					uci.set('stella', a.id, k, a[k]);
			if (a.enabled != null)
				uci.set('stella', a.id, 'enabled', a.enabled ? '1' : '0');
			uci.commit('stella');
			restart_if_enabled(uci);
			return { ok: true };
		}
	},

	// Удаление подписки (вместе с кэшем) или отдельной ссылки.
	remove: {
		args: { id: 'id' },
		call: function(req) {
			let uci = cursor();
			let id = req.args?.id;
			let t = uci.get('stella', id);
			if (t != 'subscription' && t != 'node')
				return { error: 'не найдено' };
			uci.delete('stella', id);
			uci.commit('stella');
			if (t == 'subscription')
				unlink(`${CACHE_DIR}/${id}.json`);
			return { ok: true };
		}
	},

	set_enabled: {
		args: { enabled: true },
		call: function(req) {
			let uci = cursor();
			let on = !!req.args?.enabled;
			uci.set('stella', 'main', 'enabled', on ? '1' : '0');
			uci.commit('stella');
			system(`/etc/init.d/stella ${on ? 'restart' : 'stop'} </dev/null >/dev/null 2>&1 &`);
			return { ok: true };
		}
	},

	ping: {
		args: { ids: [] },
		call: function(req) {
			let ids = filter(req.args?.ids || [], (id) => type(id) == 'string' && match(id, /^[A-Za-z0-9_]+$/));
			return { started: spawn('ping', `/usr/bin/stella ping ${join(' ', ids)}`) };
		}
	},

	restart: {
		call: function() {
			restart_if_enabled(cursor());
			return { ok: true };
		}
	},

	// Выходной IP через socks-вход xray: показывает, что трафик реально идёт через узел.
	check: {
		call: function() {
			if (!running())
				return { error: 'служба не запущена' };
			let port = +(cursor().get('stella', 'main', 'socks_port') || 10808);
			let out = cmd_output(`curl -s --max-time 8 -w '\\n%{time_total}' --socks5-hostname 127.0.0.1:${port} https://ipinfo.io/json`);
			let lines = split(trim(out || ''), '\n');
			let t = +pop(lines);
			let info = json(join('\n', lines) || 'null');
			if (type(info) != 'object' || !info.ip)
				return { error: 'нет ответа через прокси' };
			return { ip: info.ip, country: info.country, org: info.org, ms: int(t * 1000) };
		}
	},

	lists: {
		call: function() {
			let uci = cursor();
			return {
				default_action: uci.get('stella', 'main', 'default_action') || 'vpn',
				lists: map(load_lists(uci), (l) => ({
					id: l.id, name: l.name, enabled: l.enabled, action: l.action,
					urls: l.urls, entries: l.entries, updated: l.updated,
					domains: length(l.domains), cidrs: length(l.cidrs),
					devices_mode: l.devices_mode, macs: l.macs
				})),
				updating: busy('lists'),
				update_log: readfile(`${RUN_DIR}/lists.log`) || ''
			};
		}
	},

	// Добавление: items — массив { name, urls, entries }; у всех одно действие.
	list_add: {
		args: { items: [], action: 'action', devices_mode: 'devices_mode', macs: [] },
		call: function(req) {
			let uci = cursor();
			let action = ACTIONS[req.args?.action] ? req.args.action : 'vpn';
			let macs = map(filter(str_list(req.args?.macs), (m) => match(m, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)), (m) => lc(m));
			let dmode = (req.args?.devices_mode in [ 'only', 'except' ] && length(macs)) ? req.args.devices_mode : null;
			let added = 0;
			for (let it in req.args?.items || []) {
				let urls = filter(str_list(it.urls), (u) => match(u, /^https?:\/\/\S+$/));
				let entries = str_list(it.entries);
				if (!length(urls) && !length(entries))
					continue;
				let sid = new_section(uci, 'list', 'list', it.name || urls[0] || entries[0]);
				uci.set('stella', sid, 'name', it.name || urls[0] || 'список');
				uci.set('stella', sid, 'action', action);
				uci.set('stella', sid, 'enabled', '1');
				if (length(urls))
					uci.set('stella', sid, 'url', urls);
				if (length(entries))
					uci.set('stella', sid, 'entry', entries);
				if (dmode) {
					uci.set('stella', sid, 'devices_mode', dmode);
					uci.set('stella', sid, 'mac', macs);
				}
				added++;
			}
			if (!added)
				return { error: 'нечего добавлять' };
			uci.commit('stella');
			lists_update_bg(uci);
			return { added };
		}
	},

	list_edit: {
		args: { id: 'id', name: 'name', urls: [], entries: [], action: 'action', enabled: true, devices_mode: 'devices_mode', macs: [] },
		call: function(req) {
			let uci = cursor();
			let a = req.args || {};
			if (uci.get('stella', a.id) != 'list')
				return { error: 'список не найден' };
			if (a.name != null)
				uci.set('stella', a.id, 'name', a.name);
			if (a.action != null && ACTIONS[a.action])
				uci.set('stella', a.id, 'action', a.action);
			if (a.enabled != null)
				uci.set('stella', a.id, 'enabled', a.enabled ? '1' : '0');
			let refetch = false;
			if (a.urls != null) {
				let urls = filter(str_list(a.urls), (u) => match(u, /^https?:\/\/\S+$/));
				refetch = sprintf('%J', urls) != sprintf('%J', str_list(uci.get('stella', a.id, 'url')));
				length(urls) ? uci.set('stella', a.id, 'url', urls) : uci.delete('stella', a.id, 'url');
			}
			if (a.entries != null) {
				let e = str_list(a.entries);
				length(e) ? uci.set('stella', a.id, 'entry', e) : uci.delete('stella', a.id, 'entry');
			}
			if (a.devices_mode != null) {
				let macs = map(filter(str_list(a.macs), (m) => match(m, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)), (m) => lc(m));
				if (a.devices_mode in [ 'only', 'except' ] && length(macs)) {
					uci.set('stella', a.id, 'devices_mode', a.devices_mode);
					uci.set('stella', a.id, 'mac', macs);
				}
				else {
					uci.delete('stella', a.id, 'devices_mode');
					uci.delete('stella', a.id, 'mac');
				}
			}
			uci.commit('stella');
			if (refetch)
				lists_update_bg(uci, a.id);
			else
				reload_if_enabled(uci);
			return { ok: true };
		}
	},

	list_remove: {
		args: { id: 'id' },
		call: function(req) {
			let uci = cursor();
			let id = req.args?.id;
			if (uci.get('stella', id) != 'list')
				return { error: 'список не найден' };
			uci.delete('stella', id);
			uci.commit('stella');
			unlink(`${LISTS_DIR}/${id}.json`);
			reload_if_enabled(uci);
			return { ok: true };
		}
	},

	// Порядок важен: срабатывает первый совпавший список.
	list_move: {
		args: { id: 'id', dir: 0 },
		call: function(req) {
			let uci = cursor();
			let id = req.args?.id, dir = +req.args?.dir;
			let all = [], ids = [];
			uci.foreach('stella', null, (s) => { push(all, s['.name']); if (s['.type'] == 'list') push(ids, s['.name']); });
			let i = index(ids, id), j = i + dir;
			if (i < 0 || j < 0 || j >= length(ids))
				return { ok: false };
			uci.reorder('stella', id, index(all, ids[j]));
			uci.commit('stella');
			reload_if_enabled(uci);
			return { ok: true };
		}
	},

	lists_update: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args?.id;
			if (id && !match(id, /^[A-Za-z0-9_]+$/))
				return { error: 'некорректный id' };
			return { started: lists_update_bg(cursor(), id) };
		}
	},

	set_default_action: {
		args: { action: 'action' },
		call: function(req) {
			let a = req.args?.action;
			if (!(a in [ 'vpn', 'direct', 'zapret' ]))
				return { error: 'нужно vpn, direct или zapret' };
			let uci = cursor();
			uci.set('stella', 'main', 'default_action', a);
			uci.commit('stella');
			reload_if_enabled(uci);
			return { ok: true };
		}
	},

	// Устройства: настроенные + известные по DHCP и ARP (только с интерфейсов LAN).
	devices: {
		call: function() {
			let uci = cursor();
			let seen = {};
			let res = [];
			for (let d in load_devices(uci)) {
				d.configured = true;
				seen[d.mac] = d;
				push(res, d);
			}
			let add = (mac, ip, host) => {
				mac = lc(mac || '');
				if (!match(mac, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/))
					return;
				let d = seen[mac];
				if (!d) {
					d = seen[mac] = { id: null, mac, name: '', policy: 'global', configured: false };
					push(res, d);
				}
				d.ip ??= ip;
				d.hostname ??= (host && host != '*') ? host : null;
			};
			for (let l in split(readfile('/tmp/dhcp.leases') || '', '\n')) {
				let f = split(l, ' ');
				if (length(f) >= 4)
					add(f[1], f[2], f[3]);
			}
			let lan = uci.get('stella', 'main', 'lan_ifname') || [ 'br-lan' ];
			for (let ifn in (type(lan) == 'array') ? lan : [ lan ]) {
				if (!match(ifn, /^[A-Za-z0-9._-]+$/))
					continue;
				for (let l in split(cmd_output(`ip -4 neigh show dev ${ifn}`) || '', '\n')) {
					let m = match(l, /^([0-9.]+) lladdr ([0-9a-f:]+)/);
					if (m)
						add(m[2], m[1], null);
				}
			}
			return { devices: res };
		}
	},

	// Режим устройства: global — по спискам, vpn — всё через VPN, direct — всё напрямую.
	device_set: {
		args: { mac: 'mac', name: 'name', policy: 'policy' },
		call: function(req) {
			let uci = cursor();
			let a = req.args || {};
			let mac = lc(a.mac || '');
			if (!match(mac, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/))
				return { error: 'некорректный MAC' };
			let sid = 'dev_' + replace(mac, /:/g, '');
			if (uci.get('stella', sid) != 'device')
				uci.set('stella', sid, 'device');
			uci.set('stella', sid, 'mac', mac);
			if (a.name != null)
				a.name == '' ? uci.delete('stella', sid, 'name') : uci.set('stella', sid, 'name', a.name);
			if (a.policy != null) {
				if (!(a.policy in [ 'global', 'vpn', 'direct' ]))
					return { error: 'некорректный режим' };
				uci.set('stella', sid, 'policy', a.policy);
			}
			uci.commit('stella');
			reload_if_enabled(uci);
			return { ok: true, id: sid };
		}
	},

	device_remove: {
		args: { id: 'id' },
		call: function(req) {
			let uci = cursor();
			if (uci.get('stella', req.args?.id) != 'device')
				return { error: 'не найдено' };
			uci.delete('stella', req.args.id);
			uci.commit('stella');
			reload_if_enabled(uci);
			return { ok: true };
		}
	},

	// Сведения для вкладки Zapret: где nfqws, работает ли отдельная служба zapret,
	// её стратегия и порты — для импорта.
	zapret_info: {
		call: function() {
			let z = uci_cursor();
			z.load('zapret');
			let bins = filter([ '/opt/zapret/nfq/nfqws', '/opt/zapret2/nfq2/nfqws2', '/usr/bin/nfqws', '/usr/bin/nfqws2' ], (b) => stat(b) != null);
			return {
				binaries: bins,
				service_enabled: system('/etc/init.d/zapret enabled 2>/dev/null') == 0,
				service_running: zapret_foreign_nfqws(),
				leftover_tables: system('nft list table inet zapret >/dev/null 2>&1 || nft list table inet zapret2 >/dev/null 2>&1') == 0,
				stella_nfqws: system("pgrep -f 'nfqws --qnum=202' >/dev/null") == 0,
				import_opts: z.get('zapret', 'config', 'NFQWS_OPT'),
				import_tcp: z.get('zapret', 'config', 'NFQWS_PORTS_TCP'),
				import_udp: z.get('zapret', 'config', 'NFQWS_PORTS_UDP')
			};
		}
	},

	// Обновления: проверка и установка идут в фоне (apk update и скачивание — долго).
	update_info: {
		call: function() {
			return {
				info: json(readfile(`${RUN_DIR}/update.json`) || 'null'),
				checking: busy('upcheck'),
				installing: busy('upgrade'),
				log: readfile(`${RUN_DIR}/upgrade.log`) || ''
			};
		}
	},

	update_check: {
		call: function() {
			return { started: spawn('upcheck', '/usr/bin/stella upgrade check') };
		}
	},

	update_install: {
		args: { what: 'what' },
		call: function(req) {
			let what = req.args?.what;
			if (!(what in [ 'stella', 'xray' ]))
				return { error: 'нужно stella или xray' };
			return { started: spawn('upgrade', `/usr/bin/stella upgrade ${what}`) };
		}
	},

	// Каталог стратегий, результаты автоподбора и ход текущей проверки.
	zapret_catalog: {
		call: function() {
			let uci = cursor();
			let cat = json(readfile(`${ZAPRET_DIR}/catalog.json`) || '[]');
			let lines = split(uci.get('stella', 'main', 'zapret_opts') || '', '\n');
			// Имя — из настроек, а у импортированной — из первой строки «#v7»; своя — если
			// такого имени в каталоге нет.
			let current = uci.get('stella', 'main', 'zapret_strategy') || match(trim(lines[0] || ''), /^#(.+)$/)?.[1] || null;
			let in_catalog = length(filter(cat, (s) => s.name == current)) > 0;
			return {
				strategies: map(cat, (s) => ({ name: s.name, family: s.family })),
				updated: +(readfile(`${ZAPRET_DIR}/catalog.updated`) || 0) || null,
				current,
				custom: !!uci.get('stella', 'main', 'zapret_opts') && !in_catalog,
				results: json(readfile(`${ZAPRET_DIR}/results.json`) || 'null'),
				progress: json(readfile(`${RUN_DIR}/ztest.json`) || 'null'),
				testing: busy('ztest'),
				updating: busy('zcatalog')
			};
		}
	},

	zapret_apply: {
		args: { name: 'name' },
		call: function(req) {
			let name = req.args?.name;
			if (!name)
				return { error: 'не указана стратегия' };
			return (system(`/usr/bin/stella zapret-apply ${shq(name)} >/dev/null 2>&1`) == 0) ? { ok: true } : { error: 'стратегии нет в каталоге' };
		}
	},

	zapret_catalog_update: {
		call: function() {
			return { started: spawn('zcatalog', '/usr/bin/stella zapret-catalog') };
		}
	},

	// scope: all | v | yv | fs | имя стратегии; apply — применить лучшую, если она лучше текущей.
	zapret_test: {
		args: { scope: 'scope', apply: true },
		call: function(req) {
			let scope = req.args?.scope || 'all';
			return { started: spawn('ztest', `/usr/bin/stella zapret-test ${shq(scope)}${req.args?.apply ? ' --apply' : ''}`) };
		}
	},

	zapret_test_stop: {
		call: function() {
			writefile(`${RUN_DIR}/ztest.stop`, '1');
			return { ok: true };
		}
	},

	// Отдельная служба zapret конфликтует с Zapret в Stella (две очереди на одни пакеты).
	zapret_service_off: {
		call: function() {
			system('/etc/init.d/zapret stop >/dev/null 2>&1; /etc/init.d/zapret disable >/dev/null 2>&1');
			// Его nft-таблицы иногда остаются после остановки — убираем, раз nfqws уже нет.
			if (!zapret_foreign_nfqws())
				system('nft delete table inet zapret 2>/dev/null; nft delete table inet zapret2 2>/dev/null');
			return { ok: true, running: zapret_foreign_nfqws() };
		}
	},

	// Настройки, которые меняются со страниц интерфейса (белый список с проверкой).
	settings: {
		call: function() {
			let uci = cursor();
			let res = {};
			for (let k, d in SETTINGS)
				res[k] = uci.get('stella', 'main', k) ?? d.def;
			return res;
		}
	},

	settings_set: {
		args: { values: {} },
		call: function(req) {
			let uci = cursor();
			let v = req.args?.values || {};
			let action = null;
			for (let k, val in v) {
				let d = SETTINGS[k];
				if (!d)
					return { error: `неизвестная настройка ${k}` };
				if (type(val) == 'bool')
					val = val ? '1' : '0';
				if (type(val) == 'array')
					val = str_list(val);
				else
					val = trim(`${val ?? ''}`);
				if (d.check && !d.check(val))
					return { error: `${d.title}: некорректное значение` };
				(val == '' || (type(val) == 'array' && !length(val))) ? uci.delete('stella', 'main', k) : uci.set('stella', 'main', k, val);
				if (d.apply == 'restart' || action == null)
					action = d.apply;
			}
			uci.commit('stella');
			if (action == 'restart')
				restart_if_enabled(uci);
			else if (action == 'reload')
				reload_if_enabled(uci);
			return { ok: true };
		}
	},

	log: {
		call: function() {
			return { log: cmd_output("logread -l 300 -e 'xray\\|stella'") || '' };
		}
	}
};

return { stella: methods };
