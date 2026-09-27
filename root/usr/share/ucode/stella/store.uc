// Узлы из UCI (отдельные ссылки) и кэша подписок. Общий код для CLI и rpcd.

'use strict';

import { readfile, writefile, stat } from 'fs';
import { parse } from 'stella.uri';
import { parse_list } from 'stella.lists';

export const CACHE_DIR = getenv('STELLA_CACHE_DIR') || '/etc/stella/subs';
export const RUN_DIR = getenv('STELLA_RUN_DIR') || '/var/run/stella';
export const LISTS_DIR = getenv('STELLA_LISTS_DIR') || '/etc/stella/lists';

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
		let list = json(readfile(`${CACHE_DIR}/${s['.name']}.json`) || '[]');
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
		let remote = json(readfile(path) || 'null') || { domains: [], cidrs: [] };
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
