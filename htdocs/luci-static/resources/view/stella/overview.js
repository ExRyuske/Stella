'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require stella.common as sui';

const callStatus = rpc.declare({ object: 'stella', method: 'status' });
const callCheck = rpc.declare({ object: 'stella', method: 'check' });
const callRestart = rpc.declare({ object: 'stella', method: 'restart' });
const callSpeedtest = rpc.declare({ object: 'stella', method: 'speedtest' });
const callSetEnabled = rpc.declare({ object: 'stella', method: 'set_enabled', params: [ 'enabled' ] });
const callLog = rpc.declare({ object: 'stella', method: 'log', expect: { log: '' } });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callUpdateInfo = rpc.declare({ object: 'stella', method: 'update_info' });
const callUpdateCheck = rpc.declare({ object: 'stella', method: 'update_check' });
const callUpdateInstall = rpc.declare({ object: 'stella', method: 'update_install', params: [ 'what' ] });

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

const CSS = `
.st-dns .cbi-dropdown { min-width:26em }
.st-state { font-size:120%; font-weight:bold }
.st-out:empty { display:none }
.st-log summary { cursor:pointer; padding:.4em 0 }
.st-log textarea { width:100%; font-family:monospace; font-size:12px }
`;

// «0.1.14-r1» → «0.1.14», «v0.1.14» → «0.1.14».
function ver(v) {
	return v ? String(v).replace(/^v/, '').replace(/-r[0-9]+$/, '') : v;
}

return view.extend({
	load() {
		return sui.need(3).then(() => Promise.all([ callStatus(), callSettings(), callUpdateInfo() ]));
	},

	renderStatus(st) {
		let state;
		if (!st.enabled)
			state = E('span', { 'class': 'st-state st-dim' }, _('Выключено'));
		else if (!st.running)
			state = E('span', { 'class': 'st-state st-bad' }, _('Не запущено, см. лог'));
		else if (!st.intercept)
			state = E('span', { 'class': 'st-state st-bad' }, _('Перехват не работает, см. лог'));
		else
			state = E('span', { 'class': 'st-state st-ok' }, _('Работает'));

		// Узел — ссылкой на «Серверы»: там он и меняется. (LuCI не разворачивает вложенные
		// массивы — здесь всё плоско.)
		const href = L.url('admin/services/stella/servers');
		let node;
		if (st.node)
			node = [ E('a', { 'href': href }, [ st.node.name ]), ', ', st.node.source == 'manual' ? _('отдельная ссылка') : st.node.source,
				st.backup ? ', ' : '', st.backup ? E('span', { 'class': 'st-bad' }, _('резервный канал %s').format(st.backup)) : '' ];
		else if (st.node_id)
			node = [ E('a', { 'href': href, 'class': 'st-bad' }, _('выбранный узел пропал из списка')) ];
		else if (st.select_mode == 'auto')
			node = [ E('a', { 'href': href }, _('автовыбор из ★')) ];
		else if (st.select_mode == 'best')
			node = [ E('a', { 'href': href }, _('лучший по проверке, ещё не подобран')) ];
		else
			node = [ E('a', { 'href': href, 'class': 'st-bad' }, _('узел не выбран')) ];

		dom.content(this.statusBox, E('div', { 'class': 'st-card' }, [
			E('div', { 'class': 'st-wide st-row' }, [
				state, E('span', {}, [ '(', ...node, ')' ]), E('span', { 'style': 'flex:1' }),
				st.enabled ? E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleRestart') }, _('Перезапустить')) : '',
				st.enabled ?
					E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'handleEnable', false) }, _('Выключить')) :
					E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleEnable', true) }, _('Включить'))
			]),
			...sui.kv(_('Проверка'), [ this.checkBtn, this.checkOut ]),
			...sui.kv(_('Скорость'), [ this.speedBtn, this.speedOut ], _('загрузка с speed.cloudflare.com'))
		]));
		this.renderSpeed(st);
	},

	// Итог проверки скорости (или её ход) — из status, который опрашивается каждые 5 с.
	renderSpeed(st) {
		const s = st.speed;
		this.speedBtn.disabled = !!st.speedtesting;
		if (st.speedtesting) {
			dom.content(this.speedOut, E('em', { 'class': 'spinning' },
				(s && s.step == 'vpn') ? _('проверяю через VPN…') : _('проверяю напрямую…')));
			return;
		}
		if (!s || s.step) {
			dom.content(this.speedOut, '');
			return;
		}
		const mbps = (v) => (v == null) ? E('span', { 'class': 'st-bad' }, _('нет ответа')) :
			'%s %s'.format(v >= 10 ? Math.round(v) : v.toFixed(1), _('Мбит/с'));
		dom.content(this.speedOut, [
			_('напрямую'), ' ', mbps(s.direct), ', ', _('через VPN'), ' ',
			s.vpn_off ? E('span', { 'class': 'st-bad' }, _('xray не запущен')) : mbps(s.vpn), ' ', sui.dim(sui.time(s.at))
		]);
	},

	save(values) {
		return sui.saveSettings(values).then((ok) => ok && ui.addTimeLimitedNotification(null, E('p', {}, _('Применено.')), 3000, 'info'));
	},

	// Флажок настройки с пояснением под ним.
	flag(key, value, label, hint) {
		return E('div', { 'class': 'st-full' }, [
			E('label', {}, [
				E('input', { 'type': 'checkbox', 'checked': value == '1' ? '' : null,
					'change': (ev) => this.save({ [key]: ev.target.checked ? '1' : '0' }) }),
				' ', label
			]),
			sui.hint(hint)
		]);
	},

	renderDns(cfg) {
		const dns = (key, choices, hint) => [ sui.combo(cfg[key], choices, (v) => this.save({ [key]: v })), sui.hint(hint) ];
		return E('div', { 'class': 'st-card st-dns' }, [
			...sui.kv(_('Через VPN'), dns('dns_remote', DNS_REMOTE, _('Основной DNS для всех устройств, запросы идут через VPN'))),
			...sui.kv(_('Напрямую'), dns('dns_direct', DNS_DIRECT, _('Запасной, если основной не ответил. Запросы идут мимо VPN'))),
			...sui.kv('', [
				this.flag('dns_hijack', cfg.dns_hijack, _('Перехватывать DNS устройств'), _('Запросы к сторонним DNS-серверам (порт 53) уходят на роутер')),
				this.flag('block_doh', cfg.block_doh, _('Блокировать DNS-over-HTTPS'),
					_('DoT и DoH к известным серверам блокируются, и браузеры спрашивают DNS роутера'))
			])
		]);
	},

	/* обновления */

	renderUpdates(u) {
		const info = u.info;
		// До первой проверки — только установленные версии (их rpcd знает и без сети).
		const inst = u.installed || {};
		const btn = (what, text) => E('button', { 'class': 'btn cbi-button-positive', 'disabled': u.installing ? '' : null,
			'click': ui.createHandlerFn(this, 'handleInstall', what) }, [ text ]);
		// Состояние пакета: есть обновление — кнопка и «что нового», ошибка проверки — она, иначе «последняя версия».
		const state = (what, x) => x.available ?
			[ btn(what, _('Обновить до %s').format(ver(x.latest))), x.url ? E('a', { 'href': x.url, 'target': '_blank' }, _('что нового')) : '' ] :
			x.error ? [ sui.dim(x.error) ] : [ info ? E('span', { 'class': 'st-ok' }, _('последняя версия')) : '' ];
		const rows = [];

		const st = info ? info.stella : { installed: inst['luci-app-stella'] };
		rows.push(...sui.kv('Stella', [ st.installed ? ver(st.installed) : _('установлена не пакетом'), ...state('stella', st) ]));

		const xr = info ? info.xray : { installed: inst['xray-core'] };
		rows.push(...sui.kv('xray-core', [ ver(xr.installed) || '—', ...state('xray', xr) ]));

		// Без nftset в dnsmasq IP сайтов из списков не попадают в правила.
		rows.push(...sui.kv('dnsmasq', u.dnsmasq_nftset ? 'full' :
			[ _('без nftset'), btn('dnsmasq', _('Установить dnsmasq-full')), E('span', { 'class': 'st-bad' }, _('без него списки не работают')) ]));

		// Установить можно и без проверки: версию из последнего релиза узнает сама установка.
		const zr = info ? info.zapret : { installed: inst.zapret };
		rows.push(...sui.kv('zapret', zr.installed ? [ ver(zr.installed), ...state('zapret', zr) ] :
			[ _('не установлен'), btn('zapret', zr.latest ? _('Установить %s').format(ver(zr.latest)) : _('Установить')) ]));

		// mwan3 — для резервного канала на «Серверах». Ставится nftables-версия с GitHub (3.x): из
		// репозитория OpenWrt — старая, на iptables, в 25.12 не рекомендуется.
		const nft = (v) => parseInt(v, 10) >= 3;
		const mw = (info && info.mwan3) ? info.mwan3 : { installed: inst.mwan3 };
		rows.push(...sui.kv('mwan3', !mw.installed ?
			[ _('не установлен'), btn('mwan3', mw.latest ? _('Установить %s').format(ver(mw.latest)) : _('Установить')), sui.dim(_('нужен для резервного канала')) ] :
			!nft(mw.installed) ?
			[ ver(mw.installed), btn('mwan3', _('Заменить на nftables-версию')), E('span', { 'class': 'st-bad' }, _('версия на iptables')) ] :
			[ ver(mw.installed), ...state('mwan3', mw), E('a', { 'href': L.url('admin/network/mwan3') }, _('настроить каналы')) ]));

		const busy = u.installing ? _('устанавливаю…') : u.checking ? _('проверяю…') : null;
		rows.push(E('hr'),
			// Автоматически и вручную — одной строкой: расписание, кнопка, когда проверено.
			...sui.kv(_('Автообновление'), [ this.autoUpd,
				busy ? E('em', { 'class': 'spinning' }, busy) :
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleUpdateCheck') }, _('Проверить сейчас')),
				sui.dim(info ? _('проверено %s').format(sui.time(info.at)) : _('ещё не проверялось')) ],
				_('Stella и xray-core, zapret и mwan3, если установлены')));

		dom.content(this.updBox, E('div', { 'class': 'st-card' }, rows));
	},

	pollUpdates() {
		return callUpdateInfo().then((u) => {
			const was = this.upd && this.upd.installing;
			this.upd = u;
			this.renderUpdates(u);
			const busy = u.checking || u.installing;
			if (busy && !this.updPoll) {
				this.updPoll = () => this.pollUpdates();
				poll.add(this.updPoll, 3);
			}
			else if (!busy && this.updPoll) {
				poll.remove(this.updPoll);
				this.updPoll = null;
			}
			if (was && !u.installing) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap' }, [ u.log || _('Готово.') ]), 'info');
				setTimeout(() => location.reload(), 3000);
			}
		}).catch(() => {
			// Во время обновления rpcd перезапускается — вызов может не пройти, это нормально.
		});
	},

	handleUpdateCheck() {
		return callUpdateCheck().then(() => this.pollUpdates());
	},

	handleInstall(what) {
		if (!confirm({ xray: _('Обновить xray-core? Служба перезапустится.'), zapret: _('Установить или обновить zapret?'),
			mwan3: _('Установить mwan3 (nftables) и luci-app-mwan3? Старый mwan3 заменится, настройки сохранятся. Каналы настраиваются в «Сеть → MultiWAN Manager».'),
			dnsmasq: _('Заменить dnsmasq на dnsmasq-full? Настройки сохранятся, DNS на роутере пропадёт на несколько секунд.') }[what] || _('Установить новую версию Stella?')))
			return;
		return callUpdateInstall(what).then(() => this.pollUpdates());
	},

	handleEnable(on) {
		return callSetEnabled(on).then(() => new Promise((r) => setTimeout(r, 2500))).then(() => this.poll());
	},

	handleSpeed() {
		return callSpeedtest().then(() => this.poll());
	},

	handleRestart() {
		return callRestart().then(() => new Promise((r) => setTimeout(r, 2500))).then(() => this.poll());
	},

	handleCheck() {
		dom.content(this.checkOut, '');
		return callCheck().then((r) => {
			dom.content(this.checkOut, (r.steps || []).map((s) => E('div', {}, [
				E('span', { 'class': s.ok ? 'st-ok' : 'st-bad' }, s.ok ? '✓ ' : '✗ '), E('strong', {}, [ s.name ]), ': ', s.detail
			])));
		}).catch((e) => dom.content(this.checkOut, E('span', { 'class': 'st-bad' }, e.message)));
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
		const [ st, cfg, upd ] = r;
		// Карточки перерисовываются при опросе, а кнопки, итоги проверок и выбор интервала
		// создаются один раз — чтобы не терять их состояние.
		this.statusBox = E('div');
		this.updBox = E('div');
		this.checkBtn = E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck') }, _('Проверить'));
		this.checkOut = E('div', { 'class': 'st-out st-full' });
		this.speedBtn = E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleSpeed') }, _('Проверить'));
		this.speedOut = E('span');
		this.autoUpd = sui.hours(cfg.upgrade_interval, (v) => this.save({ upgrade_interval: v }));
		this.upd = upd;
		this.renderUpdates(upd);
		// Обновления проверяются при открытии страницы, но не чаще раза в час: у GitHub API лимит
		// 60 запросов в час на адрес (один на всю домашнюю сеть), а проверка — три запроса. Пока
		// проверка или установка уже идут — только следим за ними.
		if (upd.checking || upd.installing)
			this.pollUpdates();
		else if (!upd.info || Date.now() / 1000 - upd.info.at > 3600)
			this.handleUpdateCheck();
		this.logBox = E('textarea', { 'class': 'cbi-input-textarea', 'readonly': 'readonly', 'wrap': 'off', 'rows': 15 });

		this.renderStatus(st);
		poll.add(() => this.poll(), 5);

		const level = sui.select(cfg.log_level, [ 'error', 'warning', 'info', 'debug' ].map((l) => [ l, l ]), (v) => this.save({ log_level: v }));

		const log = E('details', { 'class': 'st-log' }, [
			E('summary', {}, _('Лог')),
			this.logBox,
			E('div', { 'class': 'st-row', 'style': 'justify-content:flex-end' }, [
				_('Уровень лога:'), level,
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleLog') }, _('Обновить'))
			])
		]);
		log.addEventListener('toggle', () => { if (log.open) this.handleLog(); });

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, 'Stella'),
			this.statusBox,
			E('h3', {}, 'DNS'),
			this.renderDns(cfg),
			E('h3', {}, _('Обновления')),
			this.updBox,
			log
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
