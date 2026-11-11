// ubus-объект stella для LuCI. Всё долгое (обновление подписок, проверка задержки)
// запускается в фоне: rpcd однопоточный, блокировать его нельзя.

'use strict';

import { cursor as uci_cursor } from 'uci';
import { readfile, writefile, popen, stat, glob } from 'fs';
import { RUN_DIR, CACHE_DIR, TRACE_URL, DNS_DIR, dns_chain, dns_fallback, isp_dns, STAB_PATH, ZAPRET_DIR, ZAPRET_QNUM, ZT_QNUM, TIMEOUT, SOCKS_PORT, read_json, load_nodes, is_warp, sub_label, load_lists, lan_ifnames, xray_pid, task_busy, task_script, mwan3_ifaces, on_backup } from 'stella.store';
import { parse } from 'stella.uri';
import { fnv1a, try_json } from 'stella.util';
import { dns_set } from 'stella.firewall';
import { doh_url, is_ipv4, KINDS as DNS_KINDS } from 'stella.dns';
import { FAKE_DIR } from 'stella.zapret';
import { trace_info } from 'stella.warp';

// Без явного load() первый add() молча ничего не делает.
function cursor() {
	let c = uci_cursor();
	c.load('stella');
	return c;
}

function shq(s) {
	return "'" + replace(`${s}`, "'", "'\\''") + "'";
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

// Настройки страниц и их значения по умолчанию. Пишут их сами страницы — штатным UCI LuCI
// (uci set + commit; служба перечитывает конфиг по своему reload-триггеру procd).
const SETTINGS = {
	// DNS: geo — подобранные проверкой серверы обхода геоблокировок; manual — свои (dns_server).
	dns_mode: 'geo', dns_server: [], dns_fallback: [ 'isp' ], dns_interval: '24', dns_hijack: '1',
	block_ipv6: '1', log_level: 'warning', update_interval: '12', lan_ifname: [ 'br-lan' ],
	best_from: '', best_interval: '6', node_missing: 'stop',
	// Резервный канал mwan3 и его узел: вручную (backup_node) или лучший по проверке.
	backup_iface: '', backup_node: '', backup_vpn: '0', backup_mode: 'single', backup_best_from: '', backup_best_interval: '6',
	zapret_bin: '', zapret_opts: '', zapret_strategy: '', zapret_yt: '', zapret_discord: '', zapret_games: '',
	zapret_games_fake: '', zapret_discord_fake: '', zapret_test_main: '0', zapret_test_yt: '0',
	zapret_tcp_ports: '80,443', zapret_udp_ports: '443'
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
		// Сама программа (путь или имя с пробелом после), а не любая строка со словом nfqws.
		if (match(line, /[ \/]nfqws2?( |$)/) && !match(line, regexp(`--qnum=(${ZAPRET_QNUM}|${ZT_QNUM})( |$)`)))
			return true;
	return false;
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
			return {
				strategies: map(filter(cat, (s) => s.family != 'voice'), (s) => ({ name: s.name, family: s.family })),
				current,
				custom: !!uci.get('stella', 'main', 'zapret_opts') && !in_catalog,
				results: read_json(`${ZAPRET_DIR}/results.json`, null),
				// Подделки, которые есть на роутере (из пакета zapret или копии Flowseal), и чего не хватило nfqws.
				fakes: fakes(),
				missing: read_json(`${RUN_DIR}/zapret-missing.json`, []),
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

	// Настройки страниц с подставленными значениями по умолчанию.
	settings: {
		call: function() {
			let uci = cursor();
			let res = {};
			for (let k, def in SETTINGS)
				res[k] = uci.get('stella', 'main', k) ?? def;
			// Интерфейсы, с которых трафик перехватывается на деле: заданных может не быть в
			// системе, тогда это устройство интерфейса lan. По их подсетям страница отбирает устройства.
			res.lan_devices = lan_ifnames(uci);
			return res;
		}
	}
};

return { stella: methods };
