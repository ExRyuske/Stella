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

const FS_EXCLUDE = '/opt/zapret/ipset/zapret-hosts-flowseal-exclude.txt';

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
		a = replace(a, '"%LISTS%list-exclude.txt"', FS_EXCLUDE);
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

// «--ключ значение» через пробел (встречается в каталоге ZMS, например у Yv06) — nfqws
// такого ключа не узнаёт; zapret разбил бы строку по словам, а здесь нужен «--ключ=значение».
function norm_arg(a) {
	let m = match(a, /^(--[a-z0-9-]+)[ \t]+([^ \t-][^ \t]*)$/);
	return m ? `${m[1]}=${m[2]}` : a;
}

// Zapret-Manager.sh: strategy_vN() { printf '%s\n' "#vN" "--ключ" …; }
export function zms_strategies(script) {
	let res = [];
	for (let line in split(script || '', '\n')) {
		if (!match(line, /^strategy_v[0-9]+\(\) *\{ *printf/))
			continue;
		let items = map(match(line, /"[^"]*"/g) || [], (m) => substr(m[0], 1, length(m[0]) - 2));
		if (length(items) < 2 || substr(items[0], 0, 1) != '#')
			continue;
		push(res, { name: substr(items[0], 1), family: 'v', args: map(slice(items, 1), norm_arg) });
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
			push(cur.args, norm_arg(line));
	}
	return filter(res, (s) => length(s.args));
};

// Ключи стратегии → текст для UCI (по ключу в строке, первой строкой — имя).
export function strategy_text(s) {
	return join('\n', [ `#${s.name}`, ...s.args ]);
};

// Отдельные наборы — как у Zapret Manager:
//   dv — варианты TCP-блока для discord.media (Dv1…); к ним всегда добавляется блок
//        голоса и видео Discord по UDP;
//   gv — игры (Gv1…Gv4): UDP-блок с разной отсечкой + общий TCP-блок, на игровых
//        портах ZMS.
const FAKE = '/opt/zapret/files/fake';
const DISCORD_VOICE = [
	'--filter-udp=19294-19344,50000-50100', '--filter-l7=discord,stun', '--dpi-desync=fake',
	`--dpi-desync-fake-discord=${FAKE}/stun.bin`, `--dpi-desync-fake-stun=${FAKE}/stun.bin`, '--dpi-desync-repeats=6'
];
const DISCORD_TCP = '2053,2083,2087,2096,8443';
const DISCORD_UDP = '19294-19344,50000-50100';
export const GAME_PORTS = {
	udp: '88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535',
	tcp: '2099,2802,2302,2502,3478-3480,3724,6000-8000,8085,8090,8100,8903,8904,25565,27015-27030,27036-27037,35500-35600,50001,60442'
};

// Zapret-Manager.sh: DvN=$'--ключ\n--ключ…'
export function zms_discord(script) {
	let res = [];
	for (let line in split(script || '', '\n')) {
		let m = match(line, /^Dv([0-9]+)=\$'(.*)'$/);
		if (m)
			push(res, { name: `Dv${m[1]}`, family: 'dv', args: filter(split(m[2], '\\n'), (a) => substr(a, 0, 2) == '--') });
	}
	return res;
};

// Игровые порты из Zapret-Manager.sh (PORTS_UDP="…"; PORTS_TCP="…"), иначе — встроенные.
export function zms_game_ports(script) {
	let u = match(script || '', /PORTS_UDP="([0-9,-]+)"/), t = match(script || '', /PORTS_TCP="([0-9,-]+)"/);
	return { udp: u ? u[1] : GAME_PORTS.udp, tcp: t ? t[1] : GAME_PORTS.tcp };
};

export function game_strategies(ports) {
	let tcp_common = [
		`--filter-tcp=${ports.tcp}`, '--dpi-desync-any-protocol=1', '--dpi-desync-cutoff=n5', '--dpi-desync=multisplit',
		'--dpi-desync-split-seqovl=582', '--dpi-desync-split-pos=1', `--dpi-desync-split-seqovl-pattern=${FAKE}/stun.bin`
	];
	let res = [];
	for (let n = 1; n <= 4; n++) {
		let udp = (n == 1)
			? [ `--filter-udp=${ports.udp}`, '--dpi-desync=fake', '--dpi-desync-cutoff=d2', '--dpi-desync-any-protocol=1', `--dpi-desync-fake-unknown-udp=${FAKE}/stun.bin` ]
			: [ `--filter-udp=${ports.udp}`, '--dpi-desync=fake', '--dpi-desync-repeats=10', '--dpi-desync-any-protocol=1', `--dpi-desync-fake-unknown-udp=${FAKE}/stun.bin`, `--dpi-desync-cutoff=n${n}` ];
		push(res, { name: `Gv${n}`, family: 'gv', args: [ ...udp, '--new', ...tcp_common ], tcp_ports: ports.tcp, udp_ports: ports.udp });
	}
	return res;
};

// Что проверяет автоподбор: scope — all | main (v и fs) | v | yv | fs | имя стратегии.
// Discord и игры запросами curl не проверить — они не входят никуда. Текущая основная
// (cur — { name, args }) проверяется наравне, если проверяются основные: с ней
// сравнивается лучшая.
export function test_list(catalog, scope, cur) {
	let list = filter(catalog, (s) => s.family in [ 'v', 'fs', 'yv' ] &&
		(scope == 'all' || (scope == 'main' && s.family != 'yv') || s.family == scope || s.name == scope));
	// Текущая из каталога проверяется как она сама: иначе её результат записался бы
	// «текущей» и пропал из таблицы результатов.
	if (length(cur.args) && length(filter(list, (s) => s.family != 'yv')) && !length(filter(list, (s) => s.name == cur.name)))
		push(list, filter(catalog, (s) => s.name == cur.name && s.family in [ 'v', 'fs' ])[0] ||
			{ name: cur.name || 'текущая', family: 'current', args: cur.args });
	return list;
};

// Свои копии хостлистов вместо файлов пакета zapret: те устаревают вместе с пакетом, а без
// пакета стратегий с ними не запустить. Источники — те же, что у Zapret Manager.
export const HOSTLISTS = {
	google: {
		pkg: '/opt/zapret/ipset/zapret-hosts-google.txt',
		url: 'https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/ipset/zapret-hosts-google.txt',
		// Домены Google Play, которые Zapret Manager дописывает к этому списку.
		extra: [ 'gvt1.com', 'googleplay.com', 'play.google.com', 'beacons.gvt2.com', 'play.googleapis.com',
			'play-fe.googleapis.com', 'lh3.googleusercontent.com', 'android.clients.google.com',
			'connectivitycheck.gstatic.com', 'play-lh.googleusercontent.com', 'play-games.googleusercontent.com',
			'prod-lt-playstoregatewayadapter-pa.googleapis.com', 'youtubei.youtube.com' ]
	},
	exclude: {
		pkg: '/opt/zapret/ipset/zapret-hosts-user-exclude.txt',
		url: 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/zapret-hosts-user-exclude.txt',
		extra: []
	},
	// Свои исключения у стратегий Flowseal (Steam, Epic, Microsoft, VK, банки…). В пакете zapret
	// такого файла нет: путь условный, его заменяет своя копия, а без неё — список ZMS.
	exclude_fs: {
		pkg: FS_EXCLUDE,
		url: 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/list-exclude.txt',
		fallback: '/opt/zapret/ipset/zapret-hosts-user-exclude.txt',
		extra: []
	}
};

// Замена путей в ключах: { старый путь: новый }.
export function localize(args, paths) {
	return map(args, (a) => {
		for (let from, to in paths)
			a = replace(a, from, to);
		return a;
	});
};

// Файлы, на которые ссылаются ключи (--x=/путь.bin, --hostlist=/путь.txt), но которых нет.
export function missing_files(args, exists) {
	let res = {};
	for (let a in args) {
		let m = match(a, /^--[a-z0-9-]+=(\/[^,]+\.(bin|txt))$/);
		if (m && !exists(m[1]))
			res[m[1]] = true;
	}
	return keys(res);
};

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
// opts: { main: [ключи], yt: стратегия | null, discord: стратегия | null,
//         games: стратегия | null, games_fake: путь | null, discord_fake: путь | null,
//         tcp_ports, udp_ports }
export function compose(opts) {
	let blocks = [ opts.yt?.args, opts.main ];
	if (opts.discord) {
		// Своя подделка для голоса Discord — как смена fake в Zapret Manager.
		let voice = opts.discord_fake
			? map(DISCORD_VOICE, (a) => match(a, /^--dpi-desync-fake-(discord|stun)=/) ? replace(a, /=.*$/, `=${opts.discord_fake}`) : a)
			: DISCORD_VOICE;
		push(blocks, voice, opts.discord.args);
	}
	if (opts.games) {
		// Своя подделка для игр — как пункт «сменить fake» в Zapret Manager.
		let g = opts.games.args;
		if (opts.games_fake)
			g = map(g, (a) => (substr(a, 0, 30) == '--dpi-desync-fake-unknown-udp=') ? `--dpi-desync-fake-unknown-udp=${opts.games_fake}` : a);
		push(blocks, g);
	}

	let args = [];
	for (let b in filter(blocks, (b) => length(b))) {
		if (length(args))
			push(args, '--new');
		push(args, ...b);
	}
	// Порты основной и YouTube — только если они включены: иначе в очередь шёл бы весь
	// веб-трафик, которого ни один профиль не коснётся.
	let tcp = [], udp = [];
	if (length(opts.main) || opts.yt) {
		push(tcp, opts.tcp_ports || '80,443');
		push(udp, opts.udp_ports || '443');
	}
	if (opts.discord) {
		push(tcp, DISCORD_TCP);
		push(udp, DISCORD_UDP);
	}
	if (opts.games) {
		push(tcp, opts.games.tcp_ports || GAME_PORTS.tcp);
		push(udp, opts.games.udp_ports || GAME_PORTS.udp);
	}
	return { args, tcp_ports: merge_ports(tcp), udp_ports: merge_ports(udp) };
};
