// Заглушка модуля uci для локальных тестов: конфиг берётся из JSON-файла $STELLA_UCI_JSON
// вида { "<секция>": { ".type": "...", "опция": "значение" }, ... } в порядке объявления.
// Секции с именем cfgXXXXXX считаются анонимными, commit() пишет JSON обратно.

'use strict';

import { readfile, writefile } from 'fs';

export function cursor() {
	let path = getenv('STELLA_UCI_JSON');
	let conf = json(readfile(path));

	return {
		load: (pkg) => true,
		get: (pkg, sec, opt) => (opt == null) ? conf[sec]?.['.type'] : conf[sec]?.[opt],
		set: (pkg, sec, opt, val) => {
			if (val == null)
				conf[sec] = { '.type': opt };
			else
				conf[sec][opt] = val;
			return true;
		},
		rename: (pkg, sec, name) => {
			let res = {};
			for (let k, v in conf)
				res[(k == sec) ? name : k] = v;
			conf = res;
			return true;
		},
		delete: (pkg, sec, opt) => {
			if (opt == null)
				delete conf[sec];
			else if (conf[sec])
				delete conf[sec][opt];
			return true;
		},
		commit: (pkg) => writefile(path, sprintf('%J', conf)) != null,
		foreach: (pkg, type, cb) => {
			for (let name, s in conf) {
				if (s['.type'] != type)
					continue;
				if (cb({ ...s, '.name': name, '.anonymous': match(name, /^cfg[0-9a-f]{6}$/) != null }) === false)
					break;
			}
		}
	};
};
