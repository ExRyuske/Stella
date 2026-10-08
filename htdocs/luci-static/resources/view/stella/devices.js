'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require stella.ui as sui';

const callDevices = rpc.declare({ object: 'stella', method: 'devices' });
const callLists = rpc.declare({ object: 'stella', method: 'lists' });
const callSet = rpc.declare({ object: 'stella', method: 'device_set', params: [ 'mac', 'name', 'policy' ] });
const callRemove = rpc.declare({ object: 'stella', method: 'device_remove', params: [ 'id' ] });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });

const POLICIES = [
	[ 'global', _('По спискам') ],
	[ 'vpn', _('Всё через VPN') ],
	[ 'direct', _('Всё напрямую') ]
];

const CSS = `
.st-table { width:100%; border-collapse:collapse }
.st-table td, .st-table th { padding:.35em .6em; border-bottom:1px solid rgba(128,128,128,.15); vertical-align:middle; text-align:left }
.st-table th { font-weight:normal; opacity:.6; font-size:90% }
.st-table select { width:auto; min-width:10em }
.st-dim { opacity:.6; font-size:85% }
.st-act { text-align:right; white-space:nowrap; width:1% }
.st-act .btn { line-height:1.8em; min-height:0 }
.st-bar { display:flex; gap:.5em; align-items:center; margin:.5em 0 1em }
`;

return view.extend({
	load() {
		return Promise.all([ callDevices(), callLists(), callSettings() ]);
	},

	// Интерфейсы LAN, с которых перехватывается трафик (обычно br-lan; гостевая сеть — отдельный мост).
	renderLan() {
		const ifs = [].concat(this.cfg.lan_ifname || [ 'br-lan' ]);
		const input = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': ifs.join(' '), 'style': 'width:14em' });
		const save = E('button', { 'class': 'btn cbi-button', 'style': 'display:none',
			'click': ui.createHandlerFn(this, () => {
				const list = input.value.split(/[\s,]+/).filter((x) => x);
				return sui.saveSettings({ lan_ifname: list }).then((ok) => {
					if (!ok)
						return;
					this.cfg.lan_ifname = list;
					save.style.display = 'none';
					ui.addTimeLimitedNotification(null, E('p', {}, _('Применено.')), 3000, 'info');
				});
			}) }, _('Сохранить'));
		input.addEventListener('input', () => save.style.display = '');
		return E('div', { 'class': 'st-bar st-dim', 'style': 'margin-top:1em' }, [
			_('Интерфейсы LAN:'), input, save
		]);
	},

	refresh() {
		return Promise.all([ callDevices(), callLists() ]).then((r) => {
			this.devices = r[0].devices;
			this.lists = r[1].lists;
			this.renderTable();
		});
	},

	save(dev, name, policy) {
		return callSet(dev.mac, name, policy).then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
			return this.refresh();
		});
	},

	showEdit(dev) {
		const mac = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'width:100%', 'value': dev ? dev.mac : '', 'placeholder': 'AA:BB:CC:DD:EE:FF', 'disabled': dev ? '' : null });
		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'width:100%', 'value': dev ? (dev.name || '') : '', 'placeholder': dev ? (dev.hostname || '') : '' });
		ui.showModal(dev ? _('Устройство') : _('Добавить устройство'), [
			E('p', {}, [ E('b', {}, 'MAC'), mac ]),
			E('p', {}, [ E('b', {}, _('Название')), name ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')), ' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, () => {
						ui.hideModal();
						return this.save({ mac: mac.value.trim() }, name.value.trim(), dev ? undefined : 'global');
					})
				}, _('Сохранить'))
			])
		]);
	},

	// Списки, которые действуют на устройство особо: «только для него» или «кроме него».
	special(dev) {
		const res = [];
		for (const l of this.lists) {
			if (!l.enabled || l.devices_mode == 'all' || l.macs.indexOf(dev.mac) < 0)
				continue;
			res.push((l.devices_mode == 'only' ? '+ ' : '− ') + l.name);
		}
		return res.join(', ');
	},

	renderTable() {
		const label = (d) => d.name || d.hostname || '';
		const q = (this.filter || '').toLowerCase();
		const devs = this.devices.filter((d) => !q ||
			[ label(d), d.ip || '', d.mac ].some((v) => v.toLowerCase().indexOf(q) >= 0)
		).sort((a, b) =>
			(b.configured - a.configured) || (!label(a) - !label(b)) ||
			label(a).localeCompare(label(b)) || String(a.ip).localeCompare(String(b.ip), undefined, { numeric: true }));

		if (!devs.length) {
			dom.content(this.tableBox, E('p', {}, _('Устройства не найдены.')));
			return;
		}

		dom.content(this.tableBox, E('table', { 'class': 'st-table' }, [
			E('tr', {}, [ E('th', {}, _('Устройство')), E('th', {}, _('Адрес')), E('th', {}, _('Режим')), E('th', {}, '') ]),
			...devs.map((dev) => {
				const sp = (dev.policy == 'global') ? this.special(dev) : '';
				return E('tr', {}, [
					E('td', {}, [
						E('div', {}, [ label(dev) || E('span', { 'class': 'st-dim' }, _('без имени')) ]),
						sp ? E('div', { 'class': 'st-dim', 'title': _('+ только для этого устройства, − не действует на него') }, [ sp ]) : ''
					]),
					E('td', { 'class': 'st-dim' }, [ E('div', {}, dev.ip || ''), E('div', {}, dev.mac) ]),
					E('td', {}, E('select', {
						'class': 'cbi-input-select',
						'change': (ev) => this.save(dev, undefined, ev.target.value)
					}, POLICIES.map((p) => E('option', { 'value': p[0], 'selected': p[0] == dev.policy ? '' : null }, p[1])))),
					E('td', { 'class': 'st-act' }, [
						sui.iconButton('edit', _('Название'), () => this.showEdit(dev)),
						' ',
						dev.configured ? sui.iconButton('close', _('Забыть устройство'), () => callRemove(dev.id).then(() => this.refresh())) : ''
					])
				]);
			})
		]));
	},

	render(r) {
		this.devices = r[0].devices;
		this.lists = r[1].lists;
		this.cfg = r[2];
		this.tableBox = E('div');
		this.renderTable();

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Устройства')),
			E('div', { 'class': 'st-bar' }, [
				E('button', { 'class': 'btn cbi-button-add', 'click': () => this.showEdit(null) }, _('Добавить по MAC')),
				E('input', { 'class': 'cbi-input-text', 'type': 'text', 'style': 'flex:1', 'placeholder': _('Поиск по имени, IP или MAC…'),
					'input': (ev) => { this.filter = ev.target.value; this.renderTable(); } })
			]),
			this.tableBox,
			this.renderLan()
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
