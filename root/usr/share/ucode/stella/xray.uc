// Генерация конфигурации xray-core (ориентир — 26.3.x) из нормализованных узлов.

'use strict';

import { SOCKS_PORT } from 'stella.store';
import { quic_noise } from 'stella.warp';

const NET_NAMES = {
	raw: 'raw', xhttp: 'xhttp', ws: 'websocket', httpupgrade: 'httpupgrade',
	grpc: 'grpc', hysteria: 'hysteria'
};

const PRIVATE_NETS = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4'
];

// Сколько ждать DNS через VPN, прежде чем спросить запасной напрямую. У xray по умолчанию 4 с:
// при упавшем туннеле так ждал каждый запрос, и клиенты успевали сдаться. Меньше 3 с нельзя:
// первый запрос через медленный узел (подключение к серверу и TLS до DNS) идёт около 1,5 с.
const DNS_REMOTE_TIMEOUT_MS = 3000;
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
	if (n.protocol == 'wireguard') {
		let fm = n.fm ? { ...n.fm } : {};
		if (n.noise == 'quic')
			fm.udp = [ quic_noise(n), ...(fm.udp || []) ];
		if (length(fm))
			ob.streamSettings = { finalmask: fm };
	}
	else if (n.protocol != 'shadowsocks')
		ob.streamSettings = stream_settings(n);

	return ob;
};

function is_ipv4(s) {
	return match(s, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null;
}

// opts: { node, auto_nodes, log_level, socks_port,
//         intercept, tproxy_port, dns_port, dns_remote, dns_direct }
//
// node — выбранный вручную узел (outbound "proxy"). auto_nodes — узлы автовыбора:
// каждый получает outbound "proxy-N", xray раз в минуту проверяет их и ведёт трафик через
// самый быстрый живой (balancer leastPing); если не отвечает ни один — через node.
//
// intercept = прозрачный прокси для LAN: вход TPROXY и DNS для dnsmasq.
// DNS-запросы клиентов идут через туннель (dns_remote), при его отказе — напрямую
// (dns_direct, запасной); адреса самих прокси-серверов резолвятся напрямую — иначе
// для подключения к серверу нужен сервер.
export function build_config(opts) {
	let auto = (length(opts.auto_nodes || []) >= 2) ? opts.auto_nodes : null;
	let has_proxy = !!(opts.node || auto);
	let to_main = auto ? { balancerTag: 'auto' } : { outboundTag: has_proxy ? 'proxy' : 'direct' };
	let outbounds = [];
	let servers_of = [];

	let add_proxy = (n, tag) => {
		let ob = outbound(n, tag);
		if (opts.intercept)
			ob.streamSettings = { ...(ob.streamSettings || {}), sockopt: { domainStrategy: 'UseIPv4' } };
		push(outbounds, ob);
		if (!is_ipv4(n.address) && !(`full:${n.address}` in servers_of))
			push(servers_of, `full:${n.address}`);
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
		push(outbounds, { tag: 'dns-out', protocol: 'dns' });

		// Запросы к прямому DNS помечены своим тегом и идут напрямую по нему, а не по IP:
		// иначе при одном IP у обоих DNS (например, 1.1.1.1 в обоих полях) мимо VPN уходили бы
		// и запросы устройств.
		let servers = [];
		if (length(servers_of))
			push(servers, { address: opts.dns_direct, domains: servers_of, skipFallback: true, tag: 'dns-direct' });
		// Запасной нужен и при том же сервере: через VPN и напрямую — разные пути, при упавшем
		// туннеле тот же сервер ответит напрямую.
		push(servers, has_proxy ? { address: opts.dns_remote, timeoutMs: DNS_REMOTE_TIMEOUT_MS } : opts.dns_remote);
		if (has_proxy)
			push(servers, { address: opts.dns_direct, tag: 'dns-direct' });

		cfg.dns = { tag: 'dns-internal', queryStrategy: 'UseIPv4', serveStale: true, serveExpiredTTL: DNS_STALE_TTL, servers };

		push(rules, { inboundTag: ['dns-in'], outboundTag: 'dns-out' });
		push(rules, { inboundTag: ['dns-direct'], outboundTag: 'direct' });
		push(rules, { inboundTag: ['dns-internal'], ...to_main });
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
			probeURL: 'https://www.gstatic.com/generate_204',
			probeInterval: '60s',
			enableConcurrency: true
		};
	}
	return cfg;
};
