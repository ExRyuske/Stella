'use strict';
'require baseclass';
'require rpc';
'require ui';

// Общее для страниц Stella: стили, иконки, выпадающие списки с готовыми вариантами, время,
// склонение, сохранение настроек.
//
// Иконки — свои SVG одного размера и цвета текста: символы Юникода (⏱ ⟳ ⚙) в каждом
// шрифте рисуются по-своему, и кнопки выходили разной высоты.

const PATHS = {
	refresh: '<polyline points="23 4 23 10 17 10"/><path d="M20.5 15a9 9 0 1 1-2.1-9.4L23 10"/>',
	ping: '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>',
	settings: '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>',
	sort: '<path d="M3 6h11M3 12h8M3 18h5"/><path d="M19 5v14M16 16l3 3 3-3"/>',
	edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
	up: '<polyline points="18 15 12 9 6 15"/>',
	down: '<polyline points="6 9 12 15 18 9"/>',
	close: '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
	star: '<polygon points="12 2 15.1 8.3 22 9.3 17 14.1 18.2 21 12 17.8 5.8 21 7 14.1 2 9.3 8.9 8.3 12 2"/>'
};

const callSettingsSet = rpc.declare({ object: 'stella', method: 'settings_set', params: [ 'values' ] });

// Версия модуля. LuCI запрашивает его по адресу со своей версией, а не Stella, и uhttpd не
// запрещает кэш: после обновления Stella браузер может днями брать прежний модуль из кэша.
// Страницы вызывают need() с нужной им версией; повышать, когда страницам нужно новое отсюда.
const API = 14;

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
// звёздочки, цвета задержки и состояний, строка поиска.
const CSS = `
.st-info .cbi-dropdown { min-width:12em; max-width:100% }
.st-info .cbi-dynlist { min-width:20em }
.modal .st-info .td:first-child { width:30% }
.modal .st-info textarea, .modal .st-info input[type=text] { width:100% }
.st-row { display:flex; flex-wrap:wrap; gap:.4em .8em; align-items:center; min-height:30px }
.st-full { flex-basis:100% }
.st-row > .cbi-value-description { flex-basis:100%; margin-top:0 }
.st-bar { display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:0 0 1em }
.st-bar input[type=text] { flex:1; min-width:10em }
.st-table .td, .st-table .th { vertical-align:middle }
.st-table .st-dim { font-size:90% }
body .cbi-dropdown[optional][open] > ul.dropdown > li[placeholder] { display:none !important }
.st-act, .table .td.st-act { text-align:right; white-space:nowrap; width:1% }
.st-ok { color:#2a2 } .st-mid { color:#b90 } .st-slow { color:#d60 } .st-bad { color:#c33 } .st-dim { opacity:.6 }
.st-ico { display:inline-block; vertical-align:middle; line-height:1 }
.st-ico svg { display:block; width:15px; height:15px; fill:none; stroke:currentColor; stroke-width:2; stroke-linecap:round; stroke-linejoin:round }
.st-ico.filled svg { fill:currentColor }
.btn.st-ib { min-width:2.4em; padding-left:.55em; padding-right:.55em; text-align:center }
.btn.st-ib .st-ico { margin:0 auto }
.btn.st-ib.on { background:rgba(60,140,220,.25) }
@media (max-width:854px) { .st-info .td:first-child { flex-basis:100%; font-weight:bold } .st-info .td + .td { flex-basis:100% } }
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

	icon(name, filled) {
		const el = E('span', { 'class': 'st-ico' + (filled ? ' filled' : '') });
		el.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + PATHS[name] + '</svg>';
		return el;
	},

	// Кнопка-иконка с подсказкой. extra — дополнительные классы (например, «on»).
	iconButton(name, title, handler, extra) {
		return E('button', {
			'class': 'btn cbi-button st-ib ' + (extra || ''),
			'title': title,
			'aria-label': title,
			'click': (ev) => { ev.preventDefault(); ev.stopPropagation(); return handler(ev); }
		}, this.icon(name));
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
	kv(label, value, title) {
		return [ E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%', 'title': title || null }, label),
			E('td', { 'class': 'td left' }, E('div', { 'class': 'st-row' }, value))
		]) ];
	},

	// Строки kv — таблицей.
	card(rows, cls) {
		return E('table', { 'class': 'table st-info' + (cls ? ' ' + cls : '') }, rows);
	},

	info(label, value, title) {
		return this.kv(label, value, title);
	},

	infoTable(rows, cls) {
		return this.card(rows, cls);
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

	// Таблица LuCI: на телефоне тема показывает строки карточками, подписи — из заголовков
	// столбцов (data-title у ячеек). heads — [ подпись | [ подпись, атрибуты ] ]; empty — текст
	// заглушки, когда строк нет.
	table(heads, rows, cls, empty) {
		return E('table', { 'class': 'table cbi-section-table st-table' + (cls ? ' ' + cls : '') }, [
			E('tr', { 'class': 'tr table-titles' }, heads.map((h) => Array.isArray(h) ? E('th', Object.assign({ 'class': 'th' }, h[1]), h[0]) : E('th', { 'class': 'th' }, h))),
			...(rows.length || !empty ? rows : [ E('tr', { 'class': 'tr placeholder' }, E('td', { 'class': 'td' }, E('em', {}, [ empty ]))) ])
		]);
	},

	// Заголовок столбца с сортировкой, как у таблиц форм LuCI: щелчок — по возрастанию, ещё раз —
	// по убыванию; стрелку рисует тема (data-sort-direction). state — { key, desc } страницы.
	sortHead(label, key, state, onchange) {
		return [ label, {
			'data-sortable-row': '',
			'data-sort-direction': (state.key == key) ? (state.desc ? 'desc' : 'asc') : null,
			'title': _('Сортировать'),
			'click': () => {
				state.desc = (state.key == key) ? !state.desc : false;
				state.key = key;
				onchange();
			}
		} ];
	},

	// Упорядочить по state: value(x, key) — значение для сравнения (строка или число).
	sorted(list, state, value) {
		if (!state.key)
			return list;
		const v = (x) => value(x, state.key);
		return list.slice().sort((a, b) => {
			const x = v(a), y = v(b);
			const r = (typeof x == 'number' && typeof y == 'number') ? x - y : String(x).localeCompare(String(y), undefined, { numeric: true, sensitivity: 'base' });
			return state.desc ? -r : r;
		});
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

	// Сохранить настройки (rpc settings_set); ошибку — уведомлением. Промис — сохранилось ли.
	saveSettings(values) {
		return callSettingsSet(values).then((r) => {
			if (r && r.error) {
				ui.addNotification(null, E('p', {}, r.error), 'danger');
				return false;
			}
			return true;
		});
	},

	plural(n, one, few, many) {
		const m10 = n % 10, m100 = n % 100;
		return (m10 == 1 && m100 != 11) ? one : (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) ? few : many;
	}
});

