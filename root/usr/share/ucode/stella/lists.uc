// Разбор списков сайтов в домены и подсети IPv4.
// Понимает: домен в строке (itdoginfo), "+.domain" / "domain:" / "full:" (meta-rules-dat,
// v2ray), "DOMAIN-SUFFIX,x" / "DOMAIN,x" / "IP-CIDR,x" (clash), nftset=/a/b/…, CIDR и IP.
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
