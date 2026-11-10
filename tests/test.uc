// Тесты разбора ссылок и генерации конфига.
// Каждый успешно разобранный узел прогоняется через `xray run -test`.

'use strict';

import { writefile, unlink, readfile } from 'fs';
import { parse } from 'stella.uri';
import { decode } from 'stella.subscription';
import { build_config } from 'stella.xray';
import { stab_entry, stab_better, best_node, read_json } from 'stella.store';
import { parse_list, itdog_catalog } from 'stella.lists';
import { doh_catalog, dns_query, dns_answer, resolv_servers, doh_url } from 'stella.dns';
import { parse_srs } from 'stella.srs';
import { warp_link, random_endpoints, iso_time, trace_info, warp_better, warp_data_parse, warp_data_reset, WARP_DATA } from 'stella.warp';
import { nft_script, dnsmasq_conf, restore_script } from 'stella.firewall';
import { flowseal_strategy, zms_strategies, block_strategies, compose, merge_ports, zms_discord, zms_discord_voice, zms_games, zms_gp_domains, zms_yt_targets, localize, missing_files, test_list } from 'stella.zapret';

const UUID = '48b4e5f1-00ed-4c06-aa7d-e8890e1dcc5d';
const PBK = 'VaUOAQYUQAmBLwQ0NproXnB1vR_YNA9e3Pa9ghS72BY';
const PCS = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
// Ключи WireGuard: секретный — от `xray wg`, публичный — сервера WARP.
const WGK = 'iAUkyvpedMvtQtwPEbJGkWIwC2eVUKlCHiLB/z2S+2I=';
const WARP_PK = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';
const TMP = getenv('TMPDIR') || '/tmp';

// Данные WARP — из выдержек файлов генератора, как их сохраняет stella warp-data.
const WD = warp_data_parse(readfile('tests/fixtures/warp-endpoint-pool.ts'), readfile('tests/fixtures/warp-shared.ts'),
	readfile('tests/fixtures/warp-cloudflare-client.ts'));
writefile(WARP_DATA, sprintf('%J', WD));
warp_data_reset();
const XRAY = getenv('XRAY') || 'xray';

let vmess_json = b64enc(sprintf('%J', {
	v: '2', ps: 'vmess ws', add: 'vm.example.com', port: '443', id: UUID, aid: '0',
	scy: 'auto', net: 'ws', type: 'none', host: 'cdn.example.com', path: '/ws', tls: 'tls', sni: 'cdn.example.com'
}));

const CASES = [
	{
		link: `vless://${UUID}@1.2.3.4:443?type=tcp&security=reality&pbk=${PBK}&sid=abcd&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#Vision%20Reality`,
		expect: { name: 'Vision Reality', protocol: 'vless', network: 'raw', security: 'reality', flow: 'xtls-rprx-vision', sni: 'www.microsoft.com', sid: 'abcd' }
	},
	{
		link: `vless://${UUID}@srv.example.com:443?type=xhttp&security=reality&pbk=${PBK}&sid=&sni=yahoo.com&fp=firefox&path=%2Fxh&mode=stream-one&extra=${replace(sprintf('%J', { xPaddingBytes: '100-1000', noGRPCHeader: false }), /[{}":, ]/g, (c) => sprintf('%%%02X', ord(c)))}#XHTTP`,
		expect: { network: 'xhttp', security: 'reality', mode: 'stream-one', path: '/xh', fp: 'firefox' }
	},
	{
		link: `vless://${UUID}@srv.example.com:443?type=xhttp&security=tls&sni=srv.example.com&alpn=h2,http/1.1&host=srv.example.com&path=/x#XHTTP TLS`,
		expect: { network: 'xhttp', security: 'tls', mode: 'auto', alpn: ['h2', 'http/1.1'] }
	},
	{
		link: `vless://${UUID}@srv.example.com:443?type=grpc&security=tls&serviceName=svc&mode=multi&sni=srv.example.com#grpc`,
		expect: { network: 'grpc', service_name: 'svc', mode: 'multi' }
	},
	{
		link: `vless://${UUID}@srv.example.com:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048&host=srv.example.com&allowInsecure=1#ws`,
		expect: { network: 'ws', path: '/ws?ed=2048', warnings: 1 }
	},
	{
		link: `vless://${UUID}@srv.example.com:443?type=httpupgrade&security=tls&pcs=${PCS}#hu`,
		expect: { network: 'httpupgrade', pcs: PCS }
	},
	{
		link: `vmess://${vmess_json}`,
		expect: { name: 'vmess ws', protocol: 'vmess', network: 'ws', security: 'tls', host: 'cdn.example.com', path: '/ws' }
	},
	{
		link: `trojan://p%40ss@tr.example.com:443?sni=tr.example.com#trojan`,
		expect: { protocol: 'trojan', password: 'p@ss', security: 'tls', network: 'raw' }
	},
	{
		link: `ss://${b64enc('chacha20-ietf-poly1305:secret')}@5.6.7.8:8388#ss%20old`,
		expect: { protocol: 'shadowsocks', method: 'chacha20-ietf-poly1305', password: 'secret', name: 'ss old' }
	},
	{
		link: `ss://2022-blake3-aes-128-gcm:${replace(b64enc('0123456789abcdef'), /=/g, '%3D')}@5.6.7.8:8388#ss2022`,
		expect: { method: '2022-blake3-aes-128-gcm', password: b64enc('0123456789abcdef') }
	},
	{
		link: `ss://${b64enc('aes-256-gcm:pw@9.9.9.9:443')}#legacy`,
		expect: { address: '9.9.9.9', port: 443, method: 'aes-256-gcm', password: 'pw', name: 'legacy' }
	},
	{
		link: `hysteria2://letmein@hy.example.com:443/?sni=hy.example.com&obfs=salamander&obfs-password=ob&pinSHA256=${PCS}#hy2`,
		expect: { protocol: 'hysteria', auth: 'letmein', obfs: 'salamander', obfs_password: 'ob', pcs: PCS }
	},
	{
		link: `hy2://pass@hy.example.com:20000-30000/?insecure=1#hop`,
		expect: { port: 20000, ports: '20000-30000', warnings: 1 }
	},
	{ link: `vless://${UUID}@srv.example.com:443?type=ws&security=reality&pbk=${PBK}`, error: true },
	{ link: `vless://${UUID}@srv.example.com:443?type=ws&security=tls&flow=xtls-rprx-vision`, error: true },
	{ link: `ss://${b64enc('rc4-md5:x')}@1.1.1.1:1`, error: true },
	{ link: `ss://${b64enc('aes-256-gcm:x')}@1.1.1.1:1?plugin=obfs-local`, error: true },
	{ link: `wireguard://x@1.1.1.1:51820`, error: true },
	{ link: `vless://${UUID}@srv.example.com:99999?security=tls`, error: true },
	// Обычный (не url-safe) base64 в userinfo: в нём «/».
	{
		link: `ss://${b64enc('aes-256-gcm:a???b')}@1.2.3.4:8388#slash`,
		expect: { method: 'aes-256-gcm', password: 'a???b', address: '1.2.3.4', port: 8388 }
	},
	// Битый JSON в параметре — предупреждение, а не ошибка всего узла.
	{
		link: `vless://${UUID}@srv.example.com:443?type=xhttp&security=tls&extra=notjson&fm=%7Bbad#bad json`,
		expect: { network: 'xhttp', extra: null, warnings: 2 }
	},
	{ link: `vmess://${b64enc('not json')}`, error: true },
	{ link: `hysteria2://pw@hy.example.com:-1#bad port`, error: true },
	// WARP, как его создаёт Stella: ключи и адреса закодированы, маска QUIC.
	{
		link: warp_link({ secret_key: WGK, v4: '172.16.0.2', v6: '2606:4700:110:8a36::1', reserved: [ 1, 2, 3 ], endpoint: '162.159.192.1:2408', name: 'Мой WARP' }),
		expect: { name: 'Мой WARP', protocol: 'wireguard', address: '162.159.192.1', port: 2408, secret_key: WGK, public_key: WARP_PK,
			ifaddr: [ '172.16.0.2/32', '2606:4700:110:8a36::1/128' ], reserved: [ 1, 2, 3 ], mtu: 1280, noise: 'quic' }
	},
	// Ссылка другого клиента: ключи не закодированы («+» в query стал пробелом), reserved в base64.
	{
		link: `wireguard://${WGK}@engage.cloudflareclient.com:2408/?publickey=${WARP_PK}&address=172.16.0.2/32&reserved=AQID&keepalive=25#wg`,
		expect: { public_key: WARP_PK, reserved: [ 1, 2, 3 ], keepalive: 25, noise: null, ifaddr: [ '172.16.0.2/32' ], mtu: null }
	},
	{ link: `wireguard://${WGK}@1.1.1.1:51820?address=10.0.0.2/32`, error: true },
	{ link: `wireguard://${WGK}@1.1.1.1:51820?publickey=${WARP_PK}&address=10.0.0.2/32&reserved=1,2`, error: true },
	{ link: `wg://${WGK}@1.1.1.1:51820?publickey=${WARP_PK}`, error: true },
];

let failed = 0, passed = 0;

function fail(msg) {
	failed++;
	warn(`FAIL: ${msg}\n`);
}

const INTERCEPT = {
	intercept: true, tproxy_port: 10812, dns_port: 10853,
	dns_servers: [ 'https://dns.comss.one/dns-query', 'https://1.1.1.1/dns-query' ],
	dns_hosts: { 'dns.comss.one': [ '92.38.152.163', '93.115.24.204' ] },
	dns_isp: [ '192.168.1.1' ]
};

// Каждый узел проверяется в обоих режимах: только socks и прозрачный прокси.
function xray_test(node, label) {
	for (let extra in [ {}, INTERCEPT ]) {
		let path = `${TMP}/stella-test-${passed + failed}.json`;
		writefile(path, sprintf('%.J', build_config({ node, ...extra })));
		let rc = system(`${XRAY} run -test -c '${path}' >'${path}.log' 2>&1`);
		if (rc != 0) {
			fail(`${label}${extra.intercept ? ' (перехват)' : ''}: xray отклонил конфиг, см. ${path}.log`);
			return false;
		}
		unlink(path);
		unlink(`${path}.log`);
	}
	return true;
}

for (let c in CASES) {
	let n = parse(c.link);
	let label = substr(c.link, 0, 60);

	if (c.error) {
		if (n.error)
			passed++;
		else
			fail(`${label}: ожидалась ошибка`);
		continue;
	}
	if (n.error) {
		fail(`${label}: ${n.error}`);
		continue;
	}

	let ok = true;
	for (let k, v in c.expect) {
		let got = (k == 'warnings') ? length(n.warnings) : n[k];
		if (sprintf('%J', got) != sprintf('%J', v)) {
			fail(`${label}: ${k} = ${sprintf('%J', got)}, ожидалось ${sprintf('%J', v)}`);
			ok = false;
		}
	}
	if (ok && xray_test(n, label))
		passed++;
}

// Подписка: base64 со смешанным содержимым, дубликаты схлопываются.
let body = b64enc(join('\n', [CASES[0].link, CASES[7].link, CASES[0].link, 'garbage', '', '# comment']));
let sub = decode(body, 'sub1');
if (length(sub.nodes) == 2 && length(sub.errors) == 1 && match(sub.nodes[0].id, /^sub1_[0-9a-f]{8}$/))
	passed++;
else
	fail(`подписка: ${length(sub.nodes)} узлов, ${length(sub.errors)} ошибок`);

// id не зависит от ключей: та же запись с другим sid получает тот же id.
let a = decode(CASES[0].link, 'sub3').nodes[0];
let b = decode(replace(CASES[0].link, 'sid=abcd', 'sid=ef01'), 'sub3').nodes[0];
// Две разные ссылки с одинаковыми названием/адресом/портом — разные id.
let both = decode(CASES[0].link + '\n' + replace(CASES[0].link, 'sid=abcd', 'sid=ef01'), 'sub3').nodes;
if (a.id == b.id && length(both) == 2 && both[0].id != both[1].id)
	passed++;
else
	fail(`стабильность id: ${a.id} / ${b.id}, ${length(both)} узлов`);

// Подписка открытым текстом с CRLF.
sub = decode(CASES[1].link + '\r\n' + CASES[11].link + '\r\n', 'sub2');
if (length(sub.nodes) == 2 && !length(sub.errors))
	passed++;
else
	fail('подписка открытым текстом');

// Битые строки подписки пропускаются, а не обрывают разбор всей подписки.
sub = decode(join('\n', [ 'hysteria2://pw@h.example.com:,443#bad', `vmess://${b64enc('{bad')}`, CASES[0].link ]), 'sub4');
if (length(sub.nodes) == 1 && length(sub.errors) == 2)
	passed++;
else
	fail(`подписка с битыми строками: ${length(sub.nodes)} узлов, ${length(sub.errors)} ошибок`);

// Битый файл (оборвалась запись) — значение по умолчанию, а не исключение.
writefile(`${TMP}/stella-bad.json`, '{"a": [');
if (read_json(`${TMP}/stella-bad.json`, 'def') == 'def' && read_json(`${TMP}/stella-none.json`, 'def') == 'def')
	passed++;
else
	fail('read_json: битый файл');
unlink(`${TMP}/stella-bad.json`);

// WireGuard в конфиге xray: без системного интерфейса, маска QUIC первой и одна и та же при
// каждой сборке (иначе xray перезапускался бы на каждый reload), с перехватом — и UseIPv4;
// домены сайтов — через DNS xray, сначала IPv6 (иначе мимо адресов DNS обхода геоблокировок).
let wn = parse(CASES[length(CASES) - 5].link);
let wc = build_config({ node: wn, ...INTERCEPT });
let wo = wc.outbounds[0];
let wfm = wo.streamSettings?.finalmask?.udp?.[0];
if (wo.protocol == 'wireguard' && wo.settings.noKernelTun === true && wo.targetStrategy == 'ForceIPv6v4' && wo.settings.peers[0].endpoint == '162.159.192.1:2408' &&
    sprintf('%J', wo.settings.reserved) == '[ 1, 2, 3 ]' && wfm?.type == 'noise' && length(wfm.settings.noise) == 9 &&
    match(wfm.settings.noise[0].packet, /^c[0-9a-f]+$/) && wo.streamSettings.sockopt?.domainStrategy == 'UseIPv4' &&
    sprintf('%J', build_config({ node: wn, ...INTERCEPT })) == sprintf('%J', wc) &&
    !build_config({ node: parse(CASES[length(CASES) - 4].link) }).outbounds[0].streamSettings)
	passed++;
else
	fail(`wireguard: ${sprintf('%J', wo)}`);

// Данные WARP из файлов генератора: подсети, порты, ключ, маски QUIC, API и User-Agent; из
// чужого текста — ничего.
if (length(WD.hosts) == 14 && WD.hosts[0] == '162.159.192' && length(WD.ports) == 54 && WD.ports[33] == 2408 &&
    WD.key == 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' && length(WD.masks) == 2 && substr(WD.masks[0], 0, 4) == 'c100' &&
    WD.api == 'https://api.cloudflareclient.com/v0i1909051800' && WD.ua == 'okhttp/3.12.1' &&
    !length(keys(warp_data_parse('нет', 'данных', 'тут'))))
	passed++;
else
	fail(`данные WARP: ${sprintf('%J', { ...WD, masks: length(WD.masks) })}`);

// Случайные адреса WARP — без повторов и из своих подсетей; время регистрации — ISO 8601.
let eps = random_endpoints(8);
if (length(eps) == 8 && length(uniq(eps)) == 8 && length(filter(eps, (e) => match(e, /^(162\.159|188\.114|8\.[0-9]+)\.[0-9]+\.[0-9]+:[0-9]+$/))) == 8 &&
    iso_time(0) == '1970-01-01T00:00:00.000Z')
	passed++;
else
	fail(`warp: ${sprintf('%J', eps)} ${iso_time(0)}`);

// Конфиг без узла — всё напрямую, должен быть валиден.
if (xray_test(null, 'без узла'))
	passed++;

// DNS — одна цепочка напрямую: DoH-серверы по порядку (ждать каждый 1,5 с), последним — DNS
// провайдера; имена DoH-серверов — из hosts; запросы DNS идут через свой выход, который узнаёт
// адрес DoH-сервера у встроенного DNS (то есть из hosts). Истёкшие записи отдаются из кэша.
// Сам xray спрашивает и IPv6 (для WARP); устройствам AAAA не отдаёт dnsmasq.
let c = build_config({ node: parse(CASES[1].link), ...INTERCEPT });
let dns_out = filter(c.outbounds, (o) => o.tag == 'direct-dns')[0];
if (sprintf('%J', c.dns.servers) == sprintf('%J', [ { address: INTERCEPT.dns_servers[0], timeoutMs: 1500 },
	{ address: INTERCEPT.dns_servers[1], timeoutMs: 1500 }, { address: '192.168.1.1', port: 53 } ]) &&
    c.dns.tag == 'dns-direct' && c.dns.hosts['dns.comss.one'][1] == '93.115.24.204' &&
    c.dns.serveStale === true && c.dns.serveExpiredTTL == 86400 && c.dns.queryStrategy == 'UseIP' &&
    dns_out?.streamSettings?.sockopt?.domainStrategy == 'UseIPv4' &&
    length(filter(c.routing.rules, (r) => r.inboundTag?.[0] == 'dns-direct' && r.outboundTag == 'direct-dns')) == 1 &&
    length(filter(c.routing.rules, (r) => r.inboundTag?.[0] == 'dns-internal')) == 0)
	passed++;
else
	fail(`цепочка DNS: ${sprintf('%J', { dns: c.dns, rules: c.routing.rules })}`);

// Запасные — по порядку после цепочки: DoH и обычный DNS вперемешку.
c = build_config({ node: null, ...INTERCEPT, dns_last: [ '77.88.8.8', 'https://dns.google/dns-query' ] });
if (sprintf('%J', map(c.dns.servers, (x) => x.address)) == sprintf('%J', [ ...INTERCEPT.dns_servers, '77.88.8.8', 'https://dns.google/dns-query' ]) &&
    c.dns.servers[2].port == 53 && c.dns.servers[3].timeoutMs == 1500)
	passed++;
else
	fail(`запасные DNS: ${sprintf('%J', c.dns.servers)}`);

// Без цепочки (каталог ещё не скачан) — только DNS провайдера, без hosts.
c = build_config({ node: null, ...INTERCEPT, dns_servers: [], dns_hosts: {} });
if (sprintf('%J', c.dns.servers) == '[ { "address": "192.168.1.1", "port": 53 } ]' && !c.dns.hosts)
	passed++;
else
	fail(`DNS без цепочки: ${sprintf('%J', c.dns)}`);

// Автовыбор: outbound на каждый узел, balancer с запасным ручным узлом, observatory; xray принимает.
c = build_config({ node: parse(CASES[0].link), auto_nodes: [ parse(CASES[1].link), parse(CASES[11].link), parse(CASES[7].link) ], ...INTERCEPT });
let tags = map(c.outbounds, (o) => o.tag);
let last = c.routing.rules[length(c.routing.rules) - 1];
if (sprintf('%J', slice(tags, 0, 4)) == '[ "proxy", "proxy-0", "proxy-1", "proxy-2" ]' &&
    c.routing.balancers[0].fallbackTag == 'proxy' && last.balancerTag == 'auto' && !last.outboundTag &&
    c.observatory.subjectSelector[0] == 'proxy-' && length(c.dns.servers) == 3) {
	let path = `${TMP}/stella-auto.json`;
	writefile(path, sprintf('%.J', c));
	if (system(`${XRAY} run -test -c '${path}' >/dev/null 2>&1`) == 0) {
		passed++;
		unlink(path);
	}
	else
		fail(`автовыбор: xray отклонил ${path}`);
}
else
	fail(`автовыбор: ${sprintf('%J', { tags, balancers: c.routing.balancers, last })}`);

// Один узел в автовыборе — обычный режим, без balancer.
c = build_config({ node: parse(CASES[0].link), auto_nodes: [ parse(CASES[1].link) ], ...INTERCEPT });
if (!c.routing.balancers && !c.observatory)
	passed++;
else
	fail('автовыбор из одного узла');

// Разбор списков: форматы itdoginfo, v2ray, clash, dnsmasq, yaml.
let pl = parse_list(join('\n', [
	'# комментарий', 'youtube.com', '.ua', '+.googlevideo.com', 'full:www.example.org',
	'DOMAIN-SUFFIX,Twitter.com', 'DOMAIN-KEYWORD,ads', 'keyword:tracker', 'regexp:^a.*$',
	'nftset=/t.me/telegram.org/4#inet#fw4#vpn_domains', 'payload:', '  - +.x.com',
	'91.108.4.0/22', 'IP-CIDR,149.154.160.0/20,no-resolve', '1.2.3.4', '2001:db8::/32',
	'300.1.1.1/8', '10.0.0.0/33', 'youtube.com', 'bad domain', ''
]));
let want_d = [ 'example.org', 'googlevideo.com', 't.me', 'telegram.org', 'twitter.com', 'ua', 'www.example.org', 'x.com', 'youtube.com' ];
want_d = filter(want_d, (d) => d != 'example.org');
let want_c = [ '1.2.3.4', '149.154.160.0/20', '91.108.4.0/22' ];
if (sprintf('%J', pl.domains) == sprintf('%J', want_d) && sprintf('%J', pl.cidrs) == sprintf('%J', want_c))
	passed++;
else
	fail(`parse_list: ${sprintf('%J', pl)}`);

// Наборы sing-box из russia-v2ray-rules-dat (фикстуры — telegram): домены из дерева, подсети
// IPv4 из диапазонов (IPv6 пропускается); не набор — null, битый — ошибка.
const FIX = replace(sourcepath(), /[^\/]+$/, '') + 'fixtures/';
let gs = parse_srs(readfile(FIX + 'geosite-telegram.srs'));
let gi = parse_srs(readfile(FIX + 'geoip-telegram.srs'));
let gbad = parse_srs(substr(readfile(FIX + 'geosite-telegram.srs'), 0, 100));
if (length(gs?.domains) == 21 && 't.me' in gs.domains && 'telegram.org' in gs.domains && !length(gs.cidrs) &&
    sprintf('%J', gi?.cidrs) == sprintf('%J', [ '149.154.160.0/20', '185.76.151.0/24', '91.105.192.0/23', '91.108.16.0/21',
	'91.108.4.0/22', '91.108.56.0/22', '91.108.8.0/21', '95.161.64.0/20' ]) && !length(gi.domains) &&
    parse_srs('youtube.com\n') == null && gbad?.error)
	passed++;
else
	fail(`parse_srs: ${sprintf('%J', [ gs, gi, gbad ])}`);

// nft: порядок списков, списки для части устройств, устройства в обход списков.
let nft = nft_script({
	lan_ifnames: [ 'br-lan' ], tproxy_port: 10812, default_action: 'direct', dns_hijack: true,
	lists: [
		{ id: 'list_a', action: 'vpn', cidrs: [ '1.2.3.0/24' ], devices_mode: 'all', macs: [] },
		{ id: 'list_b', action: 'zapret', cidrs: [], devices_mode: 'only', macs: [ 'aa:bb:cc:dd:ee:ff' ] },
		{ id: 'list_c', action: 'direct', cidrs: [], devices_mode: 'except', macs: [ 'aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02' ] }
	],
	devices: [ { mac: '11:22:33:44:55:66', policy: 'vpn' }, { mac: '11:22:33:44:55:77', policy: 'global' } ],
	zapret: { qnum: 202, tcp_ports: '80,443', udp_ports: 'bad ports' }
});
// Подсети — в сете interval (только если есть), адреса доменов — в обычном сете _dns со сроком,
// который продлевает трафик.
let ok = index(nft, '\t\tip daddr @list_a goto act_vpn\n' +
		'\t\tip daddr @list_a_dns update @list_a_dns { ip daddr } goto act_vpn\n' +
		'\t\tether saddr { aa:bb:cc:dd:ee:ff } ip daddr @list_b_dns update @list_b_dns { ip daddr } goto act_zapret\n' +
		'\t\tether saddr != { aa:bb:cc:dd:ee:01, aa:bb:cc:dd:ee:02 } ip daddr @list_c_dns update @list_c_dns { ip daddr } goto act_direct\n' +
		'\t\tgoto act_direct') >= 0 &&
	index(nft, '\tset list_a {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { 1.2.3.0/24 }\n\t}') >= 0 &&
	index(nft, '\tset list_a_dns {\n\t\ttype ipv4_addr\n\t\tsize 262144\n\t\tflags dynamic, timeout\n\t\ttimeout 12h\n\t}') >= 0 &&
	index(nft, 'set list_b {') < 0 && index(nft, '\tset zapret_excl {\n\t\ttype ipv4_addr\n\t\tsize 262144\n\t\tflags dynamic, timeout\n\t\ttimeout 12h\n\t}') >= 0 &&
	index(nft, 'ether saddr { 11:22:33:44:55:66 } goto act_vpn') >= 0 &&
	index(nft, '11:22:33:44:55:77') < 0 &&
	index(nft, 'dport 853') < 0 && index(nft, 'doh4') < 0 &&
	index(nft, 'tcp dport { 80, 443 }') >= 0 && index(nft, 'udp dport') < 0 &&
	index(nft, 'th dport 53 redirect to :53') >= 0;
if (ok)
	passed++;
else
	fail(`nft_script:\n${nft}`);

// Резервный канал «всё через VPN»: блок-списки (со своими устройствами) действуют, остальное —
// в VPN мимо списков и устройств «всё напрямую».
let nb = nft_script({ lan_ifnames: [ 'br-lan' ], tproxy_port: 1, default_action: 'direct', zapret: null, all_vpn: true,
	lists: [
		{ id: 'list_a', action: 'direct', cidrs: [], devices_mode: 'all', macs: [] },
		{ id: 'list_b', action: 'block', cidrs: [], devices_mode: 'only', macs: [ 'aa:bb:cc:dd:ee:ff' ] }
	],
	devices: [ { mac: '11:22:33:44:55:66', policy: 'direct' } ] });
if (index(nb, '\t\tether saddr { aa:bb:cc:dd:ee:ff } ip daddr @list_b_dns update @list_b_dns { ip daddr } goto act_block\n\t\tgoto act_vpn\n\t}') >= 0 &&
    index(nb, 'goto pol_global') < 0 && index(nb, '11:22:33:44:55:66') < 0)
	passed++;
else
	fail(`all_vpn:\n${nb}`);

// Возврат адресов в сеты: в список только добавили — возвращаются; из списка что-то убрали —
// нет (иначе убранный сайт шёл бы по правилу до перезагрузки); прежнего состояния нет — да.
let rs = restore_script(
	{ list_a: [ '1.1.1.1' ], list_b: [ '2.2.2.2' ], list_c: [ '3.3.3.3' ], zapret_excl: [ '4.4.4.4', '5.5.5.5' ] },
	{ list_a: [ 'a.com' ], list_b: [ 'b.com', '9.9.9.9' ], list_c: [ 'c.com' ] },
	{ list_a: [ 'a.com', 'new.com' ], list_b: [ 'b.com' ], list_c: [], zapret_excl: [ 'x.ru' ], list_d: [ 'd.com' ] });
if (sprintf('%J', rs) == sprintf('%J', [ 'add element inet stella list_a { 1.1.1.1 }', 'add element inet stella zapret_excl { 4.4.4.4, 5.5.5.5 }' ]))
	passed++;
else
	fail(`restore_script: ${sprintf('%J', rs)}`);

// Вставленная ссылка на сайт превращается в домен.
if (sprintf('%J', parse_list('https://www.Example.com/path?q=1\nhttp://2ip.io').domains) == '[ "2ip.io", "www.example.com" ]')
	passed++;
else
	fail('parse_list: ссылка на сайт');

// dnsmasq: домен из двух списков — одна строка с двумя сетами.
let dm = dnsmasq_conf({ dns_port: 10853, lists: [ { id: 'list_a', domains: [ 'x.com', 'y.com' ] }, { id: 'list_b', domains: [ 'x.com' ] } ] });
if (index(dm, 'nftset=/x.com/4#inet#stella#list_a,4#inet#stella#list_b\n') >= 0 && index(dm, 'nftset=/y.com/4#inet#stella#list_a\n') >= 0 &&
    index(dm, 'max-ttl=60\n') >= 0 && index(dm, 'max-cache-ttl=300\n') >= 0 && index(dm, 'filter-AAAA\n') >= 0)
	passed++;
else
	fail(`dnsmasq_conf:\n${dm}`);

// Обычный dnsmasq (не dnsmasq-full) со строками nftset= не запустился бы — их нет, остальное есть.
let dp = dnsmasq_conf({ dns_port: 10853, nftset: false, lists: [ { id: 'list_a', domains: [ 'x.com' ] } ] });
if (index(dp, 'nftset=') < 0 && index(dp, 'server=127.0.0.1#10853\n') >= 0)
	passed++;
else
	fail(`dnsmasq_conf без nftset:\n${dp}`);

// Каталог Zapret: три источника на реальных образцах.
let fs = flowseal_strategy(readfile('tests/fixtures/flowseal-general-alt3.bat'), 'general (ALT3)', '/etc/stella/zapret/fake');
let fsj = fs ? join(' ', fs.args) : '';
if (fs && fs.args[0] == '--filter-udp=19294-19344,50000-50100' && index(fsj, '%') < 0 && index(fsj, '"') < 0 &&
    index(fsj, '/etc/stella/zapret/fake/') >= 0 && index(fsj, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') >= 0 &&
    index(fsj, 'list-general') < 0 && index(fsj, '--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-flowseal-exclude.txt') >= 0 &&
    index(fsj, '--filter-tcp=12') >= 0 && fs.args[length(fs.args) - 1] != '--new' &&
    index(fsj, '--new --new') < 0 && index(fsj, 'winws') < 0)
	passed++;
else
	fail(`flowseal_strategy: ${fsj}`);

let zv = zms_strategies(readfile('tests/fixtures/zms-strategies.sh'));
if (length(zv) == 2 && zv[0].name == 'v1' && zv[0].family == 'v' && zv[0].args[0] == '--filter-tcp=443' && length(zv[1].args) > 3)
	passed++;
else
	fail(`zms_strategies: ${sprintf('%J', zv)}`);

let yv = block_strategies(readfile('tests/fixtures/stryoutube.txt'), 'yv');
if (length(yv) == 2 && yv[0].name == 'Yv01' && yv[1].name == 'Yv02' && yv[0].args[0] == '--filter-tcp=443')
	passed++;
else
	fail(`block_strategies: ${sprintf('%J', yv)}`);

// Отдельные наборы ZMS — из его скрипта: Dv, блок голоса Discord, игры Gv1–Gv4 (общий TCP-блок,
// порты PORTS_*, число — из меню fix_GAME), домены Google Play.
let zms = readfile('tests/fixtures/zms-strategies.sh');
let dv = zms_discord(zms), voice = zms_discord_voice(zms), gv = zms_games(zms), gpd = zms_gp_domains(zms);
let gvj = join(' ', gv[1]?.args || []);
if (length(dv) == 2 && dv[0].name == 'Dv1' && dv[0].family == 'dv' && dv[0].args[0] == '--filter-tcp=2053,2083,2087,2096,8443' &&
    voice?.family == 'voice' && voice.args[0] == '--filter-udp=19294-19344,50000-50100' && voice.args[length(voice.args) - 1] == '--dpi-desync-repeats=6' &&
    length(gv) == 4 && gv[0].name == 'Gv1' && gv[0].family == 'gv' && index(gv[0].args[0], '--filter-udp=88,1024-2407') == 0 &&
    gv[0].args[2] == '--dpi-desync-cutoff=d2' && gv[3].args[5] == '--dpi-desync-cutoff=n4' &&
    index(gvj, '--new --filter-tcp=2099,') > 0 && index(gvj, '$') < 0 && index(gvj, '#') < 0 && gv[1].args[0] != '--new' &&
    length(gpd) >= 10 && 'gvt1.com' in gpd && 'play.google.com' in gpd &&
    !length(zms_games('PORTS_UDP="1"')) && zms_discord_voice('') == null)
	passed++;
else
	fail(`наборы ZMS: ${sprintf('%J', { dv: length(dv), voice, gv: gv[0], gv2: gv[1], n: length(gv), gpd })}`);

// Цели проверки YouTube — из DOMAINS Zapret Manager, по одной на домен второго уровня.
let ytt = zms_yt_targets(zms);
if (sprintf('%J', ytt) == sprintf('%J', [ 'youtu.be', 'youtube.com', 'i.ytimg.com', 'yt3.ggpht.com', 'googleapis.com', 'manifest.googlevideo.com' ]) &&
    !length(zms_yt_targets('нет списка')))
	passed++;
else
	fail(`цели YouTube: ${sprintf('%J', ytt)}`);

// Сборка: YouTube первым, Discord — голос + Dv, игры — Gv; порты дополняются и сливаются.
let z = compose({ main: [ '--filter-tcp=443', '--dpi-desync=fake' ], yt: { args: [ '--filter-tcp=443', '--hostlist=g.txt' ] },
	discord: dv[0], voice, games: gv[1], tcp_ports: '80,443', udp_ports: '443' });
let zj = join(' ', z.args);
if (z.args[1] == '--hostlist=g.txt' && z.args[2] == '--new' && z.args[3] == '--filter-tcp=443' &&
    index(zj, '--filter-l7=discord,stun') > 0 && index(zj, 'discord.media') > index(zj, '--filter-l7=discord,stun') &&
    index(zj, '--dpi-desync-cutoff=n2') > 0 && z.args[length(z.args) - 1] != '--new' &&
    index(z.tcp_ports, '2053') >= 0 && index(z.tcp_ports, '25565') >= 0 && z.udp_ports == '88,443,1024-2407,2409-4499,4502-65535' &&
    merge_ports([ '443,80', '1024-2000,1500-3000', '3001', 'x', '1024-65535,443' ]) == '80,443,1024-65535')
	passed++;
else
	fail(`compose: ${sprintf('%J', z)}`);
if (sprintf('%J', compose({ main: [ '--a' ] })) == '{ "args": [ "--a" ], "tcp_ports": "80,443", "udp_ports": "443" }')
	passed++;
else
	fail('compose без наборов');

// Без основной и YouTube — только порты Discord и игр, веб-трафик в очередь не идёт.
let zo = compose({ main: [], discord: dv[0], voice }), zn = compose({ main: [] });
if (zo.tcp_ports == '2053,2083,2087,2096,8443' && zo.udp_ports == '19294-19344,50000-50100' &&
    index(join(' ', zo.args), 'discord.media') > 0 && !length(zn.args) && zn.tcp_ports == '' && zn.udp_ports == '')
	passed++;
else
	fail(`compose без основной: ${sprintf('%J', { zo, zn })}`);

// Своя подделка для игр, подмена путей хостлистов, поиск отсутствующих файлов.
let zg = compose({ main: [ '--a' ], games: gv[0], games_fake: '/f/stun2.bin' });
let lz = localize([ '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt', '--x=1' ], { '/opt/zapret/ipset/zapret-hosts-google.txt': '/etc/stella/zapret/hosts-google.txt' });
let mf = missing_files([ '--dpi-desync-fake-tls=/a.bin', '--hostlist=/b.txt', '--filter-tcp=443', '--dpi-desync-fake-tls=/a.bin', '--x=/c.bin,/d.bin' ], (f) => f == '/b.txt');
if (index(join(' ', zg.args), '--dpi-desync-fake-unknown-udp=/f/stun2.bin') > 0 && index(join(' ', zg.args), '--dpi-desync-fake-unknown-udp=/opt/') < 0 &&
    lz[0] == '--hostlist=/etc/stella/zapret/hosts-google.txt' && lz[1] == '--x=1' &&
    sprintf('%J', mf) == '[ "/a.bin" ]')
	passed++;
else
	fail(`games_fake/localize/missing_files: ${sprintf('%J', { zg: zg.args, lz, mf })}`);

// Исключения Zapret: свой сет и проверка до пометки соединения.
let nz = nft_script({ lan_ifnames: [ 'br-lan' ], tproxy_port: 1, default_action: 'zapret', lists: [], devices: [],
	zapret: { qnum: 202, tcp_ports: '443', udp_ports: '443' } });
let nn = nft_script({ lan_ifnames: [ 'br-lan' ], tproxy_port: 1, default_action: 'direct', lists: [], devices: [], zapret: null });
if (index(nz, 'set zapret_excl {') > 0 && index(nz, 'ip daddr @zapret_excl update @zapret_excl { ip daddr } accept\n\t\tct mark set') > 0 && index(nn, 'zapret_excl') < 0)
	passed++;
else
	fail(`исключения zapret:\n${nz}`);

// IPv6 устройств закрыт — отказ на выход из LAN наружу, внутри сети не трогается; открыт —
// цепочки нет, и dnsmasq отдаёт AAAA.
let n6 = nft_script({ lan_ifnames: [ 'br-lan' ], tproxy_port: 1, default_action: 'direct', lists: [], devices: [], zapret: null, block_ipv6: true });
if (index(n6, 'chain ipv6_block {') > 0 && index(n6, 'oifname { "br-lan" } return\n\t\tmeta l4proto tcp reject with tcp reset\n\t\treject with icmpx admin-prohibited') > 0 &&
    index(nn, 'ipv6_block') < 0 && index(dnsmasq_conf({ dns_port: 1, block_ipv6: false, lists: [] }), 'filter-AAAA') < 0)
	passed++;
else
	fail(`ipv6_block:\n${n6}`);

// Подделка для голоса Discord заменяет оба файла голосового блока.
let zd = join(' ', compose({ main: [ '--a' ], discord: dv[0], voice, discord_fake: '/f/x.bin' }).args);
if (index(zd, '--dpi-desync-fake-discord=/f/x.bin') > 0 && index(zd, '--dpi-desync-fake-stun=/f/x.bin') > 0 && index(zd, 'stun.bin --dpi-desync-repeats=6') < 0)
	passed++;
else
	fail(`discord_fake: ${zd}`);

// «--ключ значение» через пробел (Yv06 в каталоге ZMS) → «--ключ=значение».
let ya = block_strategies('#Yx\n--dpi-desync=fake\n--dpi-desync-autottl 2:2-12\n--new\n', 'yv')[0]?.args || [];
if (ya[1] == '--dpi-desync-autottl=2:2-12' && ya[0] == '--dpi-desync=fake' && ya[2] == '--new')
	passed++;
else
	fail(`norm_arg: ${join(' ', ya)}`);

// Автоподбор по категориям: «main» — v и fs без YouTube, «yv» — только YouTube и без
// текущей основной; Discord и игры не проверяются никогда.
let tcat = [ { name: 'v1', family: 'v', args: [ '--a' ] }, { name: 'g1', family: 'fs', args: [ '--b' ] },
	{ name: 'Yv01', family: 'yv', args: [ '--c' ] }, { name: 'Dv1', family: 'dv', args: [ '--d' ] }, { name: 'Gv1', family: 'gv', args: [ '--e' ] } ];
let tnames = (scope, cur) => join(',', map(test_list(tcat, scope, cur), (s) => `${s.name}:${s.family}`));
let tl = {
	all: tnames('all', { name: 'mine', args: [ '--x' ] }),
	main: tnames('main', { name: 'mine', args: [ '--x' ] }),
	main_cur: tnames('main', { name: 'v1', args: [ '--a' ] }),
	yv: tnames('yv', { name: 'mine', args: [ '--x' ] }),
	fs: tnames('fs', { name: '', args: [] }),
	v_cur_fs: tnames('v', { name: 'g1', args: [ '--b' ] }),
	one: tnames('Yv01', { name: 'mine', args: [ '--x' ] }),
	dv: tnames('dv', { name: '', args: [] })
};
if (tl.all == 'v1:v,g1:fs,Yv01:yv,mine:current' && tl.main == 'v1:v,g1:fs,mine:current' && tl.main_cur == 'v1:v,g1:fs' &&
    tl.yv == 'Yv01:yv' && tl.fs == 'g1:fs' && tl.v_cur_fs == 'v1:v,g1:fs' && tl.one == 'Yv01:yv' && tl.dv == '')
	passed++;
else
	fail(`test_list: ${sprintf('%J', tl)}`);

// Стабильность узла: медиана и разброс по ответившим; лучший — по доле ответов, затем
// по задержке с разбросом; менять текущий — только если новый дешевле на 20 %.
let se = stab_entry([ 120, -1, 100, 140, 110 ]);
let sn = [ { id: 'a' }, { id: 'b' }, { id: 'c' } ];
let ss = { a: { ok: 5, n: 5, ms: 300, jit: 30 }, b: { ok: 4, n: 5, ms: 50, jit: 1 }, c: { ok: 5, n: 5, ms: 200, jit: 10 } };
if (sprintf('%J', se) == '{ "ok": 4, "n": 5, "ms": 120, "jit": 12 }' && stab_entry([ -1, -1 ]).ok == 0 &&
    best_node(sn, ss).id == 'c' && best_node(sn, {}) == null &&
    stab_better(ss.c, ss.a) && !stab_better({ ok: 5, n: 5, ms: 190, jit: 10 }, ss.c) && stab_better(ss.c, { ok: 0, n: 5 }) && !stab_better(ss.b, ss.c))
	passed++;
else
	fail(`стабильность узлов: ${sprintf('%J', se)}`);

// Только игры (умолчание): в очередь — только игровые порты из блока Gv1.
let zgo = compose({ main: [], games: gv[0] });
if (zgo.udp_ports == '88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535' && index(zgo.tcp_ports, '25565') >= 0 &&
    index(zgo.tcp_ports, '443') < 0 && zgo.args[0] == gv[0].args[0])
	passed++;
else
	fail(`только игры: ${sprintf('%J', zgo)}`);

// Готовые списки itdoginfo по дереву репозитория: списки доменов по стране и сервисы с подсетями
// (то же имя, затем без учёта регистра), подсети без сервиса — отдельно; форматы других программ
// и IPv6 — нет.
let itc = itdog_catalog(json(readfile('tests/fixtures/itdog-tree.json')));
let itf = map(itc, (e) => join('+', e.files));
if (sprintf('%J', itf) == sprintf('%J', [ 'Categories/block.lst', 'Russia/inside-raw.lst', 'Services/discord.lst+Subnets/IPv4/discord.lst',
	'Services/hetzner.lst+Subnets/IPv4/hetzner.lst', 'Services/youtube.lst', 'Ukraine/inside-raw.lst', 'Subnets/IPv4/Meta.lst' ]) &&
    itc[0].group == 'Categories' && itc[6].group == 'Services' && !length(itdog_catalog(null)))
	passed++;
else
	fail(`itdog_catalog: ${sprintf('%J', itc)}`);

// Каталог DoH из массива PROVIDERS панели Zapret Manager: вид, адреса для начального разрешения
// (только IPv4), без адресов не https и без того, что после массива.
let dc = doh_catalog(readfile('tests/fixtures/zms-doh-providers.txt'));
if (length(dc) == 7 && dc[0].id == 'google' && dc[0].kind == 'plain' && sprintf('%J', dc[0].boot) == '[ "8.8.8.8", "8.8.4.4" ]' &&
    dc[2].kind == 'safe' && dc[2].label == 'Cloudflare · Защита от угроз' && dc[3].id == 'xbox' && dc[3].kind == 'geo' && !length(dc[3].boot) &&
    !length(filter(dc, (x) => x.id == 'bad' || x.id == 'after')) && !length(doh_catalog('нет массива')) &&
    doh_url('https://dns.comss.one/dns-query') && doh_url('https://api.magicdns.ru/sync') && !doh_url('https://a b/') && !doh_url('http://x.ru/q'))
	passed++;
else
	fail(`doh_catalog: ${sprintf('%J', dc)}`);

// DNS провайдера из resolv.conf.
let rsv = resolv_servers('# Interface wan\nnameserver 192.168.1.1\nnameserver 127.0.0.1\nnameserver fe80::1\nnameserver 8.8.8.8\nnameserver 192.168.1.1\n');
if (sprintf("%J", rsv) == "[ \"192.168.1.1\", \"8.8.8.8\" ]")
	passed++;
else
	fail(`resolv_servers: ${sprintf("%J", rsv)}`);

// Запрос DNS для DoH GET (base64url без «=») и разбор ответа: A-записи, ссылки-сжатие, CNAME
// пропускается; не ответ DNS — null.
let dq = dns_query('example.com');
let ans = '\x00\x00\x81\x80\x00\x01\x00\x02\x00\x00\x00\x00' + '\x07example\x03com\x00\x00\x01\x00\x01' +
	'\xc0\x0c\x00\x05\x00\x01\x00\x00\x00\x3c\x00\x02\xc0\x0c' +
	'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x5d\xb8\xd7\x0e';
let da = dns_answer(ans), dn = dns_answer('\x00\x00\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00\x03bad\x00\x00\x01\x00\x01');
if (dq == 'AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE' && sprintf('%J', da) == '{ "rcode": 0, "ips": [ "93.184.215.14" ] }' &&
    dn.rcode == 3 && !length(dn.ips) && dns_answer('<html>') == null && dns_answer(substr(ans, 0, 40)) == null)
	passed++;
else
	fail(`dns_query/dns_answer: ${sprintf('%J', { dq, da, dn })}`);

// WARP: узел Cloudflare и страна из cdn-cgi/trace; лучше — отвечающий, среди отвечающих — заметно
// более быстрый (страна выхода у WARP всегда страна пользователя — её не сравниваем).
let ti = trace_info('fl=1\nh=www.cloudflare.com\nip=1.2.3.4\nloc=RU\ncolo=ARN\nwarp=on\n');
let wa = { ok: true, ms: 40 }, wb = { ok: true, ms: 120 };
if (ti?.loc == 'RU' && ti.colo == 'ARN' && trace_info('<html>') == null &&
    warp_better(wa, wb) && !warp_better(wb, wa) && warp_better(wb, { ok: false }) && !warp_better({ ok: false }, wa) &&
    !warp_better({ ok: true, ms: 100 }, wb) && warp_better(wb, null))
	passed++;
else
	fail(`warp_better: ${sprintf('%J', ti)}`);

print(`passed: ${passed}, failed: ${failed}\n`);
exit(failed ? 1 : 0);
