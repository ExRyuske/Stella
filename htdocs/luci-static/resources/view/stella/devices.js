'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';
'require stella.common as sui';

// Устройства сети — все, что видны роутеру на интерфейсах LAN (аренды DHCP, соседи ARP), и
// добавленные вручную. Чтобы устройство было легко узнать: название (своё или имя из DHCP), IP,
// MAC и в сети ли оно сейчас. Режим меняется прямо в строке и применяется сразу.

const callDevices = rpc.declare({ object: 'stella', method: 'devices' });
const callLists = rpc.declare({ object: 'stella', method: 'lists' });
const callSet = rpc.declare({ object: 'stella', method: 'device_set', params: [ 'mac', 'name', 'policy' ] });
const callRemove = rpc.declare({ object: 'stella', method: 'device_remove', params: [ 'id' ] });
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
.st-on { color:#2a2; white-space:nowrap }
.st-on::before { content:'●'; margin-right:.3em }
.st-offline { opacity:.55 }
`;

function label(d) {
	return d.name || d.hostname || '';
}

// «был в 10:42» сегодня, иначе с датой.
function seenText(ts) {
	if (!ts)
		return '—';
	const t = new Date(ts * 1000), now = new Date();
	return (t.toDateString() == now.toDateString())
		? _('был в %s').format(t.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }))
		: _('был %s').format(t.toLocaleString('ru-RU', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }));
}

return view.extend({
	load() {
		return sui.need(14).then(() => Promise.all([ callDevices(), callLists(), callSettings(), callNetDevices().catch(() => ({})) ]));
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
		return Promise.all([ callDevices(), callLists() ]).then(([ d, l ]) => {
			this.devices = d.devices;
			this.lists = l.lists;
			this.renderTable();
		});
	},

	save(mac, name, policy) {
		return callSet(mac, name, policy).then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
			return this.refresh();
		});
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
			E('div', { 'class': 'button-row' }, [
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
			(b.online - a.online) || (b.configured - a.configured) || (!label(a) - !label(b)) ||
			label(a).localeCompare(label(b)) || String(a.ip || '').localeCompare(String(b.ip || ''), undefined, { numeric: true }));

		dom.content(this.tableBox, sui.table([ _('Устройство'), 'IP', 'MAC', _('В сети'), _('Режим'), '' ], devs.map((d) => {
			const sp = this.special(d);
			return sui.tr([
				sui.td(_('Устройство'), [
					E('div', {}, [ label(d) || E('span', { 'class': 'st-dim' }, _('без имени')) ]),
					sp ? E('div', { 'class': 'st-dim st-scope' }, [ sp ]) : ''
				]),
				sui.td('IP', d.ip || '—'),
				sui.td('MAC', E('span', { 'class': 'st-dim' }, d.mac)),
				sui.td(_('В сети'), d.online ? E('span', { 'class': 'st-on' }, _('в сети')) : sui.dim(seenText(d.seen))),
				sui.td(_('Режим'), sui.select(d.policy, POLICIES, (v) => this.save(d.mac, undefined, v))),
				sui.td(null, [
					sui.rowButton(_('Изменить'), 'edit', () => this.showEdit(d)),
					' ',
					d.configured ? sui.rowButton(_('Забыть'), 'remove', () => callRemove(d.id).then(() => this.refresh())) : ''
				], 'st-act')
			], d.online ? '' : 'st-offline');
		}), 'st-devtable', this.devices.length ? _('Ничего не найдено.') : _('Устройства не найдены.')));
	},

	render([ devs, lists, cfg, netdevs ]) {
		this.devices = devs.devices;
		this.lists = lists.lists;
		this.cfg = cfg;
		this.netdevs = netdevs || {};
		this.tableBox = E('div');
		this.renderTable();
		// Кто в сети — меняется: раз в 30 с.
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

