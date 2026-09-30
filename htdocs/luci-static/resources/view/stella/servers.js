'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require stella.ui as sui';

const callNodes = rpc.declare({ object: 'stella', method: 'nodes' });
const callSelect = rpc.declare({ object: 'stella', method: 'select', params: [ 'id' ] });
const callUpdate = rpc.declare({ object: 'stella', method: 'update', params: [ 'id' ] });
const callPing = rpc.declare({ object: 'stella', method: 'ping', params: [ 'ids' ] });
const callAdd = rpc.declare({ object: 'stella', method: 'add', params: [ 'text', 'name' ] });
const callEdit = rpc.declare({ object: 'stella', method: 'edit', params: [ 'id', 'name', 'url', 'user_agent', 'enabled' ] });
const callRemove = rpc.declare({ object: 'stella', method: 'remove', params: [ 'id' ] });
const callAuto = rpc.declare({ object: 'stella', method: 'auto_set', params: [ 'mode', 'id', 'on' ] });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callSettingsSet = rpc.declare({ object: 'stella', method: 'settings_set', params: [ 'values' ] });

const INTERVALS = [ [ '0', _('вручную') ], [ '3', _('каждые 3 ч') ], [ '6', _('каждые 6 ч') ],
	[ '12', _('каждые 12 ч') ], [ '24', _('раз в сутки') ], [ '168', _('раз в неделю') ] ];


const PROTO = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'SS', hysteria: 'Hysteria2' };
const NET = { raw: 'TCP', xhttp: 'XHTTP', ws: 'WS', httpupgrade: 'HTTPUpgrade', grpc: 'gRPC' };

const CSS = `
.st-current { display:flex; flex-wrap:wrap; gap:.5em 1em; align-items:center; padding:.6em .9em; border-radius:4px; background:rgba(128,128,128,.12); margin-bottom:.8em }
.st-current .st-node { flex:1; min-width:16em }
.st-current select { width:auto }
.st-bar { display:flex; flex-wrap:wrap; gap:.4em; align-items:center; margin-bottom:.8em }
.st-bar input[type=text] { flex:1; min-width:10em }
.st-group { border:1px solid rgba(128,128,128,.3); border-radius:4px; margin-bottom:.6em }
.st-group > summary { display:flex; flex-wrap:wrap; gap:.3em .8em; align-items:center; padding:.45em .8em; cursor:pointer; list-style:none }
.st-group > summary::-webkit-details-marker { display:none }
.st-group > summary::before { content:'▸'; width:1em; opacity:.6 }
.st-group[open] > summary::before { content:'▾' }
.st-group .st-title { font-weight:bold }
.st-group .st-meta { opacity:.6; font-size:85% }
.st-group .st-actions { margin-left:auto; display:flex; gap:.25em }
.st-group .st-actions .btn, .st-act .btn { line-height:1.7em; min-height:0 }
.st-list { max-height:24em; overflow-y:auto; border-top:1px solid rgba(128,128,128,.3) }
.st-list table { width:100%; border-collapse:collapse; margin:0 }
.st-list td { padding:.3em .6em; border-bottom:1px solid rgba(128,128,128,.1); vertical-align:middle }
.st-list tr.st-sel td { background:rgba(60,160,60,.14) }
.st-list tr:hover td { background:rgba(128,128,128,.07) }
.st-list .st-type { display:block; opacity:.5; font-size:80%; line-height:1.2 }
.st-ping { white-space:nowrap; text-align:right; width:5.5em; font-size:90% }
.st-act { text-align:right; width:1%; white-space:nowrap }
@media (hover:hover) { .st-list tr:not(:hover) .st-act .btn { visibility:hidden } }
.st-star { cursor:pointer; color:#d9a400; user-select:none; display:inline-flex }
.st-star.off { color:inherit; opacity:.3 }
.st-ok { color:#2a2 } .st-mid { color:#b90 } .st-slow { color:#d60 } .st-bad { color:#c33 } .st-dim { opacity:.5 }
`;

function typeLabel(n) {
	let t = PROTO[n.protocol] || n.protocol;
	if (n.protocol == 'hysteria' || n.protocol == 'shadowsocks')
		return t;
	t += ' · ' + (NET[n.network] || n.network);
	if (n.security == 'reality')
		t += ' · REALITY';
	else if (n.security == 'tls')
		t += ' · TLS';
	return t;
}

function pingLabel(v) {
	if (v == null)
		return E('span', { 'class': 'st-dim' }, '—');
	if (v == -2)
		return E('span', { 'class': 'st-bad', 'title': _('xray не принял конфигурацию узла') }, _('ошибка'));
	if (v < 0)
		return E('span', { 'class': 'st-bad' }, '✕');
	const cls = (v < 800) ? 'st-ok' : (v < 1500) ? 'st-mid' : 'st-slow';
	return E('span', { 'class': cls }, v + ' ' + _('мс'));
}

function smallBtn(label, title, handler, cls) {
	return E('button', {
		'class': 'btn cbi-button ' + (cls || ''),
		'title': title || '',
		'click': (ev) => { ev.preventDefault(); ev.stopPropagation(); return handler(ev); }
	}, label);
}

return view.extend({
	filter: '',
	sortByPing: false,
	open: null,

	load() {
		return Promise.all([ callNodes(), callSettings() ]);
	},

	refresh() {
		return callNodes().then((data) => {
			const wasUpdating = this.data && this.data.updating;
			const same = this.data && this.signature(this.data) == this.signature(data);
			this.data = data;
			// Во время опроса меняются только задержки и счётчики — обновляем их на месте,
			// иначе перерисовка сбрасывает прокрутку.
			if (same && !this.sortByPing)
				this.updateInPlace();
			else
				this.renderAll();

			const busy = data.pinging || data.updating;
			if (busy && !this.polling) {
				this.polling = () => this.refresh();
				poll.add(this.polling, 2);
			}
			else if (!busy && this.polling) {
				poll.remove(this.polling);
				this.polling = null;
			}
			if (wasUpdating && !data.updating && data.update_log)
				ui.addNotification(_('Обновление подписок'), E('pre', { 'style': 'white-space:pre-wrap' }, data.update_log), 'info');
		});
	},

	/* действия */

	handleSelect(id) {
		return callSelect(id).then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
			return this.refresh();
		});
	},

	handleUpdate(id) {
		return callUpdate(id || undefined).then(() => this.refresh());
	},

	handlePing(ids) {
		return callPing(ids || []).then(() => this.refresh());
	},

	handleRemove(id, what) {
		if (!confirm(_('Удалить «%s»?').format(what)))
			return;
		return callRemove(id).then(() => this.refresh());
	},

	showAdd() {
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 6, 'style': 'width:100%',
			'placeholder': 'https://example.com/sub/…\nvless://…\nhysteria2://…'
		});
		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'width:100%', 'placeholder': _('необязательно') });

		ui.showModal(_('Добавить серверы'), [
			E('p', {}, _('Вставьте ссылку на подписку (https://…) или ссылки на серверы: vless://, vmess://, trojan://, ss://, hysteria2://. Можно несколько — по одной в строке.')),
			text,
			E('p', {}, [ _('Название (если добавляется одна подписка или ссылка):'), name ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')), ' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, () => {
						return callAdd(text.value, name.value.trim() || undefined).then((r) => {
							ui.hideModal();
							const msg = [];
							if (r.subscriptions)
								msg.push(_('Подписок добавлено: %d — загружаю узлы…').format(r.subscriptions));
							if (r.links)
								msg.push(_('Ссылок добавлено: %d').format(r.links));
							for (const e of (r.errors || []))
								msg.push(_('Не разобрано «%s…»: %s').format(e.line, e.error));
							if (msg.length)
								ui.addNotification(null, msg.map((m) => E('p', {}, m)), (r.errors && r.errors.length) ? 'warning' : 'info');
							return this.refresh();
						});
					})
				}, _('Добавить'))
			])
		]);
		text.focus();
	},

	showEdit(src) {
		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'width:100%', 'value': src.name });
		const url = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'width:100%', 'value': src.url || '' });
		const ua = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'width:100%', 'value': src.user_agent, 'placeholder': 'v2rayN/7.0' });
		const en = E('input', { 'type': 'checkbox', 'checked': src.enabled ? '' : null });

		ui.showModal(_('Подписка'), [
			E('p', {}, [ _('Название'), name ]),
			E('p', {}, [ _('URL'), url ]),
			E('p', {}, [ _('User-Agent'), ua,
				E('small', { 'class': 'st-dim' }, _('Некоторые панели отдают разный формат в зависимости от клиента.')) ]),
			E('p', {}, E('label', {}, [ en, ' ', _('Включена') ])),
			E('div', { 'style': 'display:flex;gap:.5em' }, [
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': () => { ui.hideModal(); this.handleRemove(src.id, src.name); }
				}, _('Удалить')),
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, () => {
						return callEdit(src.id, name.value.trim(), url.value.trim(), ua.value.trim(), en.checked).then((r) => {
							if (r && r.error)
								return ui.addNotification(null, E('p', {}, r.error), 'danger');
							ui.hideModal();
							return this.refresh();
						});
					})
				}, _('Сохранить'))
			])
		]);
	},

	/* отрисовка */

	handleAuto(mode, id, on) {
		return callAuto(mode, id, on).then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
			return this.refresh();
		});
	},

	renderCurrent() {
		const d = this.data;
		const n = d.nodes.find((x) => x.id == d.selected);
		const known = d.auto_nodes.filter((id) => d.nodes.find((x) => x.id == id));
		const auto = d.select_mode == 'auto';

		let node;
		if (auto && known.length >= 2)
			node = [ E('strong', {}, _('Автовыбор из %d ★').format(known.length)), ' ',
				E('span', { 'class': 'st-dim' }, n ? _('запасной: %s').format(n.name) : _('запасной не выбран')) ];
		else if (auto)
			node = [ E('span', { 'class': 'st-bad' }, _('Отметьте ★ хотя бы два узла для автовыбора.')) ];
		else if (n)
			node = [ E('strong', {}, n.name), ' ', E('span', { 'class': 'st-dim' }, typeLabel(n)), ' ', (this.curPing = E('span', {}, pingLabel(d.ping[n.id]))) ];
		else if (d.selected)
			node = [ E('span', { 'class': 'st-bad' }, _('Выбранный узел пропал из списка — выберите другой.')) ];
		else
			node = [ E('span', { 'class': 'st-dim' }, _('Узел не выбран.')) ];

		dom.content(this.currentBox, [
			E('div', { 'class': 'st-node' }, node),
			E('label', { 'style': 'white-space:nowrap' }, [ _('Выбор узла'), ' ', E('select', {
				'class': 'cbi-input-select', 'change': (ev) => this.handleAuto(ev.target.value)
			}, [
				E('option', { 'value': 'single', 'selected': auto ? null : '' }, _('вручную')),
				E('option', { 'value': 'auto', 'selected': auto ? '' : null }, _('самый быстрый из ★'))
			]) ])
		]);
	},

	showOptions() {
		const cfg = this.cfg;
		ui.showModal(_('Серверы: настройки'), [
			E('div', { 'style': 'margin:.6em 0' }, [ E('b', { 'style': 'display:block;margin-bottom:.25em' }, _('Обновлять подписки')),
				sui.combo(cfg.sub_interval, INTERVALS, (v) => callSettingsSet({ sub_interval: v }).then((r) => {
					if (r && r.error)
						ui.addNotification(null, E('p', {}, r.error), 'danger');
					else
						cfg.sub_interval = v;
				}), { custom_placeholder: _('часов…') }) ]),
			E('p', { 'class': 'st-dim' }, _('Автовыбор проверяет отмеченные ★ узлы раз в минуту и ведёт трафик через самый быстрый из отвечающих.')),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Закрыть')))
		]);
	},

	signature(d) {
		return JSON.stringify([ d.selected, d.select_mode, d.auto_nodes, d.errors.length, d.nodes.length,
			d.sources.map((x) => [ x.id, x.count, x.updated, x.enabled, x.name ]) ]);
	},

	metaText(src) {
		const d = this.data;
		const all = d.nodes.filter((n) => n.source == src.id);
		const tested = all.filter((n) => d.ping[n.id] != null).length;
		const meta = [ '%d %s'.format(src.count, sui.plural(src.count, _('узел'), _('узла'), _('узлов'))) ];
		if (tested)
			meta.push(_('отвечают %d').format(all.filter((n) => d.ping[n.id] >= 0).length));
		if (src.kind == 'subscription' && src.updated)
			meta.push(_('обновлено %s').format(new Date(src.updated * 1000).toLocaleString('ru-RU')));
		if (src.kind == 'subscription' && !src.enabled)
			meta.push(_('выключена'));
		return meta.join(' · ');
	},

	renderBusy() {
		const d = this.data;
		dom.content(this.busyBox, [
			d.updating ? E('em', { 'class': 'spinning' }, _('обновляю подписки…')) : '',
			d.pinging ? E('em', { 'class': 'spinning' }, _('проверяю задержку…')) : ''
		]);
	},

	updateInPlace() {
		const d = this.data;
		for (const id in this.cells)
			dom.content(this.cells[id], pingLabel(d.ping[id]));
		for (const src of d.sources)
			if (this.metas[src.id])
				this.metas[src.id].textContent = this.metaText(src);
		this.renderBusy();
		// Строка текущего узла не пересобирается (иначе закрывался бы открытый выбор режима) —
		// меняется только её задержка.
		const cur = d.nodes.find((x) => x.id == d.selected);
		if (cur && this.curPing)
			dom.content(this.curPing, pingLabel(d.ping[cur.id]));
	},

	renderGroups() {
		const d = this.data;

		// Прокрутка внутри групп переживает перерисовку.
		const scroll = {};
		for (const el of this.groupsBox.querySelectorAll('.st-list[data-src]'))
			scroll[el.dataset.src] = el.scrollTop;
		this.cells = {};
		this.metas = {};
		this.renderBusy();
		const q = this.filter.toLowerCase();
		const rank = (n) => { const v = d.ping[n.id]; return (v == null || v < 0) ? Infinity : v; };

		if (this.open == null) {
			const sel = d.nodes.find((x) => x.id == d.selected);
			this.open = new Set([ sel ? sel.source : (d.sources[0] ? d.sources[0].id : null) ]);
		}

		const errors = d.errors.map((e) => E('div', { 'class': 'alert-message warning' },
			_('Ссылка «%s» не разобрана: %s').format(e.name, e.error)));

		if (!d.sources.length) {
			dom.content(this.groupsBox, [ ...errors, E('p', {}, _('Серверов пока нет. Нажмите «Добавить» и вставьте подписку или ссылку.')) ]);
			return;
		}

		const groups = d.sources.map((src) => {
			let list = d.nodes.filter((n) => n.source == src.id);
			if (q)
				list = list.filter((n) => n.name.toLowerCase().indexOf(q) >= 0);
			if (q && !list.length)
				return null;
			if (this.sortByPing)
				list = list.slice().sort((a, b) => rank(a) - rank(b));

			const isSub = (src.kind == 'subscription');

			const rows = list.map((n) => {
				const sel = (n.id == d.selected);
				const star = d.auto_nodes.indexOf(n.id) >= 0;
				return E('tr', { 'class': sel ? 'st-sel' : '' }, [
					E('td', { 'style': 'width:1.5em' }, E('span', {
						'class': 'st-star' + (star ? '' : ' off'),
						'title': star ? _('Убрать из автовыбора') : _('Добавить в автовыбор'),
						'click': ui.createHandlerFn(this, 'handleAuto', undefined, n.id, !star)
					}, sui.icon('star', star))),
					E('td', {}, [
						sel ? E('strong', {}, '✓ ' + n.name) : n.name,
						(n.warnings && n.warnings.length) ? E('span', { 'title': n.warnings.join('\n'), 'style': 'cursor:help' }, ' ⚠') : '',
						E('span', { 'class': 'st-type' }, typeLabel(n))
					]),
					(this.cells[n.id] = E('td', { 'class': 'st-ping' }, pingLabel(d.ping[n.id]))),
					E('td', { 'class': 'st-act' }, [
						sel ? '' : smallBtn(_('Выбрать'), '', () => this.handleSelect(n.id), 'cbi-button-apply'),
						sui.iconButton('ping', _('Проверить задержку'), () => this.handlePing([ n.id ])),
						isSub ? '' : sui.iconButton('close', _('Удалить'), () => this.handleRemove(n.id, n.name))
					])
				]);
			});

			const el = E('details', { 'class': 'st-group', 'open': (q || this.open.has(src.id)) ? '' : null }, [
				E('summary', { 'class': 'st-summary' }, [
					E('span', { 'class': 'st-title' }, isSub ? src.name : _('Отдельные ссылки')),
					(this.metas[src.id] = E('span', { 'class': 'st-meta' }, this.metaText(src))),
					E('span', { 'class': 'st-actions' }, [
						sui.iconButton('ping', _('Проверить задержку узлов'), () => this.handlePing(list.map((n) => n.id))),
						isSub ? sui.iconButton('refresh', _('Обновить подписку'), () => this.handleUpdate(src.id)) : '',
						isSub ? sui.iconButton('settings', _('Настройки подписки'), () => this.showEdit(src)) : ''
					])
				]),
				E('div', { 'class': 'st-list', 'data-src': src.id }, E('table', {}, rows.length ? rows :
					E('tr', {}, E('td', { 'class': 'st-dim' }, isSub ? _('Узлов нет — нажмите «Обновить».') : ''))))
			]);
			el.addEventListener('toggle', () => { if (!q) el.open ? this.open.add(src.id) : this.open.delete(src.id); });
			return el;
		}).filter((g) => g);

		dom.content(this.groupsBox, [ ...errors, ...(groups.length ? groups : [ E('p', {}, _('Ничего не найдено.')) ]) ]);
		for (const el of this.groupsBox.querySelectorAll('.st-list[data-src]'))
			if (scroll[el.dataset.src])
				el.scrollTop = scroll[el.dataset.src];
	},

	renderAll() {
		this.renderCurrent();
		this.renderGroups();
	},

	render(r) {
		const [ data, cfg ] = r;
		this.data = data;
		this.cfg = cfg;
		this.currentBox = E('div', { 'class': 'st-current' });
		this.busyBox = E('span', { 'style': 'white-space:nowrap' });
		this.groupsBox = E('div');

		const sortBtn = sui.iconButton('sort', _('Сортировать по задержке'), () => {
			this.sortByPing = !this.sortByPing;
			sortBtn.classList.toggle('on', this.sortByPing);
			this.renderGroups();
		});
		const bar = E('div', { 'class': 'st-bar' }, [
			E('button', { 'class': 'btn cbi-button-add', 'click': () => this.showAdd() }, _('Добавить')),
			E('input', {
				'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('Поиск по названию…'),
				'input': (ev) => { this.filter = ev.target.value; this.renderGroups(); }
			}),
			this.busyBox,
			sui.iconButton('ping', _('Проверить задержку всех узлов'), () => this.handlePing([])),
			sui.iconButton('refresh', _('Обновить все подписки'), () => this.handleUpdate(undefined)),
			sortBtn,
			sui.iconButton('settings', _('Настройки'), () => this.showOptions())
		]);

		this.renderAll();
		if (data.pinging || data.updating)
			this.refresh();

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Серверы')),
			this.currentBox,
			bar,
			this.groupsBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
