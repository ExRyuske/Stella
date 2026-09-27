// Каталог стратегий Zapret — из тех же источников, что у Zapret Manager (ZMS) и splify2:
//   v   — функции strategy_vN в Zapret-Manager.sh;
//   yv  — файл files/StrYoutube того же репозитория (уже в формате «#Имя + ключи»);
//   fs  — general*.bat из Flowseal/zapret-discord-youtube, переведённые в ключи nfqws
//         теми же правилами, что download_strategies в Zapret-Manager.sh.
// Стратегия — { name, family, args: [ "--ключ", … ] }.

'use strict';

// Профили .bat, которые берёт и Zapret Manager; остальное в файле — обвязка Windows.
const FS_PROFILES = [
	'--filter-udp=19294-19344,50000-50100',
	'--filter-tcp=%GameFilterTCP%',
	'--filter-udp=%GameFilterUDP%',
	'--filter-tcp=2053,2083,2087,2096,8443',
	'--filter-tcp=443 --hostlist="%LISTS%list-google.txt"',
	'--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt"'
];

// Фильтры по спискам Flowseal: на роутере их роль играют списки Stella (в очередь nfqws
// попадает только трафик списков с действием «Zapret»).
const FS_DROP = [
	'--hostlist="%LISTS%list-general.txt"',
	'--hostlist="%LISTS%list-general-user.txt"',
	'--ipset="%LISTS%ipset-all.txt"',
	'--ipset-exclude="%LISTS%ipset-exclude.txt"',
	'--ipset-exclude="%LISTS%ipset-exclude-user.txt"',
	'--hostlist-exclude="%LISTS%list-exclude-user.txt"'
];

// Игровой фильтр Flowseal выключен: так же, как у него по умолчанию (порт 12 — «ничего»).
const FS_GAME_OFF = '12';

function args_of_line(line) {
	return filter(map(split(replace(line, /--/g, '\n--'), '\n'), (a) => trim(a)), (a) => a != '');
}

// .bat Flowseal → стратегия. fake_dir — куда положены его файлы-подделки (*.bin).
export function flowseal_strategy(bat, name, fake_dir) {
	let args = [];
	for (let line in split(bat || '', /\r?\n/)) {
		line = trim(line);
		let ok = false;
		for (let p in FS_PROFILES)
			if (substr(line, 0, length(p)) == p)
				ok = true;
		if (!ok)
			continue;
		line = replace(line, /[ \t]*\^$/, '');
		push(args, ...args_of_line(line));
	}

	let out = [];
	for (let a in args) {
		if (a in FS_DROP)
			continue;
		a = replace(a, /"%BIN%([^"]+)"/g, (m, f) => `${fake_dir}/${f}`);
		a = replace(a, '"%LISTS%list-exclude.txt"', '/opt/zapret/ipset/zapret-hosts-user-exclude.txt');
		a = replace(a, '"%LISTS%list-google.txt"', '/opt/zapret/ipset/zapret-hosts-google.txt');
		a = replace(a, /%GameFilter(TCP|UDP)%/g, FS_GAME_OFF);
		a = replace(a, '^!', `${fake_dir}/tls_clienthello_www_google_com.bin`);
		a = replace(a, /"/g, '');
		// Лишний --new подряд или в конце nfqws не простит.
		if (a == '--new' && (!length(out) || out[length(out) - 1] == '--new'))
			continue;
		push(out, a);
	}
	while (length(out) && out[length(out) - 1] == '--new')
		pop(out);

	return length(out) ? { name, family: 'fs', args: out } : null;
};

// Zapret-Manager.sh: strategy_vN() { printf '%s\n' "#vN" "--ключ" …; }
export function zms_strategies(script) {
	let res = [];
	for (let line in split(script || '', '\n')) {
		if (!match(line, /^strategy_v[0-9]+\(\) *\{ *printf/))
			continue;
		let items = map(match(line, /"[^"]*"/g) || [], (m) => substr(m[0], 1, length(m[0]) - 2));
		if (length(items) < 2 || substr(items[0], 0, 1) != '#')
			continue;
		push(res, { name: substr(items[0], 1), family: 'v', args: slice(items, 1) });
	}
	return res;
};

// Формат «#Имя, затем ключи по строке» (StrYoutube, каталог splify2).
export function block_strategies(text, family) {
	let res = [], cur = null;
	for (let line in split(text || '', /\r?\n/)) {
		line = trim(line);
		if (line == '')
			continue;
		if (substr(line, 0, 1) == '#') {
			cur = { name: substr(line, 1), family, args: [] };
			push(res, cur);
		}
		else if (cur && substr(line, 0, 2) == '--')
			push(cur.args, line);
	}
	return filter(res, (s) => length(s.args));
};

// Ключи стратегии → текст для UCI (по ключу в строке, первой строкой — имя).
export function strategy_text(s) {
	return join('\n', [ `#${s.name}`, ...s.args ]);
};

// Дополнительные блоки — как у Zapret Manager: голос и видео Discord (UDP + TCP для
// discord.media) и игры (игровой фильтр Flowseal с портами 1024–65535).
const FAKE = '/opt/zapret/files/fake';
const DISCORD = [
	'--filter-udp=19294-19344,50000-50100', '--filter-l7=discord,stun', '--dpi-desync=fake',
	`--dpi-desync-fake-discord=${FAKE}/stun.bin`, `--dpi-desync-fake-stun=${FAKE}/stun.bin`, '--dpi-desync-repeats=6',
	'--new',
	'--filter-tcp=2053,2083,2087,2096,8443', '--hostlist-domains=discord.media', '--dpi-desync=multisplit',
	'--dpi-desync-split-seqovl=652', '--dpi-desync-split-pos=2',
	`--dpi-desync-split-seqovl-pattern=${FAKE}/tls_clienthello_www_google_com.bin`
];
const GAMES = [
	'--filter-tcp=1024-65535', '--dpi-desync=multisplit', '--dpi-desync-any-protocol=1', '--dpi-desync-cutoff=n3',
	'--dpi-desync-split-seqovl=568', '--dpi-desync-split-pos=1',
	`--dpi-desync-split-seqovl-pattern=${FAKE}/tls_clienthello_www_google_com.bin`,
	'--new',
	'--filter-udp=1024-65535', '--dpi-desync=fake', '--dpi-desync-repeats=12', '--dpi-desync-any-protocol=1',
	`--dpi-desync-fake-unknown-udp=${FAKE}/quic_initial_www_google_com.bin`, '--dpi-desync-cutoff=n2'
];

// «80,443,1000-2000,1500-3000» → слитые непересекающиеся диапазоны по возрастанию.
export function merge_ports(list) {
	let iv = [];
	for (let part in split(join(',', list), ',')) {
		let m = match(trim(part), /^([0-9]+)(-([0-9]+))?$/);
		if (m)
			push(iv, [ +m[1], m[3] ? +m[3] : +m[1] ]);
	}
	iv = sort(iv, (a, b) => a[0] - b[0]);
	let out = [];
	for (let r in iv) {
		let last = out[length(out) - 1];
		if (last && r[0] <= last[1] + 1)
			last[1] = max(last[1], r[1]);
		else
			push(out, [ r[0], r[1] ]);
	}
	return join(',', map(out, (r) => (r[0] == r[1]) ? `${r[0]}` : `${r[0]}-${r[1]}`));
};

// Итоговые ключи nfqws и порты очереди. YouTube — первым: nfqws берёт первый подходящий
// профиль, а Yv ограничены доменами YouTube и остальному не мешают.
// opts: { main: [ключи], yt: [ключи] | null, discord, games, tcp_ports, udp_ports }
export function compose(opts) {
	let blocks = filter([ opts.yt, opts.main, opts.discord ? DISCORD : null, opts.games ? GAMES : null ], (b) => length(b));
	let args = [];
	for (let i, b in blocks) {
		if (i)
			push(args, '--new');
		push(args, ...b);
	}
	let tcp = [ opts.tcp_ports || '80,443' ], udp = [ opts.udp_ports || '443' ];
	if (opts.discord) {
		push(tcp, '2053,2083,2087,2096,8443');
		push(udp, '19294-19344,50000-50100');
	}
	if (opts.games) {
		push(tcp, '1024-65535');
		push(udp, '1024-65535');
	}
	return { args, tcp_ports: merge_ports(tcp), udp_ports: merge_ports(udp) };
};
