'use strict';
'require baseclass';
'require ui';

// Общее для страниц Stella: иконки, выпадающий список с готовыми вариантами, склонение.
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

const CSS = `
.st-ico { display:inline-block; vertical-align:middle; line-height:1 }
.st-ico svg { display:block; width:15px; height:15px; fill:none; stroke:currentColor; stroke-width:2; stroke-linecap:round; stroke-linejoin:round }
.st-ico.filled svg { fill:currentColor }
.btn.st-ib { min-width:2.4em; padding-left:.55em; padding-right:.55em; text-align:center }
.btn.st-ib .st-ico { margin:0 auto }
.btn.st-ib.on { background:rgba(60,140,220,.25) }
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

	// Выпадающий список LuCI с готовыми вариантами и своим значением. Виджет сообщает об
	// изменении и при простом закрытии списка — поэтому onchange зовётся, только если
	// значение действительно стало другим.
	combo(value, choices, onchange, opts) {
		const w = new ui.Combobox(value, Object.fromEntries(choices),
			Object.assign({ sort: false, custom_placeholder: _('свой вариант…') }, opts));
		const el = w.render();
		let last = value;
		el.addEventListener('widget-change', () => {
			const v = w.getValue();
			if (v == null || v === '' || v === last)
				return;
			last = v;
			onchange(v);
		});
		return el;
	},

	plural(n, one, few, many) {
		const m10 = n % 10, m100 = n % 100;
		return (m10 == 1 && m100 != 11) ? one : (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) ? few : many;
	}
});
