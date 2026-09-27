'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

const callStatus = rpc.declare({ object: 'stella', method: 'status' });
const callCheck = rpc.declare({ object: 'stella', method: 'check' });
const callRestart = rpc.declare({ object: 'stella', method: 'restart' });
const callSetEnabled = rpc.declare({ object: 'stella', method: 'set_enabled', params: [ 'enabled' ] });
const callLog = rpc.declare({ object: 'stella', method: 'log', expect: { log: '' } });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callSettingsSet = rpc.declare({ object: 'stella', method: 'settings_set', params: [ 'values' ] });

const DNS_REMOTE = [
	[ 'https://1.1.1.1/dns-query', 'Cloudflare (DoH) — https://1.1.1.1/dns-query' ],
	[ 'https://8.8.8.8/dns-query', 'Google (DoH) — https://8.8.8.8/dns-query' ],
	[ 'https://9.9.9.9/dns-query', 'Quad9 (DoH) — https://9.9.9.9/dns-query' ]
];
const DNS_DIRECT = [
	[ 'https://77.88.8.8/dns-query', _('Яндекс (DoH) — https://77.88.8.8/dns-query') ],
	[ 'https://1.1.1.1/dns-query', 'Cloudflare (DoH) — https://1.1.1.1/dns-query' ],
	[ 'https://8.8.8.8/dns-query', 'Google (DoH) — https://8.8.8.8/dns-query' ]
];

// Выпадающий список LuCI с готовыми вариантами и своим значением.
function combo(value, choices, onchange, opts) {
	const w = new ui.Combobox(value, Object.fromEntries(choices), Object.assign({ sort: false, custom_placeholder: _('свой вариант…') }, opts));
	const el = w.render();
	el.addEventListener('widget-change', () => onchange(w.getValue()));
	return el;
}


const CSS = `
.st-card { display:grid; grid-template-columns:max-content 1fr; gap:.6em 1.2em; align-items:center; padding:1em; border:1px solid rgba(128,128,128,.3); border-radius:4px; margin-bottom:1em }
.st-card .st-k { opacity:.65 }
.st-card select, .st-card input[type=text] { width:auto; max-width:100% }
.st-card .cbi-dropdown { min-width:26em; max-width:100% }
.st-head { display:flex; align-items:center; gap:1em; flex-wrap:wrap; margin-bottom:1em }
.st-head .st-state { font-size:120%; font-weight:bold }
.st-head .btn { margin-left:auto }
.st-ok { color:#2a2 } .st-bad { color:#c33 } .st-dim { opacity:.55; font-size:90% }
.st-log summary { cursor:pointer; padding:.4em 0 }
.st-log textarea { width:100%; font-family:monospace; font-size:12px }
.st-row { display:flex; gap:.5em; align-items:center; flex-wrap:wrap }
`;

return view.extend({
	load() {
		return Promise.all([ callStatus(), callSettings() ]);
	},

	renderStatus(st) {
		let state, btn;
		if (!st.enabled) {
			state = E('span', { 'class': 'st-state st-dim' }, _('Выключено'));
			btn = E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleEnable', true) }, _('Включить'));
		}
		else {
			state = st.running ?
				E('span', { 'class': 'st-state st-ok' }, _('Работает')) :
				E('span', { 'class': 'st-state st-bad' }, _('Не запущено — см. лог'));
			btn = E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'handleEnable', false) }, _('Выключить'));
		}

		let node;
		if (st.node)
			node = [ E('strong', {}, st.node.name), ' ',
				E('span', { 'class': 'st-dim' }, st.node.source == 'manual' ? _('отдельная ссылка') : st.node.source) ];
		else if (st.node_id)
			node = [ E('span', { 'class': 'st-bad' }, _('выбранный узел пропал из списка')) ];
		else
			node = [ E('span', { 'class': 'st-bad' }, _('не выбран')) ];

		dom.content(this.statusBox, [
			E('div', { 'class': 'st-head' }, [ state, btn ]),
			E('div', { 'class': 'st-card' }, [
				E('span', { 'class': 'st-k' }, _('Узел')),
				E('span', {}, [ ...node, ' ', E('a', { 'href': L.url('admin/services/stella/servers') }, _('сменить')) ]),
				E('span', { 'class': 'st-k' }, _('Выход в интернет')),
				E('span', {}, this.checkBox),
				E('span', {}, ''),
				E('span', {}, st.enabled ? E('button', {
					'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleRestart')
				}, _('Перезапустить')) : '')
			])
		]);
	},

	save(values) {
		return callSettingsSet(values).then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
			else
				ui.addTimeLimitedNotification(null, E('p', {}, _('Применено.')), 3000, 'info');
		});
	},

	dnsField(key, value, choices) {
		return combo(value, choices, (v) => this.save({ [key]: v }));
	},

	flag(key, value, label) {
		return E('label', {}, [
			E('input', { 'type': 'checkbox', 'checked': value == '1' ? '' : null,
				'change': (ev) => this.save({ [key]: ev.target.checked ? '1' : '0' }) }),
			' ', label
		]);
	},

	renderDns(cfg) {
		return E('div', {}, [
			E('h3', {}, 'DNS'),
			E('div', { 'class': 'st-card' }, [
				E('span', { 'class': 'st-k' }, _('Через VPN')),
				E('span', {}, [ this.dnsField('dns_remote', cfg.dns_remote, DNS_REMOTE),
					E('div', { 'class': 'st-dim' }, _('Все DNS-запросы устройств.')) ]),
				E('span', { 'class': 'st-k' }, _('Напрямую')),
				E('span', {}, [ this.dnsField('dns_direct', cfg.dns_direct, DNS_DIRECT),
					E('div', { 'class': 'st-dim' }, _('Адреса VPN-серверов и запасной, если VPN недоступен.')) ]),
				E('span', {}, ''),
				E('span', {}, [
					E('div', {}, this.flag('dns_hijack', cfg.dns_hijack, _('Перехватывать DNS устройств (иначе списки не работают на устройствах со своим DNS)'))),
					E('div', {}, this.flag('block_doh', cfg.block_doh, _('Блокировать DNS-over-HTTPS устройств (браузеры с «безопасным DNS»)')))
				])
			])
		]);
	},

	handleEnable(on) {
		return callSetEnabled(on).then(() => new Promise((r) => setTimeout(r, 2500))).then(() => this.poll());
	},

	handleRestart() {
		return callRestart().then(() => new Promise((r) => setTimeout(r, 2500))).then(() => this.poll());
	},

	handleCheck() {
		dom.content(this.checkBox, E('em', { 'class': 'spinning' }, _('проверяю…')));
		const again = E('a', { 'href': '#', 'click': (ev) => { ev.preventDefault(); this.handleCheck(); } }, _('ещё раз'));
		return callCheck().then((r) => {
			dom.content(this.checkBox, r.error ? [ E('span', { 'class': 'st-bad' }, r.error), ' ', again ] : [
				E('strong', {}, r.ip), ' — ', r.country || '?', ', ', r.org || '', ' ',
				E('span', { 'class': 'st-dim' }, '(%d мс)'.format(r.ms)), ' ', again
			]);
		}).catch((e) => dom.content(this.checkBox, [ E('span', { 'class': 'st-bad' }, e.message), ' ', again ]));
	},

	handleLog() {
		return callLog().then((log) => {
			this.logBox.value = log || _('Лог пуст.');
			this.logBox.scrollTop = this.logBox.scrollHeight;
		});
	},

	poll() {
		return callStatus().then((st) => this.renderStatus(st));
	},

	render(r) {
		const [ st, cfg ] = r;
		this.statusBox = E('div');
		this.checkBox = E('span', {}, E('button', {
			'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck')
		}, _('Проверить')));
		this.logBox = E('textarea', { 'class': 'cbi-input-textarea', 'readonly': 'readonly', 'wrap': 'off', 'rows': 15 });

		this.renderStatus(st);
		poll.add(() => this.poll(), 5);

		const level = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto',
			'change': (ev) => this.save({ log_level: ev.target.value }) },
			[ 'error', 'warning', 'info', 'debug' ].map((l) => E('option', { 'value': l, 'selected': l == cfg.log_level ? '' : null }, l)));

		const log = E('details', { 'class': 'st-log' }, [
			E('summary', {}, _('Лог')),
			this.logBox,
			E('div', { 'class': 'st-row', 'style': 'justify-content:flex-end' }, [
				_('Подробность лога xray:'), level,
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleLog') }, _('Обновить'))
			])
		]);
		log.addEventListener('toggle', () => { if (log.open) this.handleLog(); });

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, 'Stella'),
			this.statusBox,
			this.renderDns(cfg),
			log
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
