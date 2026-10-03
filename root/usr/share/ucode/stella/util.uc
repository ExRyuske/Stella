// Общие помощники: base64, url-декодирование, разбор query, хеш.

'use strict';

// base64 / base64url, с паддингом или без, с переносами строк.
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

// json() на невалидном тексте бросает исключение — а тексты из подписок и файлов бывают
// битыми. Здесь вместо исключения — null.
export function try_json(s) {
	try {
		return json(s);
	}
	catch (e) {
		return null;
	}
};

export function urldecode(s) {
	if (type(s) != 'string')
		return s;
	s = replace(s, /\+/g, ' ');
	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
};

// Декодирование компонента пути/userinfo: '+' там не означает пробел.
export function pctdecode(s) {
	if (type(s) != 'string')
		return s;
	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
};

export function parse_query(q) {
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
};

// Разбор scheme://userinfo@host:port/path?query#fragment.
// Порт оставляем строкой: у hysteria2 бывает "443,20000-30000".
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

	// userinfo — до последнего «@», и отделяется раньше пути: в нём бывает «/» (обычный,
	// не url-safe base64 у ss://), а в адресе и порте «@» не бывает.
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

// FNV-1a 32 бит — стабильный id узла по ссылке.
export function fnv1a(s) {
	let h = 2166136261;
	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 16777619) & 0xffffffff;
	return sprintf('%08x', h);
};
