// Разбор тела подписки: base64 или открытый список ссылок, по одной в строке.

'use strict';

import { b64dec_loose, fnv1a } from 'stella.util';
import { parse } from 'stella.uri';

function looks_like_links(s) {
	return match(s, /^[ \t\r\n]*[a-zA-Z0-9]+:\/\//) != null;
}

// Возвращает { nodes: [...], errors: [{ line, error }] }.
// id узла = <prefix>_<хеш названия, адреса и порта>: выбор сервера переживает
// обновление подписки, даже если провайдер сменил ключи или параметры ссылки.
export function decode(body, prefix) {
	let text = body || '';
	if (!looks_like_links(text)) {
		let dec = b64dec_loose(text);
		if (dec && looks_like_links(dec))
			text = dec;
	}

	let nodes = [], errors = [], seen_link = {}, seen_id = {};
	for (let line in split(text, /\r?\n/)) {
		line = trim(line);
		if (line == '' || substr(line, 0, 1) == '#')
			continue;

		let n = parse(line);
		if (n.error) {
			push(errors, { line: substr(line, 0, 64), error: n.error });
			continue;
		}

		if (seen_link[line])
			continue;
		seen_link[line] = true;

		let key = `${n.name}|${n.address}|${n.port}`;
		let id = `${prefix}_${fnv1a(key)}`;
		for (let i = 1; seen_id[id]; i++)
			id = `${prefix}_${fnv1a(`${key}|${i}`)}`;
		seen_id[id] = true;

		n.id = id;
		push(nodes, n);
	}

	return { nodes, errors };
};
