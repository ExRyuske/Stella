// ubus-объект stella для LuCI. Всё долгое (обновление подписок, проверка задержки)
// запускается в фоне: rpcd однопоточный, блокировать его нельзя.

'use strict';

import { cursor as uci_cursor } from 'uci';
import { readfile, writefile, popen, stat } from 'fs';
import { RUN_DIR, CACHE_DIR, STAB_PATH, ZAPRET_DIR, ZAPRET_QNUM, ZT_QNUM, TIMEOUT, SOCKS_PORT, read_json, load_nodes, sub_label, load_lists, xray_pid, task_busy, task_script, mwan3_ifaces, on_backup } from 'stella.store';
import { parse } from 'stella.uri';
import { try_json } from 'stella.util';
import { dns_set } from 'stella.firewall';
import { strategy_text } from 'stella.zapret';

function cursor() {
	let c = uci_cursor();
	c.load('stella');
	return c;
}

// Проверка интернета напрямую: Яндекс DNS по HTTPS — открыт и на мобильных белых списках.
const DIRECT_PROBE = 'https://77.88.8.8/dns-query';
// Подделки для UDP (голос Discord, игры) — набор из Zapret Manager; stun.bin — по умолчанию.
const UDP_FAKES = [ 'stun2.bin', 'quic_initial_www_google_com.bin', 'quic_initial_4pda_to.bin',
	'quic_initial_tencent_com.bin', 'quic_initial_steamcommunity_com.bin', 'quic_initial_5ka_ru.bin',
	'quic_initial_rutube_ru.bin', 'tls_clienthello_sochi_park.bin' ];

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

// Работает ли чужой nfqws (отдельная служба zapret), а не запущенный Stella: свой — на
// очереди 202, проверочный при автоподборе — на 205.
function zapret_foreign_nfqws() {
	for (let line in split(cmd_output('ps w') || '', '\n'))
		if (match(line, /nfqws/) && !match(line, regexp(`--qnum=(${ZAPRET_QNUM}|${ZT_QNUM})( |$)`)) && !match(line, /ps w/))
			return true;
	return false;
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
	return res;
}

// Выбранный узел без разбора всех подписок (статус запрашивается каждые 5 с): отдельная
// ссылка — это секция UCI, узел подписки — «<секция подписки>_<хеш>».
function find_node(uci, id) {
	if (!id)
		return null;
	if (uci.get('stella', id) == 'node') {
		let n = parse(uci.get('stella', id, 'link'));
		return n.error ? null : { id, name: uci.get('stella', id, 'name') || n.name, protocol: n.protocol, source: 'manual' };
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
				ping: read_json(`${RUN_DIR}/ping.json`, {}),
				stability: read_json(STAB_PATH, {}),
				mwan3: mwan3_ifaces(uci),
				backup: on_backup(uci),
				pinging: busy('ping'),
				picking: busy('pick'),
				updating: busy('update'),
				update_log: readfile(`${RUN_DIR}/update.log`) || '',
				warping: busy('warp'),
				warp_log: readfile(`${RUN_DIR}/warp.log`) || ''
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
			let dm = match(cmd_output(`curl -sk -o /dev/null --max-time ${TIMEOUT.probe} -w '%{http_code} %{time_total}' ${DIRECT_PROBE}`) || '', /^([0-9]{3}) ([0-9.]+)/);
			if (dm && dm[1] != '000')
				step('Напрямую', true, `77.88.8.8 отвечает, ${int(+dm[2] * 1000)} мс${via ? `, ${via}` : ''}`);
			else
				step('Напрямую', false, `77.88.8.8 не отвечает, нет интернета у провайдера${via ? ` (${via})` : ''}`);

			if (!running()) {
				step('xray', false, 'служба не запущена, см. лог');
				return { steps };
			}

			let port = +(uci.get('stella', 'main', 'socks_port') || SOCKS_PORT);
			let out = cmd_output(`curl -s --max-time ${TIMEOUT.probe} -w '\\n%{time_total}' --socks5-hostname 127.0.0.1:${port} https://ipinfo.io/json`);
			let lines = split(trim(out || ''), '\n');
			let t = +pop(lines);
			let info = try_json(join('\n', lines) || 'null');
			if (type(info) == 'object' && info.ip)
				step('Сервер VPN', true, `${info.ip}, ${info.country || '?'}, ${info.org || ''}, ${int(t * 1000)} мс`);
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
			// Сколько в списках доменов и подсетей; сами настройки списков страница читает из UCI.
			return {
				lists: map(load_lists(uci), (l) => ({ id: l.id, updated: l.updated, domains: length(l.domains), cidrs: length(l.cidrs) })),
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
			return { geosite: idx.geosite || [], geoip: idx.geoip || [], at: idx.at, loading: busy('geo') };
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
			return { started: spawn('upcheck', '/usr/bin/stella upgrade check') };
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
				// У основных (Zapret Manager, Flowseal) — и параметры: выбор в форме копирует их в zapret_opts.
				strategies: map(cat, (s) => ({ name: s.name, family: s.family, text: (s.family in [ 'v', 'fs' ]) ? strategy_text(s) : null })),
				updated: +(readfile(`${ZAPRET_DIR}/catalog.updated`) || 0) || null,
				current,
				custom: !!uci.get('stella', 'main', 'zapret_opts') && !in_catalog,
				results: read_json(`${ZAPRET_DIR}/results.json`, null),
				// Подделки, которые есть на роутере (из пакета zapret или копии Flowseal), и чего не хватило nfqws.
				fakes: filter(map(UDP_FAKES, (f) => stat(`/opt/zapret/files/fake/${f}`) ? `/opt/zapret/files/fake/${f}` :
					stat(`${ZAPRET_DIR}/fake/${f}`) ? `${ZAPRET_DIR}/fake/${f}` : null), (f) => f != null),
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

	log: {
		call: function() {
			return { log: cmd_output("logread -l 300 -e 'xray\\|stella'") || '' };
		}
	}
};

return { stella: methods };
