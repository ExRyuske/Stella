// Cloudflare WARP — бесплатный WireGuard от Cloudflare: регистрация, как у официального
// клиента, ссылка на узел и маска против DPI. Идеи — из github.com/nellimonix/
// warp-config-generator-vercel (MIT, (c) 2025 nellimonix), данные — из его файлов (warp_data).

'use strict';

import { readfile } from 'fs';
import { fnv1a, pctenc, try_json } from 'stella.util';

// Данные WARP — у генератора warp-config-generator-vercel, его файлы на GitHub: подсети и порты
// WireGuard, ключ сервера, маски QUIC (их пересобирает CI генератора), адрес API и User-Agent
// клиента. Stella скачивает их (stella warp-data) и хранит последнюю удачную копию: обновит автор
// — обновятся и у нас.
export const WARP_DATA = getenv('STELLA_WARP_DATA') || '/etc/stella/warp.json';
export const WARP_SOURCE = getenv('STELLA_WARP_SOURCE') || 'https://raw.githubusercontent.com/nellimonix/warp-config-generator-vercel/master/lib/';
// Файлы генератора, из которых берутся данные (пути — от WARP_SOURCE).
export const WARP_FILES = { pool: 'endpoint-pool.ts', shared: 'builders/shared.ts', client: 'cloudflare-client.ts' };
// Порт, если API его не назвал, — тот же, что у официального клиента.
export const WARP_PORT = 2408;

let data = null;

// Сохранённые данные (последние удачные); нет — {}.
export function warp_data() {
	data ??= try_json(readfile(WARP_DATA) || 'null') || {};
	return data;
};

// После записи новых данных — перечитать.
export function warp_data_reset() {
	data = null;
};

// Текст между скобками массива «ИМЯ … = [ … ]» исходника TypeScript.
function ts_array(text, name) {
	let i = index(text || '', name);
	let b = (i >= 0) ? index(substr(text, i), '[') : -1;
	let e = (b >= 0) ? index(substr(text, i + b), ']') : -1;
	return (e >= 0) ? substr(text, i + b + 1, e - 1) : '';
}

// Все совпадения первой группы шаблона re (строка регулярного выражения).
function all_of(text, re) {
	return map(match(text || '', regexp(re, 'g')) || [], (m) => m[1]);
}

// Файлы генератора → { hosts, ports, key, masks, api, ua } — только то, что нашлось и похоже на
// правду; чего нет — в ответе нет (останется прежнее).
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

// Маска для узла: всегда одна и та же у одного ключа — иначе конфиг xray менялся бы при каждой
// сборке, и xray перезапускался бы на каждый reload. reset — через сколько секунд тишины маска
// уходит снова: после паузы DPI видит соединение как новое.
// Данных ещё нет — null (маски нет).
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

// count случайных адресов WARP без повторов.
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

// Ссылка wireguard:// (как у v2rayN) с маской QUIC. w: { secret_key, public_key, v4, v6,
// reserved: [a, b, c], endpoint, name }.
export function warp_link(w) {
	let addr = [ `${split(w.v4, '/')[0]}/32`, ...(w.v6 ? [ `${split(w.v6, '/')[0]}/128` ] : []) ];
	return sprintf('wireguard://%s@%s?publickey=%s&address=%s%s&mtu=1280&noise=quic#%s',
		pctenc(w.secret_key), w.endpoint, pctenc(w.public_key || warp_data().key || ''), pctenc(join(',', addr)),
		length(w.reserved) == 3 ? `&reserved=${join(',', w.reserved)}` : '', pctenc(w.name || 'WARP'));
};

// Время для поля tos регистрации — как у клиента, ISO 8601.
export function iso_time(ts) {
	let t = gmtime(ts);
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
};

// Ответ cdn-cgi/trace → { loc — страна выхода, colo — узел Cloudflare }; null — не ответ trace.
export function trace_info(text) {
	let loc = match(text || '', /(^|\n)loc=([A-Z]{2})/)?.[2];
	return loc ? { loc, colo: match(text, /(^|\n)colo=([A-Z]+)/)?.[2] } : null;
};

// Лучше ли итог проверки a, чем b: отвечает; заметно (на 20 %) быстрее. Страну выхода
// сравнивать бесполезно: Cloudflare приписывает адресам выхода WARP страну пользователя, через
// какой бы узел (DME, ARN…) тот ни подключился.
export function warp_better(a, b) {
	if (!a?.ok)
		return false;
	if (!b?.ok)
		return true;
	return a.ms < 0.8 * b.ms;
};
