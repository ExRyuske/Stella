// Cloudflare WARP: данные генератора, маска QUIC, регистрация, подбор адреса, проверка и починка.

'use strict';

import { readfile, writefile, unlink, stat } from 'fs';
import { fnv1a, pctenc, try_json, b64dec_loose, shq, TRACE_URL, RUN_DIR, ZAPRET_DIR, ZAPRET_BIN, SOCKS_PORT, TIMEOUT, PROC_TAG, next_seq, read_json, save_file, cmd_out, run_parallel, task_busy, is_warp, uci, opt, reload_async, node_gone, fetch_any, socks_proxy, run_locked } from 'stella.core';
import { parse } from 'stella.uri';
import { zapret_catalog, ZT_PORTS, ZT_CONNECT, ZT_MAX, zt_nft, zt_start, zt_stop } from 'stella.zapret';

export const WARP_DATA = getenv('STELLA_WARP_DATA') || '/etc/stella/warp.json';
const WARP_SOURCE = getenv('STELLA_WARP_SOURCE') || 'https://raw.githubusercontent.com/nellimonix/warp-config-generator-vercel/master/lib/';
const WARP_FILES = { pool: 'endpoint-pool.ts', shared: 'builders/shared.ts', client: 'cloudflare-client.ts' };
const WARP_PORT = 2408;

const WARP_TRY = 8;
const WARP_PING_PORT = 21100;
const WARP_API_TIME = 15;
const WARP_ZAPRET_TRY = 12;
const WARP_ROUTE_TEXT = { direct: 'напрямую', zapret: 'через Zapret', vpn: 'через VPN' };
const WARP_FIX_AFTER = 2;
const WARP_REKEY_AFTER = 3;
const WARP_REKEY_EVERY = 86400;

let data = null;

function warp_data() {
	data ??= try_json(readfile(WARP_DATA) || 'null') || {};
	return data;
}

export function warp_data_reset() {
	data = null;
};

function ts_array(text, name) {
	let i = index(text || '', name);
	let b = (i >= 0) ? index(substr(text, i), '[') : -1;
	let e = (b >= 0) ? index(substr(text, i + b), ']') : -1;
	return (e >= 0) ? substr(text, i + b + 1, e - 1) : '';
}

function all_of(text, re) {
	return map(match(text || '', regexp(re, 'g')) || [], (m) => m[1]);
}

export function warp_data_parse(pool, shared, client) {
	let res = {};
	let hosts = uniq(all_of(ts_array(pool, 'WG_ENDPOINT_HOSTS'), "'([0-9]+[.][0-9]+[.][0-9]+)'"));
	let ports = uniq(filter(map(all_of(ts_array(pool, 'WG_ENDPOINT_PORTS'), '([0-9]+)'), (p) => +p), (p) => p > 0 && p < 65536));
	if (length(hosts) >= 3)
		res.hosts = hosts;
	if (length(ports) >= 3)
		res.ports = ports;
	let key = all_of(shared, "WARP_PUBLIC_KEY[^=]*=[ \t]*'([A-Za-z0-9+/]{43}=)'")[0];
	if (key)
		res.key = key;
	let b = index(shared || '', 'I1_MASKS:BEGIN'), e = index(shared || '', 'I1_MASKS:END');
	let masks = filter(map(all_of((b >= 0 && e > b) ? substr(shared, b, e - b) : '', '0x([0-9a-fA-F]+)'), (m) => lc(m)),
		(m) => length(m) >= 100 && length(m) % 2 == 0);
	if (length(masks))
		res.masks = masks;
	let api = all_of(client, "BASE_URL[ \t]*=[ \t]*'(https://api[.]cloudflareclient[.]com/v0[a-z0-9]+)'")[0];
	if (api)
		res.api = api;
	let i = index(client || '', 'DEFAULT_HEADERS');
	let ua = (i >= 0) ? all_of(substr(client, i, 300), "'User-Agent':[ \t]*'([A-Za-z0-9./ _-]+)'")[0] : null;
	if (ua)
		res.ua = ua;
	return res;
};

export function quic_noise(n) {
	let masks = warp_data().masks || [];
	if (!length(masks))
		return null;
	let mask = masks[hex(substr(fnv1a(n.secret_key || ''), 7)) % length(masks)];
	let noise = [ { type: 'hex', packet: mask, delay: '1-2' } ];
	for (let i = 0; i < 8; i++)
		push(noise, { rand: '23-911', delay: '1-3' });
	return { type: 'noise', settings: { reset: '30-60', noise } };
};

export function random_endpoints(count) {
	let d = warp_data(), hosts = d.hosts || [], ports = d.ports || [];
	let r = readfile('/dev/urandom', count * 6) || '';
	let res = [];
	if (!length(hosts) || !length(ports))
		return res;
	for (let i = 0; i < count * 2 && length(res) < count; i++) {
		let b = (j) => ord(r, i * 3 + j) ?? (i * 7 + j);
		let ep = `${hosts[b(0) % length(hosts)]}.${b(1) % 254 + 1}:${ports[b(2) % length(ports)]}`;
		if (!(ep in res))
			push(res, ep);
	}
	return res;
};

export function warp_link(w) {
	let addr = [ `${split(w.v4, '/')[0]}/32`, ...(w.v6 ? [ `${split(w.v6, '/')[0]}/128` ] : []) ];
	return sprintf('wireguard://%s@%s?publickey=%s&address=%s%s&mtu=1280&noise=quic#%s',
		pctenc(w.secret_key), w.endpoint, pctenc(w.public_key || warp_data().key || ''), pctenc(join(',', addr)),
		length(w.reserved) == 3 ? `&reserved=${join(',', w.reserved)}` : '', pctenc(w.name || 'WARP'));
};

export function iso_time(ts) {
	let t = gmtime(ts);
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
};

export function trace_info(text) {
	let loc = match(text || '', /(^|\n)loc=([A-Z]{2})/)?.[2];
	return loc ? { loc, colo: match(text, /(^|\n)colo=([A-Z]+)/)?.[2] } : null;
};

export function warp_better(a, b) {
	if (!a?.ok)
		return false;
	if (!b?.ok)
		return true;
	return a.ms < 0.8 * b.ms;
};

/* ---- CLI / обслуживание WARP ---- */

let warp_routes = [ 'direct', 'zapret', 'vpn' ];
let warp_nfqws = null;

function warp_ready() {
	return (stat(opt('main', 'zapret_bin', ZAPRET_BIN)) ? 'b' : '-') +
		(stat(`${ZAPRET_DIR}/catalog.json`) ? 'c' : '-') +
		(stat(WARP_DATA) ? 'w' : '-');
}

export function warp_first_retry() {
	let prev = readfile(`${RUN_DIR}/warp-first.ready`);
	return opt('main', 'warp_auto', '0') == '1' && prev != null && prev != warp_ready();
};

export function warp_needed() {
	if (opt('main', 'warp_auto', '0') == '1')
		return true;
	let found = false;
	uci().foreach('stella', 'node', (s) => { if (is_warp(s)) found = true; });
	return found;
};

export function warp_active() {
	let s = uci().get_all('stella', opt('main', 'node', ''));
	return is_warp(s) ? s : null;
};

function warp_api_base() {
	return getenv('STELLA_WARP_API') || warp_data().api;
}

function warp_zapret_find() {
	let bin = opt('main', 'zapret_bin', ZAPRET_BIN);
	if (!stat(bin) || task_busy('ztest'))
		return false;
	let own = filter(map(split(opt('main', 'zapret_opts', ''), /\r?\n/), (l) => trim(l)), (l) => l != '' && substr(l, 0, 1) != '#');
	let cands = [ ...(length(own) ? [ own ] : []),
		...map(filter(zapret_catalog(), (s) => s.family in [ 'v', 'fs', 'yv' ]), (s) => s.args) ];
	zt_nft(true);
	for (let args in slice(cands, 0, WARP_ZAPRET_TRY)) {
		let z = zt_start(bin, filter(args, (a) => !match(a, /^--(hostlist|ipset)/)));
		if (z.error)
			continue;
		let code = cmd_out(`curl -s -o /dev/null --local-port ${ZT_PORTS} --connect-timeout ${ZT_CONNECT} --max-time ${ZT_MAX} -w '%{http_code}' ${shq(warp_api_base() + '/')} 2>/dev/null`);
		if (match(code || '', /^[1-9]/))
			return z.pid;
		zt_stop(z.pid);
	}
	zt_nft(false);
	return false;
}

function warp_zapret_stop() {
	if (warp_nfqws) {
		zt_stop(warp_nfqws);
		zt_nft(false);
	}
	warp_nfqws = null;
}

function warp_route_args(route) {
	if (route == 'vpn')
		return ` --socks5-hostname ${shq(socks_proxy())}`;
	if (route == 'zapret') {
		warp_nfqws ??= warp_zapret_find();
		return warp_nfqws ? ` --local-port ${ZT_PORTS}` : false;
	}
	return '';
}

function warp_api(method, path, token, body) {
	if (!warp_api_base() || !warp_data().ua)
		return { error: 'нет данных WARP (stella warp-data)' };
	let tmp = `/tmp/stella-warp.${PROC_TAG}.${next_seq()}`;
	writefile(tmp, sprintf('%J', body));
	let cmd = sprintf("curl -sS --connect-timeout %d --max-time %d -X %s -H 'Content-Type: application/json' -H %s%s --data-binary @%s",
		TIMEOUT.connect, WARP_API_TIME, method, shq(`User-Agent: ${warp_data().ua}`), token ? ' -H ' + shq(`Authorization: Bearer ${token}`) : '', shq(tmp));
	let res = null, err = null, tried = [];
	for (let route in warp_routes) {
		let args = warp_route_args(route);
		if (args === false)
			continue;
		push(tried, WARP_ROUTE_TEXT[route]);
		let j = try_json(cmd_out(`${cmd}${args} ${shq(warp_api_base() + path)} 2>/dev/null`) || 'null');
		res = j?.result;
		if (type(res) == 'object') {
			warp_routes = uniq([ route, ...warp_routes ]);
			break;
		}
		err = j?.errors?.[0]?.message ?? err;
	}
	unlink(tmp);
	return (type(res) == 'object') ? res : { error: err || `API Cloudflare не отвечает (${join(', ', tried)})` };
}

function trace_cmd(port, out) {
	return sprintf("curl -s --max-time %d -w '\\n@%%{time_total}' --socks5-hostname 127.0.0.1:%d %s >%s 2>/dev/null",
		TIMEOUT.probe, port, TRACE_URL, shq(out));
}

function trace_result(out) {
	let text = readfile(out) || '';
	unlink(out);
	let t = trace_info(text);
	let ms = match(text, /@([0-9.]+)$/)?.[1];
	return t ? { ok: true, ms: int(+ms * 1000), loc: t.loc, colo: t.colo } : { ok: false };
}

function warp_trace(nodes, base, socks_start) {
	let got = socks_start(nodes, base);
	if (!got)
		return null;
	let res = {};
	for (let round = 0; round < 2; round++) {
		let cmds = [], pending = [];
		for (let i, n in nodes) {
			if (!res[n.id]?.ok) {
				let out = `${RUN_DIR}/trace.${PROC_TAG}.${base + i}`;
				push(cmds, trace_cmd(base + i, out));
				push(pending, [ n, out ]);
			}
		}
		if (!length(cmds))
			break;
		run_parallel(cmds, length(cmds));
		for (let item in pending)
			res[item[0].id] = trace_result(item[1]);
	}
	got.stop();
	return res;
}

function warp_pick(mk, first, socks_start) {
	let cands = slice(uniq([ ...(first ? [ first ] : []), ...random_endpoints(WARP_TRY) ]), 0, WARP_TRY);
	if (!length(cands))
		return { error: 'нет адресов WARP (stella warp-data)' };
	let nodes = map(cands, (ep, i) => ({ ...parse(mk(ep)), id: `warp${i}`, ep }));
	system(`mkdir -p ${shq(RUN_DIR)}`);
	let tr = warp_trace(nodes, WARP_PING_PORT, socks_start);
	if (tr == null)
		return { error: 'xray не принял конфиг WARP' };
	let best = null;
	for (let n in nodes)
		if (warp_better(tr[n.id], best ? tr[best.id] : null))
			best = n;
	return best ? { ep: best.ep, r: tr[best.id] } : { ep: cands[0], r: null, tried: length(cands) };
}

function warp_register() {
	let keys = cmd_out('xray wg 2>/dev/null');
	let priv = match(keys, /PrivateKey: *([A-Za-z0-9+\/=]+)/)?.[1];
	let pub = match(keys, /PublicKey\)?: *([A-Za-z0-9+\/=]+)/)?.[1];
	if (!priv || !pub)
		return { error: 'xray не выдал ключи WireGuard (xray wg)' };

	let reg = warp_api('POST', '/reg', null, { install_id: '', tos: iso_time(), key: pub, fcm_token: '', type: 'ios', locale: 'en_US' });
	if (reg.error || !reg.id || !reg.token) {
		warp_zapret_stop();
		return { error: `регистрация в WARP не удалась: ${reg.error || 'нет учётной записи в ответе'}` };
	}
	let acc = warp_api('PATCH', `/reg/${reg.id}`, reg.token, { warp_enabled: true });
	warp_zapret_stop();
	let conf = acc.config, peer = acc.config?.peers?.[0], ifa = acc.config?.interface?.addresses;
	if (acc.error || !peer?.public_key || !ifa?.v4)
		return { error: `WARP не выдал настройки: ${acc.error || 'нет адреса в ответе'}` };
	if (warp_routes[0] != 'direct')
		printf('API Cloudflare напрямую закрыт, учётная запись создана %s\n', WARP_ROUTE_TEXT[warp_routes[0]]);
	let raw = b64dec_loose(conf.client_id || '') || '';
	let w = { secret_key: priv, public_key: peer.public_key, v4: ifa.v4, v6: ifa.v6,
		reserved: (length(raw) == 3) ? [ ord(raw, 0), ord(raw, 1), ord(raw, 2) ] : null };
	let host = match(peer.endpoint?.v4 || '', /^([0-9.]+)/)?.[1];
	let port = +(match(peer.endpoint?.host || '', /:([0-9]+)$/)?.[1] || WARP_PORT);
	return { w, first: host ? `${host}:${port}` : null };
}

function warp_result_text(r) {
	return r?.ok ? sprintf('%d мс, узел Cloudflare %s', r.ms, r.colo || '?') : 'не отвечает';
}

export function cmd_warp_data() {
	let got = {};
	for (let k, f in WARP_FILES)
		got[k] = fetch_any(WARP_SOURCE + f);
	let old = warp_data(), fresh = warp_data_parse(got.pool, got.shared, got.client);
	let res = { ...old, ...fresh };
	let missing = filter([ 'hosts', 'ports', 'key', 'masks', 'api', 'ua' ], (k) => fresh[k] == null);
	if (length(missing))
		warn(`данные WARP: не получено ${join(', ', missing)}${length(keys(old)) ? ', остаются прежние' : ''}\n`);
	else
		res.at = time();
	system(`mkdir -p ${shq(replace(WARP_DATA, /\/[^\/]+$/, '') || '/')}`);
	save_file(WARP_DATA, sprintf('%J', res));
	warp_data_reset();
	printf('WARP: подсетей %d, портов %d, масок %d\n', length(res.hosts), length(res.ports), length(res.masks));
	return length(missing) ? 1 : 0;
};

function warp_create(argv, socks_start) {
	if (!warp_data().api || !length(warp_data().hosts || []))
		cmd_warp_data();
	let reg = warp_register();
	if (reg.error) {
		warn(reg.error + '\n');
		return 1;
	}
	let c = uci(), sid = null, name = join(' ', argv);
	c.foreach('stella', 'node', (s) => {
		if (!sid && is_warp(s)) {
			sid = s['.name'];
			if (name == '')
				name = s.name || '';
		}
	});
	if (name == '') {
		let taken = {};
		c.foreach('stella', 'node', (s) => { taken[s.name] = true; });
		name = 'WARP';
		for (let i = 2; taken[name]; i++)
			name = `WARP ${i}`;
	}
	let mk = (ep) => warp_link({ ...reg.w, endpoint: ep, name });
	let p = warp_pick(mk, reg.first, socks_start);
	if (p.error) {
		warn(p.error + '\n');
		return 1;
	}
	let link = mk(p.ep);
	sid ??= `node_${fnv1a(link)}`;
	c.load('stella');
	c.set('stella', sid, 'node');
	c.set('stella', sid, 'name', name);
	c.set('stella', sid, 'link', link);
	c.set('stella', sid, 'warp', '1');
	c.commit('stella');
	if (p.r)
		printf('Узел «%s»: адрес %s, %s\n', name, p.ep, warp_result_text(p.r));
	else
		printf('Узел «%s» добавлен, но ни один из %d адресов WARP не ответил: похоже, WARP закрыт у провайдера\n', name, p.tried);
	return 0;
}

export function warp_run(argv, socks_start, on_first_done) {
	let first = ('--first' in argv), c = uci();
	argv = filter(argv, (a) => a != '--first');
	let has = () => { let r = null; c.foreach('stella', 'node', (s) => { if (!r && is_warp(s)) r = s['.name']; }); return r; };
	if (first && opt('main', 'warp_auto', '0') != '1')
		return 0;
	if (first && !has()) {
		if (!stat(`${ZAPRET_DIR}/catalog.json`) && !task_busy('zcatalog'))
			run_locked('zcatalog', '/usr/bin/stella zapret-catalog');
		for (let i = 0; i < 300 && (task_busy('zcatalog') || task_busy('ztest')); i++)
			sleep(2000);
		system(`mkdir -p ${shq(RUN_DIR)}`);
		writefile(`${RUN_DIR}/warp-first.ready`, warp_ready());
	}
	let rc = (first && has()) ? 0 : warp_create(argv, socks_start);
	warp_zapret_stop();
	if (first && on_first_done)
		on_first_done();
	if (rc == 0) {
		c.load('stella');
		let sid = has();
		if (first)
			c.delete('stella', 'main', 'warp_auto');
		if (sid && node_gone(opt('main', 'node', '')))
			c.set('stella', 'main', 'node', sid);
		c.commit('stella');
		reload_async();
	}
	return rc;
};

function warp_repair(s, cur, rekey, socks_start) {
	let mk, first = match(s.link, /@([^?\/]+)/)?.[1];
	if (rekey) {
		let reg = warp_register();
		if (reg.error)
			return null;
		mk = (ep) => warp_link({ ...reg.w, endpoint: ep, name: s.name || 'WARP' });
		first = reg.first;
	}
	else
		mk = (ep) => replace(s.link, /@[^?\/]+/, `@${ep}`);
	let p = warp_pick(mk, first, socks_start);
	if (p.error || !warp_better(p.r, cur))
		return null;
	let c = uci();
	c.set('stella', s['.name'], 'link', mk(p.ep));
	c.set('stella', s['.name'], 'warp', '1');
	c.commit('stella');
	reload_async();
	return { r: p.r, text: sprintf('%s: %s, %s', rekey ? 'новые ключи и адрес' : 'новый адрес', p.ep, warp_result_text(p.r)) };
}

export function cmd_warp_check(socks_start, ...argv) {
	let s = warp_active();
	if (!s) {
		print('узел WARP сейчас не используется\n');
		return 0;
	}
	system(`mkdir -p ${shq(RUN_DIR)}`);
	let path = `${RUN_DIR}/warp-check.json`;
	let st = read_json(path, {});
	let id = s['.name'];
	let e = st[id] || { bad: 0, repairs: 0 };
	let out = `${RUN_DIR}/trace.${PROC_TAG}.main`;
	system(trace_cmd(+opt('main', 'socks_port', SOCKS_PORT), out));
	let r = trace_result(out);
	e.last = { ...r, at: time() };
	e.bad = r.ok ? 0 : e.bad + 1;
	if (!e.bad)
		e.repairs = 0;
	printf('%s: %s\n', s.name || id, warp_result_text(r));
	if ('--fix' in argv && e.bad >= WARP_FIX_AFTER) {
		let rekey = e.repairs + 1 >= WARP_REKEY_AFTER && time() - (e.rekey_at || 0) >= WARP_REKEY_EVERY;
		if (rekey)
			e.rekey_at = time();
		let fix = warp_repair(s, r, rekey, socks_start);
		if (fix) {
			e = { bad: 0, repairs: 0, rekey_at: e.rekey_at, last: { ...fix.r, at: time() }, fixed: { at: time(), text: fix.text } };
			print(fix.text, '\n');
			system(`logger -t stella ${shq(`WARP «${s.name || id}» починен — ${fix.text}`)}`);
		}
		else {
			e.repairs++;
			print('лучше не нашлось\n');
		}
	}
	st = {};
	st[id] = e;
	writefile(path, sprintf('%J', st));
	return 0;
};
