'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require stella.common as sui';

// DNS для всей сети: цепочка DoH-серверов — подобранные серверы обхода геоблокировок или свои,
// за ними запасные (по умолчанию — Cloudflare и Google). Серверы — из каталога Zapret Manager,
// по группам: обход геоблокировок, без фильтрации, с фильтрацией. Правки применяются сразу.

const callInfo = rpc.declare({ object: 'stella', method: 'dns_info' });
const callCheck = rpc.declare({ object: 'stella', method: 'dns_check', params: [ 'apply' ] });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });

const KINDS = [
	[ 'geo', _('обход геоблокировок') ],
	[ 'plain', _('без фильтрации') ],
	[ 'safe', _('защита от угроз') ],
	[ 'family', _('семейный фильтр') ]
];
// Группы каталога на странице.
const GROUPS = [
	[ _('Обход геоблокировок'), [ 'geo' ] ],
	[ _('Без фильтрации'), [ 'plain' ] ],
	[ _('С фильтрацией'), [ 'safe', 'family' ] ]
];
const KIND = Object.fromEntries(KINDS);
const MAX = 4;

const CSS = `
.st-dns .td:nth-child(1) { width:30% } .st-dns .td:nth-child(2) { width:40% }
`;

// Название из каталога, фильтр — в скобках: «Cloudflare · Защита от угроз» → «Cloudflare (защита от
// угроз)».
function title(c) {
	const m = String(c.label).match(/^(.*?) · (.+)$/);
	if (m)
		return '%s (%s)'.format(m[1], m[2].charAt(0).toLowerCase() + m[2].slice(1));
	return (c.kind == 'safe' || c.kind == 'family') ? '%s (%s)'.format(c.label, KIND[c.kind]) : c.label;
}

return view.extend({

	load() {
		return sui.need(21).then(() => Promise.all([ callInfo(), callSettings() ]));
	},

	// Сервер — названием из каталога и адресом.
	label(url) {
		if (url == 'isp')
			return _('DNS провайдера (%s)').format(this.info.isp.length ? this.info.isp.join(', ') : _('не найден'));
		const c = this.info.catalog.find((x) => x.url == url);
		return c ? '%s — %s'.format(title(c), url) : url;
	},

	// Ответ сервера по последней проверке; у проверенных на обход — сколько закрытых сервисов
	// через него открывается.
	result(url) {
		const r = (this.info.check.items || {})[url];
		if (!r)
			return sui.dim(_('не проверялся'));
		if (!r.ok)
			return E('span', { 'class': 'st-bad' }, [ r.error || _('не отвечает') ]);
		return E('span', {}, [
			E('span', { 'class': r.ms < 150 ? 'st-ok' : r.ms < 400 ? 'st-mid' : 'st-slow' }, _('%d мс').format(r.ms)),
			r.geo_of ? sui.dim(' · ' + _('обход %d из %d').format(r.geo, r.geo_of)) : ''
		]);
	},

	save(values) {
		return sui.saveSettings(values).then((ok) => {
			if (!ok)
				return;
			Object.assign(this.cfg, values);
			// Цепочку в конфиге xray служба пересобирает при reload — немного подождать.
			return new Promise((r) => window.setTimeout(r, 1500)).then(() => this.refresh());
		});
	},

	setMode(v) {
		return this.save({ dns_mode: v }).then(() => {
			// Подбор включили, а подобранных ещё нет — подобрать сразу.
			if (v == 'geo' && !this.info.chain.length && this.info.catalog.length)
				return callCheck(true).then(() => this.refresh());
		});
	},

	// Список серверов — стоковый виджет LuCI (как DynamicList форм): варианты из каталога по
	// группам (заголовок группы — невыбираемый пункт, как уже добавленные), свой — адресом.
	// key — настройка, extra — варианты над группами (DNS провайдера).
	serverList(key, values, extra, validate) {
		const choices = Object.assign({}, extra), order = Object.keys(extra);
		GROUPS.forEach(([ group, kinds ], i) => {
			const list = this.info.catalog.filter((c) => kinds.indexOf(c.kind) >= 0);
			if (!list.length)
				return;
			choices['__group' + i] = E('strong', {}, [ group ]);
			order.push('__group' + i);
			for (const c of list) {
				choices[c.url] = '%s — %s'.format(title(c), c.url);
				order.push(c.url);
			}
		});
		const w = new ui.DynamicList(values, choices, { sort: order, validate: (v) => validate(v) });
		const el = w.render();
		el.querySelectorAll('li[data-value^="__group"]').forEach((li) => li.setAttribute('unselectable', ''));
		el.addEventListener('widget-change', () => {
			const v = [].concat(w.getValue() || []).map((x) => String(x).trim()).filter((x) => x && x.indexOf('__group') != 0);
			if (v.join(' ') == values.join(' '))
				return;
			if (v.length > MAX)
				return ui.addNotification(null, E('p', {}, _('Не больше %d серверов.').format(MAX)), 'warning');
			this.save({ [key]: v });
		});
		return el;
	},

	renderMain() {
		const d = this.info, cfg = this.cfg;
		const geo = (cfg.dns_mode || 'geo') != 'manual';
		const doh = (v) => /^https:\/\/[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(:[0-9]+)?(\/\S*)?$/.test(v);
		const ipv4 = (v) => /^([0-9]{1,3}\.){3}[0-9]{1,3}$/.test(v);
		const names = (d.check.names || []).join(', ');
		const rows = [
			...sui.kv(_('Серверы'), [
				sui.select(geo ? 'geo' : 'manual', [ [ 'geo', _('подбирать автоматически') ], [ 'manual', _('выбрать вручную') ] ], (v) => this.setMode(v)),
				// Расписание подбора — как у подбора узла и автоподбора Zapret.
				geo ? sui.hours(cfg.dns_interval || '24', (v) => this.save({ dns_interval: v })) : '',
				sui.hint(!geo ? _('Спрашиваются по порядку.') : names
					? _('Два сервера обхода геоблокировок. Проверяются: %s.').format(names)
					: _('Два сервера обхода геоблокировок.'))
			])
		];
		if (geo) {
			// Подобранные — с адресом и итогом проверки.
			rows.push(...sui.kv(_('Подобраны'), d.chain.length ? d.chain.map((u, i) => E('div', { 'class': 'st-full' }, [
				'%d. %s '.format(i + 1, this.label(u)), this.result(u) ])) : [ sui.dim(d.catalog.length ? _('подходящих серверов не нашлось') : _('каталог ещё не загружен')) ]));
		}
		else
			rows.push(...sui.kv(_('Цепочка'), [ this.serverList('dns_server', [].concat(cfg.dns_server || []), {},
				(v) => (!v || doh(v)) ? true : _('Нужен адрес DoH: https://…')),
				sui.hint(_('До четырёх. Свой сервер: https://…')) ]));
		rows.push(
			...sui.kv(_('Запасные'), [ this.serverList('dns_fallback', [].concat(d.fallback || [ 'isp' ]), { isp: this.label('isp') },
				(v) => (!v || v == 'isp' || doh(v) || ipv4(v)) ? true : _('Нужен адрес DoH (https://…) или IPv4')),
				sui.hint(_('Если серверы выше не ответили. Свой сервер: https://… или IPv4.')) ]),
			...sui.kv(_('Перехват DNS'), [ sui.checkbox(cfg.dns_hijack == '1', (on) => this.save({ dns_hijack: on ? '1' : '0' })),
				sui.hint(_('Запросы к другим DNS-серверам идут на роутер.')) ])
		);
		dom.content(this.mainBox, sui.card(rows));
	},

	// Серверы обхода геоблокировок с итогами проверки — сворачиваемым разделом, как группы на
	// «Серверах»; остальные серверы каталога (без фильтрации, с фильтрацией) — только в списках
	// выбора выше: проверять у них нечего.
	renderCatalog() {
		const d = this.info;
		const busy = d.checking ? _('проверяю…') : d.updating ? _('загружаю каталог…') : null;
		const btn = (text, tip, fn) => E('button', { 'class': 'btn cbi-button cbi-button-action', 'title': tip || null,
			'click': (ev) => { ev.preventDefault(); ev.stopPropagation(); return fn().then(() => this.refresh()); } }, text);
		const auto = (this.cfg.dns_mode || 'geo') != 'manual';
		const items = d.check.items || {};
		const ms = (u) => (items[u] && items[u].ok) ? items[u].ms : 1e9;
		// По умолчанию — как при подборе: кто открывает больше сервисов, при равенстве — быстрее.
		const score = (u) => (items[u] && items[u].ok && items[u].geo) || 0;
		const list = d.catalog.filter((c) => c.kind == 'geo').sort((a, b) => score(b.url) - score(a.url) || ms(a.url) - ms(b.url));

		const el = E('details', { 'class': 'cbi-section st-group', 'open': this.catalogOpen ? '' : null }, [
			E('summary', {}, [
				E('h3', {}, _('Серверы обхода геоблокировок')),
				E('span', { 'class': 'st-meta' }, [ [ list.length ? '%d'.format(list.length) : _('каталог не загружен'),
					d.check.at ? _('проверено %s').format(sui.time(d.check.at)) : '' ].filter((x) => x).join(' · ') ]),
				// Каталог обновляется вместе со всем остальным — расписание и кнопка на «Обзоре».
				E('span', { 'class': 'st-actions' }, busy ? [ E('em', { 'class': 'spinning' }, busy) ] : !list.length ? [] : [
					btn(_('Проверить'), _('Проверить время ответа и обход'), () => callCheck(false)),
					auto ? btn(_('Подобрать сейчас'), _('Проверить и взять лучшие'), () => callCheck(true)) : ''
				])
			]),
			sui.dataTable('dns', [ _('Сервер'), _('Адрес'), _('Ответ'), _('Обход') ], list.map((c) => {
				const r = items[c.url];
				return { cells: [
					E('span', {}, [ title(c), ...((d.chain.indexOf(c.url) >= 0) ? [ ' ', E('span', { 'class': 'st-ok' }, _('в цепочке')) ] : []) ]),
					c.url,
					// В таблице — обычным текстом, как соседние столбцы; сортировка — по миллисекундам.
					E('span', { 'data-value': ms(c.url) }, [ !r ? _('не проверялся') : !r.ok ? this.result(c.url) :
						E('span', { 'class': r.ms < 150 ? 'st-ok' : r.ms < 400 ? 'st-mid' : 'st-slow' }, _('%d мс').format(r.ms)) ]),
					E('span', { 'data-value': score(c.url) }, [ (r && r.ok && r.geo_of) ? _('%d из %d').format(r.geo, r.geo_of) : '—' ])
				] };
			}), 'st-dns', _('Серверов нет.'))
		]);
		el.addEventListener('toggle', () => this.catalogOpen = el.open);
		dom.content(this.catalogBox, el);
	},

	refresh() {
		return Promise.all([ callInfo(), callSettings() ]).then(([ d, cfg ]) => {
			const was = this.info.checking || this.info.updating;
			this.info = d;
			this.cfg = cfg;
			// Открытый список не трогаем — перерисовка закрыла бы его.
			if (!this.mainBox.querySelector('.cbi-dropdown[open]'))
				this.renderMain();
			this.renderCatalog();
			const busy = d.checking || d.updating;
			if (busy && !this.polling) {
				this.polling = () => this.refresh();
				poll.add(this.polling, 2);
			}
			else if (!busy && this.polling) {
				poll.remove(this.polling);
				this.polling = null;
			}
			if (was && !busy && d.log)
				ui.addNotification(_('DNS'), E('pre', { 'style': 'white-space:pre-wrap' }, [ d.log ]), 'info');
		});
	},

	render([ info, cfg ]) {
		this.info = info;
		this.cfg = cfg;
		this.mainBox = E('div');
		this.catalogBox = E('div');
		this.renderMain();
		this.renderCatalog();
		if (info.checking || info.updating)
			this.refresh();

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, 'DNS'),
			sui.section(null, this.mainBox),
			this.catalogBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
