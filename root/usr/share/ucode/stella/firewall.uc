// Правила nftables (только IPv4) и конфиг dnsmasq для маршрутизации по спискам.
// Своя таблица inet stella: fw4 её не трогает, снимается одной командой.
//
// Путь пакета от устройства LAN (prerouting, mangle):
//   локальные адреса → мимо; DNS (при перехвате) → мимо, его заберёт nat-цепочка;
//   устройство «всё через VPN / напрямую» → сразу act_vpn / act_direct;
//   остальные → pol_global: первый совпавший список (сет с IP, наполняемый dnsmasq;
//   список может действовать только для части устройств) решает действие:
//   act_vpn (TPROXY в xray), act_zapret (метка соединения → очередь nfqws на выходе),
//   act_direct, act_block; не совпал ни один — действие по умолчанию.
//   Работает резервный канал с «всё через VPN» — только блок-списки, остальное в act_vpn.

'use strict';

export const FW_MARK = 0x00100000;
export const ZAPRET_MARK = 0x00200000;
export const ROUTE_TABLE = 1127;
export const NFQWS_DESYNC_MARK = 0x40000000;

const BYPASS4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4'
];

const ACTIONS = { vpn: true, zapret: true, direct: true, block: true };

// Публичные DoH-резолверы (Cloudflare, Google, Quad9, AdGuard, OpenDNS, Яндекс).
const DOH4 = [
	'1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4', '9.9.9.9', '149.112.112.112',
	'94.140.14.14', '94.140.15.15', '208.67.222.222', '208.67.220.220', '77.88.8.8', '77.88.8.1',
	'104.16.248.249', '104.16.249.249', '162.159.61.4', '172.64.41.4'
];

function hex(v) {
	return sprintf('0x%08x', v);
}

function ports(s) {
	s = replace(s || '', / /g, '');
	return match(s, /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) ? replace(s, /,/g, ', ') : null;
}

function macs(l) {
	return `{ ${join(', ', l.macs)} }`;
}

// Условие на устройства списка, действующего только для части устройств.
function scope(l) {
	return (l.devices_mode == 'only') ? `ether saddr ${macs(l)} ` :
		(l.devices_mode == 'except') ? `ether saddr != ${macs(l)} ` : '';
}
// opts: { lan_ifnames, tproxy_port, default_action, dns_hijack, block_doh,
//         lists:   [ { id, action, cidrs, devices_mode, macs } ]   — включённые, по порядку,
//         devices: [ { mac, policy } ]                               — vpn/direct в обход списков,
//         zapret:  { qnum, tcp_ports, udp_ports } | null,
//         all_vpn: работает резервный канал, и на нём всё через VPN }
export function nft_script(opts) {
	let ifs = join(', ', map(opts.lan_ifnames, (i) => sprintf('%J', i)));
	let out = [
		'table inet stella',
		'delete table inet stella',
		'table inet stella {',
		'	set bypass4 {',
		'		type ipv4_addr',
		'		flags interval',
		'		auto-merge',
		`		elements = { ${join(', ', BYPASS4)} }`,
		'	}'
	];

	if (opts.zapret)
		push(out, '', '	set zapret_excl {', '		type ipv4_addr', '		flags interval', '		auto-merge', '	}');

	for (let l in opts.lists || []) {
		push(out, '', `	set ${l.id} {`, '		type ipv4_addr', '		flags interval', '		auto-merge');
		if (length(l.cidrs))
			push(out, `		elements = { ${join(', ', l.cidrs)} }`);
		push(out, '	}');
	}

	push(out, '',
		'	chain prerouting {',
		'		type filter hook prerouting priority mangle; policy accept;',
		`		iifname != { ${ifs} } return`,
		'		meta nfproto != ipv4 return',
		'		ip daddr @bypass4 return');
	if (opts.dns_hijack) {
		push(out, '		meta l4proto { tcp, udp } th dport 53 return');
		// Сторонний DNS-over-TLS/HTTPS в обход роутера: без этого списки доменов
		// не видят, какие адреса узнало устройство. Браузеры откатываются на обычный DNS.
		if (opts.block_doh)
			push(out,
				'		meta l4proto { tcp, udp } th dport 853 drop',
				`		ip daddr { ${join(', ', DOH4)} } meta l4proto { tcp, udp } th dport 443 drop`);
	}
	if (opts.all_vpn) {
		// Резервный канал (например, мобильный с белыми списками): напрямую там мало что
		// открывается — всё через VPN, списки и устройства не действуют, кроме блокировки.
		for (let l in opts.lists || [])
			if (l.action == 'block')
				push(out, `		${scope(l)}ip daddr @${l.id} goto act_block`);
		push(out, '		goto act_vpn', '	}');
	}
	else {
		for (let p in [ 'vpn', 'direct' ]) {
			let m = map(filter(opts.devices || [], (d) => d.policy == p), (d) => d.mac);
			if (length(m))
				push(out, `		ether saddr { ${join(', ', m)} } goto act_${p}`);
		}
		push(out, '		goto pol_global', '	}');
	}

	push(out, '', '	chain pol_global {');
	for (let l in opts.lists || []) {
		if (!ACTIONS[l.action])
			continue;
		push(out, `		${scope(l)}ip daddr @${l.id} goto act_${l.action}`);
	}
	push(out, `		goto act_${(opts.default_action in [ 'vpn', 'zapret' ]) ? opts.default_action : 'direct'}`, '	}');

	push(out, '',
		'	chain act_vpn {',
		`		meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${opts.tproxy_port} meta mark set ${hex(FW_MARK)} accept`,
		'		accept',
		'	}',
		'',
		'	chain act_direct {',
		'		accept',
		'	}',
		'',
		'	chain act_block {',
		'		drop',
		'	}',
		'',
		'	chain act_zapret {',
		// Исключения Zapret (российские сайты и сервисы, которые ломаются от обхода) —
		// всегда напрямую, без искажений; сет наполняет dnsmasq.
		...(opts.zapret ? [ '		ip daddr @zapret_excl accept' ] : []),
		`		ct mark set ct mark | ${hex(ZAPRET_MARK)} accept`,
		'	}');

	if (opts.dns_hijack)
		push(out, '',
			'	chain dns_hijack {',
			'		type nat hook prerouting priority dstnat - 5; policy accept;',
			`		iifname != { ${ifs} } return`,
			'		meta nfproto != ipv4 return',
			'		fib daddr type local return',
			'		meta l4proto { tcp, udp } th dport 53 redirect to :53',
			'	}');

	let z = opts.zapret;
	if (z) {
		let tcp = ports(z.tcp_ports), udp = ports(z.udp_ports);
		let guard = [
			`		ct mark & ${hex(ZAPRET_MARK)} == 0 return`,
			`		meta mark & ${hex(NFQWS_DESYNC_MARK)} != 0 return`
		];
		push(out, '',
			'	chain zapret_out {',
			'		type filter hook postrouting priority srcnat - 2; policy accept;',
			...guard);
		if (tcp)
			push(out, `		tcp dport { ${tcp} } ct original packets 1-9 queue flags bypass to ${z.qnum}`);
		if (udp)
			push(out, `		udp dport { ${udp} } ct original packets 1-9 queue flags bypass to ${z.qnum}`);
		push(out, '	}');

		// Ответы сервера (SYN-ACK) нужны nfqws для autottl и подобных приёмов.
		if (tcp)
			push(out, '',
				'	chain zapret_in {',
				'		type filter hook prerouting priority filter; policy accept;',
				...guard,
				`		tcp sport { ${tcp} } ct reply packets 1-3 queue flags bypass to ${z.qnum}`,
				'	}');
	}

	push(out, '}', '');
	return join('\n', out);
};

// Команды, возвращающие в пересозданные сеты адреса, которые туда уже положил dnsmasq.
// saved — { сет: [IP] } из прежней таблицы; prev и cur — { сет: [домены и подсети] } при
// прошлом и нынешнем включении. Если из списка что-то убрали, его адреса не возвращаются:
// по ним не понять, чей это IP, а убранный сайт шёл бы по правилу списка до перезагрузки.
// Сет снова наполнится, как только устройства переспросят DNS.
export function restore_script(saved, prev, cur) {
	let out = [];
	for (let id, entries in cur) {
		if (!length(saved[id]))
			continue;
		let now = {};
		for (let e in entries)
			now[e] = true;
		if (length(filter(prev[id] || [], (e) => !now[e])))
			continue;
		push(out, `add element inet stella ${id} { ${join(', ', saved[id])} }`);
	}
	return out;
};

// dnsmasq: DNS только через xray; IP доменов из списков — в сеты nftables.
// Домен из нескольких списков получает все их сеты одной строкой.
export function dnsmasq_conf(opts) {
	let sets = {}, order = [];
	for (let l in opts.lists || [])
		for (let d in l.domains || []) {
			if (!sets[d]) {
				sets[d] = [];
				push(order, d);
			}
			push(sets[d], `4#inet#stella#${l.id}`);
		}

	// max-ttl: устройства переспрашивают не реже раза в минуту — новый список начинает
	// действовать через минуту, а не когда истечёт TTL сайта. Кэш dnsmasq держит настоящий TTL.
	let out = [ 'no-resolv', `server=127.0.0.1#${opts.dns_port}`, 'max-ttl=60' ];
	// «Канарейки»: по NXDOMAIN Firefox отключает свой DoH, Apple — iCloud Private Relay.
	if (opts.block_doh)
		push(out, 'address=/use-application-dns.net/', 'address=/mask.icloud.com/', 'address=/mask-h2.icloud.com/');
	for (let d in order)
		push(out, `nftset=/${d}/${join(',', sets[d])}`);
	push(out, '');
	return join('\n', out);
};
