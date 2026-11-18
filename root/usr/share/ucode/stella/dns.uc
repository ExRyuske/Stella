// DNS: каталог DoH-серверов, цепочка и запасные в UCI, проверка задержки и обхода.

'use strict';

import { readfile, writefile, unlink } from 'fs';
import { is_ipv4, url_host, as_array, shq, DNS_DIR, RUN_DIR, PROC_TAG, next_seq, read_json, save_file, run_parallel, cmd_out, task_busy, uci, opt, fetch_any, fetch_file_any, reload_async } from 'stella.core';

const KINDS = [ 'geo', 'plain', 'safe', 'family' ];
const DNS_MAX = 4;
const DNS_AUTO = 2;

const DNS_FALLBACK_IDS = [ 'cloudflare', 'google' ];
const DNS_CATALOG_URL = getenv('STELLA_DNS_CATALOG') || 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/ZapretManager_LuCI.sh';
const DNS_PROBE_LIST = getenv('STELLA_DNS_PROBE_LIST') || 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst';
const DNS_HOSTS_TTL = 86400;
const DNS_PARALLEL = 4;
const DNS_PROBES = 50;

export function doh_url(s) {
	return type(s) == 'string' && length(s) <= 200 &&
		match(s, /^https:\/\/[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~%\/+=&?-]*)?$/) != null;
};

function js_field(line, key) {
	return match(line, regexp(`[{ ,]${key}: '([^']*)'`))?.[1];
}

export function doh_catalog(text) {
	let start = index(text || '', 'PROVIDERS = [');
	if (start < 0)
		return [];
	let res = [], seen = {};
	for (let line in split(substr(text, start), '\n')) {
		if (match(line, /^[ \t]*\];/))
			break;
		let id = js_field(line, 'id'), url = js_field(line, 'url'), kind = js_field(line, 'k');
		if (!id || !doh_url(url) || !(kind in KINDS) || seen[url])
			continue;
		seen[url] = true;
		push(res, {
			id, url, kind,
			label: js_field(line, 'label') || url_host(url),
			boot: filter(map(split(js_field(line, 'boot') || '', /[ ,;]+/), (x) => trim(x)), is_ipv4)
		});
	}
	return res;
};

export function dns_query(name) {
	let q = '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00';
	for (let label in split(lc(name), '.'))
		if (label != '')
			q += chr(length(label)) + label;
	q += '\x00\x00\x01\x00\x01';
	return replace(replace(replace(b64enc(q), /=+$/, ''), /\+/g, '-'), /\//g, '_');
};

function u16(s, i) {
	return ord(s, i) * 256 + ord(s, i + 1);
}

function skip_name(s, i) {
	for (let n = 0; n < 128 && i < length(s); n++) {
		let l = ord(s, i);
		if (l == 0)
			return i + 1;
		if (l >= 192)
			return i + 2;
		i += l + 1;
	}
	return null;
}

export function dns_answer(s) {
	if (type(s) != 'string' || length(s) < 12)
		return null;
	let rcode = ord(s, 3) & 15, qd = u16(s, 4), an = u16(s, 6);
	let i = 12;
	for (let k = 0; k < qd; k++) {
		i = skip_name(s, i);
		if (i == null)
			return null;
		i += 4;
	}
	let ips = [];
	for (let k = 0; k < an; k++) {
		i = skip_name(s, i);
		if (i == null || i + 10 > length(s))
			return null;
		let t = u16(s, i), len = u16(s, i + 8);
		i += 10;
		if (i + len > length(s))
			return null;
		if (t == 1 && len == 4)
			push(ips, sprintf('%d.%d.%d.%d', ord(s, i), ord(s, i + 1), ord(s, i + 2), ord(s, i + 3)));
		i += len;
	}
	return { rcode, ips };
};

export function resolv_servers(text) {
	let res = [];
	for (let line in split(text || '', '\n')) {
		let ip = match(line, /^[ \t]*nameserver[ \t]+([0-9.]+)/)?.[1];
		if (is_ipv4(ip) && !match(ip, /^127\./) && !(ip in res))
			push(res, ip);
	}
	return res;
};

/* ---- настройки и файлы DNS ---- */

export function dns_catalog() {
	return filter(read_json(`${DNS_DIR}/catalog.json`, []), (c) => c?.kind in KINDS);
};

function dns_auto(c) {
	if (c.get('stella', 'main', 'dns_mode') == 'manual')
		return [];
	let v = read_json(`${DNS_DIR}/auto.json`, {})?.servers;
	return slice(filter((type(v) == 'array') ? v : [], doh_url), 0, DNS_AUTO);
}

function dns_user(c) {
	return slice(filter(as_array(c.get('stella', 'main', 'dns_server')), doh_url), 0, DNS_MAX);
}

export function dns_chain(c) {
	return (c.get('stella', 'main', 'dns_mode') == 'manual') ? dns_user(c) : dns_auto(c);
};

export function dns_fallback(c) {
	let res = filter(as_array(c.get('stella', 'main', 'dns_fallback')), (x) => x == 'isp' || is_ipv4(x) || doh_url(x));
	if (length(res))
		return slice(res, 0, DNS_MAX);
	let cat = dns_catalog();
	res = [];
	for (let id in DNS_FALLBACK_IDS)
		for (let e in cat)
			if (e?.id == id && doh_url(e.url))
				push(res, e.url);
	return length(res) ? res : [ 'isp' ];
};

export function isp_dns() {
	return resolv_servers(readfile('/tmp/resolv.conf.d/resolv.conf.auto') || readfile('/tmp/resolv.conf.auto') || '');
};

/* ---- проверка DoH и подбор цепочки ---- */

function parse_nslookup(text) {
	let ips = [];
	for (let line in split(text || '', '\n')) {
		let ip = match(line, /^Address( [0-9]+)?:[ \t]+([0-9.]+)/)?.[2];
		if (is_ipv4(ip) && !(ip in ips))
			push(ips, ip);
	}
	return ips;
}

function resolve_at(host, servers) {
	for (let s in servers) {
		let ips = parse_nslookup(cmd_out(`nslookup -type=A ${shq(host)} ${shq(s)} 2>/dev/null`));
		if (length(ips))
			return ips;
	}
	return [];
}

function resolve_many(names, servers) {
	let res = {};
	for (let n in names)
		res[n] = [];
	if (!length(names) || !length(servers))
		return res;
	let s = servers[0], cmds = [];
	for (let i, n in names)
		push(cmds, `nslookup -type=A ${shq(n)} ${shq(s)} >${shq(`${RUN_DIR}/isp.${PROC_TAG}.${i}`)} 2>/dev/null`);
	run_parallel(cmds, DNS_PARALLEL);
	for (let i, n in names) {
		let f = `${RUN_DIR}/isp.${PROC_TAG}.${i}`;
		let ips = parse_nslookup(readfile(f));
		unlink(f);
		res[n] = length(ips) ? ips : (length(servers) > 1 ? resolve_at(n, slice(servers, 1)) : []);
	}
	return res;
}

export function dns_hosts(urls, fresh) {
	let path = `${DNS_DIR}/hosts.json`;
	let cache = read_json(path, {}), cat = dns_catalog(), res = {}, changed = false, isp = isp_dns();
	for (let u in urls) {
		let h = url_host(u);
		if (!h || is_ipv4(h) || res[h])
			continue;
		let boot = filter(cat, (c) => c.url == u)[0]?.boot || [];
		if (length(boot)) {
			res[h] = boot;
			continue;
		}
		let c = cache[h], ips = null;
		if (fresh || !c || time() - c.at >= DNS_HOSTS_TTL) {
			ips = resolve_at(h, isp);
			if (length(ips)) {
				cache[h] = { ips, at: time() };
				changed = true;
			}
		}
		ips = length(ips) ? ips : c?.ips;
		if (length(ips))
			res[h] = ips;
	}
	if (changed) {
		system(`mkdir -p ${shq(DNS_DIR)}`);
		save_file(path, sprintf('%J', cache));
	}
	return res;
};

function geo_probe_names() {
	let names = [], first = true;
	for (let line in split(fetch_any(opt('main', 'dns_probe_list', DNS_PROBE_LIST), 'stella') || '', '\n')) {
		let d = trim(line);
		if (d == '') {
			first = true;
			continue;
		}
		if (first && match(d, /^[a-z0-9-]+(\.[a-z0-9-]+)+$/))
			push(names, d);
		first = false;
		if (length(names) >= DNS_PROBES)
			break;
	}
	return names;
}

function doh_ask(jobs, hosts) {
	let cmds = [];
	for (let j, q in jobs) {
		let h = url_host(q.url), port = match(q.url, /^https:\/\/[^\/:]+:([0-9]+)/)?.[1] || '443';
		let pin = (!is_ipv4(h) && hosts[h]) ? `--resolve ${shq(`${h}:${port}:${hosts[h][0]}`)} ` : '';
		let arg = (index(q.url, '?') >= 0 ? '&' : '?') + 'dns=' + dns_query(q.name);
		let base = `${RUN_DIR}/dns.${PROC_TAG}.${j}`;
		push(cmds, sprintf("curl -s -o %s --connect-timeout 3 --max-time 5 -H 'accept: application/dns-message' %s-w '%%{http_code} %%{time_total}' %s >%s 2>/dev/null",
			shq(base), pin, shq(q.url + arg), shq(`${base}.w`)));
	}
	run_parallel(cmds, DNS_PARALLEL);
	let out = [];
	for (let j = 0; j < length(jobs); j++) {
		let base = `${RUN_DIR}/dns.${PROC_TAG}.${j}`;
		let w = match(readfile(`${base}.w`) || '', /^([0-9]+) ([0-9.]+)/);
		push(out, { code: w ? +w[1] : 0, ms: w ? int(+w[2] * 1000) : -1, a: dns_answer(readfile(base)) });
		unlink(base);
		unlink(`${base}.w`);
	}
	return out;
}

function https_reach(pairs) {
	let cmds = [];
	for (let j, p in pairs)
		push(cmds, sprintf("curl -s -o /dev/null --connect-timeout 3 --max-time 6 --resolve %s -w '%%{http_code}' %s >%s 2>/dev/null",
			shq(`${p[0]}:443:${p[1]}`), shq(`https://${p[0]}/`), shq(`${RUN_DIR}/reach.${PROC_TAG}.${j}`)));
	run_parallel(cmds, DNS_PARALLEL);
	let out = [];
	for (let j = 0; j < length(pairs); j++) {
		let f = `${RUN_DIR}/reach.${PROC_TAG}.${j}`;
		push(out, +(trim(readfile(f) || '0')) > 0);
		unlink(f);
	}
	return out;
}

export function cmd_dns_check(...argv) {
	let apply = ('--apply' in argv), watch = ('--watch' in argv), c = uci();
	let cat = dns_catalog();
	if (watch && !length(dns_auto(c)))
		return 0;
	let urls = watch ? dns_auto(c) : apply ? map(filter(cat, (x) => x.kind == 'geo'), (x) => x.url)
		: uniq([ ...dns_chain(c), ...map(filter(cat, (x) => x.kind == 'geo'), (x) => x.url) ]);
	system(`mkdir -p ${shq(RUN_DIR)} ${shq(DNS_DIR)}`);
	if (!length(urls)) {
		warn('нет серверов для проверки — обновите каталог DNS\n');
		return 1;
	}
	let names = watch ? [] : geo_probe_names();
	let hosts = dns_hosts(urls, true);
	let isp = resolve_many(names, isp_dns());
	let net16 = (ip) => match(ip, /^([0-9]+\.[0-9]+)\./)?.[1];
	let isp16 = {};
	for (let n, ips in isp)
		isp16[n] = map(ips, net16);
	let substituted = (n, ip) => !(ip in isp[n]) && !(net16(ip) in isp16[n]);

	let kind = {};
	for (let x in cat)
		kind[x.url] = x.kind;
	let probes = (u) => (kind[u] in [ 'plain', 'safe', 'family' ]) ? [] : names;

	let probe_host = (u) => { let h = url_host(u); return (!h || is_ipv4(h)) ? 'example.com' : h; };
	let first_ans = doh_ask(map(urls, (u) => ({ url: u, name: probe_host(u) })), hosts);
	let alive = {};
	for (let k, u in urls)
		alive[u] = first_ans[k].code == 200 && first_ans[k].a?.rcode == 0;
	let jobs = [], idx = {};
	for (let i = 0; i < length(names); i++)
		for (let u in urls)
			if (alive[u] && i < length(probes(u))) {
				idx[`${i}|${u}`] = length(jobs);
				push(jobs, { url: u, name: probes(u)[i] });
			}
	let ans = doh_ask(jobs, hosts);
	let at = (i, u) => ans[idx[`${i}|${u}`]];
	let res = read_json(`${DNS_DIR}/check.json`, {});
	res.items ??= {};
	let pairs = [], owner = [];
	for (let k, u in urls) {
		let first = first_ans[k], ok = alive[u];
		let e = ok ? { ok: true, ms: first.ms, at: time() }
			: { ok: false, at: time(), error: first.code == 0 ? 'не отвечает' : (first.code != 200) ? `HTTP ${first.code}` : 'не ответ DNS' };
		let old = res.items[u], p = probes(u);
		if (!length(names) && old?.geo_of) {
			e.geo = old.geo;
			e.geo_of = old.geo_of;
		}
		else if (length(p)) {
			e.geo = 0;
			e.geo_of = length(p);
		}
		for (let i, n in p) {
			let ip = at(i, u)?.a?.ips?.[0];
			if (ok && ip && substituted(n, ip) && !match(ip, /^(0\.|127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/)) {
				push(pairs, [ n, ip ]);
				push(owner, u);
			}
		}
		res.items[u] = e;
	}
	for (let i, r in https_reach(pairs))
		if (r)
			res.items[owner[i]].geo++;
	res.at = time();
	if (length(names))
		res.names = names;
	save_file(`${DNS_DIR}/check.json`, sprintf('%J', res));

	for (let u in urls) {
		let e = res.items[u];
		printf('%8s  %s  %s\n', e.ok ? `${e.ms}ms` : e.error, e.geo_of ? sprintf('обход %d/%d', e.geo, e.geo_of) : '', u);
	}
	let good = filter(urls, (u) => res.items[u]?.ok);
	if (watch) {
		if (length(good))
			return 0;
		print('подобранные серверы не отвечают — подбираю заново\n');
		return cmd_dns_check('--apply');
	}
	if (!apply)
		return 0;
	good = sort(filter(good, (u) => !length(names) || res.items[u].geo > 0),
		(a, b) => (res.items[b].geo - res.items[a].geo) || (res.items[a].ms - res.items[b].ms));
	if (!length(good))
		warn('ни один сервер обхода геоблокировок не подошёл — пока работает DNS провайдера\n');
	let chain = slice(good, 0, DNS_AUTO);
	let path = `${DNS_DIR}/auto.json`;
	let was = read_json(path, {})?.servers;
	save_file(path, sprintf('%J', { servers: chain, at: time() }));
	printf('Подобраны: %s\n', length(chain) ? join(', ', chain) : 'никто');
	if (sprintf('%J', was) != sprintf('%J', chain))
		reload_async();
	return 0;
};

export function cmd_dns_catalog(...argv) {
	system(`mkdir -p ${shq(DNS_DIR)}`);
	let tmp = `/tmp/stella-dns-catalog.${PROC_TAG}.${next_seq()}`;
	let cat = [];
	if (fetch_file_any(DNS_CATALOG_URL, tmp, 'stella'))
		cat = doh_catalog(cmd_out(`sed -n '/PROVIDERS = \\[/,/^[[:space:]]*\\];/p' ${shq(tmp)}`));
	unlink(tmp);
	let rc = 0;
	if (length(cat) >= 3) {
		save_file(`${DNS_DIR}/catalog.json`, sprintf('%J', cat));
		writefile(`${DNS_DIR}/catalog.updated`, `${time()}`);
	}
	else {
		warn('каталог DNS не получен, оставляю прежний\n');
		rc = 1;
	}
	printf('DNS: серверов %d\n', length(dns_catalog()));
	if (!('--no-check' in argv) && opt('main', 'dns_mode', 'geo') != 'manual' && !task_busy('dnscheck'))
		cmd_dns_check('--apply');
	return rc;
};
