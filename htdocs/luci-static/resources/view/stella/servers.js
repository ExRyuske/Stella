'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require stella.common as sui';

const callNodes = rpc.declare({ object: 'stella', method: 'nodes' });
const callSelect = rpc.declare({ object: 'stella', method: 'select', params: [ 'id' ] });
const callUpdate = rpc.declare({ object: 'stella', method: 'update', params: [ 'id' ] });
const callPing = rpc.declare({ object: 'stella', method: 'ping', params: [ 'ids' ] });
const callAdd = rpc.declare({ object: 'stella', method: 'add', params: [ 'text', 'name' ] });
const callEdit = rpc.declare({ object: 'stella', method: 'edit', params: [ 'id', 'name', 'url', 'user_agent', 'enabled' ] });
const callRemove = rpc.declare({ object: 'stella', method: 'remove', params: [ 'id' ] });
const callAuto = rpc.declare({ object: 'stella', method: 'auto_set', params: [ 'mode', 'id', 'on' ] });
const callPick = rpc.declare({ object: 'stella', method: 'node_pick', params: [ 'backup' ] });
const callWarp = rpc.declare({ object: 'stella', method: 'warp', params: [ 'name' ] });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });

const PROTO = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'SS', hysteria: 'Hysteria2', wireguard: 'WireGuard' };
const NET = { raw: 'TCP', xhttp: 'XHTTP', ws: 'WS', httpupgrade: 'HTTPUpgrade', grpc: 'gRPC' };

const CSS = `
.st-group { margin-bottom:1.5em }
.st-group > summary { display:flex; flex-wrap:wrap; gap:.3em .8em; align-items:center; cursor:pointer; list-style:none; padding:.2em 0 .5em }
.st-group > summary::-webkit-details-marker { display:none }
.st-group > summary::before { content:'▸'; width:1em; opacity:.6 }
.st-group[open] > summary::before { content:'▾' }
.st-group > summary > h3 { display:inline; margin:0; padding:0; border:0 }
.st-group .st-meta { opacity:.6; font-size:90% }
.st-group .st-actions { margin-left:auto; display:flex; flex-wrap:wrap; gap:.25em }
.st-list { max-height:32em; overflow-y:auto }
.st-nodes { margin:0 }
.st-nodes .tr.st-sel .td { background:rgba(60,160,60,.14) }
.st-nodes .td.st-starcell { width:1.5em }
.st-nodes .st-type { display:block; opacity:.6; font-size:85% }
.st-ping { white-space:nowrap; text-align:right; width:5.5em }
@media (hover:hover) { .st-nodes .tr:not(:hover) .st-act .btn { visibility:hidden } }
@media (max-width:854px) { .st-nodes .tr { flex-wrap:nowrap; align-items:center } .st-nodes .td { flex:0 0 auto } .st-nodes .td.st-name { flex:1 1 auto } }
.st-star { cursor:pointer; color:#d9a400; user-select:none; display:inline-flex }
.st-star.off { color:inherit; opacity:.3 }
`;

function typeLabel(n) {
	if (n.warp)
		return 'WARP';
	let t = PROTO[n.protocol] || n.protocol;
	if (n.protocol == 'hysteria' || n.protocol == 'shadowsocks' || n.protocol == 'wireguard')
		return t;
	t += ' · ' + (NET[n.network] || n.network);
	if (n.security == 'reality')
		t += ' · REALITY';
	else if (n.security == 'tls')
		t += ' · TLS';
	return t;
}

// st — итоги проверки стабильности (режим «лучший по проверке»): потери — рядом с
// задержкой, подробности — в подсказке.
function pingLabel(v, st) {
	const el = pingValue(v);
	if (!st || st.n < 2)
		return el;
	el.title = _('ответил %d из %d, разброс ±%d мс, проверено %s').format(st.ok, st.n, st.jit, sui.time(st.at));
	if (st.ok && st.ok < st.n)
		return E('span', { 'title': el.title }, [ el, ' ', E('span', { 'class': 'st-mid' }, '%d/%d'.format(st.ok, st.n)) ]);
	return el;
}

function pingValue(v) {
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
		'class': 'btn cbi-button ' + (cls || 'cbi-button-action'),
		'title': title || '',
		'click': (ev) => { ev.preventDefault(); ev.stopPropagation(); return handler(ev); }
	}, label);
}

return view.extend({
	filter: '',
	// Сортировка узлов — по заголовку столбца: { key: name | ping, desc }.
	sort: {},
	open: null,

	load() {
		return sui.need(14).then(() => Promise.all([ callNodes(), callSettings() ]));
	},

	refresh() {
		return callNodes().then((data) => {
			const wasUpdating = this.data && this.data.updating;
			const wasWarping = this.data && this.data.warping;
			const same = this.data && this.signature(this.data) == this.signature(data);
			this.data = data;
			// Во время опроса меняются только задержки и счётчики — обновляем их на месте,
			// иначе перерисовка сбрасывает прокрутку.
			if (same && !this.sort.key)
				this.updateInPlace();
			else
				this.renderAll();

			const busy = data.pinging || data.updating || data.picking || data.warping;
			if (busy && !this.polling) {
				this.polling = () => this.refresh();
				poll.add(this.polling, 2);
			}
			else if (!busy && this.polling) {
				poll.remove(this.polling);
				this.polling = null;
			}
			if (wasUpdating && !data.updating && data.update_log)
				ui.addNotification(_('Обновление подписок'), E('pre', { 'style': 'white-space:pre-wrap' }, [ data.update_log ]), 'info');
			if (wasWarping && !data.warping)
				ui.addNotification(_('WARP'), E('pre', { 'style': 'white-space:pre-wrap' }, [ data.warp_log || '' ]), 'info');
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
			sui.card([
				sui.field(_('Подписка или ссылки'), [ text, sui.hint(_('По одной в строке.')) ]),
				sui.field(_('Название'), name)
			]),
			E('div', { 'class': 'button-row' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, () => {
						return callAdd(text.value, name.value.trim() || undefined).then((r) => {
							ui.hideModal();
							const msg = [];
							if (r.subscriptions)
								msg.push(_('Добавлено подписок: %d, загружаю узлы…').format(r.subscriptions));
							if (r.links)
								msg.push(_('Добавлено ссылок: %d').format(r.links));
							for (const e of (r.errors || []))
								msg.push(_('Не разобрано «%s…»: %s').format(e.line, e.error));
							if (msg.length)
								ui.addNotification(null, msg.map((m) => E('p', {}, [ m ])), (r.errors && r.errors.length) ? 'warning' : 'info');
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

		ui.showModal(_('Подписка'), [
			sui.card([
				sui.field(_('Название'), name),
				sui.field(_('Ссылка'), url),
				sui.field(_('User-Agent'), ua)
			]),
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
						return callEdit(src.id, name.value.trim(), url.value.trim(), ua.value.trim(), src.enabled ? undefined : true).then((r) => {
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
		const auto = d.select_mode == 'auto', best = d.select_mode == 'best';
		// Работает резервный канал mwan3 — xray идёт через его узел.
		const bn = d.backup && d.nodes.find((x) => x.id == this.cfg.backup_node);

		let node;
		if (bn)
			node = [ E('strong', {}, [ bn.name ]), ' ', E('span', { 'class': 'st-dim' }, typeLabel(bn)), ' ',
				E('span', { 'class': 'st-mid' }, _('резервный канал %s').format(d.backup)) ];
		else if (best && !n && !d.selected)
			node = [ E('span', { 'class': 'st-dim' }, d.picking ? _('Подбираю узел…') : _('Узел ещё не подобран.')) ];
		else if (auto && known.length >= 2)
			node = [ E('strong', {}, _('Автовыбор из %d ★').format(known.length)), ' ',
				E('span', { 'class': 'st-dim' }, [ n ? _('запасной: %s').format(n.name) : _('запасной не выбран') ]) ];
		else if (auto)
			node = [ E('span', { 'class': 'st-bad' }, _('Отметьте ★ хотя бы два узла для автовыбора.')) ];
		else if (n)
			node = [ E('strong', {}, [ n.name ]), ' ', E('span', { 'class': 'st-dim' }, typeLabel(n)), ' ', (this.curPing = E('span', {}, pingLabel(d.ping[n.id], d.stability[n.id]))) ];
		else if (d.selected)
			node = [ E('span', { 'class': 'st-bad' }, _('Выбранного узла больше нет.')) ];
		else
			node = [ E('span', { 'class': 'st-dim' }, _('Узел не выбран.')) ];

		// Подбор по проверке — в той же строке, что и режим: из каких узлов, как часто, и подобрать
		// сейчас. Одинаково для основного узла и узла резервного канала (тот меряется через свой
		// канал — пока он не работает, подбирать не через что).
		const cfg = this.cfg, set = (key) => (v) => this.setting(key, v);
		const subs = d.sources.filter((x) => x.kind == 'subscription');
		const pickRow = (fromKey, everyKey, forBackup) => {
			const wait = forBackup && !d.backup;
			return [
				_('из'), sui.select(cfg[fromKey], [ [ '', _('всех подписок и ссылок') ], ...subs.map((x) => [ x.id, x.name ]) ], set(fromKey)),
				sui.hours(cfg[everyKey], set(everyKey)),
				d.picking ? E('em', { 'class': 'spinning' }, _('подбираю…')) :
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': (d.pinging || wait) ? '' : null,
						'title': wait ? _('Подбирается через резервный канал, когда он работает') : _('Проверить узлы и выбрать лучший'),
						'click': ui.createHandlerFn(this, () => callPick(forBackup || undefined).then((r) => {
							if (r && r.error)
								ui.addNotification(null, E('p', {}, r.error), 'warning');
							return this.refresh();
						})) }, _('Подобрать сейчас'))
			];
		};
		const pick = best ? pickRow('best_from', 'best_interval', false) : [];

		// Резервный канал mwan3 (например, мобильный оператор с белыми списками) и узел для него:
		// вручную или лучший по проверке, как основной, только без автовыбора из ★.
		const ifs = d.mwan3 || [];
		const save = (key) => (v) => this.setting(key, v).then(() => this.refresh()).then(() => this.renderCurrent());
		const bsel = cfg.backup_node && d.nodes.find((x) => x.id == cfg.backup_node);
		const bbest = cfg.backup_mode == 'best';
		const srcName = (id) => { const src = d.sources.find((x) => x.id == id); return (src && src.kind == 'subscription') ? src.name : _('отдельная ссылка'); };
		const backup = [
			sui.select(cfg.backup_iface, [ [ '', _('нет') ],
				...ifs.map((i) => [ i.name, '%s (%s)'.format(i.name, i.online ? _('в сети') : _('не в сети')) ]),
				...((cfg.backup_iface && !ifs.find((i) => i.name == cfg.backup_iface)) ? [ [ cfg.backup_iface, _('%s (нет в mwan3)').format(cfg.backup_iface) ] ] : [])
			], save('backup_iface')),
			...(cfg.backup_iface ? [
				_('через'),
				sui.select(bbest ? 'best' : 'single', [ [ 'single', _('вручную') ], [ 'best', _('лучший по проверке') ] ], save('backup_mode')),
				...(bbest ? [ ...pickRow('backup_best_from', 'backup_best_interval', true), bsel ? sui.dim(_('подобран: %s').format(bsel.name)) : '' ] :
					[ sui.select(bsel ? cfg.backup_node : '', [
						[ '', (cfg.backup_node && !bsel) ? _('узел удалён') : _('выберите узел') ],
						...d.nodes.map((x) => [ x.id, sui.label(x.name, srcName(x.source)) ])
					], save('backup_node')) ]),
				E('label', { 'style': 'white-space:nowrap', 'title': _('На резервном канале весь трафик идёт через VPN') }, [
					E('input', { 'type': 'checkbox', 'checked': cfg.backup_vpn == '1' ? '' : null, 'change': (ev) => save('backup_vpn')(ev.target.checked ? '1' : '0') }), ' ', _('всё через VPN')
				])
			] : []),
			d.backup ? E('span', { 'class': 'st-mid' }, _('работает сейчас')) : ''
		];

		// Строка «Резервный канал» — только когда к месту (есть mwan3 или канал уже задан).
		dom.content(this.currentBox, [
			...sui.kv(_('Узел'), node),
			...sui.kv(_('Выбор узла'), [ sui.select(d.select_mode || 'single', [
				[ 'single', _('вручную') ], [ 'auto', _('самый быстрый из ★') ], [ 'best', _('лучший по проверке') ]
			], (v) => this.handleAuto(v)), ...pick ]),
			...((ifs.length || cfg.backup_iface) ? sui.kv(_('Резервный канал'), backup) : []),
			...sui.kv(_('Если узел пропал'), sui.select(cfg.node_missing == 'best' ? 'best' : 'stop', [
				[ 'stop', _('лучший из ★, иначе не запускать Stella') ], [ 'best', _('лучший из ★, иначе лучший из всех') ]
			], set('node_missing')))
		]);
	},

	handleWarp() {
		return callWarp(undefined).then(() => this.refresh());
	},

	// Сохранить настройку и запомнить её у себя.
	setting(key, v) {
		return sui.saveSettings({ [key]: v }).then((ok) => ok && (this.cfg[key] = v));
	},

	signature(d) {
		return JSON.stringify([ d.selected, d.select_mode, d.picking, d.updating, d.warping, d.auto_nodes, d.backup, d.mwan3, d.errors.length, d.nodes.length,
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
			meta.push(_('обновлено %s').format(sui.time(src.updated)));
		if (src.kind == 'subscription' && !src.enabled)
			meta.push(_('выключена'));
		return meta.join(' · ');
	},

	renderBusy() {
		const d = this.data;
		dom.content(this.busyBox, [
			d.pinging ? E('em', { 'class': 'spinning' }, _('проверяю задержку…')) : ''
		]);
	},

	updateInPlace() {
		const d = this.data;
		for (const id in this.cells)
			dom.content(this.cells[id], pingLabel(d.ping[id], d.stability[id]));
		for (const src of d.sources)
			if (this.metas[src.id])
				this.metas[src.id].textContent = this.metaText(src);
		this.renderBusy();
		// Строка текущего узла не пересобирается (иначе закрывался бы открытый выбор режима) —
		// меняется только её задержка.
		const cur = d.nodes.find((x) => x.id == d.selected);
		if (cur && this.curPing)
			dom.content(this.curPing, pingLabel(d.ping[cur.id], d.stability[cur.id]));
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
			[ _('Ссылка «%s» не разобрана: %s').format(e.name, e.error) ]));

		if (!d.sources.length) {
			dom.content(this.groupsBox, [ ...errors, E('p', {}, _('Серверов пока нет.')) ]);
			return;
		}

		const groups = d.sources.map((src) => {
			let list = d.nodes.filter((n) => n.source == src.id);
			if (q)
				list = list.filter((n) => n.name.toLowerCase().indexOf(q) >= 0);
			if (q && !list.length)
				return null;
			list = sui.sorted(list, this.sort, (n, key) => (key == 'ping') ? rank(n) : n.name);

			const isSub = (src.kind == 'subscription'), isWarp = (src.kind == 'warp');

			const rows = list.map((n) => {
				const sel = (n.id == d.selected);
				const star = d.auto_nodes.indexOf(n.id) >= 0;
				return sui.tr([
					sui.td(null, E('span', {
						'class': 'st-star' + (star ? '' : ' off'),
						'title': star ? _('Убрать из автовыбора') : _('Добавить в автовыбор'),
						'click': ui.createHandlerFn(this, 'handleAuto', undefined, n.id, !star)
					}, sui.icon('star', star)), 'st-starcell'),
					sui.td(null, [
						sel ? E('strong', {}, [ '✓ ' + n.name ]) : n.name,
						(n.warnings && n.warnings.length) ? E('span', { 'title': n.warnings.join('\n'), 'style': 'cursor:help' }, ' ⚠') : '',
						E('span', { 'class': 'st-type' }, typeLabel(n))
					], 'st-name'),
					(this.cells[n.id] = sui.td(null, pingLabel(d.ping[n.id], d.stability[n.id]), 'st-ping')),
					sui.td(null, [
						sel ? '' : smallBtn(_('Выбрать'), '', () => this.handleSelect(n.id), 'cbi-button-apply'),
						' ',
						smallBtn(_('Проверить'), _('Проверить задержку'), () => this.handlePing([ n.id ]), 'cbi-button-action'),
						' ',
						isSub ? '' : smallBtn(_('Удалить'), '', () => this.handleRemove(n.id, n.name), 'cbi-button-remove')
					], 'st-act')
				], sel ? 'st-sel' : '');
			});

			// Группа — раздел, как в LuCI: заголовок h3 (сворачивается), под ним таблица узлов.
			const el = E('details', { 'class': 'cbi-section st-group', 'open': (q || this.open.has(src.id)) ? '' : null }, [
				E('summary', {}, [
					E('h3', {}, [ isSub ? src.name : isWarp ? 'WARP' : _('Отдельные ссылки') ]),
					(this.metas[src.id] = E('span', { 'class': 'st-meta' }, this.metaText(src))),
					// Проверка задержки — правее остальных кнопок.
					E('span', { 'class': 'st-actions' }, [
						isSub ? smallBtn(_('Обновить'), '', () => this.handleUpdate(src.id), 'cbi-button-action') : '',
						isSub ? smallBtn(_('Изменить'), '', () => this.showEdit(src), 'cbi-button-edit') : '',
						// WARP один и создаётся здесь, а не через «Добавить»; чинит его роутер сам.
						(isWarp && d.warping) ? E('em', { 'class': 'spinning' }, _('создаю WARP…')) :
						(isWarp && !src.count) ? smallBtn(_('Создать WARP'), _('Бесплатный узел Cloudflare WARP'), () => this.handleWarp(), 'cbi-button-add') : '',
						list.length ? smallBtn(_('Проверить задержку'), '', () => this.handlePing(list.map((n) => n.id)), 'cbi-button-action') : ''
					])
				]),
				E('div', { 'class': 'st-list', 'data-src': src.id }, sui.table([ '', sui.sortHead(_('Узел'), 'name', this.sort, () => this.renderGroups()),
					sui.sortHead(_('Задержка'), 'ping', this.sort, () => this.renderGroups()), '' ], rows, 'st-nodes',
					isWarp ? _('Узла пока нет.') : _('Узлов нет.')))
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
		this.currentBox = sui.card([]);
		this.busyBox = E('span', { 'style': 'white-space:nowrap' });
		this.groupsBox = E('div');

		const bar = E('div', { 'class': 'st-bar' }, [
			E('input', {
				'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('Поиск по названию…'),
				'input': (ev) => { this.filter = ev.target.value; this.renderGroups(); }
			}),
			this.busyBox,
			smallBtn(_('Проверить задержку всех'), _('Проверить задержку всех узлов'), () => this.handlePing([]), 'cbi-button-action')
		]);

		this.renderAll();
		if (data.pinging || data.updating || data.picking || data.warping)
			this.refresh();

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Серверы')),
			sui.section(null, this.currentBox),
			bar,
			this.groupsBox,
			sui.create(_('Добавить'), () => this.showAdd())
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

