// Правила nftables (только IPv4), конфиг dnsmasq (nftset + strict-order) и команды fw up/down/show.

'use strict';

import { readfile, writefile, unlink, rename, glob, popen, stat } from 'fs';
import { is_ipv4, shq, try_json, FW_MARK, ZAPRET_MARK, ROUTE_TABLE, CONF_DIR, TPROXY_PORT, BT_INSPECT_PORT, DNS_PORT, RUN_DIR, LISTS_DIR, ZAPRET_QNUM, PROC_TAG, read_json, load_devices, lan_ifnames, on_backup, wait_until, dnsmasq_nftset, zapret_used, uci, opt } from 'stella.core';
import { parse_list, load_lists } from 'stella.lists';
import { dns_fallback, isp_dns } from 'stella.dns';
import { zapret_exclude_files, zapret_exclude_domains, zapret_ports } from 'stella.zapret';

const DNS_TIMEOUT = '12h';
const DNS_CACHE_TTL = 300;
const BYPASS4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4'
];
const ACTIONS = { vpn: true, zapret: true, direct: true, block: true };

function dns_set_def(name) {
	return [ '', `	set ${name} {`, '		type ipv4_addr', '		size 262144', '		flags dynamic, timeout', `		timeout ${DNS_TIMEOUT}`, '	}' ];
}

function dns_match(name) {
	return `ip daddr @${name} update @${name} { ip daddr }`;
}

function hex(v) {
	return sprintf('0x%08x', v);
}

function ports(s) {
	s = replace(s || '', / /g, '');
	return match(s, /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) ? replace(s, /,/g, ', ') : null;
}

function scope(l) {
	let m = `{ ${join(', ', l.macs)} }`;
	return (l.devices_mode == 'only') ? `ether saddr ${m} ` : (l.devices_mode == 'except') ? `ether saddr != ${m} ` : '';
}

export function dns_set(id) {
	return `${id}_dns`;
};

function list_rules(l, verdict) {
	let res = [];
	if (length(l.cidrs))
		push(res, `		${scope(l)}ip daddr @${l.id} ${verdict}`);
	push(res, `		${scope(l)}${dns_match(dns_set(l.id))} ${verdict}`);
	return res;
}

function port_jumps(z, chain) {
	let out = [];
	for (let proto in [ 'tcp', 'udp' ]) {
		let p = ports(z[`${proto}_ports`]);
		if (p)
			push(out, `		${proto} dport { ${p} } goto ${chain}`);
	}
	return out;
}

export function nft_script(opts) {
	let bt_inspect = (opts.torrent_action in [ 'vpn', 'block' ]) && opts.default_action != 'vpn';
	let lists = filter(opts.lists || [], (l) => ACTIONS[l.action]);
	let ifs = join(', ', map(opts.lan_ifnames, (i) => sprintf('%J', i)));
	let out = [
		'table inet stella',
		'delete table inet stella',
		'table inet stella {',
		'	set bypass4 {',
		'		type ipv4_addr',
		'		flags interval',
		'		auto-merge',
		`		elements = { ${join(', ', BYPASS4)} }`,
		'	}'
	];

	if (opts.zapret)
		push(out, ...dns_set_def('zapret_excl'));

	for (let l in lists) {
		if (length(l.cidrs))
			push(out, '', `	set ${l.id} {`, '		type ipv4_addr', '		flags interval', '		auto-merge',
				`		elements = { ${join(', ', l.cidrs)} }`, '	}');
		push(out, ...dns_set_def(dns_set(l.id)));
	}

	push(out, '',
		'	chain prerouting {',
		'		type filter hook prerouting priority mangle; policy accept;',
		`		iifname != { ${ifs} } return`,
		'		meta nfproto != ipv4 return',
		'		ip daddr @bypass4 return');
	if (opts.dns_hijack)
		push(out, '		meta l4proto { tcp, udp } th dport 53 return');
	if (opts.all_vpn) {
		for (let l in lists)
			if (l.action == 'block')
				push(out, ...list_rules(l, 'goto act_block'));
		push(out, '		goto act_vpn', '	}');
	}
	else {
		for (let p in [ 'vpn', 'direct' ]) {
			let m = map(filter(opts.devices || [], (d) => d.policy == p), (d) => d.mac);
			if (length(m))
				push(out, `		ether saddr { ${join(', ', m)} } goto act_${p}`);
		}
		push(out, '		goto pol_global', '	}');
	}

	push(out, '', '	chain pol_global {');
	for (let l in lists)
		push(out, ...list_rules(l, `goto act_${l.action}`));
	if (opts.default_action == 'direct' && opts.zapret?.special)
		push(out, ...port_jumps(opts.zapret.special, 'act_special'));
	if (bt_inspect && opts.default_action == 'zapret' && opts.zapret)
		push(out, ...port_jumps(opts.zapret, 'act_zapret'));
	push(out, `		goto act_${bt_inspect ? 'bt_inspect' : (opts.default_action in [ 'vpn', 'zapret' ]) ? opts.default_action : 'direct'}`, '	}');

	push(out, '',
		'	chain act_vpn {',
		`		meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${opts.tproxy_port} meta mark set meta mark | ${hex(FW_MARK)} accept`,
		'		accept',
		'	}',
		'',
		'	chain act_direct {',
		'		accept',
		'	}',
		'',
		'	chain act_block {',
		'		drop',
		'	}',
		'',
		'	chain act_zapret {',
		...(opts.zapret ? [ `		${dns_match('zapret_excl')} accept` ] : []),
		`		ct mark set ct mark | ${hex(ZAPRET_MARK)} accept`,
		'	}');

	if (bt_inspect)
		push(out, '',
			'	chain act_bt_inspect {',
			`		meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${opts.bt_port || 10813} meta mark set meta mark | ${hex(FW_MARK)} accept`,
			'		accept',
			'	}');

	if (opts.zapret?.special)
		push(out, '', '	chain act_special {',
			`		${dns_match('zapret_excl')} accept`,
			'		ct mark set ct mark | 0x00400000 accept', '	}');

	if (opts.block_ipv6)
		push(out, '',
			'	chain ipv6_block {',
			'		type filter hook forward priority filter - 1; policy accept;',
			`		iifname != { ${ifs} } return`,
			'		meta nfproto != ipv6 return',
			`		oifname { ${ifs} } return`,
			'		meta l4proto tcp reject with tcp reset',
			'		reject with icmpx admin-prohibited',
			'	}');

	if (opts.dns_hijack)
		push(out, '',
			'	chain dns_hijack {',
			'		type nat hook prerouting priority dstnat - 5; policy accept;',
			`		iifname != { ${ifs} } return`,
			'		meta nfproto != ipv4 return',
			'		fib daddr type local return',
			'		meta l4proto { tcp, udp } th dport 53 redirect to :53',
			'	}');

	for (let kind in [ 'zapret', 'special' ]) {
		let z = kind == 'zapret' ? opts.zapret : opts.zapret?.special;
		if (!z)
			continue;
		let mark = kind == 'zapret' ? ZAPRET_MARK : 0x00400000;
		let tcp = ports(z.tcp_ports), udp = ports(z.udp_ports);
		let guard = [
			`		ct mark & ${hex(mark)} == 0 return`,
			`		meta mark & ${hex(0x40000000)} != 0 return`
		];
		push(out, '',
			`	chain ${kind}_out {`,
			'		type filter hook postrouting priority srcnat - 2; policy accept;',
			'		ct direction != original return',
			...guard);
		if (tcp)
			push(out, `		tcp dport { ${tcp} } ct original packets 1-9 queue flags bypass to ${z.qnum}`);
		if (udp)
			push(out, `		udp dport { ${udp} } ct original packets 1-9 queue flags bypass to ${z.qnum}`);
		push(out, '	}');

		if (tcp)
			push(out, '',
				`	chain ${kind}_in {`,
				'		type filter hook prerouting priority filter; policy accept;',
				'		ct direction != reply return',
				...guard,
				`		tcp sport { ${tcp} } ct reply packets 1-3 queue flags bypass to ${z.qnum}`,
				'	}');
	}

	push(out, '}', '');
	return join('\n', out);
};

export function restore_script(saved, prev, cur) {
	let out = [];
	for (let id, entries in cur) {
		if (!length(saved[id]))
			continue;
		let p = prev[id];
		if (type(p) == 'object') {
			if (p.remote != entries.remote)
				continue;
			if (length(p.entries)) {
				let now = {};
				for (let e in entries.entries || [])
					now[e] = true;
				if (length(filter(p.entries, (e) => !now[e])))
					continue;
			}
		}
		else if (length(p))
			continue;
		push(out, `add element inet stella ${id} { ${join(', ', saved[id])} }`);
	}
	return out;
};

export function dnsmasq_conf(opts) {
	let sets = {}, order = [];
	for (let l in opts.lists || []) {
		let tag = `4#inet#stella#${l.id}`;
		for (let d in l.domains || []) {
			if (!sets[d]) {
				sets[d] = tag;
				push(order, d);
			}
			else
				sets[d] += `,${tag}`;
		}
	}

	let out = [ 'no-resolv' ];
	if (length(opts.fallback_servers))
		push(out, 'strict-order');
	push(out, `server=127.0.0.1#${opts.dns_port}`);
	for (let s in opts.fallback_servers || [])
		push(out, `server=${s}`);
	push(out, 'max-ttl=60', `max-cache-ttl=${DNS_CACHE_TTL}`);
	if (opts.block_ipv6 !== false)
		push(out, 'filter-AAAA');
	if (opts.nftset !== false)
		for (let d in order)
			push(out, `nftset=/${d}/${sets[d]}`);
	push(out, '');
	return join('\n', out);
};

/* ---- CLI / управление правилами ---- */

function dnsmasq_confs() {
	return map(glob('/tmp/dnsmasq*.d') || [], (d) => `${d}/stella.conf`);
}

function dnsmasq_restart() {
	let keep = `${RUN_DIR}/dnsmasq-dhcp.${PROC_TAG}`;
	system(`mkdir -p ${shq(keep)} && cp -p /var/run/dnsmasq.*.dhcp ${shq(keep)}/ 2>/dev/null; ` +
	       `/etc/init.d/dnsmasq stop >/dev/null 2>&1; cp -p ${shq(keep)}/* /var/run/ 2>/dev/null; rm -rf ${shq(keep)}; ` +
	       '/etc/init.d/dnsmasq start >/dev/null 2>&1');
	wait_until(() => match(readfile('/proc/net/udp') || '', /:0035 /) != null, 5000);
}

export function fw_down() {
	system('nft delete table inet stella 2>/dev/null');
	system(sprintf('while ip rule del fwmark 0x%x/0x%x table %d 2>/dev/null; do :; done', FW_MARK, FW_MARK, ROUTE_TABLE));
	system(`ip route flush table ${ROUTE_TABLE} 2>/dev/null`);

	let changed = false;
	for (let f in dnsmasq_confs())
		if (readfile(f) != null) {
			unlink(f);
			changed = true;
		}
	if (changed)
		dnsmasq_restart();
	return 0;
};

function routing_opts() {
	let c = uci();
	let lists = filter(load_lists(c), (l) => l.enabled && ACTIONS[l.action]);
	let zapret = zapret_used(c, lists);
	let hijack = opt('main', 'dns_hijack', '1') == '1';
	let block_ipv6 = opt('main', 'block_ipv6', '1') == '1';
	let fb = [];
	for (let e in dns_fallback(c)) {
		if (e == 'isp')
			push(fb, ...isp_dns());
		else if (is_ipv4(e))
			push(fb, e);
	}
	if (!length(fb))
		fb = isp_dns();
	return {
		lists,
		nft: {
			lan_ifnames: lan_ifnames(c),
			tproxy_port: TPROXY_PORT,
			bt_port: BT_INSPECT_PORT,
			default_action: opt('main', 'default_action', 'direct'),
			torrent_action: opt('main', 'torrent_action', 'direct'),
			dns_hijack: hijack,
			lists: map(lists, (l) => ({ id: l.id, action: l.action, cidrs: l.cidrs, devices_mode: l.devices_mode, macs: l.macs })),
			devices: load_devices(c),
			zapret: zapret ? { qnum: ZAPRET_QNUM, ...zapret_ports() } : null,
			all_vpn: opt('main', 'backup_vpn', '0') == '1' && on_backup(c) != null,
			block_ipv6
		},
		dnsmasq: { dns_port: DNS_PORT, fallback_servers: uniq(fb), block_ipv6, nftset: dnsmasq_nftset(), lists: [
			...map(lists, (l) => ({ id: dns_set(l.id), domains: l.domains })),
			...(zapret ? [ { id: 'zapret_excl', domains: zapret_exclude_domains() } ] : [])
		] }
	};
}

function set_elem(e) {
	if (type(e) == 'string')
		return match(e, /^[0-9.]+$/) ? e : null;
	let v = e?.elem?.val, ex = e?.elem?.expires;
	if (type(v) != 'string' || !match(v, /^[0-9.]+$/))
		return null;
	return (type(ex) == 'int' && ex > 0) ? `${v} expires ${ex}s` : v;
}

function saved_set_ips(names) {
	let res = {};
	for (let name in names || []) {
		if (!match(name, /^[A-Za-z0-9_]+$/))
			continue;
		let p = popen(`nft -j list set inet stella ${name} 2>/dev/null`, 'r');
		let j = p ? try_json(p.read('all') || 'null') : null;
		p?.close();
		for (let o in j?.nftables || [])
			if (o.set && o.set.name == name)
				res[name] = filter(map(o.set.elem || [], set_elem), (e) => e != null);
	}
	return res;
}

function fw_up() {
	let o = routing_opts();
	system(`mkdir -p ${shq(CONF_DIR)}`);

	if (!o.dnsmasq.nftset && length(filter(o.dnsmasq.lists, (l) => length(l.domains))))
		warn('dnsmasq без nftset (нужен dnsmasq-full): сайты из списков по доменам не работают\n');
	let conf = dnsmasq_conf(o.dnsmasq);
	let dconfs = dnsmasq_confs();
	let changed = false;
	for (let f in dconfs)
		if (readfile(f) != conf)
			changed = true;

	let rules = nft_script(o.nft), nft = `${CONF_DIR}/fw.nft`, skipped = false;
	let same_nft = !changed && readfile(nft) == rules &&
		system('nft list chain inet stella prerouting >/dev/null 2>&1') == 0;

	if (!same_nft) {
		let saved = saved_set_ips(map(o.dnsmasq.lists, (l) => l.id));

		let cur = {};
		for (let l in o.lists) {
			let st = stat(`${LISTS_DIR}/${l.id}.json`);
			cur[dns_set(l.id)] = { remote: st ? `${st.mtime}:${st.size}` : '', entries: l.entries };
		}
		if (o.nft.zapret)
			cur.zapret_excl = {
				remote: join('|', map(zapret_exclude_files(), (f) => { let st = stat(f); return st ? `${f}:${st.mtime}:${st.size}` : f; })),
				entries: []
			};
		let state = `${CONF_DIR}/fw-sets.json`;
		let restore = restore_script(saved, read_json(state, {}), cur);
		skipped = length(filter(keys(cur), (s) => length(saved[s]))) > length(restore);

		let applied = false, nft_new = `${CONF_DIR}/fw.new.${PROC_TAG}.nft`;
		writefile(nft_new, rules);
		if (length(restore)) {
			let full = `${CONF_DIR}/fw-apply.${PROC_TAG}.nft`;
			writefile(full, `include ${sprintf('%J', nft_new)}\n${join('\n', restore)}\n`);
			applied = system(`nft -f ${shq(full)} 2>/dev/null`) == 0;
			unlink(full);
			if (!applied)
				skipped = true;
		}
		if (!applied && system(`nft -f ${shq(nft_new)}`) != 0) {
			unlink(nft_new);
			warn('nft не принял правила, перехват не включён\n');
			fw_down();
			return 1;
		}
		rename(nft_new, nft);
		writefile(state, sprintf('%J', cur));
	}

	let manual = [];
	if (!same_nft)
		for (let l in o.lists)
			for (let e in parse_list(join('\n', l.entries)).domains)
				if (length(manual) < 300)
					push(manual, e);
	o = null;
	rules = null;
	if (type(gc) == 'function')
		gc();

	let rule = sprintf('fwmark 0x%x/0x%x table %d', FW_MARK, FW_MARK, ROUTE_TABLE);
	let p = popen(`ip rule list ${rule} 2>/dev/null`, 'r');
	let have = filter(split(trim(p?.read('all') || ''), '\n'), (l) => l != '');
	p?.close();
	let rule_ok = length(have) == 1 && index(have[0], `${ROUTE_TABLE}:`) == 0;
	if (!rule_ok)
		system(`while ip rule del ${rule} 2>/dev/null; do :; done`);
	if ((!rule_ok && system(`ip rule add ${rule} priority ${ROUTE_TABLE}`) != 0) ||
	    system(`ip route replace local 0.0.0.0/0 dev lo table ${ROUTE_TABLE}`) != 0)
		warn('не удалось добавить маршрут для VPN (нужен пакет ip-full) — трафик списков VPN не пойдёт\n');

	if (changed) {
		for (let f in dconfs)
			if (readfile(f) != conf)
				writefile(f, conf);
		conf = null;
		if (type(gc) == 'function')
			gc();
		dnsmasq_restart();
	}
	else if (skipped)
		system('killall -HUP dnsmasq 2>/dev/null');

	if (!same_nft && length(manual))
		system(`( for d in ${join(' ', manual)}; do nslookup -type=A $d 127.0.0.1 >/dev/null 2>&1; done ) </dev/null >/dev/null 2>&1 &`);
	return 0;
}

export function cmd_fw(action) {
	if (action == 'up')
		return fw_up();
	if (action == 'down')
		return fw_down();
	if (action == 'show') {
		let o = routing_opts();
		print(nft_script(o.nft), '\n', dnsmasq_conf(o.dnsmasq));
		return 0;
	}
	return 2;
};
