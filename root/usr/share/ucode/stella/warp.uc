// Cloudflare WARP — бесплатный WireGuard от Cloudflare: регистрация, как у официального
// клиента, ссылка на узел и маска против DPI. Идеи, адреса и маски QUIC — из
// github.com/nellimonix/warp-config-generator-vercel (MIT, (c) 2025 nellimonix).

'use strict';

import { readfile } from 'fs';
import { fnv1a, pctenc } from 'stella.util';

export const WARP_API = getenv('STELLA_WARP_API') || 'https://api.cloudflareclient.com/v0i1909051800';
// Ключ сервера WARP у всех один.
export const WARP_PEER_KEY = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';
export const WARP_PORT = 2408;

// Подсети и порты, на которых отвечает WireGuard WARP. Часть адресов у провайдеров закрыта —
// Stella проверяет несколько случайных и берёт лучший.
const HOSTS = [
	'162.159.192', '162.159.195', '8.6.112', '8.34.70', '8.34.146', '8.35.211', '8.39.125',
	'8.39.204', '8.39.214', '8.47.69', '188.114.96', '188.114.97', '188.114.98', '188.114.99'
];
const PORTS = [
	500, 854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942,
	943, 945, 946, 955, 968, 987, 988, 1002, 1010, 1014, 1018, 1070, 1074, 1180, 1387,
	1701, 1843, 2371, 2408, 2506, 3138, 3476, 3581, 3854, 4177, 4198, 4233, 4500, 5279, 5956,
	7103, 7152, 7156, 7281, 7559, 8319, 8742, 8854, 8886
];

// Перед рукопожатием WireGuard — пакет QUIC Initial (ClientHello к обычному сайту) и несколько
// случайных: DPI принимает соединение за QUIC и не узнаёт в нём WireGuard.
const QUIC_MASKS = [
	'c10000000114367096bb0fb3f58f3a3fb8aaacd61d63a1c8a40e14f7374b8a62dccba6431716c3abf6f5afbcfb39bd00' +
		'8000047c32e268567c652e6f4db58bff759bc8c5aaca183b87cb4d22938fe7d8dca22a679a79e4d9ee62e4bbb3a380dd' +
		'78d4e8e48f26b38a1d42d76b371a5a9a0444827a69d1ab5872a85749f65a4104e931740b4dc1e2dd77733fc7fac4f930' +
		'11cd622f2bb47e85f71992e2d585f8dc765a7a12ddeb879746a267393ad023d267c4bd79f258703e27345155268bd3cc' +
		'0506ebd72e2e3c6b5b0f005299cd94b67ddabe30389c4f9b5c2d512dcc298c14f14e9b7f931e1dc397926c31fbb7cebf' +
		'c668349c218672501031ecce151d4cb03c4c660b6c6fe7754e75446cd7de09a8c81030c5f6fb377203f551864f3d83e2' +
		'7de7b86499736cbbb549b2f37f436db1cae0a4ea39930f0534aacdd1e3534bc87877e2afabe959ced261f228d6362e6f' +
		'd277c88c312d966c8b9f67e4a92e757773db0b0862fb8108d1d8fa262a40a1b4171961f0704c8ba314da2482ac8ed9bd' +
		'28d4b50f7432d89fd800c25a50c5e2f5c0710544fef5273401116aa0572366d8e49ad758fcb29e6a92912e644dbe227c' +
		'247cb3417eabfab2db16796b2fba420de3b1dc94e8361f1f324a331ddaf1e626553138860757fd0bf687566108b77b70' +
		'fb9f8f8962eca599c4a70ed373666961a8cb506b96756d9e28b94122b20f16b54f118c0e603ce0b831efea614ad836df' +
		'6cf9affbdd09596412547496967da758cec9080295d853b0861670b71d9abde0d562b1a6de82782a5b0c14d297f27283' +
		'a895abc889a5f6703f0e6eb95f67b2da45f150d0d8ab805612d570c2d5cb6997ac3a7756226c2f5c8982ffbd480c5004' +
		'b0660a3c9468945efde90864019a2b519458724b55d766e16b0da25c0557c01f3c11ddeb024b62e303640e17fdd57ded' +
		'b3aeb4a2c1b7c93059f9c1d7118d77caac1cd0f6556e46cbc991c1bb16970273dea833d01e5090d061a0c6d25af2415c' +
		'd2878af97f6d0e7f1f936247b394ecb9bd484da6be936dee9b0b92dc90101a1b4295e97a9772f2263eb09431995aa173' +
		'df4ca2abd687d87706f0f93eaa5e13cbe3b574fa3cfe94502ace25265778da6960d561381769c24e0cbd7aac73c16f95' +
		'ae74ff7ec38124f7c722b9cb151d4b6841343f29be8f35145e1b27021056820fed77003df8554b4155716c8cf6049ef5' +
		'e318481460a8ce3be7c7bfac695255be84dc491c19e9dedc449dd3471728cd2a3ee51324ccb3eef121e3e08f8e18f000' +
		'6ea8957371d9f2f739f0b89e4db11e5c6430ada61572e589519fbad4498b460ce6e4407fc2d8f2dd4293a50a0cb8fcaa' +
		'f35cd9a8cc097e3603fbfa08d9036f52b3e7fcce11b83ad28a4ac12dba0395a0cc871cefd1a2856fffb3f28d82ce35cf' +
		'80579974778bab13d9b3578d8c75a2d196087a2cd439aff2bb33f2db24ac175fff4ed91d36a4cdbfaf3f83074f03894e' +
		'a40f17034629890da3efdbb41141b38368ab532209b69f057ddc559c19bc8ae62bf3fd564c9a35d9a83d14a95834a92b' +
		'ae6d9a29ae5e8ece07910d16433e4c6230c9bd7d68b47de0de9843988af6dc88b5301820443bd4d0537778bf6b4c1dd0' +
		'67fcf14b81015f2a67c7f2a28f9cb7e0684d3cb4b1c24d9b343122a086611b489532f1c3a26779da1706c6759d96d8ab',
	'ce000000010897a297ecc34cd6dd000044d0ec2e2e1ea2991f467ace4222129b5a098823784694b4897b9986ae0b7280' +
		'135fa85e196d9ad980b150122129ce2a9379531b0fd3e871ca5fdb883c369832f730e272d7b8b74f393f9f0fa43f11e5' +
		'10ecb2219a52984410c204cf875585340c62238e14ad04dff382f2c200e0ee22fe743b9c6b8b043121c5710ec289f471' +
		'c91ee414fca8b8be8419ae8ce7ffc53837f6ade262891895f3f4cecd31bc93ac5599e18e4f01b472362b8056c3172b51' +
		'3051f8322d1062997ef4a383b01706598d08d48c221d30e74c7ce000cdad36b706b1bf9b0607c32ec4b3203a4ee21ab6' +
		'4df336212b9758280803fcab14933b0e7ee1e04a7becce3e2633f4852585c567894a5f9efe9706a151b615856647e8b7' +
		'dba69ab357b3982f554549bef9256111b2d67afde0b496f16962d4957ff654232aa9e845b61463908309cfd9de0a6abf' +
		'5f425f577d7e5f6440652aa8da5f73588e82e9470f3b21b27b28c649506ae1a7f5f15b876f56abc4615f49911549b9bb' +
		'39dd804fde182bd2dcec0c33bad9b138ca07d4a4a1650a2c2686acea05727e2a78962a840ae428f55627516e73c83dd8' +
		'893b02358e81b524b4d99fda6df52b3a8d7a5291326e7ac9d773c5b43b8444554ef5aea104a738ed650aa979674bbed3' +
		'8da58ac29d87c29d387d80b526065baeb073ce65f075ccb56e47533aef357dceaa8293a523c5f6f790be90e4731123d3' +
		'c6152a70576e90b4ab5bc5ead01576c68ab633ff7d36dcde2a0b2c68897e1acfc4d6483aaaeb635dd63c96b2b6a7a2bf' +
		'e042f6aed82e5363aa850aace12ee3b1a93f30d8ab9537df483152a5527faca21efc9981b304f11fc95336f5b9637b17' +
		'4c5a0659e2b22e159a9fed4b8e93047371175b1d6d9cc8ab745f3b2281537d1c75fb9451871864efa5d184c38c185fd2' +
		'03de206751b92620f7c369e031d2041e152040920ac2c5ab5340bfc9d0561176abf10a147287ea90758575ac6a9f5ac9' +
		'f390d0d5b23ee12af583383d994e22c0cf42383834bcd3ada1b3825a0664d8f3fb678261d57601ddf94a8a68a7c273a1' +
		'8c08aa99c7ad8c6c42eab67718843597ec9930457359dfdfbce024afc2dcf9348579a57d8d3490b2fa99f278f1c37d87' +
		'dad9b221acd575192ffae1784f8e60ec7cee4068b6b988f0433d96d6a1b1865f4e155e9fe020279f434f3bf1bd117b71' +
		'7b92f6cd1cc9bea7d45978bcc3f24bda631a36910110a6ec06da35f8966c9279d130347594f13e9e07514fa370754d14' +
		'24c0a1545c5070ef9fb2acd14233e8a50bfc5978b5bdf8bc1714731f798d21e2004117c61f2989dd44f0cf027b27d401' +
		'9e81ed4b5c31db347c4a3a4d85048d7093cf16753d7b0d15e078f5c7a5205dc2f87e330a1f716738dce1c6180e9d0286' +
		'9b5546f1c4d2748f8c90d9693cba4e0079297d22fd61402dea32ff0eb69ebd65a5d0b687d87e3a8b2c42b648aa723c7c' +
		'7daf37abcc4bb85caea2ee8f55bec20e913b3324ab8f5c3304f820d42ad1b9f2ffc1a3af9927136b4419e1e579ab4c2a' +
		'e3c776d293d397d575df181e6cae0a4ada5d67ecea171cca3288d57c7bbdaee3befe745fb7d634f70386d873b90c4d6c' +
		'6596bb65af68f9e5121e67ebf0d89d3c909ceedfb32ce9575a7758ff080724e1ab5d5f43074ecb53a479af21ed03d7b6' +
		'899c36631c0166f9d47e5e1d4528a5d3d3f744029c4b1c190cbfbad06f5f83f7ad0429fa9a2719c56ffe3783460e166d' +
		'e2d8'
];

// Маска для узла: всегда одна и та же у одного ключа — иначе конфиг xray менялся бы при каждой
// сборке, и xray перезапускался бы на каждый reload. reset — через сколько секунд тишины маска
// уходит снова: после паузы DPI видит соединение как новое.
export function quic_noise(n) {
	let mask = QUIC_MASKS[hex(substr(fnv1a(n.secret_key || ''), 7)) % length(QUIC_MASKS)];
	let noise = [ { type: 'hex', packet: mask, delay: '1-2' } ];
	for (let i = 0; i < 8; i++)
		push(noise, { rand: '23-911', delay: '1-3' });
	return { type: 'noise', settings: { reset: '30-60', noise } };
};

// count случайных адресов WARP без повторов.
export function random_endpoints(count) {
	let r = readfile('/dev/urandom', count * 6) || '';
	let res = [];
	for (let i = 0; i < count * 2 && length(res) < count; i++) {
		let b = (j) => ord(r, i * 3 + j) ?? (i * 7 + j);
		let ep = `${HOSTS[b(0) % length(HOSTS)]}.${b(1) % 254 + 1}:${PORTS[b(2) % length(PORTS)]}`;
		if (!(ep in res))
			push(res, ep);
	}
	return res;
};

// Ссылка wireguard:// (как у v2rayN) с маской QUIC. w: { secret_key, public_key, v4, v6,
// reserved: [a, b, c], endpoint, name }.
export function warp_link(w) {
	let addr = [ `${split(w.v4, '/')[0]}/32`, ...(w.v6 ? [ `${split(w.v6, '/')[0]}/128` ] : []) ];
	return sprintf('wireguard://%s@%s?publickey=%s&address=%s%s&mtu=1280&noise=quic#%s',
		pctenc(w.secret_key), w.endpoint, pctenc(w.public_key || WARP_PEER_KEY), pctenc(join(',', addr)),
		length(w.reserved) == 3 ? `&reserved=${join(',', w.reserved)}` : '', pctenc(w.name || 'WARP'));
};

// Время для поля tos регистрации — как у клиента, ISO 8601.
export function iso_time(ts) {
	let t = gmtime(ts);
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
};
