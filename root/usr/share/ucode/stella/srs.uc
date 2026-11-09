// Наборы правил sing-box (.srs): так russia-v2ray-rules-dat (runetfreedom) раздаёт geosite и
// geoip — по набору в файле. Из набора берутся домены и подсети IPv4, как из текстовых
// списков; ключевые слова и регулярные выражения dnsmasq не умеет — они пропускаются.
//
// Файл: «SRS», байт версии, дальше поток zlib: число правил, у правила — пункты до 0xFF.
// Домены лежат префиксным деревом (LOUDS): узлы по порядку обхода в ширину, у каждого — по
// нулевому биту на ребёнка (буква ребёнка — следующая в labels) и единица в конце; бит leaves
// отмечает узел, на котором кончается запись. Записи — домены задом наперёд, и у суффикса
// («домен и поддомены») в конце служебный символ.

'use strict';

const ITEM_DOMAIN = 2, ITEM_KEYWORD = 3, ITEM_REGEX = 4, ITEM_IPCIDR = 6, ITEM_FINAL = 0xff;

function uvarint(st) {
	let x = 0;
	for (let s = 0; ; s += 7) {
		let b = ord(st.d, st.o++);
		if (b == null)
			die('обрыв данных');
		x |= (b & 0x7f) << s;
		if (b < 0x80)
			return x;
	}
}

// Бит i массива uint64, записанного по big-endian: младший бит слова — первый.
function bit(d, off, i) {
	return (ord(d, off + (i >> 6) * 8 + 7 - ((i & 63) >> 3)) >> (i & 7)) & 1;
}

function skip_strings(st) {
	for (let n = uvarint(st); n > 0; n--)
		st.o += uvarint(st);
}

// Домен из записи: буквы уже в прямом порядке (каждая следующая — впереди), остаётся снять
// служебный символ суффикса и точку за ним. Домен всегда с поддоменами, как в dnsmasq, —
// запись «только сам домен» и суффикс сливаются в одну. Не ASCII (кириллические домены
// antifilter) dnsmasq не примет — такие пропускаются, как и в текстовых списках.
function add_domain(k, out) {
	let i = 0;
	while (i < length(k) && (ord(k, i) < 0x21 || substr(k, i, 1) == '.'))
		i++;
	k = lc(i ? substr(k, i) : k);
	if (match(k, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/))
		out.domains[k] = true;
}

function read_domains(st, out) {
	st.o++;  // версия дерева
	let nl = uvarint(st), lo = st.o;
	st.o += nl * 8;
	let nb = uvarint(st), bo = st.o;
	st.o += nb * 8;
	let nlab = uvarint(st), labels = substr(st.d, st.o, nlab);
	st.o += nlab;

	// Очередь узлов, у которых ещё не разобраны дети: обход в ширину создаёт их по порядку.
	// Биты — по байтам: внутри слова uint64 (big-endian) младший бит первый. done — сколько
	// узлов уже снято с начала очереди (их не держим).
	let queue = [ '' ], head = 0, done = 0, li = 0, d = st.d;
	for (let w = 0; w < nb; w++)
		for (let j = 7; j >= 0; j--) {
			let byte = ord(d, bo + w * 8 + j);
			for (let b = 0; b < 8; b++, byte >>= 1) {
				if (!(byte & 1)) {
					push(queue, substr(labels, li++, 1) + queue[head]);
					continue;
				}
				// Дети узла кончились: он разобран.
				let node = done + head;
				if ((node >> 6) < nl && bit(d, lo, node))
					add_domain(queue[head], out);
				if (++head >= length(queue))
					return;
				if (head >= 4096) {
					splice(queue, 0, head);
					done += head;
					head = 0;
				}
			}
		}
}

function ip4(n) {
	return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
}

// Диапазон адресов — наименьшим числом подсетей.
function range_cidrs(a, b, out) {
	while (a <= b) {
		let bits = 0;
		while (bits < 32 && !((a >> bits) & 1) && a + (1 << (bits + 1)) - 1 <= b)
			bits++;
		out.cidrs[`${ip4(a)}/${32 - bits}`] = true;
		a += 1 << bits;
	}
}

function read_addr(st) {
	let n = uvarint(st), v = substr(st.d, st.o, n);
	st.o += n;
	return v;
}

function read_ipset(st, out) {
	st.o++;  // версия
	let n = 0;
	for (let i = 0; i < 8; i++)
		n = n * 256 + ord(st.d, st.o++);
	for (; n > 0; n--) {
		let a = read_addr(st), b = read_addr(st);
		if (length(a) != 4 || length(b) != 4)
			continue;   // IPv6
		let x = 0, y = 0;
		for (let i = 0; i < 4; i++) {
			x = x * 256 + ord(a, i);
			y = y * 256 + ord(b, i);
		}
		range_cidrs(x, y, out);
	}
}

// { domains, cidrs } — как у parse_list. Не набор — null; набор не разобрался — { error }.
// Распаковке нужен пакет ucode-mod-zlib.
export function parse_srs(data) {
	if (type(data) != 'string' || substr(data, 0, 3) != 'SRS')
		return null;
	let zlib;
	try {
		zlib = require('zlib');
	}
	catch (e) {
		return { error: 'нужен пакет ucode-mod-zlib' };
	}
	let out = { domains: {}, cidrs: {} };
	try {
		let st = { d: zlib.inflate(substr(data, 4)), o: 0 };
		if (type(st.d) != 'string')
			return { error: 'набор повреждён' };
		for (let rules = uvarint(st); rules > 0; rules--) {
			if (ord(st.d, st.o++) != 0)
				return { error: 'составные правила не поддерживаются' };
			for (let item = ord(st.d, st.o++); item != ITEM_FINAL; item = ord(st.d, st.o++)) {
				if (item == ITEM_DOMAIN)
					read_domains(st, out);
				else if (item == ITEM_KEYWORD || item == ITEM_REGEX)
					skip_strings(st);
				else if (item == ITEM_IPCIDR)
					read_ipset(st, out);
				else if (item == null)
					return { error: 'набор оборван' };
				else
					return { error: `неизвестный пункт правила ${item}` };
			}
			st.o++;  // invert
		}
	}
	catch (e) {
		return { error: 'набор повреждён' };
	}
	return { domains: sort(keys(out.domains)), cidrs: sort(keys(out.cidrs)) };
};
