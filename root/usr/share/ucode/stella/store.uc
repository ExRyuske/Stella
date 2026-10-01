// Узлы из UCI (отдельные ссылки) и кэша подписок. Общий код для CLI и rpcd.

'use strict';

import { readfile, writefile, stat } from 'fs';
import { parse } from 'stella.uri';
import { parse_list } from 'stella.lists';

export const CACHE_DIR = getenv('STELLA_CACHE_DIR') || '/etc/stella/subs';
export const RUN_DIR = getenv('STELLA_RUN_DIR') || '/var/run/stella';
export const LISTS_DIR = getenv('STELLA_LISTS_DIR') || '/etc/stella/lists';
// Итоги проверки стабильности узлов — на флеше: после перезагрузки по ним выбирается
// замена пропавшему узлу. Рядом с кэшем подписок, но не в нём (там чистятся *.json).
export const STAB_PATH = replace(CACHE_DIR, /\/[^\/]+\/?$/, '') + '/stability.json';

// JSON из файла; нет файла — def.
export function read_json(path, def) {
	return json(readfile(path) || 'null') ?? def;
};

function as_array(v) {
	return (v == null) ? [] : (type(v) == 'array') ? v : [ v ];
}

export function sub_label(s) {
	return s.name || s['.name'];
};

// errors (необязательно) — массив, куда складываются битые отдельные ссылки.
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
		n.source = 'manual';
		n.source_id = 'manual';
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
			entries: as_array(s.entry),
			domains: keys(domains),
			cidrs: keys(cidrs),
			updated: stat(path)?.mtime,
			// Для каких устройств действует: all — для всех, only/except — MAC из списка.
			devices_mode: (s.devices_mode in [ 'only', 'except' ] && length(as_array(s.mac))) ? s.devices_mode : 'all',
			macs: map(filter(as_array(s.mac), (m) => match(m, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)), (m) => lc(m))
		});
	});
	return res;
};

// Устройства с особым режимом: vpn — всё через VPN, direct — всё напрямую
// (global — по спискам, как все; такие записи хранят только название).
export function load_devices(uci) {
	let res = [];
	uci.foreach('stella', 'device', (s) => {
		if (!match(s.mac || '', /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/))
			return;
		push(res, {
			id: s['.name'],
			name: s.name || '',
			mac: lc(s.mac),
			policy: (s.policy in [ 'vpn', 'direct' ]) ? s.policy : 'global'
		});
	});
	return res;
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
