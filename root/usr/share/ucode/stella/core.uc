// Общая основа Stella: утилиты, константы путей/портов, UCI, HTTP-загрузка, задачи и замеры.

'use strict';

import { cursor as uci_cursor } from 'uci';
import { readfile, writefile, rename, unlink, stat, popen } from 'fs';

/* ---- базовые утилиты (строки, URL, сети, shell) ---- */

export function b64dec_loose(s) {
	if (type(s) != 'string')
		return null;
	s = replace(s, /[ \t\r\n]/g, '');
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	s = replace(s, /=+$/, '');
	while (length(s) % 4)
		s += '=';
	return b64dec(s);
};

export function try_json(s) {
	try {
		return json(s);
	}
	catch (e) {
		return null;
	}
};

export function pctdecode(s) {
	return (type(s) == 'string') ? replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h))) : s;
};

function urldecode(s) {
	return (type(s) == 'string') ? pctdecode(replace(s, /\+/g, ' ')) : s;
}

export function pctenc(s) {
	return replace(`${s ?? ''}`, /[^A-Za-z0-9._~-]/g, (c) => sprintf('%%%02X', ord(c)));
};

function parse_query(q) {
	let res = {};
	if (!q)
		return res;
	for (let pair in split(q, '&')) {
		if (pair == '')
			continue;
		let i = index(pair, '=');
		let k = (i < 0) ? pair : substr(pair, 0, i);
		let v = (i < 0) ? '' : substr(pair, i + 1);
		res[urldecode(k)] = urldecode(v);
	}
	return res;
}

// Разбор scheme://userinfo@host:port/path?query#fragment (порт остаётся строкой: port hopping).
export function parse_url(s) {
	let m = match(s, /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^#]*)(#(.*))?$/);
	if (!m)
		return null;

	let res = { scheme: lc(m[1]), fragment: m[4] ? pctdecode(m[4]) : '' };
	let rest = m[2];

	let qi = index(rest, '?');
	res.query = parse_query((qi < 0) ? '' : substr(rest, qi + 1));
	if (qi >= 0)
		rest = substr(rest, 0, qi);

	// userinfo — до последнего «@», раньше пути: в base64 и путях бывает «/».
	let ai = rindex(rest, '@');
	res.userinfo = (ai < 0) ? null : substr(rest, 0, ai);
	if (ai >= 0)
		rest = substr(rest, ai + 1);

	let pi = index(rest, '/');
	res.path = (pi < 0) ? '' : pctdecode(substr(rest, pi));
	let hostport = (pi < 0) ? rest : substr(rest, 0, pi);

	let hm = match(hostport, /^\[([^\]]+)\](:(.*))?$/) || match(hostport, /^([^:]*)(:(.*))?$/);
	if (!hm)
		return null;
	res.host = hm[1];
	res.port = hm[3];
	return res;
};

export function valid_port(p) {
	p = +p;
	return (type(p) == 'int' && p > 0 && p < 65536) ? p : null;
};

export function split_list(s) {
	if (type(s) != 'string' || s == '')
		return null;
	let res = filter(map(split(s, ','), (v) => trim(v)), (v) => v != '');
	return length(res) ? res : null;
};

export function as_array(v) {
	return (v == null) ? [] : (type(v) == 'array') ? v : [ v ];
};

export function shq(s) {
	return "'" + replace(`${s ?? ''}`, "'", "'\\''") + "'";
};

export function mac_list(v) {
	return map(filter(as_array(v), (m) => type(m) == 'string' && match(trim(m), /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)), (m) => lc(trim(m)));
};

// FNV-1a 32 бит — стабильный id узла по ссылке.
export function fnv1a(s) {
	let h = 2166136261;
	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 16777619) & 0xffffffff;
	return sprintf('%08x', h);
};

export function is_ipv4(s) {
	let m = match(s || '', /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
	if (!m)
		return false;
	for (let i = 1; i <= 4; i++)
		if (+m[i] > 255)
			return false;
	return true;
};

export function url_host(s) {
	return match(s || '', /^https?:\/\/([^\/:?#]+)/)?.[1];
};

/* ---- константы системы ---- */

export const CACHE_DIR = getenv('STELLA_CACHE_DIR') || '/etc/stella/subs';
export const RUN_DIR = getenv('STELLA_RUN_DIR') || '/var/run/stella';
export const LISTS_DIR = getenv('STELLA_LISTS_DIR') || '/etc/stella/lists';
export const DNS_DIR = getenv('STELLA_DNS_DIR') || '/etc/stella/dns';
export const ZAPRET_DIR = getenv('STELLA_ZAPRET_DIR') || '/etc/stella/zapret';
export const ZAPRET_BIN = '/opt/zapret/nfq/nfqws';
export const CONF_DIR = '/var/etc/stella';
export const XRAY_CONF = `${CONF_DIR}/config.json`;

export const PROBE_URL = getenv('STELLA_PROBE_URL') || 'https://cp.cloudflare.com/generate_204';
export const TRACE_URL = getenv('STELLA_TRACE_URL') || 'https://www.cloudflare.com/cdn-cgi/trace';

export const TIMEOUT = { connect: 10, fetch: 60, probe: 8 };
export const AUTO_MAX = 30;
export const SOCKS_PORT = 10808;
export const TPROXY_PORT = 10812;
export const BT_INSPECT_PORT = 10813;
export const DNS_PORT = 10853;
export const ZAPRET_QNUM = 202;
export const ZT_QNUM = 205;

export const FW_MARK = 0x00100000;
export const ZAPRET_MARK = 0x00200000;
export const ROUTE_TABLE = 1127;
export const NFQWS_DESYNC_MARK = 0x40000000;

export const STAB_PATH = replace(CACHE_DIR, /\/[^\/]+\/?$/, '') + '/stability.json';
export const STAB_BACKUP_PATH = replace(CACHE_DIR, /\/[^\/]+\/?$/, '') + '/stability-backup.json';
const MWAN3_STATE = getenv('STELLA_MWAN3_STATE') || '/var/run/mwan3/iface_state';
export const DEFAULT_UA = 'v2rayN/7.0';

export const PROC_TAG = fnv1a(readfile('/dev/urandom', 8) || `${time()}`);
let seq = 0;

export function next_seq() {
	return seq++;
};

/* ---- UCI и системные хелперы ---- */

// Ленивый курсор для CLI: юнит-тесты не задают STELLA_UCI_JSON и не обращаются к uci().
let _uci = null;
export function uci() {
	return _uci ??= uci_cursor();
};

export function opt(sec, name, def) {
	return uci().get('stella', sec, name) ?? def;
};

// Отвязанно: при reload/restart procd остановил бы и вызвавший процесс (например, планировщик).
export function reload_async() {
	if (opt('main', 'enabled', '0') == '1')
		system('setsid /etc/init.d/stella reload </dev/null >/dev/null 2>&1 &');
};

export function set_main(values) {
	let c = uci();
	for (let k, v in values)
		c.set('stella', 'main', k, v);
	c.commit('stella');
	reload_async();
};

export function cmd_out(cmd) {
	let p = popen(cmd, 'r');
	let out = p ? p.read('all') : '';
	p?.close();
	return out || '';
};

export function read_json(path, def) {
	return try_json(readfile(path) || 'null') ?? def;
};

// Запись через временный файл (читатель не увидит половину) и только при изменениях (бережет флеш).
export function save_file(path, data) {
	if (readfile(path) == data)
		return;
	writefile(`${path}.tmp`, data);
	rename(`${path}.tmp`, path);
};

export function wait_until(cond, max_ms) {
	for (let t = 0; t < max_ms; t += 100) {
		if (cond())
			return true;
		sleep(100);
	}
	return cond();
};

export function run_parallel(cmds, limit) {
	for (let i = 0; i < length(cmds); i += limit)
		system(join(' & ', slice(cmds, i, i + limit)) + ' & wait');
};

export function stop_pid(pid, max_ms, force) {
	if (!pid)
		return;
	system(`kill ${pid} 2>/dev/null`);
	for (let t = 0; t < (max_ms || 0) && system(`kill -0 ${pid} 2>/dev/null`) == 0; t += 100)
		sleep(100);
	if (force && system(`kill -0 ${pid} 2>/dev/null`) == 0)
		system(`kill -9 ${pid} 2>/dev/null`);
};

let cached_mem_kb = null;
export function mem_total_kb() {
	if (cached_mem_kb == null)
		cached_mem_kb = +(match(readfile('/proc/meminfo') || '', /MemTotal:[ \t]+([0-9]+)/)?.[1] || 0);
	return cached_mem_kb;
};

function xray_mem_env() {
	let kb = mem_total_kb();
	return kb ? sprintf('GOMEMLIMIT=%dMiB %s', max(int(kb / 3 / 1024), 16), (kb <= 262144) ? 'GOGC=50 ' : '') : '';
}

export function xray_pid() {
	return match(cmd_out(`pgrep -f '^/usr/bin/xray run -c ${XRAY_CONF}'`), /^[0-9]+/)?.[0];
};

export function lan_ifnames(c) {
	let v = c.get('stella', 'main', 'lan_ifname') ?? [ 'br-lan' ];
	let names = filter((type(v) == 'array') ? v : split(v, /[ ,]+/), (n) => match(n, /^[A-Za-z0-9._-]+$/) != null);
	if (length(filter(names, (n) => stat(`/sys/class/net/${n}`) != null)))
		return names;
	let st = try_json(cmd_out('ubus call network.interface.lan status 2>/dev/null') || 'null');
	let dev = st?.l3_device || st?.device;
	return (type(dev) == 'string' && match(dev, /^[A-Za-z0-9._-]+$/)) ? [ dev ] : names;
};

export function dnsmasq_nftset() {
	return match(cmd_out('dnsmasq --version 2>/dev/null'), /[ \t]nftset/) != null;
};

export function mwan3_ifaces(c) {
	let res = [];
	c.foreach('mwan3', 'interface', (s) => {
		if (s.enabled in [ '1', 'on', 'yes', 'true' ] && s.family != 'ipv6')
			push(res, { name: s['.name'], online: trim(readfile(`${MWAN3_STATE}/${s['.name']}`) || '') == 'online' });
	});
	return res;
};

export function on_backup(c) {
	let b = c.get('stella', 'main', 'backup_iface');
	let up = filter(mwan3_ifaces(c), (i) => i.online);
	return (b && length(up) == 1 && up[0].name == b) ? b : null;
};

export function load_devices(c) {
	let res = [];
	c.foreach('stella', 'device', (s) => {
		let mac = mac_list(s.mac)[0];
		if (mac)
			push(res, { id: s['.name'], name: s.name || '', mac, policy: (s.policy in [ 'vpn', 'direct' ]) ? s.policy : 'global' });
	});
	return res;
};

export function sub_label(s) {
	return s.name || s['.name'];
};

export function is_warp(s) {
	return s?.warp == '1';
};

export function zapret_used(c, lists) {
	if ((c.get('stella', 'main', 'default_action') || 'direct') == 'zapret' ||
		c.get('stella', 'main', 'zapret_yt') || c.get('stella', 'main', 'zapret_discord') || c.get('stella', 'main', 'zapret_games'))
		return true;
	if (lists) {
		for (let l in lists)
			if (l.action == 'zapret')
				return true;
		return false;
	}
	let used = false;
	c.foreach('stella', 'list', (s) => {
		if (s.enabled != '0' && (s.action || 'vpn') == 'zapret')
			used = true;
	});
	return used;
};

export function node_gone(id) {
	if (!id)
		return true;
	let c = uci();
	if (c.get('stella', id))
		return false;
	let sub = false;
	c.foreach('stella', 'subscription', (s) => { if (index(id, `${s['.name']}_`) == 0) sub = true; });
	return !sub;
};

/* ---- фоновые задачи ---- */

export function task_busy(name) {
	let path = `${RUN_DIR}/${name}.running`;
	let v = trim(readfile(path) || '');
	if (v == 'starting')
		return time() - (stat(path)?.mtime ?? 0) < 15;
	return match(v, /^[0-9]+$/) != null && system(`kill -0 ${v} 2>/dev/null`) == 0;
};

export function task_script(name, cmd) {
	let run = `${RUN_DIR}/${name}.running`;
	system(`mkdir -p ${RUN_DIR}`);
	writefile(run, 'starting');
	let script = `${RUN_DIR}/${name}.sh`;
	writefile(script, `echo $$ >${run}\numask 022\n{ ${cmd}; } >${RUN_DIR}/${name}.log 2>&1\nrc=$?\nrm -f ${run}\nexit $rc\n`);
	return script;
};

let last_rc = 0;
export function last_exit() {
	return last_rc;
};

export function run_locked(name, cmd, detach) {
	if (task_busy(name))
		return false;
	let script = task_script(name, cmd);
	last_rc = system(detach ? `setsid sh ${script} </dev/null >/dev/null 2>&1 &` : `sh ${script} </dev/null`);
	return true;
};

export function run_batch(jobs, limit) {
	let active = [];
	for (let j in jobs) {
		while (length(active) >= limit) {
			sleep(200);
			active = filter(active, task_busy);
		}
		if (run_locked(j[0], j[1], true))
			push(active, j[0]);
		else
			warn(`${j[0]}: уже идёт\n`);
	}
	while (length(active)) {
		active = filter(active, task_busy);
		if (length(active))
			sleep(200);
	}
};

/* ---- стабильность узлов ---- */

export function stab_entry(samples) {
	let good = sort(filter(samples, (v) => v >= 0), (a, b) => a - b);
	let ok = length(good);
	if (!ok)
		return { ok: 0, n: length(samples), ms: -1, jit: 0 };
	let ms = good[int(ok / 2)];
	let dev = 0;
	for (let v in good)
		dev += (v > ms) ? v - ms : ms - v;
	return { ok, n: length(samples), ms, jit: int(dev / ok) };
};

function stab_cost(e) {
	return e.ms + 2 * e.jit;
}

export function stab_better(a, b) {
	if (!a?.ok)
		return false;
	if (!b?.ok)
		return true;
	if (a.ok * b.n != b.ok * a.n)
		return a.ok * b.n > b.ok * a.n;
	return stab_cost(a) < 0.8 * stab_cost(b);
};

export function best_node(nodes, stab) {
	let best = null;
	for (let n in nodes) {
		let e = stab[n.id];
		if (!e?.ok)
			continue;
		let b = best ? stab[best.id] : null;
		if (!best || e.ok * b.n > b.ok * e.n || (e.ok * b.n == b.ok * e.n && stab_cost(e) < stab_cost(b)))
			best = n;
	}
	return best;
};

/* ---- HTTP-загрузка с резервом через VPN ---- */

let proxy_hosts = {};

export function socks_proxy() {
	return `127.0.0.1:${opt('main', 'socks_port', SOCKS_PORT)}`;
};

function fetch_file(url, path, ua, proxy, header, fast) {
	return system(sprintf('curl -fsSL --connect-timeout %d --max-time %d %s-A %s %s%s-o %s %s',
		fast ? 8 : TIMEOUT.connect, fast ? 25 : TIMEOUT.fetch, fast ? '' : '--retry 2 ',
		shq(ua), proxy ? `--socks5-hostname ${shq(proxy)} ` : '',
		header ? `-H ${shq(header)} ` : '', shq(path), shq(url))) == 0;
}

export function fetch_file_any(url, path, ua, header) {
	ua ||= 'Mozilla/5.0';
	let h = url_host(url);
	let has_vpn = xray_pid() != null;
	if (h && proxy_hosts[h] && has_vpn)
		return fetch_file(url, path, ua, socks_proxy(), header) || fetch_file(url, path, ua, null, header);
	if (fetch_file(url, path, ua, null, header, has_vpn))
		return true;
	if (fetch_file(url, path, ua, socks_proxy(), header)) {
		if (h)
			proxy_hosts[h] = true;
		return true;
	}
	return false;
};

function fetch_tmp(url, fn) {
	let tmp = `/tmp/stella-fetch.${PROC_TAG}.${fnv1a(url)}.${seq++}`;
	let body = fn(tmp) ? readfile(tmp) : null;
	unlink(tmp);
	return body;
}

export function fetch(url, ua, proxy, header, fast) {
	return fetch_tmp(url, (tmp) => fetch_file(url, tmp, ua, proxy, header, fast));
};

export function fetch_any(url, ua, header) {
	return fetch_tmp(url, (tmp) => fetch_file_any(url, tmp, ua, header));
};

export function fetch_asset(f) {
	return (f?.api ? fetch_any(f.api, null, 'Accept: application/octet-stream') : null) ?? (f?.file ? fetch_any(f.file) : null);
};

/* ---- временный xray и очереди ---- */

function listening(ports) {
	let want = {};
	for (let p in ports)
		want[sprintf('0100007F:%04X', p)] = true;
	for (let line in split(readfile('/proc/net/tcp') || '', '\n')) {
		let f = split(trim(line), /[ \t]+/);
		if (f[3] == '0A')
			delete want[f[1]];
	}
	return length(want) == 0;
}

export function queue_bound(qnum) {
	let t = readfile('/proc/net/netfilter/nfnetlink_queue');
	if (t == null)
		return null;
	for (let line in split(t, '\n'))
		if (+(match(line, /^ *([0-9]+) /)?.[1] ?? -1) == qnum)
			return true;
	return false;
};

export function xray_start(cfg, base, ports) {
	let cfg_path = `${RUN_DIR}/xray.${PROC_TAG}.${base}.json`;
	let pid_path = `${RUN_DIR}/xray.${PROC_TAG}.${base}.pid`;
	system(`mkdir -p ${shq(RUN_DIR)}`);
	writefile(cfg_path, sprintf('%J', cfg));
	system(`${xray_mem_env()}xray run -c ${shq(cfg_path)} >/dev/null 2>&1 & echo $! > ${shq(pid_path)}`);
	let pid = trim(readfile(pid_path) || '');
	unlink(pid_path);
	let alive = () => pid != '' && system(`kill -0 ${pid} 2>/dev/null`) == 0;
	wait_until(() => !alive() || listening(ports), 5000);
	unlink(cfg_path);
	return alive() ? pid : null;
};

export function xray_stop(pid) {
	stop_pid(pid, 3000);
};
