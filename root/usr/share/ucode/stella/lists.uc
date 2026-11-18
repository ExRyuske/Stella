// Разбор списков сайтов (текст, .srs), каталог itdoginfo, пересечения, загрузка и обновление списков.

'use strict';

import { readfile, unlink, glob, stat } from 'fs';
import { is_ipv4, as_array, mac_list, shq, try_json, LISTS_DIR, RUN_DIR, PROC_TAG, read_json, save_file, cmd_out, uci, fetch_any, fetch_file_any } from 'stella.core';

function norm_domain(d) {
	d = lc(trim(d));
	d = replace(d, /^\*?\.+/, '');
	d = replace(d, /\.+$/, '');
	return match(d, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/) ? d : null;
}

function norm_cidr(s) {
	let m = match(trim(s), /^([^\/]+)(\/([0-9]+))?$/);
	if (!m || !is_ipv4(m[1]) || (m[3] != null && +m[3] > 32))
		return null;
	return m[2] ? `${m[1]}${m[2]}` : m[1];
}

// Возвращает { domains: [...], cidrs: [...] } без повторов.
export function parse_list(text) {
	let domains = {}, cidrs = {};

	for (let line in split(text || '', /\r?\n/)) {
		line = trim(replace(line, /#.*$/, ''));
		if (line == '' || substr(line, 0, 2) == '//' || line == 'payload:')
			continue;
		line = replace(line, /^- +/, '');
		line = replace(line, /^['"]|['"]$/g, '');

		let m = match(line, /^(nftset|ipset)=\/(.*)\/[^\/]*$/);
		if (m) {
			for (let d in split(m[2], '/'))
				if ((d = norm_domain(d)))
					domains[d] = true;
			continue;
		}

		m = match(line, /^([A-Za-z0-9-]+),([^,]+)/);
		if (m) {
			let kind = uc(m[1]);
			let v = (kind in ['DOMAIN', 'DOMAIN-SUFFIX', 'HOST', 'HOST-SUFFIX']) ? norm_domain(m[2]) :
				(kind in ['IP-CIDR', 'IP-CIDR6', 'IP']) ? norm_cidr(m[2]) : null;
			if (v)
				(kind in ['IP-CIDR', 'IP-CIDR6', 'IP'] ? cidrs : domains)[v] = true;
			continue;
		}

		if (match(line, /^(keyword|regexp|regex|geosite|geoip|ext):/))
			continue;
		line = replace(line, /^[a-z]+:\/\/([^\/:?#]+).*$/, '$1');
		line = replace(line, /^(domain|full|suffix|domain-suffix):/, '');
		line = replace(line, /^\+\./, '');

		let c = norm_cidr(line);
		if (c) {
			cidrs[c] = true;
			continue;
		}
		let d = norm_domain(line);
		if (d)
			domains[d] = true;
	}

	return { domains: sort(keys(domains)), cidrs: sort(keys(cidrs)) };
};

// Дерево репозитория itdoginfo/allow-domains → [ { group, files } ].
export function itdog_catalog(tree) {
	let paths = [];
	for (let e in (type(tree?.tree) == 'array') ? tree.tree : [])
		if (e?.type == 'blob' && type(e.path) == 'string' && match(e.path, /\.lst$/))
			push(paths, e.path);
	let subnets = {};
	for (let p in paths) {
		let m = match(p, /^Subnets\/IPv4\/([^\/]+)\.lst$/);
		if (m)
			subnets[m[1]] = p;
	}
	let used = {};
	let subnet_of = (name) => {
		if (subnets[name])
			return subnets[name];
		for (let n, p in subnets)
			if (lc(n) == lc(name))
				return p;
		return null;
	};
	let res = [];
	for (let p in sort(paths)) {
		let m = match(p, /^(Russia|Ukraine)\/[^\/]+-raw\.lst$/) || match(p, /^(Services|Categories)\/[^\/]+\.lst$/);
		if (!m)
			continue;
		let files = [ p ];
		if (m[1] == 'Services') {
			let s = subnet_of(match(p, /([^\/]+)\.lst$/)[1]);
			if (s) {
				push(files, s);
				used[s] = true;
			}
		}
		push(res, { group: m[1], files });
	}
	for (let n, p in subnets)
		if (!used[p] && !length(filter(res, (r) => r.group == 'Services' && lc(match(r.files[0], /([^\/]+)\.lst$/)[1]) == lc(n))))
			push(res, { group: 'Services', files: [ p ] });
	return res;
};

/* ---- пересечения списков ---- */

function pack_cidr(s, idx) {
	let k = index(s, '/');
	let a = iptoarr((k >= 0) ? substr(s, 0, k) : s);
	if (!a || length(a) != 4)
		return null;
	let bits = (k >= 0) ? +substr(s, k + 1) : 32;
	if (bits < 0 || bits > 32)
		return null;
	let ip = ((a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]) & 0xffffffff;
	let mask = (bits == 0) ? 0 : ((0xffffffff << (32 - bits)) & 0xffffffff);
	return ((ip & mask) << 30) | (bits << 24) | (idx & 0xffffff);
}

function unpack_end(p) {
	let start = (p >> 30) & 0xffffffff;
	let bits = (p >> 24) & 0x3f;
	let mask = (bits == 0) ? 0 : ((0xffffffff << (32 - bits)) & 0xffffffff);
	return start | ((~mask) & 0xffffffff);
}

function scopes_overlap(a, b) {
	let ma = a.devices_mode || 'all', mb = b.devices_mode || 'all';
	if (ma == 'all' || mb == 'all')
		return true;
	if (ma == 'except' && mb == 'only')
		return scopes_overlap(b, a);
	let sa = {};
	for (let m in a.macs || []) sa[m] = true;
	if (ma == 'only' && mb == 'only') {
		for (let m in b.macs || [])
			if (sa[m])
				return true;
		return false;
	}
	if (ma == 'only' && mb == 'except') {
		let sb = {};
		for (let m in b.macs || []) sb[m] = true;
		for (let m in a.macs || [])
			if (!sb[m])
				return true;
		return false;
	}
	return true;
}

const SAMPLE_MAX = 25;

export function list_overlaps(lists) {
	let res = {};
	let en = filter(lists || [], (l) => l.enabled);
	if (length(en) < 2)
		return res;

	let with_dom = filter(en, (l) => length(l.domains) > 0);
	let with_cidr = filter(en, (l) => length(l.cidrs) > 0);

	let parsed_cidrs = {};
	if (length(with_cidr) >= 2) {
		for (let l in with_cidr) {
			let rngs = [];
			for (let idx, c in l.cidrs) {
				let p = pack_cidr(c, idx);
				if (p != null)
					push(rngs, p);
			}
			sort(rngs);
			let merged = [], last_end = -1;
			for (let p in rngs) {
				let end = unpack_end(p);
				if (end > last_end) {
					push(merged, p);
					last_end = end;
				}
			}
			parsed_cidrs[l.id] = merged;
		}
	}

	let dom_sets = {};
	if (length(with_dom) >= 2) {
		for (let l in with_dom) {
			let s = {};
			for (let d in l.domains)
				s[d] = true;
			dom_sets[l.id] = s;
		}
	}

	let sub_in = (d, set_a) => {
		for (let i = index(d, '.'); i >= 0; i = index(d, '.')) {
			d = substr(d, i + 1);
			if (set_a[d])
				return d;
		}
		return null;
	};

	for (let i = 0; i < length(en); i++) {
		let a = en[i], set_a = dom_sets[a.id], cidrs_a = parsed_cidrs[a.id];

		for (let j = i + 1; j < length(en); j++) {
			let b = en[j];
			if (!scopes_overlap(a, b))
				continue;
			let set_b = dom_sets[b.id], cidrs_b = parsed_cidrs[b.id];

			let d_count = 0, d_samples = [];
			if (set_a && set_b) {
				for (let d in b.domains) {
					let p = set_a[d] ? d : sub_in(d, set_a);
					if (p) {
						d_count++;
						if (length(d_samples) < SAMPLE_MAX)
							push(d_samples, (p == d) ? d : `${d} (⊂ ${p})`);
					}
				}
				for (let d in a.domains) {
					if (set_b[d])
						continue;
					let p = sub_in(d, set_b);
					if (p) {
						d_count++;
						if (length(d_samples) < SAMPLE_MAX)
							push(d_samples, `${d} (⊂ ${p})`);
					}
				}
			}

			let c_count = 0, c_samples = [];
			if (length(cidrs_a) && length(cidrs_b)) {
				let ia = 0, ib = 0, na = length(cidrs_a), nb = length(cidrs_b);
				while (ia < na && ib < nb) {
					let pa = cidrs_a[ia], pb = cidrs_b[ib];
					let sa = (pa >> 30) & 0xffffffff, ea = unpack_end(pa);
					let sb = (pb >> 30) & 0xffffffff, eb = unpack_end(pb);
					if (sa <= eb && sb <= ea) {
						c_count++;
						if (length(c_samples) < SAMPLE_MAX) {
							let ca = a.cidrs[pa & 0xffffff], cb = b.cidrs[pb & 0xffffff];
							push(c_samples, (ca == cb) ? ca : `${cb} (∩ ${ca})`);
						}
						if (ea < eb)
							ia++;
						else if (eb < ea)
							ib++;
						else {
							ia++;
							ib++;
						}
					}
					else if (ea < sb)
						ia++;
					else
						ib++;
				}
			}

			if (d_count || c_count) {
				res[b.id] ??= [];
				push(res[b.id], {
					id: a.id, name: a.name, action: a.action, shadowed: true,
					domains_count: d_count, cidrs_count: c_count, domains: d_samples, cidrs: c_samples
				});
				res[a.id] ??= [];
				push(res[a.id], {
					id: b.id, name: b.name, action: b.action, shadowed: false,
					domains_count: d_count, cidrs_count: c_count, domains: d_samples, cidrs: c_samples
				});
			}
		}
	}
	return res;
};

/* ---- бинарные наборы sing-box (.srs) ---- */

const ITEM_DOMAIN = 2, ITEM_KEYWORD = 3, ITEM_REGEX = 4, ITEM_IPCIDR = 6, ITEM_FINAL = 0xff;

function uvarint(st) {
	let x = 0;
	for (let s = 0; s <= 63; s += 7) {
		let b = ord(st.d, st.o++);
		if (b == null)
			die('обрыв данных');
		x |= (b & 0x7f) << s;
		if (b < 0x80)
			return x;
	}
	die('переполнение varint');
}

function bit(d, off, i) {
	return (ord(d, off + (i >> 6) * 8 + 7 - ((i & 63) >> 3)) >> (i & 7)) & 1;
}

function skip_strings(st) {
	for (let n = uvarint(st); n > 0; n--) {
		st.o += uvarint(st);
		if (st.o > length(st.d))
			die('обрыв данных');
	}
}

function add_domain(k, out) {
	let i = 0;
	while (i < length(k) && (ord(k, i) < 0x21 || substr(k, i, 1) == '.'))
		i++;
	k = lc(i ? substr(k, i) : k);
	if (match(k, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/))
		out.domains[k] = true;
}

function read_domains(st, out) {
	st.o++;
	let nl = uvarint(st), lo = st.o;
	st.o += nl * 8;
	let nb = uvarint(st), bo = st.o;
	st.o += nb * 8;
	let nlab = uvarint(st), labels = substr(st.d, st.o, nlab);
	st.o += nlab;
	if (st.o > length(st.d))
		die('обрыв данных');

	let queue = [ '' ], head = 0, done = 0, li = 0, d = st.d;
	for (let w = 0; w < nb; w++)
		for (let j = 7; j >= 0; j--) {
			let byte = ord(d, bo + w * 8 + j);
			for (let b = 0; b < 8; b++, byte >>= 1) {
				if (!(byte & 1)) {
					push(queue, substr(labels, li++, 1) + queue[head]);
					continue;
				}
				let node = done + head;
				if ((node >> 6) < nl && bit(d, lo, node))
					add_domain(queue[head], out);
				if (++head >= length(queue))
					return;
				if (head >= 4096) {
					splice(queue, 0, head);
					done += head;
					head = 0;
				}
			}
		}
}

function ip4(n) {
	return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
}

function range_cidrs(a, b, out) {
	while (a <= b) {
		let bits = 0;
		while (bits < 32 && !((a >> bits) & 1) && a + (1 << (bits + 1)) - 1 <= b)
			bits++;
		out.cidrs[`${ip4(a)}/${32 - bits}`] = true;
		a += 1 << bits;
	}
}

function read_addr(st) {
	let n = uvarint(st);
	if (st.o + n > length(st.d))
		die('обрыв данных');
	let v = substr(st.d, st.o, n);
	st.o += n;
	return v;
}

function read_ipset(st, out) {
	st.o++;
	if (st.o + 8 > length(st.d))
		die('обрыв данных');
	let n = 0;
	for (let i = 0; i < 8; i++)
		n = n * 256 + ord(st.d, st.o++);
	for (; n > 0; n--) {
		let a = read_addr(st), b = read_addr(st);
		if (length(a) != 4 || length(b) != 4)
			continue;
		let x = 0, y = 0;
		for (let i = 0; i < 4; i++) {
			x = x * 256 + ord(a, i);
			y = y * 256 + ord(b, i);
		}
		range_cidrs(x, y, out);
	}
}

export function parse_srs(data) {
	if (type(data) != 'string' || substr(data, 0, 3) != 'SRS')
		return null;
	let zlib;
	try {
		zlib = require('zlib');
	}
	catch (e) {
		return { error: 'нужен пакет ucode-mod-zlib' };
	}
	let out = { domains: {}, cidrs: {} };
	try {
		let st = { d: zlib.inflate(substr(data, 4)), o: 0 };
		if (type(st.d) != 'string')
			return { error: 'набор повреждён' };
		for (let rules = uvarint(st); rules > 0; rules--) {
			if (ord(st.d, st.o++) != 0)
				return { error: 'составные правила не поддерживаются' };
			for (let item = ord(st.d, st.o++); item != ITEM_FINAL; item = ord(st.d, st.o++)) {
				if (item == ITEM_DOMAIN)
					read_domains(st, out);
				else if (item == ITEM_KEYWORD || item == ITEM_REGEX)
					skip_strings(st);
				else if (item == ITEM_IPCIDR)
					read_ipset(st, out);
				else if (item == null)
					return { error: 'набор оборван' };
				else
					return { error: `неизвестный пункт правила ${item}` };
			}
			st.o++;
		}
	}
	catch (e) {
		return { error: 'набор повреждён' };
	}
	return { domains: sort(keys(out.domains)), cidrs: sort(keys(out.cidrs)) };
};

/* ---- загрузка из UCI и обновление списков ---- */

function merge_uniq(base, extra) {
	base ||= [];
	if (!length(extra))
		return base;
	let m = {};
	for (let x in base) m[x] = true;
	for (let x in extra) m[x] = true;
	return keys(m);
}

export function load_lists(c) {
	let res = [];
	c.foreach('stella', 'list', (s) => {
		let path = `${LISTS_DIR}/${s['.name']}.json`;
		let remote = read_json(path, { domains: [], cidrs: [] });
		let manual = parse_list(join('\n', as_array(s.entry)));
		push(res, {
			id: s['.name'],
			name: s.name || s['.name'],
			enabled: s.enabled != '0',
			action: s.action || 'vpn',
			urls: as_array(s.url),
			geo: as_array(s.geo),
			entries: as_array(s.entry),
			domains: merge_uniq(remote.domains, manual.domains),
			cidrs: merge_uniq(remote.cidrs, manual.cidrs),
			updated: stat(path)?.mtime,
			devices_mode: (s.devices_mode in [ 'only', 'except' ] && length(as_array(s.mac))) ? s.devices_mode : 'all',
			macs: mac_list(s.mac)
		});
	});
	return res;
};

const GEO_BASE = getenv('STELLA_GEO_BASE') || 'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/';
const GEO_TREES = getenv('STELLA_GEO_TREES') || 'https://api.github.com/repos/runetfreedom/russia-v2ray-rules-dat/git/trees/release:sing-box/rule-set-';
const ITDOG_TGZ = getenv('STELLA_ITDOG_TGZ') ?? 'https://codeload.github.com/itdoginfo/allow-domains/tar.gz/refs/heads/main';
const ITDOG_TREE = getenv('STELLA_ITDOG_TREE') || 'https://api.github.com/repos/itdoginfo/allow-domains/git/trees/main?recursive=1';

export function list_sources(s) {
	let res = [ ...as_array(s.url) ];
	for (let g in as_array(s.geo)) {
		let m = match(g, /^(geosite|geoip):([a-z0-9@!_.-]+)$/);
		if (m)
			push(res, `${GEO_BASE}rule-set-${m[1]}/${m[1]}-${m[2]}.srs`);
	}
	return res;
};

function merge_field(parts, key) {
	let nonempty = filter(parts, (p) => length(p[key]) > 0);
	if (!length(nonempty))
		return [];
	if (length(nonempty) == 1)
		return nonempty[0][key];
	let set = {};
	for (let p in nonempty)
		for (let x in p[key]) set[x] = true;
	return sort(keys(set));
}

export function cmd_lists(...only) {
	let failed = 0, c = uci();
	system(`mkdir -p ${shq(LISTS_DIR)}`);

	c.foreach('stella', 'list', (s) => {
		let urls = list_sources(s);
		if ((length(only) && !(s['.name'] in only)) || !length(urls))
			return;
		if (!length(only) && s.enabled == '0' &&
		    readfile(`${LISTS_DIR}/${s['.name']}.src`) == join('\n', urls) &&
		    stat(`${LISTS_DIR}/${s['.name']}.json`)?.size > 0)
			return;

		let text = [], parts = [];
		for (let u in urls) {
			let body = fetch_any(u, 'stella');
			if (body == null) {
				warn(`${s.name}: не удалось скачать ${u}\n`);
				failed++;
				return;
			}
			let srs = parse_srs(body);
			if (srs?.error) {
				warn(`${s.name}: ${u}: ${srs.error}\n`);
				failed++;
				return;
			}
			srs ? push(parts, srs) : push(text, body);
			body = null;
		}

		let all = [ ...(length(text) ? [ parse_list(join('\n', text)) ] : []), ...parts ];
		let res = { domains: merge_field(all, 'domains'), cidrs: merge_field(all, 'cidrs') };
		parts = text = all = null;
		if (!length(res.domains) && !length(res.cidrs)) {
			warn(`${s.name}: список пуст, оставляю прежний\n`);
			failed++;
			return;
		}
		save_file(`${LISTS_DIR}/${s['.name']}.json`, sprintf('%J', res));
		save_file(`${LISTS_DIR}/${s['.name']}.src`, join('\n', urls));
		print(`${s.name}: доменов ${length(res.domains)}, подсетей ${length(res.cidrs)}\n`);
		res = null;
		if (type(gc) == 'function')
			gc();
	});

	let known = {};
	c.foreach('stella', 'list', (s) => {
		if (!length(list_sources(s)))
			return;
		known[`${LISTS_DIR}/${s['.name']}.json`] = true;
		known[`${LISTS_DIR}/${s['.name']}.src`] = true;
	});
	for (let f in [ ...(glob(`${LISTS_DIR}/*.json`) || []), ...(glob(`${LISTS_DIR}/*.src`) || []) ])
		if (!known[f])
			unlink(f);

	return failed ? 1 : 0;
};

function itdog_tree_tgz() {
	if (ITDOG_TGZ == '')
		return null;
	let tmp = `/tmp/stella-itdog.${PROC_TAG}.tgz`;
	let names = fetch_file_any(ITDOG_TGZ, tmp, 'stella')
		? split(cmd_out(`tar -tzf ${shq(tmp)} 2>/dev/null`), '\n') : [];
	unlink(tmp);
	let tree = map(filter(names, (n) => match(n, /^[^\/]+\/.+\.lst$/)), (n) => ({ type: 'blob', path: replace(n, /^[^\/]+\//, '') }));
	return length(tree) ? { tree } : null;
}

export function cmd_geo_index() {
	let path = `${RUN_DIR}/geo-index.json`;
	let old = read_json(path, {});
	let res = { ...old };
	let failed = 0;
	for (let kind in [ 'geosite', 'geoip' ]) {
		let tree = try_json(fetch_any(GEO_TREES + kind, 'stella') ?? 'null')?.tree;
		if (type(tree) != 'array') {
			warn(`russia-v2ray-rules-dat: не удалось получить наборы ${kind}\n`);
			failed++;
			continue;
		}
		let re = regexp(`^${kind}-([a-z0-9@!_.-]+)\\.srs$`);
		res[kind] = sort(map(filter(tree, (e) => e.type == 'blob' && match(e.path, re)), (e) => match(e.path, re)[1]));
	}
	let it = itdog_catalog(itdog_tree_tgz());
	if (!length(it))
		it = itdog_catalog(try_json(fetch_any(ITDOG_TREE, 'stella') ?? 'null'));
	if (length(it))
		res.itdog = it;
	else {
		warn('itdoginfo/allow-domains: не удалось получить список файлов\n');
		failed++;
	}
	res.at = failed ? (old.at ?? 0) : time();
	system(`mkdir -p ${shq(RUN_DIR)}`);
	save_file(path, sprintf('%J', res));
	printf('russia-v2ray-rules-dat: geosite %d, geoip %d; itdoginfo: %d\n', length(res.geosite), length(res.geoip), length(res.itdog));
	return failed ? 1 : 0;
};
