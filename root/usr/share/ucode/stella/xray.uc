// Генерация конфигурации xray-core (ориентир — 26.3.x) из нормализованных узлов.

'use strict';

import { SOCKS_PORT, PROBE_URL } from 'stella.store';
import { quic_noise } from 'stella.warp';

const NET_NAMES = {
	raw: 'raw', xhttp: 'xhttp', ws: 'websocket', httpupgrade: 'httpupgrade',
	grpc: 'grpc', hysteria: 'hysteria'
};

const PRIVATE_NETS = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4'
];

// Сколько ждать сервер цепочки, прежде чем спросить следующий. Устройства ждут ответа около 5 с,
// а xray спрашивает серверы по очереди: при упавших DoH-серверах до DNS провайдера надо дойти
// раньше. Прямой DoH отвечает за 0,1–0,6 с вместе с подключением.
const DNS_TIMEOUT_MS = 1500;
// Истёкшую запись xray отдаёт сразу (с TTL 1) и обновляет её в фоне, но не дольше суток после
// срока: при упавшем туннеле знакомые имена отвечают без ожидания.
const DNS_STALE_TTL = 86400;

function compact(o) {
	for (let k in o)
		if (o[k] == null)
			delete o[k];
	return o;
}

function tls_settings(n) {
	return compact({
		serverName: n.sni,
		fingerprint: n.fp,
		alpn: n.alpn,
		echConfigList: n.ech,
		pinnedPeerCertSha256: n.pcs,
		verifyPeerCertByName: n.vcn
	});
}

function reality_settings(n) {
	return compact({
		serverName: n.sni,
		fingerprint: n.fp,
		publicKey: n.pbk,
		shortId: n.sid,
		spiderX: n.spx,
		mldsa65Verify: n.pqv
	});
}

function stream_settings(n) {
	let ss = { network: NET_NAMES[n.network], security: n.security };

	switch (n.network) {
	case 'raw':
		if (n.header_type == 'http')
			ss.rawSettings = {
				header: {
					type: 'http',
					request: compact({
						path: n.path ? split(n.path, ',') : null,
						headers: n.host ? { Host: split(n.host, ',') } : null
					})
				}
			};
		break;

	case 'xhttp':
		ss.xhttpSettings = compact({ host: n.host, path: n.path, mode: n.mode, extra: n.extra });
		break;

	case 'ws':
		ss.wsSettings = compact({ host: n.host, path: n.path });
		break;

	case 'httpupgrade':
		ss.httpupgradeSettings = compact({ host: n.host, path: n.path });
		break;

	case 'grpc':
		ss.grpcSettings = compact({
			serviceName: n.service_name,
			authority: n.authority,
			multiMode: (n.mode == 'multi') || null
		});
		break;

	case 'hysteria':
		ss.hysteriaSettings = { version: 2, auth: n.auth };
		break;
	}

	if (n.security == 'tls') {
		ss.tlsSettings = tls_settings(n);
		if (n.network == 'hysteria' && !ss.tlsSettings.alpn)
			ss.tlsSettings.alpn = ['h3'];
	}
	else if (n.security == 'reality')
		ss.realitySettings = reality_settings(n);

	let fm = n.fm ? { ...n.fm } : {};
	if (n.obfs == 'salamander')
		fm.udp = [ ...(fm.udp || []), { type: 'salamander', settings: { password: n.obfs_password } } ];
	if (n.ports)
		fm.quicParams = { ...(fm.quicParams || {}), udpHop: { ports: n.ports } };
	if (length(fm))
		ss.finalmask = fm;

	return ss;
}

export function outbound(n, tag) {
	let ob = { tag, protocol: n.protocol };

	switch (n.protocol) {
	case 'vless':
		ob.settings = { vnext: [{
			address: n.address, port: n.port,
			users: [ compact({ id: n.uuid, encryption: n.encryption, flow: n.flow }) ]
		}] };
		break;

	case 'vmess':
		ob.settings = { vnext: [{
			address: n.address, port: n.port,
			users: [{ id: n.uuid, security: n.encryption }]
		}] };
		break;

	case 'trojan':
		ob.settings = { servers: [{ address: n.address, port: n.port, password: n.password }] };
		break;

	case 'shadowsocks':
		ob.settings = { servers: [{
			address: n.address, port: n.port, method: n.method, password: n.password
		}] };
		break;

	case 'hysteria':
		ob.settings = { version: 2, address: n.address, port: n.port };
		break;

	case 'wireguard':
		ob.settings = compact({
			secretKey: n.secret_key,
			address: n.ifaddr,
			peers: [ compact({
				publicKey: n.public_key,
				preSharedKey: n.psk,
				endpoint: (index(n.address, ':') >= 0) ? `[${n.address}]:${n.port}` : `${n.address}:${n.port}`,
				keepAlive: n.keepalive,
				allowedIPs: [ '0.0.0.0/0', '::/0' ]
			}) ],
			mtu: n.mtu || 1280,
			reserved: n.reserved,
			// Иначе xray от root поднимет в системе свой интерфейс с маршрутами и правилами.
			noKernelTun: true
		});
		break;

	default:
		die(`unsupported protocol ${n.protocol}`);
	}

	// У WireGuard транспорта нет — только маски пакетов (finalmask), маска QUIC — первой.
	// Домен сайта WireGuard не передаёт серверу, а разрешает здесь — targetStrategy: через DNS
	// xray (цепочку DNS), сначала IPv6. Без него xray шёл мимо цепочки на настоящий адрес сайта, и
	// ChatGPT через WARP (выход в России) отвечал 403. Серверы обхода геоблокировок для таких
	// сайтов дают только IPv4 (адрес своего прокси) — он и берётся. Остальное — по IPv6: через
	// WARP по IPv4 YouTube не открывается.
	if (n.protocol == 'wireguard') {
		ob.targetStrategy = 'ForceIPv6v4';
		let fm = n.fm ? { ...n.fm } : {};
		// Маски — из данных WARP; их ещё нет — без маски, до первого скачивания.
		let q = (n.noise == 'quic') ? quic_noise(n) : null;
		if (q)
			fm.udp = [ q, ...(fm.udp || []) ];
		if (length(fm))
			ob.streamSettings = { finalmask: fm };
	}
	else if (n.protocol != 'shadowsocks')
		ob.streamSettings = stream_settings(n);

	return ob;
};

// opts: { node, auto_nodes, log_level, socks_port,
//         intercept, tproxy_port, dns_port, dns_servers, dns_hosts, dns_last (или dns_isp) }
//
// node — выбранный вручную узел (outbound "proxy"). auto_nodes — узлы автовыбора:
// каждый получает outbound "proxy-N", xray раз в минуту проверяет их и ведёт трафик через
// самый быстрый живой (balancer leastPing); если не отвечает ни один — через node.
//
// intercept = прозрачный прокси для LAN: вход TPROXY и DNS для dnsmasq.
// DNS — напрямую, цепочкой: DoH-серверы dns_servers по порядку, за ними запасные dns_last (DoH
// или обычный UDP; по умолчанию — DNS провайдера). Имена DoH-серверов xray берёт из dns_hosts (их адреса узнаёт
// Stella): иначе он спросил бы их у dnsmasq, а тот — у самого xray.
export function build_config(opts) {
	let auto = (length(opts.auto_nodes || []) >= 2) ? opts.auto_nodes : null;
	let has_proxy = !!(opts.node || auto);
	let to_main = auto ? { balancerTag: 'auto' } : { outboundTag: has_proxy ? 'proxy' : 'direct' };
	let outbounds = [];

	// Адреса прокси-серверов xray узнаёт своим DNS — он и так напрямую.
	let add_proxy = (n, tag) => {
		let ob = outbound(n, tag);
		if (opts.intercept)
			ob.streamSettings = { ...(ob.streamSettings || {}), sockopt: { domainStrategy: 'UseIPv4' } };
		push(outbounds, ob);
	};

	if (opts.node)
		add_proxy(opts.node, 'proxy');
	for (let i, n in auto || [])
		add_proxy(n, `proxy-${i}`);
	// Автовыбор без ручного узла: запасным становится первый из отмеченных.
	let fallback = opts.node ? 'proxy' : (auto ? 'proxy-0' : null);

	push(outbounds,
		{ tag: 'direct', protocol: 'freedom' },
		{ tag: 'block', protocol: 'blackhole' });

	let inbounds = [{
		tag: 'socks-in',
		listen: '127.0.0.1',
		port: opts.socks_port || SOCKS_PORT,
		protocol: 'socks',
		settings: { udp: true },
		sniffing: { enabled: true, destOverride: ['http', 'tls', 'quic'], routeOnly: true }
	}];

	let rules = [];
	// Журнал подключений (строка на каждое соединение) — только при подробном логе: на слабом
	// роутере он заметно ест процессор и вытесняет из лога всё остальное.
	let level = opts.log_level || 'warning';
	let cfg = { log: { loglevel: level, access: (level in [ 'info', 'debug' ]) ? '' : 'none' } };

	if (opts.intercept) {
		push(inbounds, {
			tag: 'tproxy-in',
			listen: '127.0.0.1',
			port: opts.tproxy_port,
			protocol: 'dokodemo-door',
			settings: { network: 'tcp,udp', followRedirect: true },
			streamSettings: { sockopt: { tproxy: 'tproxy' } },
			// Домен из трафика подменяет IP назначения: ответы DNS провайдера не важны.
			sniffing: { enabled: true, destOverride: ['http', 'tls', 'quic'] }
		}, {
			tag: 'dns-in',
			listen: '127.0.0.1',
			port: opts.dns_port,
			protocol: 'dokodemo-door',
			settings: { address: '1.1.1.1', port: 53, network: 'tcp,udp' }
		});
		// Сам xray спрашивает и IPv6 — для WARP; устройствам, пока IPv6 закрыт, AAAA не отдаёт dnsmasq.
		push(outbounds, { tag: 'dns-out', protocol: 'dns' });

		// Свой выход для DNS: имя DoH-сервера он узнаёт у встроенного DNS xray, то есть из hosts.
		push(outbounds, { tag: 'direct-dns', protocol: 'freedom', streamSettings: { sockopt: { domainStrategy: 'UseIPv4' } } });
		let servers = [];
		for (let url in opts.dns_servers || [])
			push(servers, { address: url, timeoutMs: DNS_TIMEOUT_MS });
		// Запасные по порядку: DoH или обычный DNS (IPv4, UDP 53); без них — DNS провайдера.
		for (let x in opts.dns_last ?? opts.dns_isp ?? [])
			push(servers, match(x, /^[0-9.]+$/) ? { address: x, port: 53 } : { address: x, timeoutMs: DNS_TIMEOUT_MS });

		cfg.dns = { tag: 'dns-direct', queryStrategy: 'UseIP', serveStale: true, serveExpiredTTL: DNS_STALE_TTL, servers };
		if (length(opts.dns_hosts || {}))
			cfg.dns.hosts = opts.dns_hosts;

		push(rules, { inboundTag: ['dns-in'], outboundTag: 'dns-out' });
		push(rules, { inboundTag: ['dns-direct'], outboundTag: 'direct-dns' });
	}

	push(rules,
		{ ip: PRIVATE_NETS, outboundTag: 'direct' },
		{ network: 'tcp,udp', ...to_main });

	cfg.inbounds = inbounds;
	cfg.outbounds = outbounds;
	cfg.routing = { domainStrategy: 'AsIs', rules };

	if (auto) {
		cfg.routing.balancers = [ { tag: 'auto', selector: [ 'proxy-' ], strategy: { type: 'leastPing' }, fallbackTag: fallback } ];
		cfg.observatory = {
			subjectSelector: [ 'proxy-' ],
			probeURL: PROBE_URL,
			probeInterval: '60s',
			enableConcurrency: true
		};
	}
	return cfg;
};
