'use strict';
'require baseclass';
'require rpc';
'require ui';
'require uci';

// Общее для страниц Stella: стили, выпадающие списки с готовыми вариантами, время, склонение,
// запись настроек.

// Звёздочка автовыбора — свой SVG: символ Юникода в каждом шрифте рисуется по-своему.
const STAR = '<polygon points="12 2 15.1 8.3 22 9.3 17 14.1 18.2 21 12 17.8 5.8 21 7 14.1 2 9.3 8.9 8.3 12 2"/>';

const callInit = rpc.declare({ object: 'luci', method: 'setInitAction', params: [ 'name', 'action' ] });
const callCommit = rpc.declare({ object: 'uci', method: 'commit', params: [ 'config' ], reject: true });
const callRevert = rpc.declare({ object: 'uci', method: 'revert', params: [ 'config' ] });
const callHostHints = rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callNetDevices = rpc.declare({ object: 'luci-rpc', method: 'getNetworkDevices', expect: { '': {} } });

// Пока правка идёт на роутер, LuCI не узнаёт о перечитанном конфиге: иначе между отправкой и
// записью он показал бы вверху «Непринятые изменения», хотя они тут же записываются.
let writing = false;
window.addEventListener('uci-loaded', (ev) => { if (writing) ev.stopPropagation(); }, true);

// Правки конфига идут по одной: следующая ждёт, пока прежняя дойдёт до роутера.
let queue = Promise.resolve();

// Что вводится руками (свой вариант в списке, поле портов): [ настройки, вид значения, сообщение ].
const CHECKS = [
	[ /_interval$|^zapret_test_/, /^[0-9]{1,4}$/, _('Нужно число.') ],
	[ /_ports$/, /^([0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)?$/, _('Порты через запятую: 80,443,1000-2000.') ]
];

// Версия модуля. LuCI запрашивает его по адресу со своей версией, а не Stella, и uhttpd не
// запрещает кэш: после обновления Stella браузер может днями брать прежний модуль из кэша.
// Страницы вызывают need() с нужной им версией; повышать, когда страницам нужно новое отсюда.
const API = 21;

// Расписания в часах — одни для всех: подписки, списки, подбор узла, автообновление.
const HOURS = [ [ '0', _('вручную') ], [ '1', _('каждый час') ], [ '3', _('каждые 3 ч') ], [ '6', _('каждые 6 ч') ],
	[ '12', _('каждые 12 ч') ], [ '24', _('раз в сутки') ], [ '168', _('раз в неделю') ] ];

// Пункт «-- Please choose --» Combobox добавляет всегда (optional у него не отключить), а
// значение у наших списков есть всегда — в раскрытом списке он скрыт (правило темы с
// !important перебивается тем же селектором с body впереди; стили — только на страницах Stella).
// Страницы Stella — из стоковых частей LuCI, в одном стиле с главной («Состояние → Обзор»):
// разделы cbi-section с заголовком h3, строки «подпись | значение» — таблицей (подпись слева,
// треть ширины) и на страницах, и в окнах, пояснения cbi-value-description, таблицы
// cbi-section-table с заглушкой, когда пусто, сортировкой по заголовку столбца (как у таблиц
// форм LuCI) и «Добавить» под ними (cbi-section-create). Своё — только то, чего в LuCI нет:
// звёздочки, цвета задержки и состояний, строка поиска, сворачиваемый раздел с кнопками в
// заголовке (группы узлов, серверы DNS).
const CSS = `
.st-info .cbi-dropdown { min-width:12em; max-width:100% }
.st-info .cbi-dynlist { min-width:20em }
.modal .st-info .td:first-child { width:30% }
.modal .st-info textarea, .modal .st-info input[type=text] { width:100% }
.st-info > .tr > .td { vertical-align:top }
.st-kl { position:sticky; top:4.5em; min-height:30px; display:flex; align-items:center }
.modal .st-kl { top:.5em }
.st-row { display:flex; flex-wrap:wrap; gap:.4em .8em; align-items:center; min-height:30px }
.st-full { flex-basis:100% }
.st-row > .cbi-value-description { flex-basis:100%; margin-top:0 }
.st-group { margin-bottom:1.5em }
.st-group > summary { display:flex; flex-wrap:wrap; gap:.3em .8em; align-items:center; cursor:pointer; list-style:none; padding:.2em 0 .5em }
.st-group > summary::-webkit-details-marker { display:none }
.st-group > summary::before { content:'▸'; width:1em; font-size:130%; opacity:.7 }
.st-group[open] > summary::before { content:'▾' }
.st-group > summary > h3 { display:inline; margin:0; padding:0; border:0 }
.st-group .st-meta { opacity:.6; font-size:90% }
.st-group .st-actions { margin-left:auto; display:flex; flex-wrap:wrap; gap:.25em }
.st-buttons { display:flex; flex-wrap:wrap; gap:.5em; margin-top:1em }
.st-bar { display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:0 0 1em }
.st-bar input[type=text] { flex:1; min-width:10em }
.st-table .td, .st-table .th { vertical-align:middle }
body .cbi-dropdown[optional][open] > ul.dropdown > li[placeholder] { display:none !important }
.st-act, .table .td.st-act { text-align:right; white-space:nowrap; width:1% }
.st-ok { color:#2a2 } .st-mid { color:#b90 } .st-slow { color:#d60 } .st-bad { color:#c33 } .st-dim { opacity:.6 }
.st-ico { display:inline-block; vertical-align:middle; line-height:1 }
.st-ico svg { display:block; width:15px; height:15px; fill:none; stroke:currentColor; stroke-width:2; stroke-linecap:round; stroke-linejoin:round }
.st-ico.filled svg { fill:currentColor }
@media (max-width:854px) { .st-info .td:first-child { flex-basis:100%; font-weight:bold } .st-info .td + .td { flex-basis:100% } .st-kl { position:static; min-height:0 } }
`;

function injectCss() {
	if (document.getElementById('stella-ui-css'))
		return;
	document.head.appendChild(E('style', { 'id': 'stella-ui-css' }, CSS));
}

return baseclass.extend({
	__init__() {
		injectCss();
	},

	star(filled) {
		const el = E('span', { 'class': 'st-ico' + (filled ? ' filled' : '') });
		el.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + STAR + '</svg>';
		return el;
	},

	// Для load() страницы: модуль из кэша браузера старее нужного — скачать его заново и
	// перезагрузить страницу (один раз за сеанс, чтобы не зациклиться).
	need(api) {
		if (API >= api)
			return Promise.resolve();
		try {
			if (sessionStorage.getItem('stella-common') == String(api))
				return Promise.resolve();
			sessionStorage.setItem('stella-common', String(api));
		}
		catch (e) {}
		return fetch(L.env.base_url + '/stella/common.js' + (L.env.resource_version ? '?v=' + L.env.resource_version : ''), { cache: 'reload' })
			.then(() => { location.reload(); return new Promise(() => {}); });
	},

	// Строка «подпись | значение», как на «Состояние → Обзор»: подпись слева, треть ширины,
	// значения в строку, пояснение под ними. Массив — чтобы строки собирались через «...».
	// Подпись стоит у верха строки и при прокрутке длинного значения (каталог списков, серверы
	// DNS) остаётся на виду, а не уезжает в середину или за край.
	kv(label, value, title) {
		return [ E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%', 'title': title || null }, E('div', { 'class': 'st-kl' }, label)),
			E('td', { 'class': 'td left' }, E('div', { 'class': 'st-row' }, value))
		]) ];
	},

	// Строки kv — таблицей.
	card(rows, cls) {
		return E('table', { 'class': 'table st-info' + (cls ? ' ' + cls : '') }, rows);
	},

	// Флажок, как у форм LuCI (ui.Checkbox): подпись — у строки, рядом только флажок.
	checkbox(on, onchange) {
		const w = new ui.Checkbox(on ? '1' : '0', { value_enabled: '1', value_disabled: '0' });
		const el = w.render();
		el.addEventListener('widget-change', () => onchange(w.isChecked()));
		return el;
	},

	// Пояснение под значением — как у полей форм LuCI.
	hint(text) {
		return E('div', { 'class': 'cbi-value-description' }, [ text ]);
	},

	// Раздел страницы, как у форм LuCI: cbi-section, заголовок h3 внутри.
	section(title, content) {
		return E('div', { 'class': 'cbi-section' }, [ title ? E('h3', {}, title) : '', ...[].concat(content) ]);
	},

	// Таблица без сортировки (списки: порядок строк — это порядок проверки), собирается вручную:
	// на телефоне тема показывает строки карточками, подписи — из заголовков столбцов (data-title
	// у ячеек). heads — [ подпись | [ подпись, атрибуты ] ]; empty — текст заглушки, когда строк нет.
	table(heads, rows, cls, empty) {
		return E('table', { 'class': 'table cbi-section-table st-table' + (cls ? ' ' + cls : '') }, [
			E('tr', { 'class': 'tr table-titles' }, heads.map((h) => Array.isArray(h) ? E('th', Object.assign({ 'class': 'th' }, h[1]), h[0]) : E('th', { 'class': 'th' }, h))),
			...(rows.length || !empty ? rows : [ E('tr', { 'class': 'tr placeholder' }, E('td', { 'class': 'td' }, E('em', {}, [ empty ]))) ])
		]);
	},

	// Таблица данных — стоковый виджет LuCI (ui.Table): сортировка щелчком по заголовку (LuCI её
	// запоминает), заглушка, когда пусто, подписи столбцов на телефоне. id — имя таблицы на странице;
	// columns — [ заголовок | [ заголовок, класс ячеек ] ]; rows — [ { cells, cls } ]: ячейка —
	// текст или один элемент (сортируется по его data-value, иначе по тексту), cls — класс строки.
	// Столбец кнопок — с классом cbi-section-actions: по нему не сортируют.
	dataTable(id, columns, rows, cls, empty) {
		const t = new ui.Table(columns.map((c) => [].concat(c)[0]), {
			id, classes: [ 'cbi-section-table', 'st-table' ].concat(cls || []),
			captionClasses: columns.map((c) => [].concat(c)[1] || null)
		});
		// Виджет при каждой сортировке собирает строки заново — классы строк возвращаются здесь.
		const update = t.update.bind(t);
		t.update = (data, text) => {
			const node = update(data, text);
			node.querySelectorAll('.tr:not(.table-titles):not(.placeholder)').forEach((tr, i) => {
				if (data[i] && data[i].cls)
					tr.classList.add(data[i].cls);
			});
			return node;
		};
		// Текст — элементом: голую строку виджет вставил бы как HTML (а имена приходят из подписок).
		const cell = (c) => (typeof c == 'string') ? E('span', {}, [ c ]) : c;
		return t.update(rows.map((r) => Object.assign(r.cells.map(cell), { cls: r.cls })), E('em', {}, [ empty ]));
	},

	tr(cells, cls) {
		return E('tr', { 'class': 'tr' + (cls ? ' ' + cls : '') }, cells);
	},

	td(title, content, cls, attrs) {
		return E('td', Object.assign({ 'class': 'td' + (cls ? ' ' + cls : ''), 'data-title': title || null }, attrs || {}), content);
	},

	// «Добавить» под таблицей, как у таблиц форм LuCI.
	create(label, handler) {
		return E('div', { 'class': 'cbi-section-create' },
			E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': handler }, label));
	},

	// Кнопка в строке таблицы, как в таблицах форм LuCI: cls — edit, remove, action…
	rowButton(label, cls, handler) {
		return E('button', { 'class': 'btn cbi-button cbi-button-' + cls, 'click': ui.createHandlerFn(this, handler) }, label);
	},

	// Поле в окне — такой же строкой «подпись | значение», окно собирает их в card().
	field(label, content) {
		return this.kv(label, [].concat(content))[0];
	},

	dim(text) {
		return E('span', { 'class': 'st-dim' }, [ text ]);
	},

	// Время событий везде одинаково — с датой и секундами.
	time(ts) {
		return new Date(ts * 1000).toLocaleString('ru-RU');
	},

	// Расписание в часах (0 — вручную) с готовыми вариантами.
	hours(value, onchange) {
		return this.combo(value, HOURS, onchange, { custom_placeholder: _('часов…') });
	},

	// Выпадающие списки — только виджеты LuCI, а не <select> браузера: у них другие отступы и
	// стрелка. choices — [ [значение, подпись] ] в нужном порядке; подпись может быть элементом.
	// Виджет сообщает об изменении и при простом закрытии списка — поэтому onchange зовётся,
	// только если значение действительно стало другим.
	dropdown(widget, value, choices, onchange, opts) {
		value = (value == null) ? '' : String(value);
		const w = new widget(value, Object.fromEntries(choices), Object.assign({ sort: choices.map((c) => c[0]) }, opts));
		const el = w.render();
		let last = value;
		el.addEventListener('widget-change', () => {
			const v = w.getValue();
			if (v == null || v === last || (v === '' && widget === ui.Combobox))
				return;
			last = v;
			onchange(v);
		});
		return el;
	},

	// Готовые варианты и своё значение.
	combo(value, choices, onchange, opts) {
		return this.dropdown(ui.Combobox, value, choices, onchange, Object.assign({ custom_placeholder: _('свой вариант…') }, opts));
	},

	// Только готовые варианты (пустое значение — обычный вариант; снять выбор нельзя).
	// Значения нет среди вариантов (например, выбранная подписка удалена) — показывается первый,
	// как у обычного списка, а не пустое поле.
	select(value, choices, onchange) {
		value = (value == null) ? '' : String(value);
		if (!choices.some((c) => c[0] === value))
			value = choices[0][0];
		return this.dropdown(ui.Dropdown, value, choices, onchange, { optional: false });
	},

	// Подпись варианта с серой припиской — вместо групп <optgroup>.
	label(text, note) {
		return E('span', {}, [ text, ' ', this.dim(note) ]);
	},

	// Правка конфига stella штатным UCI LuCI: fn меняет его (uci.add/remove/move и set ниже),
	// изменения сразу уходят на роутер и записываются (uci commit) — службу перезагружает её
	// reload-триггер procd. Перед правкой конфиг перечитывается: его меняет и сам роутер (подбор
	// узла, WARP, автоподбор Zapret). fn вернула false — ничего не пишется. Промис — записано ли;
	// ошибка — уведомлением.
	edit(fn) {
		const res = queue.then(() => {
			writing = true;
			uci.unload('stella');
			return uci.load('stella');
		}).then(() => fn()).then((r) => (r === false) ? false : uci.save().then(() => callCommit('stella')).then(() => true))
			.catch((e) => {
				// Отправленное наполовину не должно записаться вместе со следующей правкой.
				uci.unload('stella');
				ui.addNotification(null, E('p', {}, [ _('Не удалось сохранить: %s').format(e.message || e) ]), 'danger');
				return callRevert('stella').catch(() => null).then(() => false);
			}).then((ok) => {
				writing = false;
				return ok;
			});
		queue = res;
		return res;
	},

	// Внутри edit: опция секции; пустая строка, пустой список и null — убрать опцию.
	set(sid, key, value) {
		uci.set('stella', sid, key, (value === '' || (Array.isArray(value) && !value.length)) ? null : value);
	},

	// Устройства сети: стоковый список LuCI (имена и адреса из DHCP и соседей) и настроенные
	// (секции device). Свои адреса роутера и всё, что не в подсетях LAN (шлюз провайдера), — не
	// устройства. [ { mac, ip, hostname, id, name, policy, configured } ].
	devices() {
		return Promise.all([ callHostHints().catch(() => ({})), callNetDevices().catch(() => ({})), callSettings(), uci.load('stella') ]).then(([ hints, net, cfg ]) => {
			const own = {}, lans = [];
			const num = (ip) => ip.split('.').reduce((n, x) => n * 256 + +x, 0);
			const lan = cfg.lan_devices || [];
			for (const name in net) {
				if (net[name].mac)
					own[net[name].mac.toLowerCase()] = true;
				if (lan.indexOf(name) >= 0)
					for (const a of (net[name].ipaddrs || []))
						lans.push([ num(a.address), a.netmask ]);
			}
			const inLan = (ip) => !lans.length || lans.some(([ net4, bits ]) => Math.floor(num(ip) / 2 ** (32 - bits)) == Math.floor(net4 / 2 ** (32 - bits)));
			const byMac = {}, res = [];
			for (const s of uci.sections('stella', 'device')) {
				const mac = String(L.toArray(s.mac)[0] || '').toLowerCase();
				if (!mac)
					continue;
				res.push(byMac[mac] = { mac, id: s['.name'], name: s.name || '', configured: true,
					policy: (s.policy == 'vpn' || s.policy == 'direct') ? s.policy : 'global' });
			}
			for (const m in hints) {
				const mac = m.toLowerCase(), ip = (hints[m].ipaddrs || []).filter(inLan)[0];
				let d = byMac[mac];
				if (!d && (own[mac] || !ip))
					continue;
				if (!d)
					res.push(d = byMac[mac] = { mac, id: null, name: '', policy: 'global', configured: false });
				d.ip = ip || null;
				d.hostname = hints[m].name || null;
			}
			return res;
		});
	},

	// Служба Stella: start, stop, restart — стоковым вызовом LuCI.
	service(action) {
		return callInit('stella', action);
	},

	// Имя новой секции (list_1a2b3c4d): постоянное — на нём держатся файлы списка и id узлов.
	newId(prefix) {
		const b = crypto.getRandomValues(new Uint8Array(4));
		return prefix + '_' + Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
	},

	// Сохранить настройки (секция main); ошибку — уведомлением. Промис — сохранилось ли.
	saveSettings(values) {
		for (const key in values) {
			const v = values[key];
			const bad = CHECKS.find((c) => c[0].test(key) && !c[1].test(String(v).trim()));
			if (bad) {
				ui.addNotification(null, E('p', {}, [ bad[2] ]), 'danger');
				return Promise.resolve(false);
			}
		}
		return this.edit(() => {
			for (const key in values)
				this.set('main', key, (typeof values[key] == 'string') ? values[key].trim() : values[key]);
		});
	},

	plural(n, one, few, many) {
		const m10 = n % 10, m100 = n % 100;
		return (m10 == 1 && m100 != 11) ? one : (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) ? few : many;
	}
});

