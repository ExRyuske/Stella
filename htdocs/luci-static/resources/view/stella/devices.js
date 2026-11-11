'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';
'require uci';
'require stella.common as sui';

// Устройства сети — стоковый список LuCI (аренды DHCP, соседи) и добавленные вручную. Чтобы
// устройство было легко узнать: название (своё или имя из DHCP), IP и MAC. Режим меняется прямо
// в строке и применяется сразу.

const callLists = rpc.declare({ object: 'stella', method: 'lists' });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callNetDevices = rpc.declare({ object: 'luci-rpc', method: 'getNetworkDevices', expect: { '': {} } });

const POLICIES = [
	[ 'global', _('по спискам') ],
	[ 'vpn', _('всё через VPN') ],
	[ 'direct', _('всё напрямую') ]
];

const CSS = `
.st-devtable .cbi-dropdown { min-width:10em; max-width:14em }
@media (max-width:854px) { .st-devtable .cbi-dropdown { min-width:0; max-width:100% } }
`;

function label(d) {
	return d.name || d.hostname || '';
}

return view.extend({
	load() {
		return sui.need(21).then(() => Promise.all([ sui.devices(), callLists(), callSettings(), callNetDevices().catch(() => ({})) ]));
	},

	// Интерфейсы LAN, с которых перехватывается трафик (обычно br-lan; гостевая сеть — отдельный мост).
	renderLan() {
		const cur = [].concat(this.cfg.lan_ifname || [ 'br-lan' ]);
		const names = Object.keys(this.netdevs).filter((n) => n != 'lo' && !/^(ifb|teql|gre|ip6|sit|erspan)/.test(n));
		const choices = {};
		for (const n of [ ...new Set([ ...names, ...cur ]) ].sort())
			choices[n] = (this.netdevs[n] && this.netdevs[n].type == 1 && this.netdevs[n].devtype == 'bridge') ? '%s (%s)'.format(n, _('мост')) : n;
		const w = new ui.Dropdown(cur, choices, { multiple: true, optional: false, sort: true });
		const el = w.render();
		el.addEventListener('widget-change', () => {
			const v = [].concat(w.getValue() || []).filter((x) => x);
			if (!v.length || v.join(' ') == [].concat(this.cfg.lan_ifname || []).join(' '))
				return;
			sui.saveSettings({ lan_ifname: v }).then((ok) => {
				if (ok) {
					this.cfg.lan_ifname = v;
					this.refresh();
				}
			});
		});
		// IPv6 устройств закрыт (по умолчанию): перехват Stella — только для IPv4.
		const ipv6 = sui.checkbox((this.cfg.block_ipv6 || '1') == '1', (on) => sui.saveSettings({ block_ipv6: on ? '1' : '0' })
			.then((ok) => ok && (this.cfg.block_ipv6 = on ? '1' : '0')));
		return sui.card([
			...sui.kv(_('Интерфейсы LAN'), [ el, sui.hint(_('Трафик перехватывается только с этих интерфейсов.')) ]),
			...sui.kv(_('Блокировать IPv6'), [ ipv6, sui.hint(_('Устройства выходят в интернет только по IPv4.')) ])
		]);
	},

	refresh() {
		return Promise.all([ sui.devices(), callLists() ]).then(([ d, l ]) => {
			this.devices = d;
			this.lists = l.lists;
			this.renderTable();
		});
	},

	// Название и режим устройства — секция device (у нового — dev_<MAC>); name не задан — не трогать.
	save(mac, name, policy) {
		const known = this.devices.find((d) => d.mac == mac && d.id);
		return sui.edit(() => {
			const sid = known ? known.id : 'dev_' + mac.replace(/:/g, '');
			if (!uci.get('stella', sid))
				uci.add('stella', 'device', sid);
			sui.set(sid, 'mac', mac);
			if (name != null)
				sui.set(sid, 'name', name);
			sui.set(sid, 'policy', policy);
		}).then(() => this.refresh());
	},

	// Окно: новое устройство (по MAC) или название и режим известного.
	showEdit(dev) {
		const mac = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': dev ? dev.mac : '', 'placeholder': 'aa:bb:cc:dd:ee:ff' });
		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': dev ? (dev.name || '') : '',
			'placeholder': (dev && dev.hostname) || _('необязательно') });
		let policy = dev ? dev.policy : 'global';
		const sel = sui.select(policy, POLICIES, (v) => policy = v);
		const save = () => {
			const m = mac.value.trim().toLowerCase();
			if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(m))
				return ui.addNotification(null, E('p', {}, _('Нужен MAC вида aa:bb:cc:dd:ee:ff.')), 'warning');
			ui.hideModal();
			return this.save(m, name.value.trim(), policy);
		};
		ui.showModal(dev ? (label(dev) || dev.mac) : _('Новое устройство'), [
			sui.card([
				dev ? sui.field('IP, MAC', [ [ dev.ip, dev.mac ].filter((x) => x).join(', ') ]) : sui.field('MAC', mac),
				sui.field(_('Название'), name),
				sui.field(_('Режим'), sel)
			]),
			E('div', { 'class': 'st-buttons' }, [
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, save) }, _('Сохранить'))
			])
		]);
	},

	// Списки, которые действуют на устройство особо: «только для него» или «кроме него».
	special(dev) {
		const res = [];
		for (const l of this.lists)
			if (l.enabled && l.devices_mode != 'all' && l.macs.indexOf(dev.mac) >= 0)
				res.push((l.devices_mode == 'only' ? _('только: %s') : _('кроме: %s')).format(l.name));
		return res.join(', ');
	},

	renderTable() {
		const q = (this.filter || '').toLowerCase();
		const devs = this.devices.filter((d) => !q ||
			[ label(d), d.ip || '', d.mac ].some((v) => v.toLowerCase().indexOf(q) >= 0)
		).sort((a, b) =>
			(b.configured - a.configured) || (!label(a) - !label(b)) ||
			label(a).localeCompare(label(b)) || String(a.ip || '').localeCompare(String(b.ip || ''), undefined, { numeric: true }));

		dom.content(this.tableBox, sui.dataTable('devices', [ _('Устройство'), 'IP', 'MAC', _('Режим'), [ '', 'cbi-section-actions' ] ], devs.map((d) => {
			const sp = this.special(d);
			return { cells: [
				E('div', {}, [
					E('div', {}, [ label(d) || E('span', { 'class': 'st-dim' }, _('без имени')) ]),
					sp ? E('div', { 'class': 'st-dim st-scope' }, [ sp ]) : ''
				]),
				d.ip || '—',
				d.mac,
				// Сортировка — по названию режима, а не по тексту всего списка.
				E('div', { 'data-value': d.policy }, sui.select(d.policy, POLICIES, (v) => this.save(d.mac, undefined, v))),
				E('div', {}, [
					sui.rowButton(_('Изменить'), 'edit', () => this.showEdit(d)),
					d.configured ? sui.rowButton(_('Забыть'), 'remove', () => sui.edit(() => uci.remove('stella', d.id)).then(() => this.refresh())) : ''
				])
			] };
		}), 'st-devtable', this.devices.length ? _('Ничего не найдено.') : _('Устройства не найдены.')));
	},

	render([ devs, lists, cfg, netdevs ]) {
		this.devices = devs;
		this.lists = lists.lists;
		this.cfg = cfg;
		this.netdevs = netdevs || {};
		this.tableBox = E('div');
		this.renderTable();
		// Новые устройства появляются сами: раз в 30 с.
		poll.add(() => this.tableBox.querySelector('.cbi-dropdown[open]') ? Promise.resolve() : this.refresh(), 30);

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Устройства')),
			sui.section(null, this.renderLan()),
			sui.section(null, [
				E('div', { 'class': 'st-bar' }, [
					E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('Поиск по имени, IP или MAC…'),
						'input': (ev) => { this.filter = ev.target.value; this.renderTable(); } })
				]),
				this.tableBox,
				sui.create(_('Добавить'), () => this.showEdit(null))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

