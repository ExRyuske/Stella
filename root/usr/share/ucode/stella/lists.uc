// Разбор списков сайтов в домены и подсети IPv4.
// Понимает: домен в строке (itdoginfo), "+.domain" / "domain:" / "full:" (v2ray,
// mihomo), "DOMAIN-SUFFIX,x" / "DOMAIN,x" / "IP-CIDR,x" (clash), nftset=/a/b/…, CIDR и IP.
// Домен всегда означает «он и все поддомены» — так работает nftset в dnsmasq.
// Ключевые слова и регулярные выражения dnsmasq не поддерживает — они пропускаются.

'use strict';

function norm_domain(d) {
	d = lc(trim(d));
	d = replace(d, /^\*?\.+/, '');
	d = replace(d, /\.+$/, '');
	return match(d, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/) ? d : null;
}

function norm_cidr(s) {
	let m = match(trim(s), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(\/([0-9]+))?$/);
	if (!m)
		return null;
	for (let i = 1; i <= 4; i++)
		if (+m[i] > 255)
			return null;
	if (m[6] != null && +m[6] > 32)
		return null;
	return m[5] ? `${m[1]}.${m[2]}.${m[3]}.${m[4]}${m[5]}` : `${m[1]}.${m[2]}.${m[3]}.${m[4]}`;
}

// Возвращает { domains: [...], cidrs: [...] } без повторов.
export function parse_list(text) {
	let domains = {}, cidrs = {};

	for (let line in split(text || '', /\r?\n/)) {
		line = trim(replace(line, /#.*$/, ''));
		if (line == '' || substr(line, 0, 2) == '//' || line == 'payload:')
			continue;
		line = replace(line, /^- +/, '');           // yaml
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
		line = replace(line, /^[a-z]+:\/\/([^\/:?#]+).*$/, '$1');   // вставили ссылку на сайт
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

// Дерево репозитория itdoginfo/allow-domains (ответ GitHub API trees?recursive=1) → готовые
// списки по группам: [ { group, files: [ путь, … ] } ]. Берутся списки доменов — по стране
// (Russia/inside-raw.lst …), сервисы и категории; к сервису — его подсети IPv4
// (Subnets/IPv4/<имя>.lst: сначала то же имя, потом без учёта регистра). Подсети без
// сервиса — отдельным пунктом. Остальное в репозитории — те же списки в форматах других программ.
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
	// Подсети, у которых нет списка доменов, и дубли имён другого регистра — только если такого
	// сервиса нет совсем.
	for (let n, p in subnets)
		if (!used[p] && !length(filter(res, (r) => r.group == 'Services' && lc(match(r.files[0], /([^\/]+)\.lst$/)[1]) == lc(n))))
			push(res, { group: 'Services', files: [ p ] });
	return res;
};

// Упаковка CIDR или IP в 62-битное целое: (start << 30) | (bits << 24) | idx.
// Это позволяет сортировать десятки тысяч подсетей нативным C-шным sort() без колбэка ucode
// и без создания вложенных массивов на каждую подсеть.
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
	let start = ip & mask;
	return (start << 30) | (bits << 24) | (idx & 0xffffff);
}

function unpack_end(p) {
	let start = (p >> 30) & 0xffffffff;
	let bits = (p >> 24) & 0x3f;
	let mask = (bits == 0) ? 0 : ((0xffffffff << (32 - bits)) & 0xffffffff);
	return start | ((~mask) & 0xffffffff);
}

// Сравнение областей действия устройств двух списков: могут ли оба сработать для одного устройства.
function scopes_overlap(a, b) {
	let ma = a.devices_mode || 'all', mb = b.devices_mode || 'all';
	if (ma == 'all' || mb == 'all')
		return true;
	let sa = {};
	for (let m in a.macs || [])
		sa[m] = true;
	if (ma == 'only' && mb == 'only') {
		for (let m in b.macs || [])
			if (sa[m])
				return true;
		return false;
	}
	if (ma == 'only' && mb == 'except') {
		let sb = {};
		for (let m in b.macs || [])
			sb[m] = true;
		for (let m in a.macs || [])
			if (!sb[m])
				return true;
		return false;
	}
	if (ma == 'except' && mb == 'only') {
		for (let m in b.macs || [])
			if (!sa[m])
				return true;
		return false;
	}
	return true;
}

const SAMPLE_MAX = 25;

// Поиск пересечений доменов (с учётом поддоменов) и подсетей IPv4 между списками.
// Возвращает { id_списка: [ { id, name, action, shadowed, domains_count, cidrs_count, domains, cidrs } ] }.
export function list_overlaps(lists) {
	let res = {};
	let en = filter(lists || [], (l) => l.enabled);
	if (length(en) < 2)
		return res;

	let with_dom = filter(en, (l) => length(l.domains) > 0);
	let with_cidr = filter(en, (l) => length(l.cidrs) > 0);

	// Предварительно разбираем диапазоны CIDR только если хотя бы у двух включённых списков есть подсети.
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

	// Покрывается ли домен d родительским доменом из набора set_a.
	let sub_in = (d, set_a) => {
		for (let i = index(d, '.'); i >= 0; i = index(d, '.')) {
			d = substr(d, i + 1);
			if (set_a[d])
				return d;
		}
		return null;
	};

	for (let i = 0; i < length(en); i++) {
		let a = en[i];
		let set_a = dom_sets[a.id];
		let cidrs_a = parsed_cidrs[a.id];

		for (let j = i + 1; j < length(en); j++) {
			let b = en[j];
			if (!scopes_overlap(a, b))
				continue;
			let set_b = dom_sets[b.id];
			let cidrs_b = parsed_cidrs[b.id];

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
					domains_count: d_count, cidrs_count: c_count,
					domains: d_samples, cidrs: c_samples
				});
				res[a.id] ??= [];
				push(res[a.id], {
					id: b.id, name: b.name, action: b.action, shadowed: false,
					domains_count: d_count, cidrs_count: c_count,
					domains: d_samples, cidrs: c_samples
				});
			}
		}
	}
	return res;
};
