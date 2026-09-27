// Генерация конфигурации xray-core (ориентир — 26.3.x) из нормализованных узлов.

'use strict';

const NET_NAMES = {
	raw: 'raw', xhttp: 'xhttp', ws: 'websocket', httpupgrade: 'httpupgrade',
	grpc: 'grpc', hysteria: 'hysteria'
};

const PRIVATE_NETS = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4'
];

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

	default:
		die(`unsupported protocol ${n.protocol}`);
	}

	if (n.protocol != 'shadowsocks')
		ob.streamSettings = stream_settings(n);

	return ob;
};

function is_ipv4(s) {
	return match(s, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null;
}

// IP из адреса DNS-сервера: "https://77.88.8.8/dns-query", "tcp://1.1.1.1:53", "8.8.8.8".
export function dns_server_ip(addr) {
	let m = match(addr || '', /^([a-z+]+:\/\/)?([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
	return m ? m[2] : null;
};

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
		port: opts.socks_port || 10808,
		protocol: 'socks',
		settings: { udp: true },
		sniffing: { enabled: true, destOverride: ['http', 'tls', 'quic'], routeOnly: true }
	}];

	let rules = [];
	let cfg = { log: { loglevel: opts.log_level || 'warning' } };

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

		let servers = [];
		let direct_ip = dns_server_ip(opts.dns_direct);
		if (length(servers_of))
			push(servers, { address: opts.dns_direct, domains: servers_of, skipFallback: true });
		push(servers, opts.dns_remote);
		if (has_proxy && opts.dns_direct != opts.dns_remote)
			push(servers, opts.dns_direct);

		cfg.dns = { tag: 'dns-internal', queryStrategy: 'UseIPv4', servers };

		push(rules, { inboundTag: ['dns-in'], outboundTag: 'dns-out' });
		if (direct_ip)
			push(rules, { inboundTag: ['dns-internal'], ip: [ direct_ip ], outboundTag: 'direct' });
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
