// DNS: каталог DoH-серверов, запрос и разбор ответа DNS.
//
// Каталог — из панели Zapret Manager (массив PROVIDERS в ZapretManager_LuCI.sh): там у
// каждого сервера id, название, адрес, вид (plain — только шифрование, safe — защита от
// угроз, family — семейный фильтр, geo — обход геоблокировок) и иногда адреса для начального
// разрешения (boot).

'use strict';

// Вид сервера и порядок групп в интерфейсе: обход геоблокировок, без фильтрации, с фильтрацией
// (safe — защита от угроз, family — семейный фильтр).
export const KINDS = [ 'geo', 'plain', 'safe', 'family' ];

function ipv4(s) {
	let m = match(s || '', /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
	if (!m)
		return false;
	for (let i = 1; i <= 4; i++)
		if (+m[i] > 255)
			return false;
	return true;
}

export function is_ipv4(s) {
	return ipv4(s);
};

// Адрес DoH: только https:// с именем или IPv4, без пробелов и кавычек.
export function doh_url(s) {
	return type(s) == 'string' && length(s) <= 200 &&
		match(s, /^https:\/\/[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~%\/+=&?-]*)?$/) != null;
};

export function url_host(s) {
	return match(s || '', /^https:\/\/([^\/:]+)/)?.[1];
};

// Значение поля «ключ: 'строка'» из строки объекта JavaScript.
function js_field(line, key) {
	return match(line, regexp(`[{ ,]${key}: '([^']*)'`))?.[1];
}

// Текст ZapretManager_LuCI.sh (или выдержка с массивом PROVIDERS) → [ { id, label, url, kind, boot } ].
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
			boot: filter(map(split(js_field(line, 'boot') || '', /[ ,;]+/), (x) => trim(x)), (x) => ipv4(x))
		});
	}
	return res;
};

/* ---- запрос DNS (RFC 1035) в виде для DoH GET (RFC 8484) ---- */

// Запрос A для имени → base64url без «=».
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

// Пропустить имя (метки или ссылку-сжатие) с позиции i → позиция после него; null — битое.
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

// Ответ DNS (двоичный) → IPv4 из записей A; null — не ответ DNS. rcode — в поле rcode.
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

// Адреса DNS провайдера из resolv.conf (nameserver …), только IPv4 и не свои.
export function resolv_servers(text) {
	let res = [];
	for (let line in split(text || '', '\n')) {
		let ip = match(line, /^[ \t]*nameserver[ \t]+([0-9.]+)/)?.[1];
		if (ipv4(ip) && !match(ip, /^127\./) && !(ip in res))
			push(res, ip);
	}
	return res;
};
