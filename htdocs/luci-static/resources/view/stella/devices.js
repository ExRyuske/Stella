'use strict';
'require view';
'require form';
'require uci';
'require network';
'require tools.widgets as widgets';

// Устройства с особым режимом и интерфейсы LAN. Таблица без своего заголовка — как в
// «Система → LED»: заголовок страницы и есть её название.
return view.extend({
	load() {
		return network.getHostHints();
	},

	render(hosts) {
		const m = new form.Map('stella', _('Устройства'));

		let s = m.section(form.GridSection, 'device', '');
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;

		let o = s.option(form.Value, 'mac', 'MAC');
		o.datatype = 'macaddr';
		o.rmempty = false;
		for (const [ mac, hint ] of hosts.getMACHints())
			o.value(mac, hint ? '%s (%s)'.format(mac, hint) : mac);
		o.textvalue = function(sid) {
			const mac = this.cfgvalue(sid) || '';
			const hint = hosts.getHostnameByMACAddr(mac) || hosts.getIPAddrByMACAddr(mac);
			return '%h'.format(hint ? '%s (%s)'.format(mac, hint) : mac);
		};

		o = s.option(form.Value, 'name', _('Название'));
		o.placeholder = _('необязательно');

		o = s.option(form.ListValue, 'policy', _('Режим'));
		o.value('global', _('по спискам'));
		o.value('vpn', _('всё через VPN'));
		o.value('direct', _('всё напрямую'));
		o.default = 'global';
		o.editable = true;

		// Списки, которые действуют на устройство особо: «только для него» или «кроме него».
		o = s.option(form.DummyValue, '_lists', _('Особые списки'));
		o.modalonly = false;
		o.cfgvalue = function(sid) {
			const mac = String(uci.get('stella', sid, 'mac') || '').toLowerCase();
			const res = [];
			for (const l of uci.sections('stella', 'list')) {
				const macs = L.toArray(l.mac).map((x) => String(x).toLowerCase());
				if (mac && l.enabled != '0' && (l.devices_mode == 'only' || l.devices_mode == 'except') && macs.indexOf(mac) >= 0)
					res.push((l.devices_mode == 'only' ? _('только: %s') : _('кроме: %s')).format(l.name || l['.name']));
			}
			return res.join(', ') || '—';
		};

		s = m.section(form.NamedSection, 'main', 'stella');
		o = s.option(widgets.DeviceSelect, 'lan_ifname', _('Интерфейсы LAN'), _('Трафик перехватывается только с этих интерфейсов.'));
		o.multiple = true;
		o.noaliases = true;
		o.default = 'br-lan';
		o.rmempty = false;

		return m.render();
	}
});
