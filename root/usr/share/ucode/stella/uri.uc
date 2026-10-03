// Разбор share-ссылок в нормализованный узел.
// Формат ссылок: https://github.com/XTLS/Xray-core/discussions/716
//
// Узел:
//   { name, protocol, address, port,
//     uuid, flow, encryption, password, method, auth,        — протокол
//     network, security, sni, fp, alpn, pbk, sid, spx, pqv,
//     ech, pcs, vcn, path, host, mode, extra, service_name,
//     authority, header_type, ports, obfs, obfs_password,  — транспорт
//     fm, warnings }
// При ошибке parse() возвращает { error: '...' }.

'use strict';

import { b64dec_loose, urldecode, pctdecode, parse_url, valid_port, split_list, try_json } from 'stella.util';

const NETWORKS = {
	'': 'raw', raw: 'raw', tcp: 'raw',
	xhttp: 'xhttp', splithttp: 'xhttp',
	ws: 'ws', websocket: 'ws',
	httpupgrade: 'httpupgrade',
	grpc: 'grpc', gun: 'grpc'
};

const SS_METHODS = {
	'2022-blake3-aes-128-gcm': true,
	'2022-blake3-aes-256-gcm': true,
	'2022-blake3-chacha20-poly1305': true,
	'aes-128-gcm': true,
	'aes-256-gcm': true,
	'chacha20-poly1305': true,
	'chacha20-ietf-poly1305': true,
	'xchacha20-poly1305': true,
	'xchacha20-ietf-poly1305': true
};

function json_param(node, q, key) {
	if (!q[key])
		return null;
	let v = try_json(q[key]);
	if (type(v) != 'object') {
		push(node.warnings, `параметр ${key} не является JSON-объектом, пропущен`);
		return null;
	}
	return v;
}

// Общие для vless/vmess/trojan параметры транспорта и безопасности.
function apply_stream(node, q, default_security) {
	let net = NETWORKS[lc(q.type || '')];
	if (!net)
		return `транспорт "${q.type}" не поддерживается`;
	node.network = net;

	let sec = lc(q.security || default_security);
	if (sec == 'xtls')
		sec = 'tls';
	if (!(sec in ['none', 'tls', 'reality']))
		return `security "${sec}" не поддерживается`;
	node.security = sec;

	if (sec == 'reality') {
		if (!q.pbk)
			return 'REALITY без pbk';
		if (!(net in ['raw', 'xhttp', 'grpc']))
			return `REALITY несовместим с транспортом ${net}`;
		node.pbk = q.pbk;
		node.sid = q.sid || '';
		node.spx = q.spx || null;
		node.pqv = q.pqv || null;
	}

	if (sec != 'none') {
		node.sni = q.sni || q.peer || null;
		node.fp = q.fp || 'chrome';
		node.alpn = split_list(q.alpn);
		if (sec == 'tls') {
			node.ech = q.ech || null;
			node.pcs = q.pcs || null;
			node.vcn = q.vcn || null;
			if (q.allowInsecure in ['1', 'true'] || q.insecure in ['1', 'true'])
				push(node.warnings, 'allowInsecure удалён из xray 26.x и проигнорирован; при самоподписанном сертификате нужен pcs');
		}
	}

	node.path = q.path || null;
	node.host = q.host || null;

	switch (net) {
	case 'raw':
		if (q.headerType == 'http')
			node.header_type = 'http';
		else if (q.headerType && q.headerType != 'none')
			return `headerType "${q.headerType}" не поддерживается`;
		break;

	case 'xhttp':
		node.mode = q.mode || 'auto';
		node.extra = json_param(node, q, 'extra');
		break;

	case 'grpc':
		node.service_name = q.serviceName || q.path || '';
		node.authority = q.authority || null;
		node.mode = (q.mode == 'multi') ? 'multi' : 'gun';
		node.path = null;
		break;
	}

	node.fm = json_param(node, q, 'fm');
	return null;
}

function new_node(protocol, u) {
	return {
		name: u.fragment || '',
		protocol,
		address: u.host,
		port: valid_port(u.port),
		warnings: []
	};
}

function check_endpoint(node) {
	if (!node.address)
		return 'не указан адрес сервера';
	if (!node.port)
		return 'некорректный порт';
	return null;
}

function parse_vless(u) {
	let node = new_node('vless', u);
	node.uuid = pctdecode(u.userinfo);
	if (!node.uuid)
		return { error: 'не указан UUID' };

	let q = u.query;
	node.encryption = q.encryption || 'none';
	node.flow = q.flow || null;

	let err = check_endpoint(node) || apply_stream(node, q, 'none');
	if (err)
		return { error: err };

	if (node.flow && !(node.network == 'raw' && node.security != 'none'))
		return { error: 'flow допустим только с raw + tls/reality' };
	if (node.security == 'none' && node.encryption == 'none')
		push(node.warnings, 'VLESS без шифрования: трафик не защищён');

	return node;
}

function parse_trojan(u) {
	let node = new_node('trojan', u);
	node.password = pctdecode(u.userinfo);
	if (!node.password)
		return { error: 'не указан пароль' };

	let err = check_endpoint(node) || apply_stream(node, u.query, 'tls');
	return err ? { error: err } : node;
}

// vmess://base64(json) — формат v2rayN; иначе стандартный URI.
function parse_vmess(s, u) {
	let body = substr(s, length('vmess://'));
	let hash = index(body, '#');
	let raw = b64dec_loose((hash < 0) ? body : substr(body, 0, hash));
	let j = raw ? try_json(raw) : null;

	if (type(j) != 'object') {
		if (!u || !u.userinfo)
			return { error: 'не удалось разобрать vmess' };
		let node = new_node('vmess', u);
		node.uuid = pctdecode(u.userinfo);
		node.encryption = u.query.encryption || 'auto';
		let err = check_endpoint(node) || apply_stream(node, u.query, 'none');
		return err ? { error: err } : node;
	}

	let node = {
		name: j.ps || '',
		protocol: 'vmess',
		address: j.add,
		port: valid_port(j.port),
		uuid: j.id,
		encryption: j.scy || 'auto',
		warnings: []
	};
	if (!node.uuid)
		return { error: 'не указан UUID' };
	if (+j.aid > 0)
		return { error: 'VMess с alterId > 0 удалён из xray' };

	let q = {
		type: j.net || 'tcp',
		security: j.tls || 'none',
		sni: j.sni,
		fp: j.fp,
		alpn: j.alpn,
		path: j.path,
		host: j.host,
		headerType: j.type,
		serviceName: j.path,
		mode: j.mode
	};
	// В json-формате для grpc поле type означает режим, а не заголовок.
	if (q.type == 'grpc') {
		q.mode = j.type;
		q.headerType = null;
	}
	if (q.type == 'xhttp' || q.type == 'splithttp')
		q.headerType = null;

	let err = check_endpoint(node) || apply_stream(node, q, 'none');
	return err ? { error: err } : node;
}

// ss://base64(method:password)@host:port#name   (SIP002)
// ss://method:password@host:port#name           (percent-encoded, часто для 2022)
// ss://base64(method:password@host:port)#name   (старый формат)
function parse_ss(s, u) {
	let method, password;

	if (u && u.userinfo != null) {
		let ui = pctdecode(u.userinfo);
		let dec = (index(ui, ':') < 0) ? b64dec_loose(ui) : ui;
		if (!dec || index(dec, ':') < 0)
			return { error: 'не удалось разобрать userinfo' };
		let i = index(dec, ':');
		method = substr(dec, 0, i);
		password = substr(dec, i + 1);
	}
	else {
		let body = substr(s, length('ss://'));
		let hash = index(body, '#');
		let name = (hash < 0) ? '' : pctdecode(substr(body, hash + 1));
		let dec = b64dec_loose((hash < 0) ? body : substr(body, 0, hash));
		let m = dec ? match(dec, /^([^:]+):(.*)@([^@]+)$/) : null;
		if (!m)
			return { error: 'не удалось разобрать ss' };
		method = m[1];
		password = m[2];
		u = parse_url(`ss://x@${m[3]}#${name}`);
		if (!u)
			return { error: 'не удалось разобрать адрес' };
		u.query = {};
	}

	method = lc(method);
	if (!SS_METHODS[method])
		return { error: `метод шифрования ${method} не поддерживается xray` };
	if (u.query.plugin)
		return { error: 'плагины shadowsocks не поддерживаются xray' };

	let node = new_node('shadowsocks', u);
	node.method = method;
	node.password = password;
	node.network = 'raw';
	node.security = 'none';

	let err = check_endpoint(node);
	return err ? { error: err } : node;
}

// hysteria2://auth@host:port[,ports]/?sni=&obfs=salamander&obfs-password=&pinSHA256=&mport=
function parse_hysteria2(u) {
	let q = u.query;
	let node = {
		name: u.fragment || '',
		protocol: 'hysteria',
		address: u.host,
		auth: pctdecode(u.userinfo || q.auth || ''),
		network: 'hysteria',
		security: 'tls',
		warnings: []
	};

	// Порт может быть списком/диапазоном — это port hopping.
	let ports = u.port || '443';
	if (match(ports, /^[0-9]+$/))
		node.port = valid_port(ports);
	else if (match(ports, /^[0-9, -]+$/)) {
		node.ports = replace(ports, / /g, '');
		node.port = valid_port(match(node.ports, /^[0-9]+/)?.[0]);
	}
	if (q.mport)
		node.ports = replace(q.mport, / /g, '');

	let err = check_endpoint(node);
	if (err)
		return { error: err };

	node.sni = q.sni || q.peer || null;
	node.alpn = split_list(q.alpn);
	node.pcs = q.pinSHA256 || q.pcs || null;
	node.fp = q.fp || null;
	node.ech = q.ech || null;
	node.vcn = q.vcn || null;

	if (q.obfs) {
		if (q.obfs != 'salamander')
			return { error: `obfs "${q.obfs}" не поддерживается` };
		node.obfs = 'salamander';
		node.obfs_password = q['obfs-password'] || '';
	}

	if ((q.insecure in ['1', 'true'] || q.allowInsecure in ['1', 'true']) && !node.pcs)
		push(node.warnings, 'insecure=1 без pinSHA256: xray 26.x не умеет отключать проверку сертификата');

	node.fm = json_param(node, q, 'fm');
	return node;
}

export function parse(s) {
	s = trim(s || '');
	let sm = match(s, /^([a-zA-Z0-9]+):\/\//);
	if (!sm)
		return { error: 'не ссылка' };

	let scheme = lc(sm[1]);
	let u = parse_url(s);
	let node;

	switch (scheme) {
	case 'vless':
		node = u ? parse_vless(u) : { error: 'некорректная ссылка' };
		break;
	case 'vmess':
		node = parse_vmess(s, u);
		break;
	case 'trojan':
		node = u ? parse_trojan(u) : { error: 'некорректная ссылка' };
		break;
	case 'ss':
		node = parse_ss(s, u);
		break;
	case 'hysteria2':
	case 'hy2':
		node = u ? parse_hysteria2(u) : { error: 'некорректная ссылка' };
		break;
	default:
		node = { error: `протокол ${scheme} не поддерживается` };
	}

	if (!node.error && node.name == '')
		node.name = `${node.address}:${node.port}`;
	return node;
};
