// Zapret: парсеры каталога (ZMS, StrYoutube, Flowseal), хостлисты, сборка аргументов nfqws и автоподбор.

'use strict';

import { readfile, writefile, unlink, glob, stat } from 'fs';
import { shq, try_json, NFQWS_DESYNC_MARK, ZAPRET_DIR, ZAPRET_BIN, ZAPRET_QNUM, ZT_QNUM, RUN_DIR, PROC_TAG, read_json, wait_until, run_parallel, stop_pid, uci, opt, set_main, fetch_any, queue_bound, zapret_used } from 'stella.core';
import { parse_list } from 'stella.lists';

const FS_PROFILES = [
	'--filter-udp=19294-19344,50000-50100',
	'--filter-tcp=%GameFilterTCP%',
	'--filter-udp=%GameFilterUDP%',
	'--filter-tcp=2053,2083,2087,2096,8443',
	'--filter-tcp=443 --hostlist="%LISTS%list-google.txt"',
	'--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt"'
];

const FS_DROP = [
	'--hostlist="%LISTS%list-general.txt"',
	'--hostlist="%LISTS%list-general-user.txt"',
	'--ipset="%LISTS%ipset-all.txt"',
	'--ipset-exclude="%LISTS%ipset-exclude.txt"',
	'--ipset-exclude="%LISTS%ipset-exclude-user.txt"',
	'--hostlist-exclude="%LISTS%list-exclude-user.txt"'
];

const FS_GAME_OFF = '12';
const FS_EXCLUDE = '/opt/zapret/ipset/zapret-hosts-flowseal-exclude.txt';
export const FAKE_DIR = '/opt/zapret/files/fake';

const ZMS_RAW = 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main';
const FLOWSEAL_TGZ = 'https://codeload.github.com/Flowseal/zapret-discord-youtube/tar.gz/refs/heads/main';
const DPI_SUITE = 'https://raw.githubusercontent.com/hyperion-cs/dpi-checkers/main/ru/tcp-16-20/suite.v2.json';

export const ZT_PORTS = '20000-20999';
const ZT_PARALLEL = 4;
export const ZT_CONNECT = 3;
export const ZT_MAX = 6;

const HOSTLISTS = {
	google: {
		pkg: '/opt/zapret/ipset/zapret-hosts-google.txt',
		url: 'https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/ipset/zapret-hosts-google.txt',
		zms_extra: true
	},
	exclude: {
		pkg: '/opt/zapret/ipset/zapret-hosts-user-exclude.txt',
		url: 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/zapret-hosts-user-exclude.txt'
	},
	exclude_fs: {
		pkg: FS_EXCLUDE,
		url: 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/list-exclude.txt',
		fallback: '/opt/zapret/ipset/zapret-hosts-user-exclude.txt'
	}
};

function args_of_line(line) {
	return filter(map(split(replace(line, /--/g, '\n--'), '\n'), (a) => trim(a)), (a) => a != '');
}

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
		if (a == '--new' && (!length(out) || out[length(out) - 1] == '--new'))
			continue;
		push(out, a);
	}
	while (length(out) && out[length(out) - 1] == '--new')
		pop(out);

	return length(out) ? { name, family: 'fs', args: out } : null;
};

function norm_arg(a) {
	let m = match(a, /^(--[a-z0-9-]+)[ \t]+([^ \t-][^ \t]*)$/);
	return m ? `${m[1]}=${m[2]}` : a;
}

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

function strategy_text(s) {
	return join('\n', [ `#${s.name}`, ...s.args ]);
}

function printf_items(text) {
	let i = index(text || '', 'printf ');
	if (i < 0)
		return [];
	return filter(map(match(substr(text, i), /"[^"]*"/g) || [], (m) => substr(m[0], 1, length(m[0]) - 2)), (a) => a != '%s\\n' && a != '%s\n');
}

function sh_func(script, name) {
	let i = index(script || '', `\n${name}() {`);
	if (i < 0)
		return null;
	let body = '';
	for (let line in split(substr(script, i + 1), '\n')) {
		body += line + '\n';
		if (!match(line, /\\$/) && match(line, /; *\}$/))
			break;
	}
	return body;
}

function trim_new(args) {
	while (length(args) && args[0] == '--new')
		args = slice(args, 1);
	return args;
}

export function zms_discord(script) {
	let res = [];
	for (let line in split(script || '', '\n')) {
		let m = match(line, /^Dv([0-9]+)=\$'(.*)'$/);
		if (m)
			push(res, { name: `Dv${m[1]}`, family: 'dv', args: filter(split(m[2], '\\n'), (a) => substr(a, 0, 2) == '--') });
	}
	return res;
};

export function zms_discord_voice(script) {
	let args = [];
	for (let a in trim_new(printf_items(sh_func(script, 'discord_str_add'))))
		if (substr(a, 0, 1) == '#' || a == "'")
			break;
		else
			push(args, a);
	return (length(args) && match(args[0], /^--filter-udp=/)) ? { name: 'voice', family: 'voice', args } : null;
};

export function zms_games(script) {
	let u = match(script || '', /PORTS_UDP="([0-9,-]+)"/)?.[1], t = match(script || '', /PORTS_TCP="([0-9,-]+)"/)?.[1];
	let one = printf_items(sh_func(script, 'strategy_Gv1')), gen = printf_items(sh_func(script, 'strategy_Gv'));
	let tcp = printf_items(sh_func(script, 'strategy_TCP_common'));
	if (!u || !t || !length(one) || !length(tcp))
		return [];
	let fix = sh_func(script, 'fix_GAME') || '';
	let n = 1;
	for (let m in match(fix, /for i in ([0-9 ]+); do/g) || [])
		for (let x in split(trim(m[1]), / +/))
			n = max(n, +x);
	for (let m in match(fix, /seq 1 ([0-9]+)/g) || [])
		n = max(n, +m[1]);
	let subst = (a, i) => replace(replace(replace(a, '$PORTS_UDP', u), '$PORTS_TCP', t), /\$\{?N\}?/g, `${i}`);
	let body = (items, i) => trim_new(filter(map(items, (a) => subst(a, i)), (a) => substr(a, 0, 2) == '--'));
	let res = [];
	for (let i = 1; i <= n; i++) {
		let udp = (i == 1) ? body(one, i) : (length(gen) ? body(gen, i) : null);
		if (udp)
			push(res, { name: `Gv${i}`, family: 'gv', args: [ ...udp, '--new', ...body(tcp, i) ] });
	}
	return res;
};

export function zms_gp_domains(script) {
	return filter(printf_items(sh_func(script, 'ADD_GP_DOMAINS')), (d) => match(d, /^[a-z0-9.-]+\.[a-z]+$/));
};

export function zms_yt_targets(script) {
	let m = match(script || '', /(^|\n)DOMAINS="([^"]*)"/);
	let res = [], seen = {};
	for (let d in split(m?.[2] || '', /[ \t]+/)) {
		if (!match(d, /^[a-z0-9.-]+\.[a-z]+$/))
			continue;
		let p = split(d, '.');
		let base = `${p[length(p) - 2]}.${p[length(p) - 1]}`;
		if (!seen[base]) {
			seen[base] = true;
			push(res, d);
		}
	}
	return res;
};

function block_ports(args) {
	let res = { tcp: [], udp: [] };
	for (let a in args || []) {
		let m = match(a, /^--filter-(tcp|udp)=([0-9,-]+)$/);
		if (m)
			push(res[m[1]], m[2]);
	}
	return res;
}

export function test_list(catalog, scope, cur) {
	let list = filter(catalog, (s) => s.family in [ 'v', 'fs', 'yv' ] &&
		(scope == 'all' || (scope == 'main' && s.family != 'yv') || s.family == scope || s.name == scope));
	if (length(cur.args) && length(filter(list, (s) => s.family != 'yv')) && !length(filter(list, (s) => s.name == cur.name)))
		push(list, filter(catalog, (s) => s.name == cur.name && s.family in [ 'v', 'fs' ])[0] ||
			{ name: cur.name || 'текущая', family: 'current', args: cur.args });
	return list;
};

export function localize(args, paths) {
	return map(args, (a) => {
		for (let from, to in paths)
			a = replace(a, from, to);
		return a;
	});
};

export function missing_files(args, exists) {
	let res = {};
	for (let a in args) {
		let m = match(a, /^--[a-z0-9-]+=(\/[^,]+\.(bin|txt))$/);
		if (m && !exists(m[1]))
			res[m[1]] = true;
	}
	return keys(res);
};

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

export function compose(opts) {
	let blocks = [ opts.yt?.args ], extra = [];
	if (opts.discord) {
		let voice = opts.voice?.args || [];
		if (opts.discord_fake)
			voice = map(voice, (a) => match(a, /^--dpi-desync-fake-(discord|stun)=/) ? replace(a, /=.*$/, `=${opts.discord_fake}`) : a);
		push(blocks, voice, opts.discord.args);
		push(extra, ...voice, ...opts.discord.args);
	}
	if (opts.games) {
		let g = opts.games.args;
		if (opts.games_fake)
			g = map(g, (a) => (substr(a, 0, 30) == '--dpi-desync-fake-unknown-udp=') ? `--dpi-desync-fake-unknown-udp=${opts.games_fake}` : a);
		push(blocks, g);
		push(extra, ...g);
	}
	push(blocks, opts.main);

	let args = [];
	for (let b in filter(blocks, (b) => length(b))) {
		if (length(args))
			push(args, '--new');
		push(args, ...b);
	}
	let tcp = [], udp = [];
	if (length(opts.main) || opts.yt) {
		push(tcp, opts.tcp_ports || '80,443');
		push(udp, opts.udp_ports || '443');
	}
	let p = block_ports(extra);
	push(tcp, ...p.tcp);
	push(udp, ...p.udp);
	return { args, tcp_ports: merge_ports(tcp), udp_ports: merge_ports(udp) };
};

/* ---- CLI / runtime Zapret ---- */

function strategy_lines(text) {
	let res = [];
	for (let line in split(text || '', /\r?\n/)) {
		line = trim(line);
		if (line != '' && substr(line, 0, 1) != '#')
			push(res, ...filter(split(line, /[ \t]+/), (a) => a != ''));
	}
	return res;
}

function zapret_paths() {
	let res = {};
	for (let name, h in HOSTLISTS) {
		let own = `${ZAPRET_DIR}/hosts-${name}.txt`;
		if (stat(own)?.size > 0)
			res[h.pkg] = own;
		else if (h.fallback)
			res[h.pkg] = h.fallback;
	}
	return res;
}

function zapret_readable() {
	system(`chmod a+x ${shq(replace(ZAPRET_DIR, /\/[^\/]+\/?$/, '') || '/')} 2>/dev/null; chmod -R a+rX ${shq(ZAPRET_DIR)} 2>/dev/null`);
}

export function zapret_exclude_files() {
	let res = [];
	for (let n in [ 'exclude', 'exclude_fs' ]) {
		let own = `${ZAPRET_DIR}/hosts-${n}.txt`;
		let f = (stat(own)?.size > 0) ? own : HOSTLISTS.exclude.pkg;
		if (!(f in res))
			push(res, f);
	}
	return res;
};

function zapret_localize(args) {
	let own = map([ HOSTLISTS.exclude.pkg, HOSTLISTS.exclude_fs.pkg ], (f) => `--hostlist-exclude=${f}`);
	let excl = map(zapret_exclude_files(), (f) => `--hostlist-exclude=${f}`);
	let out = [];
	for (let a in args)
		if (a in own)
			push(out, ...excl);
		else
			push(out, a);
	return localize(out, zapret_paths());
}

function zapret_parts(special) {
	let cat = read_json(`${ZAPRET_DIR}/catalog.json`, []);
	let pick = (key, family) => {
		let v = opt('main', key, '');
		for (let st in cat)
			if (v != '' && st.family == family && st.name == v)
				return st;
		return null;
	};
	let z = compose({
		main: special ? [] : strategy_lines(opt('main', 'zapret_opts', '')),
		yt: pick('zapret_yt', 'yv'),
		discord: pick('zapret_discord', 'dv'),
		voice: filter(cat, (st) => st.family == 'voice')[0],
		games: pick('zapret_games', 'gv'),
		games_fake: opt('main', 'zapret_games_fake', null),
		discord_fake: opt('main', 'zapret_discord_fake', null),
		tcp_ports: opt('main', 'zapret_tcp_ports', '80,443'),
		udp_ports: opt('main', 'zapret_udp_ports', '443')
	});
	z.args = zapret_localize(z.args);
	return z;
}

export function zapret_ports() {
	let z = zapret_parts();
	let special = zapret_parts(true);
	return { tcp_ports: z.tcp_ports, udp_ports: z.udp_ports,
		special: opt('main', 'default_action', 'direct') == 'direct' && length(special.args) ? { qnum: ZAPRET_QNUM + 1, tcp_ports: special.tcp_ports, udp_ports: special.udp_ports } : null };
};

export function zapret_exclude_domains() {
	let res = {};
	for (let f in zapret_exclude_files())
		for (let d in parse_list(readfile(f) || '').domains)
			res[d] = true;
	return keys(res);
};

export function cmd_zapret_cmd(mode) {
	if (!zapret_used(uci()))
		return 1;
	let special = mode == 'special';
	if (special && opt('main', 'default_action', 'direct') != 'direct')
		return 1;
	let z = zapret_parts(special);
	if (!length(z.args))
		return 1;
	let bin = opt('main', 'zapret_bin', ZAPRET_BIN);
	let missing = missing_files(z.args, (f) => stat(f) != null);
	if (!stat(bin))
		unshift(missing, bin);
	system(`mkdir -p ${shq(RUN_DIR)}`);
	zapret_readable();
	if (length(missing)) {
		writefile(`${RUN_DIR}/zapret-missing.json`, sprintf('%J', missing));
		warn(`nfqws не запущен: нет файлов ${join(', ', missing)}\n`);
		return 1;
	}
	if (!special)
		unlink(`${RUN_DIR}/zapret-missing.json`);
	let args = [ bin, `--qnum=${ZAPRET_QNUM + (special ? 1 : 0)}`, sprintf('--dpi-desync-fwmark=0x%x', NFQWS_DESYNC_MARK), ...z.args ];
	print(join('\n', args), '\n');
	return 0;
};

export function zapret_catalog() {
	return read_json(`${ZAPRET_DIR}/catalog.json`, []);
};

export function cmd_zapret_catalog() {
	let old = zapret_catalog();
	let or_keep = (got, family, label) => {
		if (length(got))
			return got;
		if (label)
			warn(`${label} не получены, оставляю прежние\n`);
		return filter(old, (s) => s.family == family);
	};
	system(`mkdir -p ${shq(ZAPRET_DIR)}/fake`);

	let zms = fetch_any(`${ZMS_RAW}/Zapret-Manager.sh`);
	let v = or_keep(zms_strategies(zms), 'v', 'ZMS: стратегии v');
	let dv = or_keep(zms_discord(zms), 'dv', null);
	let voice = zms_discord_voice(zms);
	let vo = or_keep(voice ? [ voice ] : [], 'voice', null);
	let gv = or_keep(zms_games(zms), 'gv', 'ZMS: игровые наборы');
	let gp = zms_gp_domains(zms);
	let ytt = zms_yt_targets(zms);
	if (length(ytt) >= 3)
		writefile(`${ZAPRET_DIR}/yt-targets.json`, sprintf('%J', ytt));

	let yt_body = fetch_any(`${ZMS_RAW}/files/StrYoutube`);
	let yv = or_keep(block_strategies(yt_body, 'yv'), 'yv', 'ZMS: стратегии YouTube');

	let fs = [];
	let tgz = `/tmp/stella-flowseal.${PROC_TAG}.tgz`, dir = `/tmp/stella-flowseal.${PROC_TAG}`;
	let body = fetch_any(FLOWSEAL_TGZ);
	if (body != null && writefile(tgz, body) &&
	    system(`rm -rf ${shq(dir)} && mkdir -p ${shq(dir)} && tar -xzf ${shq(tgz)} -C ${shq(dir)} 2>/dev/null`) == 0) {
		for (let f in glob(`${dir}/*/bin/*.bin`) || [])
			system(`cp -f ${shq(f)} ${shq(ZAPRET_DIR)}/fake/`);
		for (let f in sort(glob(`${dir}/*/general*.bat`) || [])) {
			let name = replace(replace(f, /^.*\//, ''), /\.bat$/, '');
			let st = flowseal_strategy(readfile(f), name, `${ZAPRET_DIR}/fake`);
			if (st)
				push(fs, st);
		}
	}
	system(`rm -rf ${shq(dir)} ${shq(tgz)}`);
	fs = or_keep(fs, 'fs', 'Flowseal: стратегии');

	for (let name, h in HOSTLISTS) {
		let hbody = fetch_any(h.url);
		let lines = filter(map(split(hbody || '', /\r?\n/), (l) => trim(l)), (l) => l != '' && substr(l, 0, 1) != '#');
		if (length(lines) < 10) {
			warn(`хостлист ${name}: не получен, оставляю прежний\n`);
			continue;
		}
		if (h.zms_extra && length(gp)) {
			let seen = {};
			for (let l in lines) seen[l] = true;
			for (let d in gp)
				if (!seen[d]) {
					seen[d] = true;
					push(lines, d);
				}
		}
		let path = `${ZAPRET_DIR}/hosts-${name}.txt`, data = join('\n', lines) + '\n';
		if (readfile(path) != data)
			writefile(path, data);
	}

	let suite = fetch_any(DPI_SUITE);
	if (suite && type(try_json(suite)) == 'array')
		writefile(`${ZAPRET_DIR}/suite.json`, suite);

	zapret_readable();

	let all = [ ...v, ...yv, ...fs, ...dv, ...vo, ...gv ];
	let data = sprintf('%J', all);
	if (length(all) && readfile(`${ZAPRET_DIR}/catalog.json`) != data)
		writefile(`${ZAPRET_DIR}/catalog.json`, data);
	if (zms != null || yt_body != null || body != null)
		writefile(`${ZAPRET_DIR}/catalog.updated`, `${time()}`);
	else
		return 1;
	printf('Каталог: v %d, YouTube %d, Flowseal %d, Discord %d%s, игры %d\n', length(v), length(yv), length(fs), length(dv),
		length(vo) ? '' : ' (без голоса)', length(gv));
	return length(all) ? 0 : 1;
};

function zt_targets(family) {
	let yt = filter(read_json(`${ZAPRET_DIR}/yt-targets.json`, []), (h) => type(h) == 'string');
	if (family == 'yv')
		return yt;
	let hosts = [], suite = read_json(`${ZAPRET_DIR}/suite.json`, []);
	for (let s in suite)
		for (let p in s?.providers || [])
			if (p?.domain && p.country != 'RU' && !(p.domain in hosts))
				push(hosts, p.domain);
	hosts = slice(hosts, 0, ZT_MAX);
	for (let y in slice(yt, 0, 2))
		if (!(y in hosts))
			push(hosts, y);
	return hosts;
}

function zt_probe(hosts) {
	let cmds = [];
	for (let i, h in hosts) {
		let out = `${RUN_DIR}/zt.${PROC_TAG}.${i}`;
		push(cmds, sprintf("(curl -s -o /dev/null --local-port %s --connect-timeout %d --max-time %d -r 0-65535 -w '%%{size_download}' %s >%s 2>/dev/null; echo \" $?\" >>%s)",
			ZT_PORTS, ZT_CONNECT, ZT_MAX, shq(`https://${h}/`), shq(out), shq(out)));
	}
	run_parallel(cmds, ZT_PARALLEL);
	let ok = [];
	for (let i, h in hosts) {
		let out = `${RUN_DIR}/zt.${PROC_TAG}.${i}`;
		let m = match(readfile(out) || '', /^([0-9]+) +([0-9]+)/);
		unlink(out);
		if (m && (+m[2] == 0 || +m[1] >= 24576))
			push(ok, h);
	}
	return ok;
}

export function zt_nft(on) {
	if (!on)
		return system('nft delete table inet stella_ztest 2>/dev/null');
	let script = join('\n', [
		'table inet stella_ztest',
		'delete table inet stella_ztest',
		'table inet stella_ztest {',
		'	chain out {',
		'		type filter hook output priority mangle; policy accept;',
		sprintf('		meta mark & 0x%x != 0 return', NFQWS_DESYNC_MARK),
		`		tcp sport ${ZT_PORTS} ct original packets 1-9 queue flags bypass to ${ZT_QNUM}`,
		`		udp sport ${ZT_PORTS} ct original packets 1-9 queue flags bypass to ${ZT_QNUM}`,
		'	}',
		'	chain in {',
		'		type filter hook prerouting priority filter; policy accept;',
		`		tcp dport ${ZT_PORTS} ct reply packets 1-3 queue flags bypass to ${ZT_QNUM}`,
		'	}',
		'}', ''
	]);
	let nft = `${RUN_DIR}/ztest.${PROC_TAG}.nft`;
	writefile(nft, script);
	let rc = system(`nft -f ${shq(nft)}`);
	unlink(nft);
	return rc;
};

export function zt_start(bin, args) {
	args = zapret_localize(args);
	let missing = missing_files(args, (f) => stat(f) != null);
	if (length(missing))
		return { error: `нет файлов: ${join(', ', missing)}` };
	let all = [ `--qnum=${ZT_QNUM}`, sprintf('--dpi-desync-fwmark=0x%x', NFQWS_DESYNC_MARK), ...args ];
	let log = `${RUN_DIR}/ztest.${PROC_TAG}.nfqws.log`;
	let pidf = `${RUN_DIR}/ztest.${PROC_TAG}.nfqws.pid`;
	system(`${shq(bin)} ${join(' ', map(all, shq))} >${shq(log)} 2>&1 & echo $! >${shq(pidf)}`);
	let pid = trim(readfile(pidf) || '');
	unlink(pidf);
	let alive = () => pid != '' && system(`kill -0 ${pid} 2>/dev/null`) == 0;
	if (queue_bound(ZT_QNUM) == null)
		sleep(400);
	else
		wait_until(() => !alive() || queue_bound(ZT_QNUM), 2000);
	if (!alive()) {
		let lines = filter(split(trim(readfile(log) || ''), '\n'), (l) => trim(l) != '');
		unlink(log);
		return { error: length(lines) ? `nfqws: ${trim(lines[length(lines) - 1])}` : 'nfqws не запустился' };
	}
	unlink(log);
	return { pid };
};

export function zt_stop(pid) {
	stop_pid(pid, 200, true);
};

function zt_run(bin, args, hosts) {
	let z = zt_start(bin, args);
	if (z.error)
		return z;
	let ok = zt_probe(hosts);
	zt_stop(z.pid);
	return ok;
}

function zapret_apply(st) {
	set_main((st.family == 'yv') ? { zapret_yt: st.name } : { zapret_strategy: st.name, zapret_opts: strategy_text(st) });
}

export function cmd_zapret_test(...argv) {
	let apply = ('--apply' in argv), scheduled = ('--scheduled' in argv);
	let scope = filter(argv, (a) => !(a in [ '--apply', '--scheduled' ]))[0] || 'all';
	let bin = opt('main', 'zapret_bin', ZAPRET_BIN);
	let cur_lines = map(split(opt('main', 'zapret_opts', ''), /\r?\n/), (l) => trim(l));
	let cur_args = filter(cur_lines, (l) => l != '' && substr(l, 0, 1) != '#');
	let first_line = filter(cur_lines, (l) => l != '')[0] || '';
	let cur_name = opt('main', 'zapret_strategy', '') || match(first_line, /^#(.+)$/)?.[1] || '';
	let list = test_list(zapret_catalog(), scope, { name: cur_name, args: cur_args });
	system(`mkdir -p ${shq(RUN_DIR)} ${shq(ZAPRET_DIR)}`);
	let progress = `${RUN_DIR}/ztest.json`;
	writefile(progress, sprintf('%J', { state: 'running', done: 0, total: 0, scope }));
	let fail = (msg) => {
		writefile(progress, sprintf('%J', { state: 'done', done: 0, total: 0, scope, message: msg }));
		warn(msg + '\n');
		return 1;
	};
	if (!length(list))
		return fail('нет стратегий для проверки — обновите каталог');
	if (!stat(bin))
		return fail(`nfqws не найден (${bin}) — установите zapret`);
	zapret_readable();

	let stopf = `${RUN_DIR}/ztest.stop`;
	unlink(stopf);
	let res_path = `${ZAPRET_DIR}/results.json`;
	let res = read_json(res_path, { items: {} });
	res.items ??= {};

	let fams = uniq(map(list, (s) => (s.family == 'yv') ? 'yv' : 'general'));
	for (let fam in fams)
		if (!length(zt_targets(fam)))
			return fail(`нет целей проверки${fam == 'yv' ? ' YouTube' : ''} — обновите каталог`);
	if (zt_nft(true) != 0)
		return fail('nft не принял правила проверки — нужен модуль ядра kmod-nft-queue');

	let baseline = {};
	for (let fam in fams) {
		let hosts = zt_targets(fam);
		baseline[fam] = { ok: length(zt_probe(hosts)), total: length(hosts) };
	}
	res.baseline = { ...(res.baseline || {}), ...baseline };

	let tested = 0;
	for (let i, st in list) {
		if (readfile(stopf) != null)
			break;
		writefile(progress, sprintf('%J', { state: 'running', done: i, total: length(list), current: st.name, scope }));
		let hosts = zt_targets((st.family == 'yv') ? 'yv' : 'general');
		let ok = zt_run(bin, st.args, hosts);
		res.items[st.name] = (type(ok) == 'array')
			? { family: st.family, ok: length(ok), total: length(hosts), at: time() }
			: { family: st.family, ok: -1, total: length(hosts), at: time(), error: ok.error };
		tested++;
	}
	zt_nft(false);
	let known = {};
	for (let st in zapret_catalog())
		known[st.name] = true;
	for (let name, r in res.items)
		if (!known[name] && r?.family != 'current')
			delete res.items[name];
	res.at = time();
	writefile(res_path, sprintf('%J', res));

	let stopped = readfile(stopf) != null;
	let msg = stopped ? 'Проверка остановлена' : 'Проверка закончена';
	if (apply && !stopped) {
		let msgs = [], yt_cur = opt('main', 'zapret_yt', '');
		for (let yt in [ false, true ]) {
			let on = yt ? yt_cur != '' : length(cur_args) > 0;
			if (scheduled && !on)
				continue;
			let best = null;
			for (let st in list)
				if (st.family != 'current' && (st.family == 'yv') == yt && res.items[st.name]?.ok >= 0 &&
				    (!best || res.items[st.name].ok > res.items[best.name].ok))
					best = st;
			if (!best)
				continue;
			let cur = on ? (res.items[yt ? yt_cur : (cur_name || 'текущая')]?.ok ?? -1) : -1;
			let base = res.baseline?.[yt ? 'yv' : 'general']?.ok ?? -1;
			let got = res.items[best.name];
			if (got.ok > max(cur, base)) {
				zapret_apply(best);
				push(msgs, sprintf('%s: %s (%d из %d)', yt ? 'YouTube' : 'основная', best.name, got.ok, got.total));
			}
		}
		msg = length(msgs) ? 'Применена ' + join(', ', msgs) : 'Текущие стратегии не хуже лучших из проверенных — оставлены';
	}
	writefile(progress, sprintf('%J', { state: stopped ? 'stopped' : 'done', done: tested, total: length(list), scope, message: msg }));
	unlink(stopf);
	print(msg, '\n');
	return 0;
};

export function cmd_zapret_apply(name) {
	for (let st in zapret_catalog())
		if (st.name == name) {
			zapret_apply(st);
			return 0;
		}
	warn(`стратегия «${name}» не найдена в каталоге\n`);
	return 1;
};
