// Тесты разбора ссылок и генерации конфига.
// Каждый успешно разобранный узел прогоняется через `xray run -test`.

'use strict';

import { writefile, unlink, readfile } from 'fs';
import { parse } from 'stella.uri';
import { decode } from 'stella.subscription';
import { build_config, dns_server_ip } from 'stella.xray';
import { parse_list } from 'stella.lists';
import { nft_script, dnsmasq_conf } from 'stella.firewall';
import { flowseal_strategy, zms_strategies, block_strategies } from 'stella.zapret';

const UUID = '48b4e5f1-00ed-4c06-aa7d-e8890e1dcc5d';
const PBK = 'VaUOAQYUQAmBLwQ0NproXnB1vR_YNA9e3Pa9ghS72BY';
const PCS = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const TMP = getenv('TMPDIR') || '/tmp';
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
];

let failed = 0, passed = 0;

function fail(msg) {
	failed++;
	warn(`FAIL: ${msg}\n`);
}

const INTERCEPT = {
	intercept: true, tproxy_port: 10812, dns_port: 10853,
	dns_remote: 'https://1.1.1.1/dns-query', dns_direct: 'https://77.88.8.8/dns-query'
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

// Конфиг без узла — всё напрямую, должен быть валиден.
if (xray_test(null, 'без узла'))
	passed++;

// Адрес прокси-сервера — домен: он резолвится напрямую, а DNS-сервер идёт в direct.
let c = build_config({ node: parse(CASES[1].link), ...INTERCEPT });
let dns0 = c.dns.servers[0];
if (dns0.domains?.[0] == 'full:srv.example.com' && c.routing.rules[1].ip[0] == '77.88.8.8' && c.routing.rules[1].outboundTag == 'direct')
	passed++;
else
	fail(`прямой резолв адреса сервера: ${sprintf('%J', dns0)}`);

// Адрес сервера — IP: прямого DNS для него не нужно; в конце — запасной DNS напрямую.
c = build_config({ node: parse(CASES[0].link), ...INTERCEPT });
if (sprintf('%J', c.dns.servers) == sprintf('%J', [ INTERCEPT.dns_remote, INTERCEPT.dns_direct ]))
	passed++;
else
	fail(`DNS-серверы для IP-адреса: ${sprintf('%J', c.dns.servers)}`);

// Автовыбор: outbound на каждый узел, balancer с запасным ручным узлом, observatory; xray принимает.
c = build_config({ node: parse(CASES[0].link), auto_nodes: [ parse(CASES[1].link), parse(CASES[11].link), parse(CASES[7].link) ], ...INTERCEPT });
let tags = map(c.outbounds, (o) => o.tag);
let last = c.routing.rules[length(c.routing.rules) - 1];
if (sprintf('%J', slice(tags, 0, 4)) == '[ "proxy", "proxy-0", "proxy-1", "proxy-2" ]' &&
    c.routing.balancers[0].fallbackTag == 'proxy' && last.balancerTag == 'auto' && !last.outboundTag &&
    c.observatory.subjectSelector[0] == 'proxy-' && length(c.dns.servers[0].domains) == 3) {
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

if (dns_server_ip('https://77.88.8.8/dns-query') == '77.88.8.8' && dns_server_ip('8.8.4.4') == '8.8.4.4' && dns_server_ip('https://dns.google/dns-query') == null)
	passed++;
else
	fail('dns_server_ip');

// Разбор списков: форматы itdoginfo, meta-rules-dat, clash, dnsmasq, yaml.
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

// nft: порядок списков, списки для части устройств, устройства в обход списков, DoH.
let nft = nft_script({
	lan_ifnames: [ 'br-lan' ], tproxy_port: 10812, default_action: 'direct', dns_hijack: true, block_doh: true,
	lists: [
		{ id: 'list_a', action: 'vpn', cidrs: [ '1.2.3.0/24' ], devices_mode: 'all', macs: [] },
		{ id: 'list_b', action: 'zapret', cidrs: [], devices_mode: 'only', macs: [ 'aa:bb:cc:dd:ee:ff' ] },
		{ id: 'list_c', action: 'direct', cidrs: [], devices_mode: 'except', macs: [ 'aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02' ] }
	],
	devices: [ { mac: '11:22:33:44:55:66', policy: 'vpn' }, { mac: '11:22:33:44:55:77', policy: 'global' } ],
	zapret: { qnum: 202, tcp_ports: '80,443', udp_ports: 'bad ports' }
});
let ok = index(nft, '\t\tip daddr @list_a goto act_vpn\n' +
		'\t\tether saddr { aa:bb:cc:dd:ee:ff } ip daddr @list_b goto act_zapret\n' +
		'\t\tether saddr != { aa:bb:cc:dd:ee:01, aa:bb:cc:dd:ee:02 } ip daddr @list_c goto act_direct\n' +
		'\t\tgoto act_direct') >= 0 &&
	index(nft, 'ether saddr { 11:22:33:44:55:66 } goto act_vpn') >= 0 &&
	index(nft, '11:22:33:44:55:77') < 0 &&
	index(nft, 'th dport 853 drop') >= 0 &&
	index(nft, 'tcp dport { 80, 443 }') >= 0 && index(nft, 'udp dport') < 0 &&
	index(nft, 'th dport 53 redirect to :53') >= 0;
if (ok)
	passed++;
else
	fail(`nft_script:\n${nft}`);

// Вставленная ссылка на сайт превращается в домен.
if (sprintf('%J', parse_list('https://www.Example.com/path?q=1\nhttp://2ip.io').domains) == '[ "2ip.io", "www.example.com" ]')
	passed++;
else
	fail('parse_list: ссылка на сайт');

// dnsmasq: домен из двух списков — одна строка с двумя сетами.
let dm = dnsmasq_conf({ dns_port: 10853, lists: [ { id: 'list_a', domains: [ 'x.com', 'y.com' ] }, { id: 'list_b', domains: [ 'x.com' ] } ] });
if (index(dm, 'nftset=/x.com/4#inet#stella#list_a,4#inet#stella#list_b\n') >= 0 && index(dm, 'nftset=/y.com/4#inet#stella#list_a\n') >= 0)
	passed++;
else
	fail(`dnsmasq_conf:\n${dm}`);

// Каталог Zapret: три источника на реальных образцах.
let fs = flowseal_strategy(readfile('tests/fixtures/flowseal-general-alt3.bat'), 'general (ALT3)', '/etc/stella/zapret/fake');
let fsj = fs ? join(' ', fs.args) : '';
if (fs && fs.args[0] == '--filter-udp=19294-19344,50000-50100' && index(fsj, '%') < 0 && index(fsj, '"') < 0 &&
    index(fsj, '/etc/stella/zapret/fake/') >= 0 && index(fsj, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') >= 0 &&
    index(fsj, 'list-general') < 0 && index(fsj, '--filter-tcp=12') >= 0 && fs.args[length(fs.args) - 1] != '--new' &&
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

print(`passed: ${passed}, failed: ${failed}\n`);
exit(failed ? 1 : 0);
