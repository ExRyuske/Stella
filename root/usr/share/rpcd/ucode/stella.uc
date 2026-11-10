// ubus-объект stella для LuCI. Всё долгое (обновление подписок, проверка задержки)
// запускается в фоне: rpcd однопоточный, блокировать его нельзя.

'use strict';

import { cursor as uci_cursor } from 'uci';
import { readfile, writefile, popen, stat, unlink, glob } from 'fs';
import { RUN_DIR, CACHE_DIR, TRACE_URL, LISTS_DIR, DNS_DIR, DNS_MAX, dns_chain, dns_fallback, isp_dns, STAB_PATH, ZAPRET_DIR, ZAPRET_QNUM, ZT_QNUM, TIMEOUT, AUTO_MAX, SOCKS_PORT, read_json, load_nodes, is_warp, sub_label, load_lists, load_devices, lan_ifnames, xray_pid, task_busy, task_script, mwan3_ifaces, on_backup } from 'stella.store';
import { parse } from 'stella.uri';
import { fnv1a, mac_list, try_json } from 'stella.util';
import { dns_set, ACTIONS } from 'stella.firewall';
import { doh_url, is_ipv4, KINDS as DNS_KINDS } from 'stella.dns';
import { FAKE_DIR } from 'stella.zapret';
import { trace_info } from 'stella.warp';

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

// Проверка интернета напрямую: Яндекс DNS по HTTPS — открыт и на мобильных белых списках.
function shq(s) {
	return "'" + replace(`${s}`, "'", "'\\''") + "'";
}

function running() {
	return xray_pid() != null;
}

function busy(name) {
	return task_busy(name);
}

function spawn(name, cmd) {
	if (busy(name))
		return false;
	system(`sh ${task_script(name, cmd)} </dev/null >/dev/null 2>&1 &`);
	return true;
}

function cmd_output(cmd) {
	let p = popen(cmd, 'r');
	if (!p)
		return null;
	let out = p.read('all');
	p.close();
	return out;
}

const PORTS = (v) => v == '' || match(v, /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) != null;
const HOURS = (v) => match(v, /^[0-9]{1,4}$/) != null && +v <= 8760;

// apply: restart — меняется конфиг xray; reload — только правила, nfqws, расписание.
const SETTINGS = {
	// DNS: geo — подобранные проверкой серверы обхода геоблокировок; manual — свои (dns_server).
	dns_mode: { title: 'Выбор DNS', def: 'geo', apply: 'reload', check: (v) => v in [ 'geo', 'manual' ] },
	dns_server: { title: 'Серверы DNS', def: [], apply: 'reload',
		check: (v) => type(v) == 'array' && length(v) <= DNS_MAX && length(filter(v, (u) => !doh_url(u))) == 0 },
	// Запасные после цепочки: 'isp' — DNS провайдера, IPv4 — обычный DNS, https://… — DoH.
	dns_fallback: { title: 'Запасные DNS', def: [ 'isp' ], apply: 'reload',
		check: (v) => type(v) == 'array' && length(v) <= DNS_MAX && length(filter(v, (x) => !(x == 'isp' || is_ipv4(x) || doh_url(x)))) == 0 },
	// Расписание подбора серверов обхода, в часах (0 — вручную); планировщик читает его сам.
	dns_interval: { title: 'Подбор DNS', def: '24', check: HOURS },
	dns_hijack: { title: 'Перехват DNS', def: '1', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	block_ipv6: { title: 'Блокировка IPv6', def: '1', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	log_level: { title: 'Лог xray', def: 'warning', apply: 'restart', check: (v) => v in [ 'error', 'warning', 'info', 'debug' ] },
	best_from: { title: 'Из каких узлов подбирать', def: '', apply: 'reload', check: (v) => match(v, /^[A-Za-z0-9_]*$/) != null },
	best_interval: { title: 'Подбор узла', def: '6', apply: 'reload', check: HOURS },
	node_missing: { title: 'Если узел пропал', def: 'stop', apply: 'restart', check: (v) => v in [ 'stop', 'best' ] },
	// Резервный канал mwan3 и его узел: xray перезапустится, только если канал уже работает.
	backup_iface: { title: 'Резервный канал', def: '', apply: 'reload', check: (v) => match(v, /^[A-Za-z0-9_.-]*$/) != null },
	backup_node: { title: 'Узел резервного канала', def: '', apply: 'reload', check: (v) => match(v, /^[A-Za-z0-9_]*$/) != null },
	backup_vpn: { title: 'Резервный канал через VPN', def: '0', apply: 'reload', check: (v) => v in [ '0', '1' ] },
	// Узел резервного канала: вручную (backup_node) или лучший по проверке через этот канал.
	backup_mode: { title: 'Выбор узла резервного канала', def: 'single', apply: 'reload', check: (v) => v in [ 'single', 'best' ] },
	backup_best_from: { title: 'Из каких узлов подбирать для резервного канала', def: '', apply: 'reload', check: (v) => match(v, /^[A-Za-z0-9_]*$/) != null },
	backup_best_interval: { title: 'Подбор узла резервного канала', def: '6', apply: 'reload', check: HOURS },
	// Планировщик читает настройки сам — применять нечего. Одно расписание на все обновления:
	// подписки, списки, каталоги, новые версии.
	update_interval: { title: 'Обновление', def: '12', check: HOURS },
	lan_ifname: { title: 'Интерфейсы LAN', def: [ 'br-lan' ], apply: 'reload',
		check: (v) => type(v) == 'array' && length(v) && length(filter(v, (i) => !match(i, /^[A-Za-z0-9._-]+$/))) == 0 },
	zapret_bin: { title: 'Программа nfqws', def: '', apply: 'reload', check: (v) => v == '' || match(v, /^\/[A-Za-z0-9._\/-]+$/) != null },
	zapret_opts: { title: 'Стратегия', def: '', apply: 'reload' },
	zapret_strategy: { title: 'Стратегия из каталога', def: '', apply: 'reload' },
	zapret_yt: { title: 'Стратегия для YouTube', def: '', apply: 'reload' },
	zapret_discord: { title: 'Стратегия для Discord', def: '', apply: 'reload' },
	zapret_games: { title: 'Стратегия для игр', def: '', apply: 'reload' },
	zapret_games_fake: { title: 'Подделка для игр', def: '', apply: 'reload', check: (v) => v == '' || match(v, /^\/[A-Za-z0-9._\/-]+\.bin$/) != null },
	zapret_discord_fake: { title: 'Подделка для Discord', def: '', apply: 'reload', check: (v) => v == '' || match(v, /^\/[A-Za-z0-9._\/-]+\.bin$/) != null },
	zapret_test_main: { title: 'Автоподбор основной', def: '0', apply: 'reload', check: (v) => match(v, /^[0-9]{1,3}$/) != null },
	zapret_test_yt: { title: 'Автоподбор YouTube', def: '0', apply: 'reload', check: (v) => match(v, /^[0-9]{1,3}$/) != null },
	zapret_tcp_ports: { title: 'Порты TCP', def: '80,443', apply: 'reload', check: PORTS },
	zapret_udp_ports: { title: 'Порты UDP', def: '443', apply: 'reload', check: PORTS }
};

// Подделки (*.bin), что есть на роутере: из пакета zapret и копии Flowseal; без повторов по имени
// (у файла пакета приоритет), stun.bin — подделка по умолчанию — не в списке.
function fakes() {
	let res = {};
	for (let dir in [ `${ZAPRET_DIR}/fake`, FAKE_DIR ])
		for (let f in glob(`${dir}/*.bin`) || [])
			res[replace(f, /^.*\//, '')] = f;
	delete res['stun.bin'];
	return map(sort(keys(res)), (n) => res[n]);
}

// Работает ли чужой nfqws (отдельная служба zapret), а не запущенный Stella: свой — на
// очереди 202, проверочный при автоподборе — на 205.
function zapret_foreign_nfqws() {
	for (let line in split(cmd_output('ps w') || '', '\n'))
		if (match(line, /nfqws/) && !match(line, regexp(`--qnum=(${ZAPRET_QNUM}|${ZT_QNUM})( |$)`)) && !match(line, /ps w/))
			return true;
	return false;
}

function str_list(v) {
	return filter(map((type(v) == 'array') ? v : [], (x) => trim(`${x}`)), (x) => x != '');
}

// Наборы russia-v2ray-rules-dat по именам: geosite:youtube, geoip:ru.
function geo_list(v) {
	return filter(str_list(v), (g) => match(g, /^(geosite|geoip):[a-z0-9@!_.-]+$/));
}

// Применить изменения, если Stella включена: restart — изменился конфиг xray; reload —
// списки, устройства и т. п.: пересобираются правила и nfqws, а xray procd оставит, если
// его конфиг не изменился.
function apply_if_enabled(uci, action) {
	if (uci.get('stella', 'main', 'enabled') == '1')
		system(`/etc/init.d/stella ${action} </dev/null >/dev/null 2>&1 &`);
}

// Фоновая задача, после которой — reload, если Stella включена.
function spawn_reload(uci, name, cmd) {
	return spawn(name, cmd + ((uci.get('stella', 'main', 'enabled') == '1') ? '; /etc/init.d/stella reload' : ''));
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
	// WARP — всегда: узел создаётся кнопкой в этой группе.
	push(res, { id: 'warp', kind: 'warp', name: 'WARP', enabled: true, count: count.warp || 0 });
	return res;
}

// Выбранный узел без разбора всех подписок (статус запрашивается каждые 5 с): отдельная
// ссылка — это секция UCI, узел подписки — «<секция подписки>_<хеш>».
function find_node(uci, id) {
	if (!id)
		return null;
	if (uci.get('stella', id) == 'node') {
		let n = parse(uci.get('stella', id, 'link'));
		return n.error ? null : { id, name: uci.get('stella', id, 'name') || n.name, protocol: n.protocol,
			source: is_warp(uci.get_all('stella', id)) ? 'warp' : 'manual' };
	}
	let found = null;
	uci.foreach('stella', 'subscription', (s) => {
		if (found || s.enabled == '0' || index(id, `${s['.name']}_`) != 0)
			return;
		for (let n in read_json(`${CACHE_DIR}/${s['.name']}.json`, []))
			if (n.id == id)
				found = { id, name: n.name, protocol: n.protocol, source: sub_label(s) };
	});
	return found;
}

// Таблица Stella на месте: список одной цепочки, а не всей таблицы с тысячами адресов в сетах.
function nft_up() {
	return system('nft list chain inet stella prerouting >/dev/null 2>&1') == 0;
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
			// Работает резервный канал mwan3 — xray идёт через его узел (если он есть).
			let backup = on_backup(uci);
			let bnode = backup ? find_node(uci, uci.get('stella', 'main', 'backup_node')) : null;
			let node = bnode || find_node(uci, sel);

			return {
				enabled: uci.get('stella', 'main', 'enabled') == '1',
				running: running(),
				// Перехват на месте: правила nft (могли быть не приняты) и маршрут в xray
				// (без ip-full не добавляется) — без любого из них трафик идёт напрямую.
				intercept: nft_up() &&
					match(cmd_output('ip rule 2>/dev/null') || '', /lookup 1127/) != null,
				node_id: sel,
				node,
				backup: bnode ? backup : null,
				select_mode: uci.get('stella', 'main', 'select_mode') || 'single',
				updating: busy('update'),
				pinging: busy('ping'),
				update_log: readfile(`${RUN_DIR}/update.log`) || '',
				speed: read_json(`${RUN_DIR}/speed.json`, null),
				speedtesting: busy('speed')
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
				warnings: n.warnings,
				warp: n.source_id == 'warp'
			}));

			let auto = uci.get('stella', 'main', 'auto_node') || [];
			return {
				selected: uci.get('stella', 'main', 'node'),
				select_mode: uci.get('stella', 'main', 'select_mode') || 'single',
				auto_nodes: (type(auto) == 'array') ? auto : [ auto ],
				sources: sources(uci, all),
				nodes,
				errors,
				ping: read_json(`${RUN_DIR}/ping.json`, {}),
				stability: read_json(STAB_PATH, {}),
				mwan3: mwan3_ifaces(uci),
				backup: on_backup(uci),
				pinging: busy('ping'),
				picking: busy('pick'),
				updating: busy('update'),
				update_log: readfile(`${RUN_DIR}/update.log`) || '',
				warping: busy('warp'),
				warp_log: readfile(`${RUN_DIR}/warp.log`) || '',
				warp_check: read_json(`${RUN_DIR}/warp-check.json`, {})
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
			apply_if_enabled(uci, 'restart');
			return { ok: true };
		}
	},

	// Режим выбора: single — вручную, auto — самый быстрый из ★ (xray), best — лучший по
	// проверке (Stella сама раз в best_interval часов); id + on — отметить узел ★ или снять.
	auto_set: {
		args: { mode: 'mode', id: 'id', on: true },
		call: function(req) {
			let uci = cursor();
			let a = req.args || {};
			if (a.mode != null) {
				if (!(a.mode in [ 'single', 'auto', 'best' ]))
					return { error: 'некорректный режим' };
				uci.set('stella', 'main', 'select_mode', a.mode);
			}
			if (a.id != null) {
				let ids = str_list(uci.get('stella', 'main', 'auto_node'));
				ids = filter(ids, (x) => x != a.id);
				if (a.on) {
					if (length(ids) >= AUTO_MAX)
						return { error: `в автовыборе не больше ${AUTO_MAX} узлов` };
					push(ids, a.id);
				}
				length(ids) ? uci.set('stella', 'main', 'auto_node', ids) : uci.delete('stella', 'main', 'auto_node');
			}
			uci.commit('stella');
			if (uci.get('stella', 'main', 'select_mode') == 'auto' || a.mode != null)
				apply_if_enabled(uci, 'restart');
			// Включили подбор — первый подбор сразу, не дожидаясь расписания.
			if (a.mode == 'best' && !busy('ping'))
				spawn('pick', '/usr/bin/stella pick --apply');
			return { ok: true };
		}
	},

	// Создать узел Cloudflare WARP (в фоне: регистрация и проверка адресов идут до полуминуты).
	warp: {
		args: { name: 'name' },
		call: function(req) {
			let name = trim(req.args?.name || '');
			return { started: spawn('warp', `/usr/bin/stella warp ${(name != '') ? shq(name) : ''}`) };
		}
	},

	update: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args?.id;
			if (id && !match(id, /^[A-Za-z0-9_]+$/))
				return { error: 'некорректный id' };
			// После обновления — reload: xray перезапустится, только если у узла сменились ключи.
			return { started: spawn_reload(cursor(), 'update', `/usr/bin/stella update ${id || ''}`) };
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
				spawn_reload(uci, 'update', '/usr/bin/stella update');
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
			let was_enabled = uci.get('stella', a.id, 'enabled') != '0';
			for (let k in [ 'name', 'url', 'user_agent' ])
				if (a[k] != null)
					uci.set('stella', a.id, k, a[k]);
			if (a.enabled != null)
				uci.set('stella', a.id, 'enabled', a.enabled ? '1' : '0');
			uci.commit('stella');
			// Название, URL и User-Agent на работающий xray не влияют; включение и выключение
			// меняет набор узлов — reload перезапустит xray, только если конфиг изменился.
			if (a.enabled != null && !!a.enabled != was_enabled)
				apply_if_enabled(uci, 'reload');
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
			// Отметки автовыбора на удалённые узлы (сам узел или узлы подписки) — тоже прочь.
			let auto = str_list(uci.get('stella', 'main', 'auto_node'));
			let keep = filter(auto, (x) => x != id && index(x, `${id}_`) != 0);
			if (length(keep) != length(auto))
				length(keep) ? uci.set('stella', 'main', 'auto_node', keep) : uci.delete('stella', 'main', 'auto_node');
			let bn = uci.get('stella', 'main', 'backup_node');
			if (bn && (bn == id || index(bn, `${id}_`) == 0))
				uci.delete('stella', 'main', 'backup_node');
			uci.commit('stella');
			if (t == 'subscription')
				unlink(`${CACHE_DIR}/${id}.json`);
			apply_if_enabled(uci, 'reload');
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
			// Подбор узла занимает те же порты для временного xray.
			return { started: !busy('pick') && spawn('ping', `/usr/bin/stella ping ${join(' ', ids)}`) };
		}
	},

	// Подобрать лучший узел сейчас (режим «лучший по проверке»).
	// backup — подобрать узел резервного канала: мерить можно только через тот канал, для
	// которого выбирается узел.
	node_pick: {
		args: { backup: true },
		call: function(req) {
			let backup = !!req.args?.backup;
			if (backup != (on_backup(cursor()) != null))
				return { error: backup ? 'резервный канал сейчас не работает — подбор для него пройдёт, когда он включится' :
					'работает резервный канал — подбор узла отложен до возвращения основного' };
			return { started: !busy('ping') && spawn('pick', `/usr/bin/stella pick${backup ? ' --backup' : ''} --apply`) };
		}
	},

	restart: {
		call: function() {
			apply_if_enabled(cursor(), 'restart');
			return { ok: true };
		}
	},

	// Скорость загрузки напрямую и через VPN; итог — в status.
	speedtest: {
		call: function() {
			return { started: spawn('speed', '/usr/bin/stella speedtest') };
		}
	},

	// Выходной IP через socks-вход xray: показывает, что трафик реально идёт через узел.
	// Проверка по шагам всей цепочки, которой идёт трафик устройства: сервер VPN отвечает,
	// правила перехвата и маршрут на месте, DNS отвечает, а IP сайта из списка попал в сет.
	check: {
		call: function() {
			let uci = cursor();
			let steps = [];
			let step = (name, ok, detail) => push(steps, { name, ok, detail });

			// Сначала — напрямую, мимо VPN (трафик самого роутера Stella не перехватывает): не
			// отвечает и это — дело в провайдере, а не в VPN. Адрес, а не имя: DNS роутера идёт
			// через xray и сам зависит от VPN. Канал — тот, через который mwan3 сейчас пускает трафик.
			let bk = on_backup(uci);
			let up = map(filter(mwan3_ifaces(uci), (i) => i.online), (i) => i.name);
			let via = bk ? `резервный канал ${bk}` : length(up) ? `канал ${join(', ', up)}` : '';
			// Напрямую — trace Cloudflare по адресу из каталога DNS (сервер Cloudflare и его boot):
			// мимо DNS роутера, который сам идёт через xray.
			let cat = filter(read_json(`${DNS_DIR}/catalog.json`, []), (c) => c?.kind == 'plain' && doh_url(c.url) && is_ipv4(c.boot?.[0]));
			let probe = filter(cat, (c) => c.id == 'cloudflare')[0] || cat[0];
			if (!probe)
				step('Напрямую', false, 'каталог DNS ещё не загружен — проверить не на чем');
			else {
				let h = match(probe.url, /^https:\/\/([^\/:]+)/)[1], ip = probe.boot[0];
				let out = cmd_output(`curl -sk --max-time ${TIMEOUT.probe} --resolve ${shq(`${h}:443:${ip}`)} -w '\\n@%{time_total}' ${shq(`https://${h}/cdn-cgi/trace`)}`) || '';
				let tr = trace_info(out), ms = int(+(match(out, /@([0-9.]+)$/)?.[1] || 0) * 1000);
				if (tr)
					step('Напрямую', true, `${ip} отвечает, ${ms} мс, ${tr.loc}${via ? `, ${via}` : ''}`);
				else
					step('Напрямую', false, `${ip} не отвечает, нет интернета у провайдера${via ? ` (${via})` : ''}`);
			}

			if (!running()) {
				step('xray', false, 'служба не запущена, см. лог');
				return { steps };
			}

			let port = +(uci.get('stella', 'main', 'socks_port') || SOCKS_PORT);
			// Через VPN — trace Cloudflare: адрес выхода, страна, узел Cloudflare.
			let out = cmd_output(`curl -s --max-time ${TIMEOUT.probe} -w '\\n@%{time_total}' --socks5-hostname 127.0.0.1:${port} ${shq(TRACE_URL)}`) || '';
			let tr = trace_info(out), ip = match(out, /(^|\n)ip=([0-9a-f.:]+)/)?.[2];
			if (tr)
				step('Сервер VPN', true, `${ip || '?'}, ${tr.loc}, узел Cloudflare ${tr.colo || '?'}, ${int(+(match(out, /@([0-9.]+)$/)?.[1] || 0) * 1000)} мс`);
			else
				step('Сервер VPN', false, 'сервер не отвечает');

			let nft = nft_up();
			step('Перехват', nft, nft ? 'правила на месте' : 'nft не принял правила, см. лог');

			let route = match(cmd_output('ip rule 2>&1') || '', /lookup 1127/) && match(cmd_output('ip route show table 1127 2>&1') || '', /local/);
			step('Маршрут', !!route, route ? 'есть' : 'нет правила маршрутизации, нужен пакет ip-full');

			let nftset = match(cmd_output('dnsmasq --version 2>/dev/null') || '', /[ \t]nftset/) != null;
			if (!nftset)
				step('dnsmasq', false, 'без nftset, нужен dnsmasq-full');

			// Сайт из первого включённого списка «VPN»: резолвим через dnsmasq роутера и
			// смотрим, попал ли его IP в сет списка.
			let vpn = filter(load_lists(uci), (l) => l.enabled && l.action == 'vpn' && length(l.domains));
			let d = length(vpn) ? vpn[0].domains[0] : 'google.com';
			let ips = filter(map(match(cmd_output(`nslookup ${shq(d)} 127.0.0.1 2>&1`) || '', /Address:?[ \t]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/g) || [],
				(m) => m[1]), (ip) => substr(ip, 0, 4) != '127.');
			step('DNS', length(ips) > 0, length(ips) ? `${d} → ${ips[0]}` : `${d} не резолвится`);

			if (length(vpn) && length(ips) && nftset && nft) {
				let l = vpn[0];
				let inset = system(`nft get element inet stella ${dns_set(l.id)} '{ ${ips[0]} }' >/dev/null 2>&1`) == 0;
				step(`Список «${l.name}»`, inset, inset ? `${d} идёт через VPN` :
					`IP ${d} нет в правилах, откройте сайт ещё раз`);
			}
			return { steps };
		}
	},

	lists: {
		call: function() {
			let uci = cursor();
			return {
				default_action: uci.get('stella', 'main', 'default_action') || 'vpn',
				lists: map(load_lists(uci), (l) => ({
					id: l.id, name: l.name, enabled: l.enabled, action: l.action,
					urls: l.urls, geo: l.geo, entries: l.entries, updated: l.updated,
					domains: length(l.domains), cidrs: length(l.cidrs),
					devices_mode: l.devices_mode, macs: l.macs
				})),
				updating: busy('lists'),
				update_log: readfile(`${RUN_DIR}/lists.log`) || ''
			};
		}
	},

	// Добавление: items — массив { name, urls, geo, entries }; у всех одно действие.
	list_add: {
		args: { items: [], action: 'action', devices_mode: 'devices_mode', macs: [] },
		call: function(req) {
			let uci = cursor();
			let action = ACTIONS[req.args?.action] ? req.args.action : 'vpn';
			let macs = mac_list(req.args?.macs);
			let dmode = (req.args?.devices_mode in [ 'only', 'except' ] && length(macs)) ? req.args.devices_mode : null;
			let added = 0;
			for (let it in req.args?.items || []) {
				let urls = filter(str_list(it.urls), (u) => match(u, /^https?:\/\/\S+$/));
				let geo = geo_list(it.geo);
				let entries = str_list(it.entries);
				if (!length(urls) && !length(geo) && !length(entries))
					continue;
				let sid = new_section(uci, 'list', 'list', it.name || urls[0] || geo[0] || entries[0]);
				uci.set('stella', sid, 'name', it.name || urls[0] || geo[0] || 'список');
				uci.set('stella', sid, 'action', action);
				uci.set('stella', sid, 'enabled', '1');
				if (length(urls))
					uci.set('stella', sid, 'url', urls);
				if (length(geo))
					uci.set('stella', sid, 'geo', geo);
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
			spawn_reload(uci, 'lists', '/usr/bin/stella lists');
			return { added };
		}
	},

	list_edit: {
		args: { id: 'id', name: 'name', urls: [], geo: [], entries: [], action: 'action', enabled: true, devices_mode: 'devices_mode', macs: [] },
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
			if (a.geo != null) {
				let geo = geo_list(a.geo);
				if (sprintf('%J', geo) != sprintf('%J', str_list(uci.get('stella', a.id, 'geo'))))
					refetch = true;
				length(geo) ? uci.set('stella', a.id, 'geo', geo) : uci.delete('stella', a.id, 'geo');
			}
			if (a.entries != null) {
				let e = str_list(a.entries);
				length(e) ? uci.set('stella', a.id, 'entry', e) : uci.delete('stella', a.id, 'entry');
			}
			if (a.devices_mode != null) {
				let macs = mac_list(a.macs);
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
				spawn_reload(uci, 'lists', `/usr/bin/stella lists ${a.id}`);
			else
				apply_if_enabled(uci, 'reload');
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
			apply_if_enabled(uci, 'reload');
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
			apply_if_enabled(uci, 'reload');
			return { ok: true };
		}
	},

	lists_update: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args?.id;
			if (id && !match(id, /^[A-Za-z0-9_]+$/))
				return { error: 'некорректный id' };
			return { started: spawn_reload(cursor(), 'lists', `/usr/bin/stella lists ${id || ''}`) };
		}
	},

	// Имена наборов geosite и geoip для поиска в окне списка; update — скачать их заново в фоне.
	geo_index: {
		args: { update: true },
		call: function(req) {
			if (req.args?.update)
				spawn('geo', '/usr/bin/stella geo-index');
			let idx = read_json(`${RUN_DIR}/geo-index.json`, {});
			return { geosite: idx.geosite || [], geoip: idx.geoip || [], itdog: idx.itdog || [], at: idx.at, loading: busy('geo') };
		}
	},

	// DNS: каталог, цепочка, итоги проверки, адреса DNS провайдера.
	dns_info: {
		call: function() {
			let uci = cursor();
			return {
				catalog: filter(read_json(`${DNS_DIR}/catalog.json`, []), (c) => c?.kind in DNS_KINDS),
				updated: +(readfile(`${DNS_DIR}/catalog.updated`) || 0) || null,
				mode: uci.get('stella', 'main', 'dns_mode') || 'geo',
				chain: dns_chain(uci),
				fallback: dns_fallback(uci),
				auto_at: read_json(`${DNS_DIR}/auto.json`, null)?.at,
				isp: isp_dns(),
				check: read_json(`${DNS_DIR}/check.json`, {}),
				checking: busy('dnscheck'),
				updating: busy('dnscat'),
				log: readfile(`${RUN_DIR}/dnscheck.log`) || ''
			};
		}
	},

	// Проверить серверы (apply — и подобрать цепочку из серверов обхода геоблокировок).
	dns_check: {
		args: { apply: true },
		call: function(req) {
			if (busy('dnscat'))
				return { started: false };
			return { started: spawn('dnscheck', `/usr/bin/stella dns-check${req.args?.apply ? ' --apply' : ''}`) };
		}
	},

	dns_catalog_update: {
		call: function() {
			if (busy('dnscheck'))
				return { started: false };
			return { started: spawn('dnscat', '/usr/bin/stella dns-catalog') };
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
			apply_if_enabled(uci, 'reload');
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
			let add = (mac, ip, host, state) => {
				mac = mac_list(mac)[0];
				if (!mac)
					return;
				let d = seen[mac];
				if (!d) {
					d = seen[mac] = { id: null, mac, name: '', policy: 'global', configured: false };
					push(res, d);
				}
				d.ip ??= ip;
				d.hostname ??= (host && host != '*') ? host : null;
				// В сети — сосед подтверждён недавно (STALE — давно не отвечал).
				if (state in [ 'REACHABLE', 'DELAY', 'PROBE', 'PERMANENT' ])
					d.online = true;
			};
			for (let l in split(readfile('/tmp/dhcp.leases') || '', '\n')) {
				let f = split(l, ' ');
				if (length(f) >= 4)
					add(f[1], f[2], f[3], null);
			}
			// Те же интерфейсы, с которых перехватывается трафик (имена в lan_ifnames уже проверены).
			for (let ifn in lan_ifnames(uci)) {
				for (let l in split(cmd_output(`ip -4 neigh show dev ${ifn}`) || '', '\n')) {
					let m = match(l, /^([0-9.]+) lladdr ([0-9a-f:]+)( router)? ([A-Z]+)/);
					if (m)
						add(m[2], m[1], null, m[4]);
				}
			}
			// Когда устройство было в сети последний раз — по прошлым запросам этой страницы
			// (до перезагрузки роутера).
			let path = `${RUN_DIR}/seen.json`, last = read_json(path, {}), now = time();
			for (let d in res) {
				d.online = !!d.online;
				if (d.online)
					last[d.mac] = now;
				d.seen = last[d.mac];
			}
			system(`mkdir -p ${RUN_DIR}`);
			writefile(path, sprintf('%J', last));
			return { devices: res };
		}
	},

	// Режим устройства: global — по спискам, vpn — всё через VPN, direct — всё напрямую.
	device_set: {
		args: { mac: 'mac', name: 'name', policy: 'policy' },
		call: function(req) {
			let uci = cursor();
			let a = req.args || {};
			let mac = mac_list(a.mac)[0];
			if (!mac)
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
			apply_if_enabled(uci, 'reload');
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
			apply_if_enabled(uci, 'reload');
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
				enabled: cursor().get('stella', 'main', 'enabled') == '1',
				binaries: bins,
				installing: busy('upgrade'),
				service_enabled: system('/etc/init.d/zapret enabled 2>/dev/null') == 0,
				service_running: zapret_foreign_nfqws(),
				leftover_tables: system('nft list table inet zapret >/dev/null 2>&1 || nft list table inet zapret2 >/dev/null 2>&1') == 0,
				// «[n]» — чтобы pgrep не нашёл собственную оболочку с этим же текстом.
				stella_nfqws: system(`pgrep -f '[n]fqws --qnum=${ZAPRET_QNUM}' >/dev/null`) == 0,
				import_opts: z.get('zapret', 'config', 'NFQWS_OPT'),
				import_tcp: z.get('zapret', 'config', 'NFQWS_PORTS_TCP'),
				import_udp: z.get('zapret', 'config', 'NFQWS_PORTS_UDP')
			};
		}
	},

	// Обновления: проверка и установка идут в фоне (apk update и скачивание — долго).
	update_info: {
		call: function() {
			// Установленные версии — локально, без сети: видны и до первой проверки обновлений.
			let installed = {};
			for (let l in split(cmd_output('apk list -I luci-app-stella xray-core zapret mwan3 2>/dev/null') || '', '\n')) {
				let m = match(l, /^(luci-app-stella|xray-core|zapret|mwan3)-([0-9][^ ]*)/);
				if (m)
					installed[m[1]] = m[2];
			}
			return {
				info: read_json(`${RUN_DIR}/update.json`, null),
				installed,
				checking: busy('upcheck'),
				installing: busy('upgrade'),
				// Умеет ли dnsmasq класть IP доменов в сеты — без этого списки сайтов не работают.
				dnsmasq_nftset: match(cmd_output('dnsmasq --version 2>/dev/null') || '', /[ \t]nftset/) != null,
				log: readfile(`${RUN_DIR}/upgrade.log`) || ''
			};
		}
	},

	update_check: {
		call: function() {
			// Одна кнопка на всё: подписки, списки, каталоги и проверка новых версий.
			return { started: spawn('upcheck', '/usr/bin/stella refresh') };
		}
	},

	update_install: {
		args: { what: 'what' },
		call: function(req) {
			let what = req.args?.what;
			if (!(what in [ 'stella', 'xray', 'zapret', 'dnsmasq', 'mwan3' ]))
				return { error: 'нужно stella, xray, zapret, dnsmasq или mwan3' };
			return { started: spawn('upgrade', `/usr/bin/stella upgrade ${what}`) };
		}
	},

	// Каталог стратегий, результаты автоподбора и ход текущей проверки.
	zapret_catalog: {
		call: function() {
			let uci = cursor();
			let cat = read_json(`${ZAPRET_DIR}/catalog.json`, []);
			let lines = split(uci.get('stella', 'main', 'zapret_opts') || '', '\n');
			// Имя — из настроек, а у импортированной — из первой строки «#v7»; своя — если
			// такого имени в каталоге нет.
			let current = uci.get('stella', 'main', 'zapret_strategy') || match(trim(lines[0] || ''), /^#(.+)$/)?.[1] || null;
			let in_catalog = length(filter(cat, (s) => s.name == current)) > 0;
			let fs_excl = index(uci.get('stella', 'main', 'zapret_opts') || '', 'zapret-hosts-flowseal-exclude.txt') >= 0;
			// Домены списков исключений: своя копия, иначе файл пакета zapret.
			let excl = {};
			for (let n in [ 'exclude', 'exclude_fs' ]) {
				excl[n] = {};
				for (let l in split(readfile(`${ZAPRET_DIR}/hosts-${n}.txt`) || readfile('/opt/zapret/ipset/zapret-hosts-user-exclude.txt') || '', '\n'))
					if (trim(l) != '' && substr(trim(l), 0, 1) != '#')
						excl[n][trim(l)] = true;
			}
			return {
				strategies: map(filter(cat, (s) => s.family != 'voice'), (s) => ({ name: s.name, family: s.family })),
				updated: +(readfile(`${ZAPRET_DIR}/catalog.updated`) || 0) || null,
				current,
				custom: !!uci.get('stella', 'main', 'zapret_opts') && !in_catalog,
				results: read_json(`${ZAPRET_DIR}/results.json`, null),
				// Подделки, которые есть на роутере (из пакета zapret или копии Flowseal), и чего не хватило nfqws.
				fakes: fakes(),
				missing: read_json(`${RUN_DIR}/zapret-missing.json`, []),
				hostlists: map([ 'google', 'exclude', 'exclude_fs' ], (n) => {
					let st = stat(`${ZAPRET_DIR}/hosts-${n}.txt`);
					return { name: n, own: !!st, updated: st?.mtime };
				}),
				// Исключения — всегда идут мимо Zapret. Без выбора — от основной стратегии (у Flowseal свои).
				exclude_auto: fs_excl ? 'fs' : 'zms',
				excluded: {
					zms: length(excl.exclude),
					fs: length(excl.exclude_fs),
					all: length(keys({ ...excl.exclude, ...excl.exclude_fs }))
				},
				progress: read_json(`${RUN_DIR}/ztest.json`, null),
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

	// scope: all | main | v | yv | fs | имя стратегии; apply — применить лучшую, если она лучше текущей.
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
			if (action)
				apply_if_enabled(uci, action);
			// Подбор узла резервного канала включили, пока он работает, — первый подбор сразу.
			if (v.backup_mode == 'best' && on_backup(uci) && !busy('ping'))
				spawn('pick', '/usr/bin/stella pick --backup --apply');
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
