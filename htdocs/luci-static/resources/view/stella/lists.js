'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require stella.ui as sui';

const callLists = rpc.declare({ object: 'stella', method: 'lists' });
const callAdd = rpc.declare({ object: 'stella', method: 'list_add', params: [ 'items', 'action', 'devices_mode', 'macs' ] });
const callEdit = rpc.declare({ object: 'stella', method: 'list_edit', params: [ 'id', 'name', 'urls', 'entries', 'action', 'enabled', 'devices_mode', 'macs' ] });
const callRemove = rpc.declare({ object: 'stella', method: 'list_remove', params: [ 'id' ] });
const callMove = rpc.declare({ object: 'stella', method: 'list_move', params: [ 'id', 'dir' ] });
const callUpdate = rpc.declare({ object: 'stella', method: 'lists_update', params: [ 'id' ] });
const callDefault = rpc.declare({ object: 'stella', method: 'set_default_action', params: [ 'action' ] });
const callDevices = rpc.declare({ object: 'stella', method: 'devices' });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callSettingsSet = rpc.declare({ object: 'stella', method: 'settings_set', params: [ 'values' ] });
const callZapretInfo = rpc.declare({ object: 'stella', method: 'zapret_info' });
const callZapretOff = rpc.declare({ object: 'stella', method: 'zapret_service_off' });
const callZCatalog = rpc.declare({ object: 'stella', method: 'zapret_catalog' });
const callZApply = rpc.declare({ object: 'stella', method: 'zapret_apply', params: [ 'name' ] });
const callZCatalogUpdate = rpc.declare({ object: 'stella', method: 'zapret_catalog_update' });
const callZTest = rpc.declare({ object: 'stella', method: 'zapret_test', params: [ 'scope', 'apply' ] });
const callZTestStop = rpc.declare({ object: 'stella', method: 'zapret_test_stop' });

const FAMILIES = { v: 'Zapret Manager', yv: _('YouTube'), fs: 'Flowseal', current: _('текущая') };

const ITD = 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/';
const META = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/';

// Готовые списки itdoginfo/allow-domains; у сервисов с известными подсетями — оба файла.
const CATALOG = [
	[ _('Россия'), [
		[ _('Заблокированные в России'), [ 'Russia/inside-raw.lst' ] ],
		[ _('Российские сайты, закрытые для зарубежных IP'), [ 'Russia/outside-raw.lst' ] ]
	] ],
	[ _('Сервисы'), [
		[ 'YouTube', [ 'Services/youtube.lst' ] ],
		[ 'Telegram', [ 'Services/telegram.lst', 'Subnets/IPv4/telegram.lst' ] ],
		[ 'Discord', [ 'Services/discord.lst', 'Subnets/IPv4/discord.lst' ] ],
		[ _('Meta (Instagram, Facebook, WhatsApp)'), [ 'Services/meta.lst', 'Subnets/IPv4/meta.lst' ] ],
		[ 'Twitter / X', [ 'Services/twitter.lst', 'Subnets/IPv4/twitter.lst' ] ],
		[ 'TikTok', [ 'Services/tiktok.lst' ] ],
		[ 'Google AI (Gemini)', [ 'Services/google_ai.lst' ] ],
		[ 'Google Meet', [ 'Services/google_meet.lst', 'Subnets/IPv4/google_meet.lst' ] ],
		[ 'Google Play', [ 'Services/google_play.lst' ] ],
		[ 'Roblox', [ 'Services/roblox.lst', 'Subnets/IPv4/roblox.lst' ] ],
		[ 'HDRezka', [ 'Services/hdrezka.lst' ] ],
		[ 'Cloudflare', [ 'Services/cloudflare.lst', 'Subnets/IPv4/cloudflare.lst' ] ]
	] ],
	[ _('Категории'), [
		[ _('Геоблок — сервисы, закрывшие доступ из России'), [ 'Categories/geoblock.lst' ] ],
		[ _('Заблокированные РКН'), [ 'Categories/block.lst' ] ],
		[ _('Новости'), [ 'Categories/news.lst' ] ],
		[ _('Аниме'), [ 'Categories/anime.lst' ] ],
		[ _('Сайты 18+'), [ 'Categories/porn.lst' ] ],
		[ _('Хостинги (Hetzner, OVH, DO, Cloudflare, AWS, Akamai)'), [ 'Categories/hodca.lst' ] ]
	] ]
];

const ACTIONS = [
	[ 'vpn', _('VPN') ],
	[ 'zapret', _('Zapret') ],
	[ 'direct', _('Напрямую') ],
	[ 'block', _('Блокировать') ]
];

const INTERVALS = [ [ '0', _('вручную') ], [ '3', _('каждые 3 ч') ], [ '6', _('каждые 6 ч') ],
	[ '12', _('каждые 12 ч') ], [ '24', _('раз в сутки') ], [ '168', _('раз в неделю') ] ];


const CSS = `
.st-bar { display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:.5em 0 1em }
.st-default { display:flex; flex-wrap:wrap; gap:.6em; align-items:center; padding:.6em .9em; border-radius:4px; background:rgba(128,128,128,.12); margin-bottom:.8em }
.st-table { width:100%; border-collapse:collapse }
.st-table td, .st-table th { padding:.35em .6em; border-bottom:1px solid rgba(128,128,128,.15); vertical-align:middle; text-align:left }
.st-table th { font-weight:normal; opacity:.6; font-size:90% }
.st-table tr.st-off td { opacity:.5 }
.st-table select, .st-default select, .st-bar select { width:auto }
.st-dim { opacity:.6; font-size:85% }
.st-order .btn, .st-act .btn { line-height:1.8em; min-height:0 }
.st-act { text-align:right; white-space:nowrap; width:1% }
.st-order { white-space:nowrap; width:1% }
.st-scope { color:#39f }
.st-field { margin:.7em 0 }
.st-field > b { display:block; margin-bottom:.25em }
.st-field textarea, .st-field input[type=text] { width:100% }
.st-cat h5 { margin:.4em 0 .15em; font-size:90%; opacity:.8 }
.st-cols { columns:2 }
.st-cols label { display:block; padding:.12em 0; break-inside:avoid }
.st-devs { margin-top:.4em; max-height:14em; overflow-y:auto; border:1px solid rgba(128,128,128,.25); border-radius:4px }
.st-dev { display:flex; align-items:center; gap:.6em; padding:.3em .6em; border-bottom:1px solid rgba(128,128,128,.12); cursor:pointer }
.st-dev:last-child { border-bottom:0 }
.st-dev input { margin:0 }
.st-dev .st-name { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
.st-dev .st-dim { white-space:nowrap }
.st-zapret { padding:.8em 1em; border:1px solid rgba(128,128,128,.3); border-radius:4px; margin-top:1.5em }
.st-zapret h3 { margin-top:0 }
.st-ok { color:#2a2 } .st-bad { color:#c33 }
.st-inline { display:inline-flex; gap:.4em; align-items:center; white-space:nowrap }
.st-zrow { display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:.45em 0 }
.st-zrow select { width:auto; max-width:22em }
.st-zres { max-height:18em; overflow-y:auto; margin-top:.4em; border:1px solid rgba(128,128,128,.2); border-radius:4px }
.st-zres table { width:100%; border-collapse:collapse }
.st-zres td { padding:.2em .6em; border-bottom:1px solid rgba(128,128,128,.1) }
.st-zres tr.st-cur td { background:rgba(60,160,60,.14) }
.st-bar-bg { display:inline-block; width:6em; height:.5em; background:rgba(128,128,128,.2); border-radius:3px; vertical-align:middle; overflow:hidden }
.st-bar-bg > span { display:block; height:100%; background:#3a3 }
`;

function actionSelect(value, onchange) {
	return E('select', { 'class': 'cbi-input-select', 'change': (ev) => onchange(ev.target.value) },
		ACTIONS.map((a) => E('option', { 'value': a[0], 'selected': (a[0] == value) ? '' : null }, a[1])));
}

function countLabel(l) {
	const p = [];
	if (l.domains)
		p.push('%d %s'.format(l.domains, sui.plural(l.domains, _('домен'), _('домена'), _('доменов'))));
	if (l.cidrs)
		p.push('%d %s'.format(l.cidrs, sui.plural(l.cidrs, _('подсеть'), _('подсети'), _('подсетей'))));
	return p.length ? p.join(' · ') : (l.urls.length ? _('не загружен') : _('пусто'));
}

function sourceLabel(l) {
	if (!l.urls.length)
		return _('свои сайты');
	const u = l.urls[0];
	if (u.indexOf(ITD) == 0)
		return 'itdoginfo';
	if (u.indexOf(META) == 0)
		return 'meta-rules-dat';
	const m = u.match(/^https?:\/\/([^\/]+)/);
	return m ? m[1] : u;
}

function lines(text) {
	return text.split(/\r?\n/).map((s) => s.trim()).filter((s) => s);
}

// Ссылка на файл списка (а не на сайт): по расширению или по известному хранилищу.
function isListUrl(s) {
	return /^https?:\/\/\S+\.(lst|list|txt|conf|yaml|yml)(\?\S*)?$/i.test(s) || /^https?:\/\/raw\.githubusercontent\.com\//i.test(s);
}

function listName(url) {
	return decodeURIComponent(url.replace(/[?#].*$/, '').split('/').pop().replace(/\.[a-z]+$/i, ''));
}

return view.extend({
	load() {
		return Promise.all([ callLists(), callDevices(), callSettings(), callZapretInfo(), callZCatalog() ]);
	},

	setDevices(dr) {
		this.devices = dr.devices;
		this.devNames = {};
		for (const d of dr.devices)
			this.devNames[d.mac] = d.name || d.hostname || d.ip || d.mac;
	},

	refresh() {
		return Promise.all([ callLists(), callDevices(), callZapretInfo(), callZCatalog() ]).then(([ d, dr, zi, zc ]) => {
			const was = this.data && this.data.updating;
			const wasTesting = this.zc && this.zc.testing;
			this.data = d;
			this.zi = zi;
			this.zc = zc;
			this.setDevices(dr);
			this.renderAll();
			if (wasTesting && !zc.testing && zc.progress && zc.progress.message)
				ui.addNotification(null, E('p', {}, _('Автоподбор: %s').format(zc.progress.message)), 'info');
			const busy = d.updating || zc.testing || zc.updating;
			if (busy && !this.polling) {
				this.polling = () => this.refresh();
				poll.add(this.polling, 2);
			}
			else if (!busy && this.polling) {
				poll.remove(this.polling);
				this.polling = null;
			}
			if (was && !d.updating && d.update_log)
				ui.addNotification(_('Обновление списков'), E('pre', { 'style': 'white-space:pre-wrap' }, d.update_log), 'info');
		});
	},

	saveSetting(values) {
		return callSettingsSet(values).then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
		});
	},

	call(p) {
		return p.then((r) => {
			if (r && r.error)
				ui.addNotification(null, E('p', {}, r.error), 'danger');
			return this.refresh();
		});
	},

	// Одно окно для создания и изменения. Для нового списка — ещё и каталог itdoginfo.
	showList(l) {
		const isNew = !l;
		l = l || { name: '', action: 'vpn', urls: [], entries: [], devices_mode: 'all', macs: [] };

		// Каталог itdoginfo — и при создании, и при изменении: уже входящие в список пункты
		// отмечены, а их ссылки не дублируются в поле ниже.
		const catUrls = {};
		const checks = [];
		const cat = E('div', { 'class': 'st-cat' }, CATALOG.map((g) => E('div', {}, [
			E('h5', {}, g[0]),
			E('div', { 'class': 'st-cols' }, g[1].map((it) => {
				const urls = it[1].map((f) => ITD + f);
				urls.forEach((u) => catUrls[u] = true);
				const cb = E('input', { 'type': 'checkbox', 'checked': (!isNew && urls.every((u) => l.urls.indexOf(u) >= 0)) ? '' : null });
				checks.push([ cb, it, urls ]);
				return E('label', {}, [ cb, ' ', it[0] ]);
			}))
		])));

		let action = l.action;
		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': l.name, 'placeholder': isNew ? _('например, Видео и соцсети') : '' });
		const text = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 4,
			'placeholder': 'mysite.ru\n203.0.113.0/24\nhttps://example.com/list.lst' },
			[ [ ...l.urls.filter((u) => !catUrls[u]), ...l.entries ].join('\n') ]);

		// Устройства: известные в сети + уже выбранные в списке (даже если сейчас не в сети).
		const devs = this.devices.slice();
		for (const m of l.macs)
			if (!devs.find((d) => d.mac == m))
				devs.push({ mac: m });
		const label = (d) => d.name || d.hostname || '';
		devs.sort((a, b) => (!label(a) - !label(b)) || label(a).localeCompare(label(b)));
		const boxes = devs.map((d) => [ d, E('input', { 'type': 'checkbox', 'checked': l.macs.indexOf(d.mac) >= 0 ? '' : null }) ]);
		const devList = E('div', { 'class': 'st-devs' }, boxes.map(([ d, cb ]) => E('label', { 'class': 'st-dev' }, [
			cb,
			E('span', { 'class': 'st-name' }, label(d) || E('span', { 'class': 'st-dim' }, _('без имени'))),
			E('span', { 'class': 'st-dim' }, d.ip || d.mac)
		])));
		const mode = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' }, [
			E('option', { 'value': 'all', 'selected': l.devices_mode == 'all' ? '' : null }, _('для всех устройств')),
			E('option', { 'value': 'only', 'selected': l.devices_mode == 'only' ? '' : null }, _('только для выбранных')),
			E('option', { 'value': 'except', 'selected': l.devices_mode == 'except' ? '' : null }, _('для всех, кроме выбранных'))
		]);
		const syncDevs = () => devList.style.display = (mode.value == 'all') ? 'none' : '';
		mode.addEventListener('change', syncDevs);
		syncDevs();

		const save = () => {
			const macs = boxes.filter(([ , cb ]) => cb.checked).map(([ d ]) => d.mac);
			if (mode.value != 'all' && !macs.length)
				return ui.addNotification(null, E('p', {}, _('Выберите хотя бы одно устройство.')), 'warning');
			const all = lines(text.value);
			const urls = all.filter(isListUrl), sites = all.filter((s) => !isListUrl(s));

			if (!isNew) {
				const all_urls = [ ...checks.filter(([ cb ]) => cb.checked).flatMap(([ , , u ]) => u), ...urls ];
				if (!all_urls.length && !sites.length)
					return ui.addNotification(null, E('p', {}, _('Список пуст — отметьте что-нибудь или впишите сайты.')), 'warning');
				ui.hideModal();
				return this.call(callEdit(l.id, name.value.trim() || l.name, all_urls, sites, action, undefined, mode.value, macs));
			}

			// Всё выбранное — один список: пункты каталога, свои ссылки и сайты.
			const picked = checks.filter(([ cb ]) => cb.checked);
			const all_urls = [ ...picked.flatMap(([ , , u ]) => u), ...urls ];
			if (!all_urls.length && !sites.length)
				return ui.addNotification(null, E('p', {}, _('Ничего не выбрано.')), 'warning');
			const names = [ ...picked.map(([ , it ]) => it[0]), ...urls.map(listName), ...(sites.length ? [ _('свои сайты') ] : []) ];
			const auto = (names.length > 3) ? names.slice(0, 3).join(', ') + _(' и ещё %d').format(names.length - 3) : names.join(', ');
			ui.hideModal();
			return this.call(callAdd([ { name: name.value.trim() || auto, urls: all_urls, entries: sites } ], action, mode.value, macs));
		};

		ui.showModal(isNew ? _('Новый список') : _('Список «%s»').format(l.name), [
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Название')), name,
				isNew ? E('small', { 'class': 'st-dim' }, _('Если не указать — по выбранному, например «YouTube, Discord».')) : '' ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Что делать с этими сайтами')), actionSelect(action, (v) => action = v) ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Готовые списки (itdoginfo)')), cat ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Свои сайты, подсети или ссылки на списки — по одному в строке')), text,
				E('small', { 'class': 'st-dim' }, _('Сайт включает все поддомены. Ссылка на файл списка (например, из meta-rules-dat) загружается и обновляется сама.')) ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Для каких устройств')), mode, devList ]),
			E('div', { 'style': 'display:flex;gap:.5em' }, [
				isNew ? '' : E('button', { 'class': 'btn cbi-button-negative', 'click': () => { ui.hideModal(); this.handleRemove(l); } }, _('Удалить')),
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, save) }, isNew ? _('Добавить') : _('Сохранить'))
			])
		]);
	},

	handleRemove(l) {
		if (confirm(_('Удалить список «%s»?').format(l.name)))
			return this.call(callRemove(l.id));
	},

	scopeLabel(l) {
		if (l.devices_mode == 'all')
			return '';
		const names = l.macs.map((m) => this.devNames[m] || m);
		return E('span', { 'class': 'st-scope' }, ' · ' + (l.devices_mode == 'only' ? _('только: %s') : _('кроме: %s')).format(names.join(', ')));
	},

	/* Zapret */

	showZapret() {
		const zi = this.zi, cfg = this.cfg;
		const bin = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			(zi.binaries.length ? zi.binaries : [ '/opt/zapret/nfq/nfqws' ]).map((b) =>
				E('option', { 'value': b, 'selected': b == (cfg.zapret_bin || zi.binaries[0]) ? '' : null }, b)));
		const opts = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 12, 'style': 'font-family:monospace;font-size:12px' }, [ cfg.zapret_opts || '' ]);
		const tcp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': cfg.zapret_tcp_ports || '', 'placeholder': '80,443' });
		const udp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': cfg.zapret_udp_ports || '', 'placeholder': '443' });

		ui.showModal(_('Своя стратегия Zapret'), [
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Программа')), bin ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Параметры nfqws')), opts,
				E('small', { 'class': 'st-dim' }, _('Можно по одному в строке, # — комментарий. Подбирается утилитой blockcheck из пакета zapret.')) ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Порты TCP')), tcp ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Порты UDP')), udp ]),
			E('div', { 'style': 'display:flex;gap:.5em' }, [
				zi.import_opts ? E('button', { 'class': 'btn cbi-button', 'click': () => {
					opts.value = String(zi.import_opts).trim();
					if (zi.import_tcp) tcp.value = zi.import_tcp;
					if (zi.import_udp) udp.value = zi.import_udp;
				} }, _('Взять из zapret')) : '',
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, () => callSettingsSet({
						zapret_bin: bin.value, zapret_opts: opts.value, zapret_strategy: '',
						zapret_tcp_ports: tcp.value.trim(), zapret_udp_ports: udp.value.trim()
					}).then((r) => {
						if (r && r.error)
							return ui.addNotification(null, E('p', {}, r.error), 'danger');
						ui.hideModal();
						return callSettings().then((c) => { this.cfg = c; return this.refresh(); });
					}))
				}, _('Сохранить'))
			])
		]);
	},

	renderZapret() {
		const zi = this.zi, cfg = this.cfg, zc = this.zc;
		const used = this.data.lists.some((l) => l.enabled && l.action == 'zapret');
		const res = (zc.results && zc.results.items) || {};
		const score = (name) => {
			const r = res[name];
			return (r && r.ok >= 0) ? '%d из %d'.format(r.ok, r.total) : (r ? _('ошибка') : '');
		};

		// Выбор стратегии: каталог по источникам (без YouTube — у неё свой выбор ниже);
		// смена применяется сразу.
		const groups = {};
		for (const st of zc.strategies)
			if (st.family != 'yv')
				(groups[st.family] = groups[st.family] || []).push(st);
		const ytSel = E('select', { 'class': 'cbi-input-select', 'change': (ev) => this.saveSetting({ zapret_yt: ev.target.value }).then(() => this.refresh()) }, [
			E('option', { 'value': '', 'selected': cfg.zapret_yt ? null : '' }, _('как в основной')),
			...zc.strategies.filter((st) => st.family == 'yv').map((st) =>
				E('option', { 'value': st.name, 'selected': st.name == cfg.zapret_yt ? '' : null }, st.name + (res[st.name] ? '  · ' + score(st.name) : '')))
		]);
		const flag = (key, label, title) => E('label', { 'title': title }, [
			E('input', { 'type': 'checkbox', 'checked': cfg[key] == '1' ? '' : null,
				'change': (ev) => this.saveSetting({ [key]: ev.target.checked ? '1' : '0' }).then(() => { cfg[key] = ev.target.checked ? '1' : '0'; }) }),
			' ', label ]);
		const sched = E('select', { 'class': 'cbi-input-select', 'change': (ev) => this.saveSetting({ zapret_test_interval: ev.target.value }).then(() => { cfg.zapret_test_interval = ev.target.value; }) },
			[ [ '0', _('вручную') ], [ '7', _('раз в неделю, ночью') ], [ '30', _('раз в месяц, ночью') ] ].map(([ v, t ]) =>
				E('option', { 'value': v, 'selected': (cfg.zapret_test_interval || '0') == v ? '' : null }, t)));
		const sel = E('select', { 'class': 'cbi-input-select', 'change': (ev) => {
			if (ev.target.value == '__custom')
				return this.showZapret();
			return this.call(callZApply(ev.target.value));
		} }, [
			(!zc.current && !zc.custom) ? E('option', { 'value': '', 'selected': '' }, _('— не выбрана —')) : '',
			...Object.keys(groups).map((f) => E('optgroup', { 'label': FAMILIES[f] || f },
				groups[f].map((st) => E('option', { 'value': st.name, 'selected': (!zc.custom && st.name == zc.current) ? '' : null },
					st.name + (res[st.name] ? '  · ' + score(st.name) : ''))))),
			E('option', { 'value': '__custom', 'selected': zc.custom ? '' : null }, zc.custom ? _('своя стратегия') : _('своя стратегия…'))
		]);

		let state;
		if (!used)
			state = E('span', { 'class': 'st-dim' }, _('не используется — ни у одного списка не выбрано «Zapret»'));
		else if (!cfg.zapret_opts)
			state = E('span', { 'class': 'st-bad' }, _('стратегия не выбрана'));
		else if (zi.stella_nfqws)
			state = E('span', { 'class': 'st-ok' }, _('работает'));
		else
			state = E('span', { 'class': 'st-bad' }, _('не запущен — стратегия не подходит к nfqws'));

		// Автоподбор.
		const p = zc.progress || {};
		const auto = E('input', { 'type': 'checkbox', 'checked': '' });
		let test;
		if (zc.testing)
			test = [
				E('em', { 'class': 'spinning' }, p.total ? _('проверяю %d из %d: %s').format(p.done + 1, p.total, p.current || '') : _('готовлюсь…')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, () => this.call(callZTestStop())) }, _('Остановить'))
			];
		else
			test = [
				E('button', { 'class': 'btn cbi-button-action', 'disabled': zc.strategies.length ? null : '',
					'click': ui.createHandlerFn(this, () => this.call(callZTest('all', auto.checked))) }, _('Подобрать')),
				E('button', { 'class': 'btn cbi-button', 'disabled': zc.strategies.length ? null : '',
					'click': ui.createHandlerFn(this, () => this.call(callZTest('yv', auto.checked))) }, _('только YouTube')),
				E('label', { 'class': 'st-dim' }, [ auto, ' ', _('применить лучшую, если она лучше текущей') ])
			];

		// Результаты: лучшие сверху, с кнопкой «Применить».
		const names = Object.keys(res).filter((n) => res[n].family != 'current').sort((a, b) => res[b].ok - res[a].ok);
		const base = zc.results && zc.results.baseline;
		const baseText = base ? Object.keys(base).map((k) => (k == 'yv' ? _('YouTube') : _('общие')) + ' ' + base[k].ok + '/' + base[k].total).join(', ') : '';
		const results = names.length ? E('details', {}, [
			E('summary', { 'style': 'cursor:pointer' }, _('Результаты проверки (%d)').format(names.length) +
				(zc.results.at ? ' · ' + new Date(zc.results.at * 1000).toLocaleString('ru-RU') : '') + (baseText ? ' · ' + _('без обхода: %s').format(baseText) : '')),
			E('div', { 'class': 'st-zres' }, E('table', {}, names.map((n) => {
				const r = res[n];
				const pct = (r.ok > 0 && r.total) ? Math.round(100 * r.ok / r.total) : 0;
				return E('tr', { 'class': n == zc.current && !zc.custom ? 'st-cur' : '' }, [
					E('td', {}, n),
					E('td', { 'class': 'st-dim' }, FAMILIES[r.family] || r.family),
					E('td', { 'style': 'white-space:nowrap' }, [ E('span', { 'class': 'st-bar-bg' }, E('span', { 'style': 'width:' + pct + '%' })), ' ', score(n) ]),
					E('td', { 'class': 'st-act' }, (n == zc.current && !zc.custom) ? _('текущая') :
						E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, () => this.call(callZApply(n))) }, _('Применить')))
				]);
			})))
		]) : '';

		const svcBad = zi.service_running || zi.service_enabled || zi.leftover_tables;
		const svc = E('div', { 'class': 'st-zrow st-dim' }, [
			_('Отдельная служба zapret:') + ' ',
			zi.service_running ? E('span', { 'class': 'st-bad' }, _('работает — будет мешать')) :
			zi.service_enabled ? E('span', { 'class': 'st-bad' }, _('включена в автозапуск')) :
			zi.leftover_tables ? _('остановлена, остались её правила') : _('остановлена'),
			svcBad ? E('button', {
				'class': 'btn cbi-button-negative', 'style': 'padding:0 .6em;line-height:1.7em;min-height:0',
				'click': ui.createHandlerFn(this, () => callZapretOff().then((r) => {
					if (r.running)
						ui.addNotification(null, E('p', {}, _('nfqws службы zapret всё ещё работает — возможно, запущен другой обход (zapret2, zapret-manager).')), 'warning');
					return this.refresh();
				}))
			}, (zi.service_running || zi.service_enabled) ? _('Остановить и отключить') : _('Убрать правила')) : ''
		]);

		dom.content(this.zapretBox, [
			E('div', { 'style': 'display:flex;align-items:baseline;gap:1em;flex-wrap:wrap' }, [
				E('h3', { 'style': 'margin:0' }, 'Zapret'),
				E('span', { 'class': 'st-dim' }, [
					zc.strategies.length ? _('каталог: %d стратегий').format(zc.strategies.length) : _('каталог не загружен'),
					zc.updated ? ' · ' + new Date(zc.updated * 1000).toLocaleDateString('ru-RU') : '', ' ',
					zc.updating ? E('em', { 'class': 'spinning' }, _('обновляю…')) : E('a', { 'href': '#', 'click': (ev) => { ev.preventDefault(); this.call(callZCatalogUpdate()); } }, _('обновить'))
				])
			]),
			E('div', { 'class': 'st-dim', 'style': 'margin:.3em 0 .5em' }, _('Обход блокировок без VPN для списков с действием «Zapret». Стратегии — из Zapret Manager, его YouTube-набора и Flowseal.')),
			E('div', { 'class': 'st-zrow' }, [ E('b', {}, _('Стратегия')), sel,
				(zc.current && res[zc.current]) ? E('span', { 'class': 'st-dim' }, score(zc.current)) : '',
				E('span', { 'class': 'st-dim' }, [ '· ', state ]) ]),
			E('div', { 'class': 'st-zrow' }, [ E('b', {}, 'YouTube'), ytSel ]),
			E('div', { 'class': 'st-zrow' }, [ E('b', {}, _('Дополнительно')),
				flag('zapret_discord', _('голос и видео Discord'), _('UDP 19294–19344, 50000–50100 и TCP для discord.media')),
				flag('zapret_games', _('игры'), _('UDP и TCP 1024–65535, как игровой фильтр Flowseal')) ]),
			(cfg.zapret_games == '1' || cfg.zapret_discord == '1') && this.data.default_action != 'zapret' ? E('div', { 'class': 'st-dim' },
				_('Игровые серверы и голос Discord ходят по IP, которых нет в списках: чтобы Zapret их касался, выберите вверху «Всё, что не попало в списки: через Zapret» или добавьте их адреса в список с действием «Zapret».')) : '',
			E('div', { 'class': 'st-zrow' }, [ E('b', {}, _('Автоподбор')), ...test ]),
			E('div', { 'class': 'st-zrow' }, [ _('по расписанию:'), sched,
				E('details', { 'style': 'display:inline-block' }, [ E('summary', { 'style': 'cursor:pointer', 'class': 'st-dim' }, _('как проверяется')),
					E('div', { 'class': 'st-dim', 'style': 'max-width:46em;margin-top:.3em' }, _('Для каждой стратегии запускается отдельный nfqws на своей очереди, и в неё уходит только трафик самой проверки (исходящие порты 20000–20999) — трафик устройств не трогается и работающая стратегия не меняется. Сначала замеряется, сколько целей открывается без обхода, затем для каждой стратегии: общие — по хостам за зарубежными CDN (обрыв на 16–20 КБ, набор hyperion-cs/dpi-checkers) и YouTube, стратегии YouTube — по доменам YouTube. Цель считается открытой, если ответ пришёл целиком или скачано больше 24 КБ. Одна стратегия — около 9 секунд, весь каталог — около 9 минут. С галочкой «применить лучшую» стратегия меняется, только если лучшая открывает больше текущей; по расписанию — всегда так.')) ]) ]),
			results,
			svc
		]);
	},

	renderAll() {
		const d = this.data;

		dom.content(this.defaultBox, [
			E('span', {}, _('Всё, что не попало в списки:')),
			E('select', { 'class': 'cbi-input-select', 'change': (ev) => this.call(callDefault(ev.target.value)) }, [
				E('option', { 'value': 'vpn', 'selected': d.default_action == 'vpn' ? '' : null }, _('через VPN')),
				E('option', { 'value': 'direct', 'selected': d.default_action == 'direct' ? '' : null }, _('напрямую')),
				E('option', { 'value': 'zapret', 'selected': d.default_action == 'zapret' ? '' : null }, _('через Zapret'))
			]),
			E('span', { 'class': 'st-dim' }, _('Списки проверяются сверху вниз, срабатывает первый подходящий.'))
		]);

		this.renderZapret();

		if (!d.lists.length) {
			dom.content(this.tableBox, E('p', {}, _('Списков нет — весь трафик идёт по правилу выше. Нажмите «Добавить», чтобы выбрать готовые списки или указать свои сайты.')));
			return;
		}

		const n = d.lists.length;
		const rows = d.lists.map((l, i) => E('tr', { 'class': l.enabled ? '' : 'st-off' }, [
			E('td', { 'class': 'st-order' }, [
				E('button', { 'class': 'btn cbi-button st-ib', 'title': _('Выше'), 'disabled': i == 0 ? '' : null,
					'click': ui.createHandlerFn(this, () => this.call(callMove(l.id, -1))) }, sui.icon('up')),
				E('button', { 'class': 'btn cbi-button st-ib', 'title': _('Ниже'), 'disabled': i == n - 1 ? '' : null,
					'click': ui.createHandlerFn(this, () => this.call(callMove(l.id, 1))) }, sui.icon('down'))
			]),
			E('td', {}, E('input', { 'type': 'checkbox', 'title': _('Включён'), 'checked': l.enabled ? '' : null,
				'change': (ev) => this.call(callEdit(l.id, undefined, undefined, undefined, undefined, ev.target.checked)) })),
			E('td', {}, [ E('div', {}, l.name), E('div', { 'class': 'st-dim' }, [ sourceLabel(l), this.scopeLabel(l) ]) ]),
			E('td', { 'class': 'st-dim' }, [
				E('div', {}, countLabel(l)),
				l.updated ? E('div', {}, new Date(l.updated * 1000).toLocaleString('ru-RU')) : ''
			]),
			E('td', {}, actionSelect(l.action, (v) => this.call(callEdit(l.id, undefined, undefined, undefined, v, undefined)))),
			E('td', { 'class': 'st-act' }, [
				l.urls.length ? sui.iconButton('refresh', _('Обновить'), () => this.call(callUpdate(l.id))) : '',
				' ',
				sui.iconButton('edit', _('Изменить'), () => this.showList(l))
			])
		]));

		dom.content(this.tableBox, [
			d.updating ? E('p', {}, E('em', { 'class': 'spinning' }, _('Загружаю списки…'))) : '',
			E('table', { 'class': 'st-table' }, [
				E('tr', {}, [ E('th', {}, ''), E('th', {}, ''), E('th', {}, _('Список')), E('th', {}, _('Содержимое')), E('th', {}, _('Действие')), E('th', {}, '') ]),
				...rows
			])
		]);
	},

	render([ data, dr, cfg, zi, zc ]) {
		this.data = data;
		this.cfg = cfg;
		this.zi = zi;
		this.zc = zc;
		this.setDevices(dr);
		this.defaultBox = E('div', { 'class': 'st-default' });
		this.tableBox = E('div');
		this.zapretBox = E('div', { 'class': 'st-zapret' });
		this.renderAll();
		if (data.updating || zc.testing || zc.updating)
			this.refresh();

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Списки сайтов')),
			E('div', { 'class': 'cbi-map-descr' }, _('Какие сайты открывать через VPN, через Zapret, напрямую или блокировать. Список можно включить только для некоторых устройств.')),
			this.defaultBox,
			E('div', { 'class': 'st-bar' }, [
				E('button', { 'class': 'btn cbi-button-add', 'click': () => this.showList(null) }, _('Добавить')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, () => this.call(callUpdate(undefined))) }, _('Обновить все')),
				E('span', { 'class': 'st-inline' }, [ _('автообновление'),
					sui.combo(cfg.lists_interval, INTERVALS, (v) => this.saveSetting({ lists_interval: v }), { custom_placeholder: _('часов…') }) ])
			]),
			this.tableBox,
			this.zapretBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
