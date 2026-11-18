// ubus-объект stella для LuCI. Всё долгое (подписки, задержка, автоподбор) запускается в фоне.

'use strict';

import { cursor as uci_cursor } from 'uci';
import { readfile, writefile, unlink, stat, glob } from 'fs';
import { fnv1a, as_array, shq, url_host, is_ipv4, RUN_DIR, CACHE_DIR, LISTS_DIR, TRACE_URL, DNS_DIR, STAB_PATH, ZAPRET_DIR, ZAPRET_QNUM, ZT_QNUM, ROUTE_TABLE, TIMEOUT, SOCKS_PORT, read_json, cmd_out, is_warp, sub_label, lan_ifnames, xray_pid, task_busy, task_script, mwan3_ifaces, on_backup, dnsmasq_nftset } from 'stella.core';
import { parse, load_nodes } from 'stella.uri';
import { parse_list, load_lists, list_overlaps } from 'stella.lists';
import { doh_url, dns_chain, dns_fallback, dns_catalog, isp_dns } from 'stella.dns';
import { dns_set } from 'stella.firewall';
import { FAKE_DIR } from 'stella.zapret';
import { trace_info } from 'stella.warp';

function cursor() {
	let c = uci_cursor();
	c.load('stella');
	return c;
}

function new_section(uci, type, prefix, seed) {
	let name;
	for (let i = 0; !name || uci.get('stella', name); i++)
		name = `${prefix}_${fnv1a(`${seed}|${time()}|${i}`)}`;
	uci.set('stella', name, type);
	return name;
}

function spawn(name, cmd, reload_uci) {
	if (task_busy(name))
		return false;
	if (reload_uci && reload_uci.get('stella', 'main', 'enabled') == '1')
		cmd += '; /etc/init.d/stella reload';
	system(`sh ${task_script(name, cmd)} </dev/null >/dev/null 2>&1 &`);
	return true;
}

function valid_id(id) {
	return !id || match(id, /^[A-Za-z0-9_]+$/) != null;
}

function ms_of(text) {
	return int(+(match(text, /@([0-9.]+)$/)?.[1] || 0) * 1000);
}

const SETTINGS = {
	dns_mode: 'geo', dns_server: [], dns_fallback: [ 'isp' ], dns_interval: '24', dns_hijack: '1', dns_vpn: '0',
	block_ipv6: '1', log_level: 'warning', update_interval: '12', lan_ifname: [ 'br-lan' ],
	best_from: '', best_interval: '6', node_missing: 'stop',
	backup_iface: '', backup_node: '', backup_vpn: '0', backup_mode: 'single', backup_best_from: '', backup_best_interval: '6',
	zapret_bin: '', zapret_opts: '', zapret_strategy: '', zapret_yt: '', zapret_discord: '', zapret_games: '',
	zapret_games_fake: '', zapret_discord_fake: '', zapret_test_main: '0', zapret_test_yt: '0',
	zapret_tcp_ports: '80,443', zapret_udp_ports: '443', torrent_action: 'direct'
};

function fakes() {
	let res = {};
	for (let dir in [ `${ZAPRET_DIR}/fake`, FAKE_DIR ])
		for (let f in glob(`${dir}/*.bin`) || [])
			res[replace(f, /^.*\//, '')] = f;
	delete res['stun.bin'];
	return map(sort(keys(res)), (n) => res[n]);
}

function zapret_foreign_nfqws() {
	for (let line in split(cmd_out('ps w'), '\n'))
		if (match(line, /[ \/]nfqws2?( |$)/) && !match(line, regexp(`--qnum=(${ZAPRET_QNUM}|${ZAPRET_QNUM + 1}|${ZT_QNUM})( |$)`)))
			return true;
	return false;
}

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
	push(res, { id: 'warp', kind: 'warp', name: 'WARP', enabled: true, count: count.warp || 0 });
	return res;
}

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

function nft_up() {
	return system('nft list chain inet stella prerouting >/dev/null 2>&1') == 0;
}

function first_vpn_list(uci) {
	let found = null;
	uci.foreach('stella', 'list', (s) => {
		if (found || s.enabled == '0' || (s.action || 'vpn') != 'vpn')
			return;
		let manual = parse_list(join('\n', as_array(s.entry))).domains;
		let path = `${LISTS_DIR}/${s['.name']}.json`, head = readfile(path, 512) || '';
		let d = manual[0] || match(head, /"domains":[ \t\r\n]*\[[ \t\r\n]*"([^"]+)"/)?.[1] ||
			read_json(path, null)?.domains?.[0];
		if (d)
			found = { id: s['.name'], name: s.name || s['.name'], domain: d };
	});
	return found;
}

const methods = {
	status: {
		call: function() {
			let uci = cursor(), sel = uci.get('stella', 'main', 'node'), backup = on_backup(uci);
			let bnode = backup ? find_node(uci, uci.get('stella', 'main', 'backup_node')) : null;
			return {
				enabled: uci.get('stella', 'main', 'enabled') == '1',
				running: xray_pid() != null,
				intercept: nft_up() && match(cmd_out('ip rule 2>/dev/null'), regexp(`lookup ${ROUTE_TABLE}([ \t\r\n]|$)`)) != null,
				node_id: sel,
				node: bnode || find_node(uci, sel),
				backup: bnode ? backup : null,
				select_mode: uci.get('stella', 'main', 'select_mode') || 'single',
				speed: read_json(`${RUN_DIR}/speed.json`, null),
				speedtesting: task_busy('speed')
			};
		}
	},

	nodes: {
		call: function() {
			let uci = cursor(), errors = [], all = load_nodes(uci, errors);
			return {
				selected: uci.get('stella', 'main', 'node'),
				select_mode: uci.get('stella', 'main', 'select_mode') || 'single',
				auto_nodes: as_array(uci.get('stella', 'main', 'auto_node')),
				sources: sources(uci, all),
				nodes: map(all, (n) => ({
					id: n.id, name: n.name, protocol: n.protocol, network: n.network,
					security: n.security, source: n.source_id, warnings: n.warnings, warp: n.source_id == 'warp'
				})),
				errors,
				ping: read_json(`${RUN_DIR}/ping.json`, {}),
				stability: read_json(STAB_PATH, {}),
				mwan3: mwan3_ifaces(uci),
				backup: on_backup(uci),
				pinging: task_busy('ping'),
				picking: task_busy('pick'),
				updating: task_busy('update'),
				update_log: readfile(`${RUN_DIR}/update.log`) || '',
				warping: task_busy('warp'),
				warp_log: readfile(`${RUN_DIR}/warp.log`) || ''
			};
		}
	},

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
			return valid_id(id) ? { started: spawn('update', `/usr/bin/stella update ${id || ''}`, cursor()) } : { error: 'некорректный id' };
		}
	},

	add: {
		args: { text: 'text', name: 'name' },
		call: function(req) {
			let uci = cursor(), lines = filter(map(split(req.args?.text || '', /\r?\n/), (l) => trim(l)), (l) => l != '');
			let subs = 0, links = 0, errors = [];

			for (let l in lines) {
				if (match(l, /^https?:\/\/\S+$/)) {
					let sid = new_section(uci, 'subscription', 'sub', l);
					uci.set('stella', sid, 'name', (length(lines) == 1 && req.args.name) ? req.args.name : (url_host(l) || l));
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
				spawn('update', '/usr/bin/stella update', uci);
			return { subscriptions: subs, links, errors };
		}
	},

	ping: {
		args: { ids: [] },
		call: function(req) {
			let ids = filter(req.args?.ids || [], (id) => type(id) == 'string' && match(id, /^[A-Za-z0-9_]+$/));
			return { started: !task_busy('pick') && spawn('ping', `/usr/bin/stella ping ${join(' ', ids)}`) };
		}
	},

	node_pick: {
		args: { backup: true },
		call: function(req) {
			let backup = !!req.args?.backup;
			if (backup != (on_backup(cursor()) != null))
				return { error: backup ? 'резервный канал сейчас не работает — подбор для него пройдёт, когда он включится' :
					'работает резервный канал — подбор узла отложен до возвращения основного' };
			return { started: !task_busy('ping') && spawn('pick', `/usr/bin/stella pick${backup ? ' --backup' : ''} --apply`) };
		}
	},

	speedtest: {
		call: function() {
			return { started: spawn('speed', '/usr/bin/stella speedtest') };
		}
	},

	check: {
		call: function() {
			let uci = cursor(), steps = [], step = (name, ok, detail) => push(steps, { name, ok, detail });
			let bk = on_backup(uci), up = map(filter(mwan3_ifaces(uci), (i) => i.online), (i) => i.name);
			let via = bk ? `резервный канал ${bk}` : length(up) ? `канал ${join(', ', up)}` : '';
			let cat = filter(read_json(`${DNS_DIR}/catalog.json`, []), (c) => c?.kind == 'plain' && doh_url(c.url) && is_ipv4(c.boot?.[0]));
			let probe = filter(cat, (c) => c.id == 'cloudflare')[0] || cat[0];
			let is_run = xray_pid() != null, port = +(uci.get('stella', 'main', 'socks_port') || SOCKS_PORT);
			let d_out = '', v_out = '', h = probe ? url_host(probe.url) : null, boot_ip = probe?.boot?.[0];
			let direct_cmd = probe ? `curl -sk --max-time ${TIMEOUT.probe} --resolve ${shq(`${h}:443:${boot_ip}`)} -w '\\n@%{time_total}' ${shq(`https://${h}/cdn-cgi/trace`)}` : null;
			let vpn_cmd = is_run ? `curl -s --max-time ${TIMEOUT.probe} -w '\\n@%{time_total}' --socks5-hostname 127.0.0.1:${port} ${shq(TRACE_URL)}` : null;
			if (direct_cmd && vpn_cmd) {
				let tag = fnv1a(readfile('/dev/urandom', 4) || `${time()}`);
				let df = `${RUN_DIR}/check.d.${tag}`, vf = `${RUN_DIR}/check.v.${tag}`;
				system(`mkdir -p ${shq(RUN_DIR)}; ${direct_cmd} >${shq(df)} 2>/dev/null & ${vpn_cmd} >${shq(vf)} 2>/dev/null & wait`);
				d_out = readfile(df) || '';
				v_out = readfile(vf) || '';
				unlink(df);
				unlink(vf);
			}
			else if (direct_cmd)
				d_out = cmd_out(`${direct_cmd} 2>/dev/null`);
			else if (vpn_cmd)
				v_out = cmd_out(`${vpn_cmd} 2>/dev/null`);

			if (!probe)
				step('Напрямую', false, 'каталог DNS ещё не загружен — проверить не на чем');
			else {
				let tr = trace_info(d_out);
				step('Напрямую', !!tr, tr ? `${boot_ip} отвечает, ${ms_of(d_out)} мс, ${tr.loc}${via ? `, ${via}` : ''}`
					: `${boot_ip} не отвечает, нет интернета у провайдера${via ? ` (${via})` : ''}`);
			}

			if (!is_run) {
				step('xray', false, 'служба не запущена, см. лог');
				return { steps };
			}

			let tr = trace_info(v_out), ip = match(v_out, /(^|\n)ip=([0-9a-f.:]+)/)?.[2];
			step('Сервер VPN', !!tr, tr ? `${ip || '?'}, ${tr.loc}, узел Cloudflare ${tr.colo || '?'}, ${ms_of(v_out)} мс` : 'сервер не отвечает');

			let nft = nft_up();
			step('Перехват', nft, nft ? 'правила на месте' : 'nft не принял правила, см. лог');

			let route = match(cmd_out('ip rule 2>&1'), regexp(`lookup ${ROUTE_TABLE}([ \t\r\n]|$)`)) && match(cmd_out(`ip route show table ${ROUTE_TABLE} 2>&1`), /local/);
			step('Маршрут', !!route, route ? 'есть' : 'нет правила маршрутизации, нужен пакет ip-full');

			let nftset = dnsmasq_nftset();
			if (!nftset)
				step('dnsmasq', false, 'без nftset, нужен dnsmasq-full');

			let vpn = first_vpn_list(uci), d = vpn ? vpn.domain : 'google.com';
			let ips = filter(map(match(cmd_out(`nslookup -type=A ${shq(d)} 127.0.0.1 2>&1`), /Address:?[ \t]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/g) || [],
				(m) => m[1]), (x) => substr(x, 0, 4) != '127.');
			step('DNS', length(ips) > 0, length(ips) ? `${d} → ${ips[0]}` : `${d} не резолвится`);

			if (vpn && length(ips) && nftset && nft) {
				let inset = system(`nft get element inet stella ${dns_set(vpn.id)} '{ ${ips[0]} }' >/dev/null 2>&1`) == 0;
				step(`Список «${vpn.name}»`, inset, inset ? `${d} идёт через VPN` : `IP ${d} нет в правилах, откройте сайт ещё раз`);
			}
			return { steps };
		}
	},

	lists: {
		call: function() {
			let uci = cursor(), sig_parts = [];
			uci.foreach('stella', 'list', (s) => {
				let st = stat(`${LISTS_DIR}/${s['.name']}.json`);
				push(sig_parts, sprintf('%s|%s|%s|%s|%J|%J|%d|%d|%J|%J|%J',
					s['.name'], s.name || '', s.enabled || '1', s.action || 'vpn',
					s.devices_mode || '', s.mac || '', st?.mtime || 0, st?.size || 0,
					s.url || '', s.geo || '', s.entry || ''));
			});
			let sig = fnv1a(join('\n', sig_parts)), cache_path = `${RUN_DIR}/lists-meta.json`, cached = read_json(cache_path, null);
			let lists = (cached?.sig == sig && type(cached.lists) == 'array') ? cached.lists : null;
			if (!lists) {
				let all = load_lists(uci), overlaps = list_overlaps(all);
				lists = map(all, (l) => ({
					id: l.id, name: l.name, enabled: l.enabled, action: l.action,
					urls: l.urls, geo: l.geo, entries: l.entries, updated: l.updated,
					domains: length(l.domains), cidrs: length(l.cidrs),
					devices_mode: l.devices_mode, macs: l.macs, overlaps: overlaps[l.id] || []
				}));
				system(`mkdir -p ${shq(RUN_DIR)}`);
				writefile(cache_path, sprintf('%J', { sig, lists }));
			}
			return {
				default_action: uci.get('stella', 'main', 'default_action') || 'direct',
				torrent_action: uci.get('stella', 'main', 'torrent_action') || 'direct',
				lists,
				updating: task_busy('lists'),
				update_log: readfile(`${RUN_DIR}/lists.log`) || ''
			};
		}
	},

	lists_update: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args?.id;
			return valid_id(id) ? { started: spawn('lists', `/usr/bin/stella lists ${id || ''}`, cursor()) } : { error: 'некорректный id' };
		}
	},

	geo_index: {
		args: { update: true },
		call: function(req) {
			if (req.args?.update)
				spawn('geo', '/usr/bin/stella geo-index');
			let idx = read_json(`${RUN_DIR}/geo-index.json`, {});
			return { geosite: idx.geosite || [], geoip: idx.geoip || [], itdog: idx.itdog || [], at: idx.at, loading: task_busy('geo') };
		}
	},

	dns_info: {
		call: function() {
			let uci = cursor(), cat_mt = stat(`${RUN_DIR}/dnscat.log`)?.mtime || 0, chk_mt = stat(`${RUN_DIR}/dnscheck.log`)?.mtime || 0;
			return {
				catalog: dns_catalog(),
				chain: dns_chain(uci),
				fallback: dns_fallback(uci),
				isp: isp_dns(),
				check: read_json(`${DNS_DIR}/check.json`, {}),
				checking: task_busy('dnscheck'),
				updating: task_busy('dnscat'),
				log: readfile((task_busy('dnscat') || (!task_busy('dnscheck') && cat_mt > chk_mt)) ? `${RUN_DIR}/dnscat.log` : `${RUN_DIR}/dnscheck.log`) || ''
			};
		}
	},

	dns_check: {
		args: { apply: true },
		call: function(req) {
			return { started: !task_busy('dnscat') && spawn('dnscheck', `/usr/bin/stella dns-check${req.args?.apply ? ' --apply' : ''}`) };
		}
	},

	zapret_info: {
		call: function() {
			let z = uci_cursor();
			z.load('zapret');
			return {
				enabled: cursor().get('stella', 'main', 'enabled') == '1',
				binaries: filter([ '/opt/zapret/nfq/nfqws', '/opt/zapret2/nfq2/nfqws2', '/usr/bin/nfqws', '/usr/bin/nfqws2' ], (b) => stat(b) != null),
				installing: task_busy('upgrade'),
				service_enabled: system('/etc/init.d/zapret enabled 2>/dev/null') == 0,
				service_running: zapret_foreign_nfqws(),
				leftover_tables: system('nft list table inet zapret >/dev/null 2>&1 || nft list table inet zapret2 >/dev/null 2>&1') == 0,
				stella_nfqws: match(cmd_out('ps w'), regexp(`[ /]nfqws2? --qnum=${ZAPRET_QNUM}( |$)`)) != null,
				import_opts: z.get('zapret', 'config', 'NFQWS_OPT'),
				import_tcp: z.get('zapret', 'config', 'NFQWS_PORTS_TCP'),
				import_udp: z.get('zapret', 'config', 'NFQWS_PORTS_UDP')
			};
		}
	},

	update_info: {
		call: function() {
			let installed = {};
			for (let l in split(cmd_out('apk list -I luci-app-stella xray-core zapret mwan3 2>/dev/null'), '\n')) {
				let m = match(l, /^(luci-app-stella|xray-core|zapret|mwan3)-([0-9][^ ]*)/);
				if (m)
					installed[m[1]] = m[2];
			}
			return {
				info: read_json(`${RUN_DIR}/update.json`, null),
				installed,
				checking: task_busy('upcheck'),
				installing: task_busy('upgrade'),
				dnsmasq_nftset: dnsmasq_nftset(),
				log: readfile(`${RUN_DIR}/upgrade.log`) || ''
			};
		}
	},

	update_check: {
		call: function() {
			return { started: spawn('upcheck', '/usr/bin/stella refresh') };
		}
	},

	update_install: {
		args: { what: 'what' },
		call: function(req) {
			let what = req.args?.what;
			return (what in [ 'stella', 'xray', 'zapret', 'dnsmasq', 'mwan3' ])
				? { started: spawn('upgrade', `/usr/bin/stella upgrade ${what}`) }
				: { error: 'нужно stella, xray, zapret, dnsmasq или mwan3' };
		}
	},

	zapret_catalog: {
		call: function() {
			let uci = cursor(), cat = read_json(`${ZAPRET_DIR}/catalog.json`, []);
			let lines = split(uci.get('stella', 'main', 'zapret_opts') || '', '\n');
			let current = uci.get('stella', 'main', 'zapret_strategy') || match(trim(lines[0] || ''), /^#(.+)$/)?.[1] || null;
			let in_catalog = length(filter(cat, (s) => s.name == current)) > 0;
			return {
				strategies: map(filter(cat, (s) => s.family != 'voice'), (s) => ({ name: s.name, family: s.family })),
				current,
				custom: !!uci.get('stella', 'main', 'zapret_opts') && !in_catalog,
				results: read_json(`${ZAPRET_DIR}/results.json`, null),
				fakes: fakes(),
				missing: read_json(`${RUN_DIR}/zapret-missing.json`, []),
				progress: read_json(`${RUN_DIR}/ztest.json`, null),
				testing: task_busy('ztest'),
				updating: task_busy('zcatalog')
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

	zapret_service_off: {
		call: function() {
			system('/etc/init.d/zapret stop >/dev/null 2>&1; /etc/init.d/zapret disable >/dev/null 2>&1');
			if (!zapret_foreign_nfqws())
				system('nft delete table inet zapret 2>/dev/null; nft delete table inet zapret2 2>/dev/null');
			return { ok: true, running: zapret_foreign_nfqws() };
		}
	},

	settings: {
		call: function() {
			let uci = cursor(), res = {};
			for (let k, def in SETTINGS)
				res[k] = uci.get('stella', 'main', k) ?? def;
			res.lan_devices = lan_ifnames(uci);
			return res;
		}
	}
};

return { stella: methods };
