// Узлы из UCI (отдельные ссылки) и кэша подписок. Общий код для CLI и rpcd.

'use strict';

import { readfile, writefile, stat, popen } from 'fs';
import { parse } from 'stella.uri';
import { parse_list } from 'stella.lists';
import { try_json, mac_list } from 'stella.util';
import { doh_url, resolv_servers, is_ipv4 } from 'stella.dns';

export const CACHE_DIR = getenv('STELLA_CACHE_DIR') || '/etc/stella/subs';
export const RUN_DIR = getenv('STELLA_RUN_DIR') || '/var/run/stella';
export const LISTS_DIR = getenv('STELLA_LISTS_DIR') || '/etc/stella/lists';
// DNS: каталог DoH-серверов, итоги проверки, подобранная цепочка, адреса имён серверов.
export const DNS_DIR = getenv('STELLA_DNS_DIR') || '/etc/stella/dns';
// Сколько серверов DNS добавляет пользователь и сколько подбирается автоматически: xray
// спрашивает их по очереди, и при упавших серверах до DNS провайдера надо дойти быстро.
// Проверки — на Cloudflare: доступность (ответ 204 без тела) и trace (IP, страна, узел).
export const PROBE_URL = getenv('STELLA_PROBE_URL') || 'https://cp.cloudflare.com/generate_204';
export const TRACE_URL = getenv('STELLA_TRACE_URL') || 'https://www.cloudflare.com/cdn-cgi/trace';

export const DNS_MAX = 4;
export const DNS_AUTO = 2;
// Тайминги и пределы, общие для CLI и rpcd (секунды). Скачивание — подписки, списки,
// каталоги, пакеты; проверка — один запрос: задержка узла, «Проверить связь».
export const TIMEOUT = { connect: 10, fetch: 60, probe: 8 };
// Узлов в автовыборе ★: у каждого свой outbound, и xray проверяет их раз в минуту.
export const AUTO_MAX = 30;
// Порт socks-входа xray, если в настройках он не задан.
export const SOCKS_PORT = 10808;

// Общее для CLI и rpcd: конфиг xray, который запускает служба, каталог и очереди Zapret
// (своя — для работы, отдельная — для автоподбора).
export const XRAY_CONF = '/var/etc/stella/config.json';
export const ZAPRET_DIR = getenv('STELLA_ZAPRET_DIR') || '/etc/stella/zapret';
export const ZAPRET_QNUM = 202;
export const ZT_QNUM = 205;

// PID xray, запущенного службой (null — не работает). «^» — чтобы pgrep не нашёл оболочку
// с этой же строкой.
export function xray_pid() {
	let p = popen(`pgrep -f '^/usr/bin/xray run -c ${XRAY_CONF}'`, 'r');
	let out = p ? p.read('all') : '';
	p?.close();
	return match(out || '', /^[0-9]+/)?.[0];
};

// Интерфейсы LAN, с которых перехватывается трафик. Если ни одного из заданных нет в системе
// (LAN — не br-lan: один порт eth0, виртуальная машина), берётся устройство интерфейса lan
// из netifd — иначе Stella молча не перехватывала бы ничего.
export function lan_ifnames(uci) {
	let v = uci.get('stella', 'main', 'lan_ifname') ?? [ 'br-lan' ];
	let names = filter((type(v) == 'array') ? v : split(v, /[ ,]+/), (n) => match(n, /^[A-Za-z0-9._-]+$/) != null);
	if (length(filter(names, (n) => stat(`/sys/class/net/${n}`) != null)))
		return names;
	let p = popen('ubus call network.interface.lan status 2>/dev/null', 'r');
	let st = try_json((p ? p.read('all') : null) || 'null');
	p?.close();
	let dev = st?.l3_device || st?.device;
	return (type(dev) == 'string' && match(dev, /^[A-Za-z0-9._-]+$/)) ? [ dev ] : names;
};

// Итоги проверки стабильности узлов — на флеше: после перезагрузки по ним выбирается
// замена пропавшему узлу. Рядом с кэшем подписок, но не в нём (там чистятся *.json).
export const STAB_PATH = replace(CACHE_DIR, /\/[^\/]+\/?$/, '') + '/stability.json';
// Такие же итоги, но через резервный канал mwan3: там отвечают другие узлы, и основным они
// не мешают.
export const STAB_BACKUP_PATH = replace(CACHE_DIR, /\/[^\/]+\/?$/, '') + '/stability-backup.json';

// JSON из файла; нет файла или он битый (оборвалась запись) — def.
export function read_json(path, def) {
	return try_json(readfile(path) || 'null') ?? def;
};

// Серверы DNS: в режиме подбора (dns_mode не «manual») — подобранные проверкой серверы обхода
// геоблокировок, вручную — свои (dns_server) по порядку. Последним xray спрашивает DNS
// провайдера (не здесь).
export function dns_auto(uci) {
	if (uci.get('stella', 'main', 'dns_mode') == 'manual')
		return [];
	let v = read_json(`${DNS_DIR}/auto.json`, {})?.servers;
	return slice(filter((type(v) == 'array') ? v : [], (u) => doh_url(u)), 0, DNS_AUTO);
};

export function dns_user(uci) {
	let v = uci.get('stella', 'main', 'dns_server');
	return slice(filter((type(v) == 'array') ? v : (v ? [ v ] : []), (u) => doh_url(u)), 0, DNS_MAX);
};

// Цепочка: при подборе — подобранные серверы, вручную — свои по порядку.
export function dns_chain(uci) {
	return (uci.get('stella', 'main', 'dns_mode') == 'manual') ? dns_user(uci) : dns_auto(uci);
};

// Запасные DNS — после цепочки, по порядку: 'isp' — DNS провайдера, IPv4 — обычный DNS,
// https://… — DoH. Не заданы — Cloudflare и Google из каталога (их адреса — оттуда же), а без
// каталога — DNS провайдера.
const DNS_FALLBACK_IDS = [ 'cloudflare', 'google' ];

export function dns_fallback(uci) {
	let v = uci.get('stella', 'main', 'dns_fallback');
	let res = filter((type(v) == 'array') ? v : (v ? [ v ] : []), (x) => x == 'isp' || is_ipv4(x) || doh_url(x));
	if (length(res))
		return slice(res, 0, DNS_MAX);
	let cat = read_json(`${DNS_DIR}/catalog.json`, []);
	res = [];
	for (let id in DNS_FALLBACK_IDS)
		for (let c in (type(cat) == 'array') ? cat : [])
			if (c?.id == id && doh_url(c.url))
				push(res, c.url);
	return length(res) ? res : [ 'isp' ];
};

// DNS провайдера — из настроек WAN (resolv.conf.auto netifd).
export function isp_dns() {
	return resolv_servers(readfile('/tmp/resolv.conf.d/resolv.conf.auto') || readfile('/tmp/resolv.conf.auto') || '');
};

function as_array(v) {
	return (v == null) ? [] : (type(v) == 'array') ? v : [ v ];
}

export function sub_label(s) {
	return s.name || s['.name'];
};

// Узел WARP: отмеченный при создании или прежний — по ключу сервера WARP в ссылке.
export function is_warp(s) {
	return s?.warp == '1';
};

// errors (необязательно) — массив, куда складываются битые отдельные ссылки. Источник узла —
// id подписки, «manual» (отдельная ссылка) или «warp».
export function load_nodes(uci, errors) {
	let nodes = [];

	uci.foreach('stella', 'node', (s) => {
		let n = parse(s.link);
		if (n.error) {
			if (errors)
				push(errors, { id: s['.name'], name: s.name || s['.name'], error: n.error });
			return;
		}
		n.id = s['.name'];
		if (s.name)
			n.name = s.name;
		n.source = n.source_id = is_warp(s) ? 'warp' : 'manual';
		push(nodes, n);
	});

	uci.foreach('stella', 'subscription', (s) => {
		if (s.enabled == '0')
			return;
		let list = read_json(`${CACHE_DIR}/${s['.name']}.json`, []);
		for (let n in list) {
			n.source = sub_label(s);
			n.source_id = s['.name'];
			push(nodes, n);
		}
	});

	return nodes;
};

// Списки по порядку секций: содержимое скачанных URL + записи, добавленные вручную.
export function load_lists(uci) {
	let res = [];
	uci.foreach('stella', 'list', (s) => {
		let path = `${LISTS_DIR}/${s['.name']}.json`;
		let remote = read_json(path, { domains: [], cidrs: [] });
		let manual = parse_list(join('\n', as_array(s.entry)));
		let domains = {}, cidrs = {};
		for (let d in [ ...remote.domains, ...manual.domains ]) domains[d] = true;
		for (let c in [ ...remote.cidrs, ...manual.cidrs ]) cidrs[c] = true;

		push(res, {
			id: s['.name'],
			name: s.name || s['.name'],
			enabled: s.enabled != '0',
			action: s.action || 'vpn',
			urls: as_array(s.url),
			geo: as_array(s.geo),
			entries: as_array(s.entry),
			domains: keys(domains),
			cidrs: keys(cidrs),
			updated: stat(path)?.mtime,
			// Для каких устройств действует: all — для всех, only/except — MAC из списка.
			devices_mode: (s.devices_mode in [ 'only', 'except' ] && length(as_array(s.mac))) ? s.devices_mode : 'all',
			macs: mac_list(s.mac)
		});
	});
	return res;
};

// Устройства с особым режимом: vpn — всё через VPN, direct — всё напрямую
// (global — по спискам, как все; такие записи хранят только название).
export function load_devices(uci) {
	let res = [];
	uci.foreach('stella', 'device', (s) => {
		let mac = mac_list(s.mac)[0];
		if (!mac)
			return;
		push(res, {
			id: s['.name'],
			name: s.name || '',
			mac,
			policy: (s.policy in [ 'vpn', 'direct' ]) ? s.policy : 'global'
		});
	});
	return res;
};

/* ---- резервный канал mwan3 ---- */

// Состояние интерфейсов mwan3 (online/offline): по этим файлам он сам решает, через какие
// каналы пускать трафик.
export const MWAN3_STATE = getenv('STELLA_MWAN3_STATE') || '/var/run/mwan3/iface_state';

// Включённые IPv4-интерфейсы mwan3 и в сети ли они; mwan3 не установлен — пусто.
export function mwan3_ifaces(uci) {
	let res = [];
	uci.foreach('mwan3', 'interface', (s) => {
		if (s.enabled in [ '1', 'on', 'yes', 'true' ] && s.family != 'ipv6')
			push(res, { name: s['.name'], online: trim(readfile(`${MWAN3_STATE}/${s['.name']}`) || '') == 'online' });
	});
	return res;
};

// Резервный канал, если трафик сейчас идёт через него: из интерфейсов mwan3 в сети только он,
// основной упал. Иначе null.
export function on_backup(uci) {
	let b = uci.get('stella', 'main', 'backup_iface');
	let up = filter(mwan3_ifaces(uci), (i) => i.online);
	return (b && length(up) == 1 && up[0].name == b) ? b : null;
};

// Фоновые задачи (обновление, проверка задержки, автоподбор…) — общие для CLI и rpcd.
// Флаг $RUN_DIR/<имя>.running хранит PID процесса: задача занята, пока он жив. Сразу
// после запуска, пока PID ещё не записан, в флаге «starting» — считается занятым 15 с.
export function task_busy(name) {
	let path = `${RUN_DIR}/${name}.running`;
	let v = trim(readfile(path) || '');
	if (v == 'starting')
		return time() - (stat(path)?.mtime ?? 0) < 15;
	return match(v, /^[0-9]+$/) != null && system(`kill -0 ${v} 2>/dev/null`) == 0;
};

// Скрипт задачи: пишет свой PID во флаг, выполняет cmd с логом в <имя>.log, снимает флаг.
export function task_script(name, cmd) {
	let run = `${RUN_DIR}/${name}.running`;
	system(`mkdir -p ${RUN_DIR}`);
	writefile(run, 'starting');
	let script = `${RUN_DIR}/${name}.sh`;
	// umask — как у обычной оболочки: у rpcd она строже, и созданные задачей файлы (хостлисты
	// Zapret) не мог бы прочитать nfqws, который работает не от root.
	writefile(script, `echo $$ >${run}\numask 022\n{ ${cmd}; } >${RUN_DIR}/${name}.log 2>&1\nrm -f ${run}\n`);
	return script;
};

/* ---- выбор узла по проверке стабильности ---- */

// Замеры одного узла (мс, -1 — нет ответа) → { ok, n, ms — медиана, jit — средний
// разброс от медианы }.
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

// Стоимость при равной доле ответов: задержка плюс удвоенный разброс.
function stab_cost(e) {
	return e.ms + 2 * e.jit;
}

// a лучше b: больше доля ответов; при равной — дешевле хотя бы на 20 % (иначе по
// расписанию узел менялся бы из-за случайных колебаний).
export function stab_better(a, b) {
	if (!a?.ok)
		return false;
	if (!b?.ok)
		return true;
	if (a.ok * b.n != b.ok * a.n)
		return a.ok * b.n > b.ok * a.n;
	return stab_cost(a) < 0.8 * stab_cost(b);
};

// Лучший из узлов по итогам проверки; null — ни один не отвечал.
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
