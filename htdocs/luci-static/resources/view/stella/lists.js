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
const callMetaIndex = rpc.declare({ object: 'stella', method: 'meta_index', params: [ 'update' ] });
const callDefault = rpc.declare({ object: 'stella', method: 'set_default_action', params: [ 'action' ] });
const callDevices = rpc.declare({ object: 'stella', method: 'devices' });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callZapretInfo = rpc.declare({ object: 'stella', method: 'zapret_info' });
const callZapretOff = rpc.declare({ object: 'stella', method: 'zapret_service_off' });
const callZCatalog = rpc.declare({ object: 'stella', method: 'zapret_catalog' });
const callZApply = rpc.declare({ object: 'stella', method: 'zapret_apply', params: [ 'name' ] });
const callZCatalogUpdate = rpc.declare({ object: 'stella', method: 'zapret_catalog_update' });
const callZTest = rpc.declare({ object: 'stella', method: 'zapret_test', params: [ 'scope', 'apply' ] });
const callZTestStop = rpc.declare({ object: 'stella', method: 'zapret_test_stop' });
const callUpdateInstall = rpc.declare({ object: 'stella', method: 'update_install', params: [ 'what' ] });

const FAMILIES = { v: 'Zapret Manager', yv: 'YouTube', fs: 'Flowseal', dv: 'Discord', gv: _('игры'), current: _('текущая') };

const ITD = 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/';
const META = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/';
const ZMS_EXCLUDE = 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/zapret-hosts-user-exclude.txt';

// Готовые списки itdoginfo/allow-domains; у сервисов с известными подсетями — оба файла.
const CATALOG = [
	[ _('Россия'), [
		[ _('Заблокированные в России'), [ 'Russia/inside-raw.lst' ] ],
		[ _('Российские сайты, закрытые из-за рубежа'), [ 'Russia/outside-raw.lst' ] ]
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
		[ _('Геоблок (закрыты для России)'), [ 'Categories/geoblock.lst' ] ],
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
.st-chips { display:flex; flex-wrap:wrap; gap:.3em; margin-bottom:.35em }
.st-chips:empty { display:none }
.st-chip { display:inline-flex; gap:.4em; align-items:center; padding:.1em .5em; border-radius:3px; background:rgba(60,140,220,.18); font-size:90% }
.st-chip a { text-decoration:none; opacity:.7 }
.st-zapret { padding:.8em 1em; border:1px solid rgba(128,128,128,.3); border-radius:4px; margin-top:1.5em }
.st-zapret h3 { margin-top:0 }
.st-ok { color:#2a2 } .st-bad { color:#c33 }
.st-inline { display:inline-flex; gap:.4em; align-items:center; white-space:nowrap }
.st-zrow { display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:.45em 0 }
.st-zrow select { width:auto; max-width:22em }
.st-zgrid { display:grid; grid-template-columns:max-content 1fr; gap:.4em 1em; align-items:center; margin:.6em 0 }
.st-zgrid > b { font-weight:600 }
.st-zgrid > div { display:flex; flex-wrap:wrap; gap:.5em; align-items:center }
.st-zgrid select { width:auto; max-width:22em }
.st-zfoot { font-size:90%; margin-top:.5em; display:flex; flex-wrap:wrap; gap:.3em 1.2em; align-items:center }
@media (max-width:600px) { .st-zgrid { grid-template-columns:1fr } }
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
	if (u == ZMS_EXCLUDE)
		return 'Zapret Manager';
	const m = u.match(/^https?:\/\/([^\/]+)/);
	return m ? m[1] : u;
}

function lines(text) {
	return text.split(/\r?\n/).map((s) => s.trim()).filter((s) => s);
}

// Кириллический домен (сайт.рф) — в punycode: dnsmasq понимает только его. У ссылки
// переводится адрес целиком, как это делает браузер.
function puny(s) {
	if (!(/[^\x00-\x7f]/).test(s))
		return s;
	const url = (/^[a-z]+:\/\//i).test(s);
	try {
		const u = new URL(url ? s : 'http://' + s);
		return url ? u.href : u.hostname;
	}
	catch (e) {
		return s;
	}
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
		// Настройки тоже: стратегию меняют и выбор из каталога, и автоподбор.
		return Promise.all([ callLists(), callDevices(), callZapretInfo(), callZCatalog(), callSettings() ]).then(([ d, dr, zi, zc, cfg ]) => {
			const was = this.data && this.data.updating;
			const wasTesting = this.zc && this.zc.testing;
			this.data = d;
			this.cfg = cfg;
			this.zi = zi;
			this.zc = zc;
			this.setDevices(dr);
			// Во время автоподбора меняется только ход проверки — обновляем одну строку,
			// иначе перерисовка каждые 2 с закрывала бы открытые списки.
			const p = zc.progress || {};
			if (wasTesting && zc.testing && !was && !d.updating && this.zProgress)
				this.zProgress.textContent = p.total ? _('проверяю %d из %d: %s').format(p.done + 1, p.total, p.current || '') : _('готовлюсь…');
			else
				this.renderAll();
			if ((wasTesting || this.zStarted) && !zc.testing && zc.progress && zc.progress.message)
				ui.addNotification(null, E('p', {}, [ _('Автоподбор: %s').format(zc.progress.message) ]), 'info');
			if (zc.testing || !this.zStarted || (zc.progress && zc.progress.message))
				this.zStarted = false;
			const busy = d.updating || zc.testing || zc.updating || zi.installing;
			if (busy && !this.polling) {
				this.polling = () => this.refresh();
				poll.add(this.polling, 2);
			}
			else if (!busy && this.polling) {
				poll.remove(this.polling);
				this.polling = null;
			}
			if (was && !d.updating && d.update_log)
				ui.addNotification(_('Обновление списков'), E('pre', { 'style': 'white-space:pre-wrap' }, [ d.update_log ]), 'info');
		});
	},

	// Сохранить и перерисовать: refresh перечитывает и настройки.
	saveSetting(values) {
		return sui.saveSettings(values).then(() => this.refresh());
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
		let action = l.action;
		const actSel = actionSelect(action, (v) => action = v);
		const catUrls = {};
		const checks = [];
		const cat = E('div', { 'class': 'st-cat' }, CATALOG.map((g) => E('div', {}, [
			E('h5', {}, g[0]),
			E('div', { 'class': 'st-cols' }, g[1].map((it) => {
				// Скобки вокруг регулярки нужны jsmin: после «=>» он принимает «/» за деление.
				const urls = it[1].map((f) => (/^https?:/).test(f) ? f : ITD + f);
				urls.forEach((u) => catUrls[u] = true);
				const cb = E('input', { 'type': 'checkbox', 'checked': (!isNew && urls.every((u) => l.urls.indexOf(u) >= 0)) ? '' : null });
				checks.push([ cb, it, urls ]);
				return E('label', {}, [ cb, ' ', it[0] ]);
			}))
		])));

		// Наборы meta-rules-dat — поиском по именам, как geosite и geoip в 3x-ui. Хранятся ссылками
		// на их файлы .list и обновляются вместе со списком.
		const metaUrl = (p) => META + p[0] + '/' + p[1] + '.list';
		const metaSel = [];
		for (const u of l.urls) {
			const m = u.indexOf(META) == 0 && u.slice(META.length).match(/^(geosite|geoip)\/([^\/]+)\.list$/);
			if (m)
				metaSel.push([ m[1], m[2] ]);
		}
		const metaInit = metaSel.map(metaUrl);
		const chips = E('div', { 'class': 'st-chips' });
		const search = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'disabled': '', 'placeholder': _('загружаю наборы…') });
		const hits = E('div', { 'class': 'st-devs', 'style': 'display:none' });
		const metaState = E('small', { 'class': 'st-dim' });
		const metaIdx = (p) => metaSel.findIndex((x) => x[0] == p[0] && x[1] == p[1]);
		const toggle = (p) => {
			const i = metaIdx(p);
			if (i >= 0)
				metaSel.splice(i, 1);
			else
				metaSel.push(p);
			drawChips();
			drawHits();
		};
		const drawChips = () => dom.content(chips, metaSel.map((p) => E('span', { 'class': 'st-chip' }, [
			p[0] + ':' + p[1],
			E('a', { 'href': '#', 'title': _('Убрать'), 'click': (ev) => { ev.preventDefault(); toggle(p); } }, '×')
		])));
		// Сначала точное совпадение, потом начинающиеся с запроса. «geoip:» или «geosite:» в начале
		// запроса — искать только среди них.
		const drawHits = () => {
			const m = search.value.trim().toLowerCase().match(/^(?:(geosite|geoip):)?(.*)$/);
			const q = m[2];
			if (!this.meta || !q) {
				hits.style.display = 'none';
				return;
			}
			const rank = (n) => (n == q) ? 0 : (n.indexOf(q) == 0) ? 1 : 2;
			const found = [];
			for (const kind of [ 'geosite', 'geoip' ])
				if (!m[1] || m[1] == kind)
					for (const n of this.meta[kind])
						if (n.indexOf(q) >= 0)
							found.push([ kind, n ]);
			found.sort((a, b) => rank(a[1]) - rank(b[1]) || a[1].length - b[1].length || a[1].localeCompare(b[1]));
			hits.style.display = '';
			dom.content(hits, found.length ? found.slice(0, 50).map((p) => E('label', { 'class': 'st-dev' }, [
				E('input', { 'type': 'checkbox', 'checked': metaIdx(p) >= 0 ? '' : null, 'change': () => toggle(p) }),
				E('span', { 'class': 'st-name' }, p[1]),
				E('span', { 'class': 'st-dim' }, p[0])
			])) : E('div', { 'class': 'st-dev st-dim' }, _('ничего не найдено')));
		};
		search.addEventListener('input', drawHits);
		const useMeta = (r) => {
			this.meta = r;
			search.disabled = false;
			search.placeholder = _('поиск: youtube, telegram, geoip:ru');
			drawHits();
		};
		// Имён нет или им больше недели — роутер скачивает их заново; пока качает — опрашиваем.
		let asked = false;
		const loadMeta = (update) => callMetaIndex(update).then((r) => {
			const have = r.geosite.length + r.geoip.length > 0;
			if (have && (!this.meta || this.meta.at != r.at))
				useMeta(r);
			if (!r.loading && !asked && (!have || Date.now() / 1000 - r.at > 7 * 86400)) {
				asked = true;
				return loadMeta(true);
			}
			if (r.loading)
				return new Promise((res) => window.setTimeout(res, 1500)).then(() => document.body.contains(search) && loadMeta(false));
			if (!have) {
				search.placeholder = '';
				dom.content(metaState, [ _('Не удалось загрузить наборы.') + ' ', E('a', { 'href': '#', 'click': (ev) => {
					ev.preventDefault();
					dom.content(metaState, '');
					search.placeholder = _('загружаю наборы…');
					loadMeta(true);
				} }, _('Повторить')) ]);
			}
		}).catch((e) => dom.content(metaState, _('Поиск недоступен: %s').format(e.message)));
		drawChips();
		if (this.meta)
			useMeta(this.meta);
		else
			loadMeta(false);

		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': l.name, 'placeholder': isNew ? _('необязательно') : '' });
		const text = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 4,
			'placeholder': 'mysite.ru\n203.0.113.0/24\nhttps://example.com/list.lst' },
			[ [ ...l.urls.filter((u) => !catUrls[u] && metaInit.indexOf(u) < 0), ...l.entries ].join('\n') ]);

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
			E('span', { 'class': 'st-name' }, [ label(d) || E('span', { 'class': 'st-dim' }, _('без имени')) ]),
			E('span', { 'class': 'st-dim' }, d.ip || d.mac)
		])));
		const mode = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' }, [
			E('option', { 'value': 'all', 'selected': l.devices_mode == 'all' ? '' : null }, _('все')),
			E('option', { 'value': 'only', 'selected': l.devices_mode == 'only' ? '' : null }, _('только выбранные')),
			E('option', { 'value': 'except', 'selected': l.devices_mode == 'except' ? '' : null }, _('все, кроме выбранных'))
		]);
		const syncDevs = () => devList.style.display = (mode.value == 'all') ? 'none' : '';
		mode.addEventListener('change', syncDevs);
		syncDevs();

		const save = () => {
			const macs = boxes.filter(([ , cb ]) => cb.checked).map(([ d ]) => d.mac);
			if (mode.value != 'all' && !macs.length)
				return ui.addNotification(null, E('p', {}, _('Выберите хотя бы одно устройство.')), 'warning');
			const all = lines(text.value).map(puny);
			const urls = all.filter(isListUrl), sites = all.filter((s) => !isListUrl(s));

			if (!isNew) {
				const all_urls = [ ...checks.filter(([ cb ]) => cb.checked).flatMap(([ , , u ]) => u), ...metaSel.map(metaUrl), ...urls ];
				if (!all_urls.length && !sites.length)
					return ui.addNotification(null, E('p', {}, _('Список пуст.')), 'warning');
				ui.hideModal();
				return this.call(callEdit(l.id, name.value.trim() || l.name, all_urls, sites, action, undefined, mode.value, macs));
			}

			// Всё выбранное — один список: пункты каталога, наборы meta-rules-dat, свои ссылки и сайты.
			const picked = checks.filter(([ cb ]) => cb.checked);
			const all_urls = [ ...picked.flatMap(([ , , u ]) => u), ...metaSel.map(metaUrl), ...urls ];
			if (!all_urls.length && !sites.length)
				return ui.addNotification(null, E('p', {}, _('Ничего не выбрано.')), 'warning');
			const names = [ ...picked.map(([ , it ]) => it[0]), ...metaSel.map((p) => p[0] + ':' + p[1]), ...urls.map(listName),
				...(sites.length ? [ _('свои сайты') ] : []) ];
			const auto = (names.length > 3) ? names.slice(0, 3).join(', ') + _(' и ещё %d').format(names.length - 3) : names.join(', ');
			ui.hideModal();
			return this.call(callAdd([ { name: name.value.trim() || auto, urls: all_urls, entries: sites } ], action, mode.value, macs));
		};

		ui.showModal([ isNew ? _('Новый список') : _('Список «%s»').format(l.name) ], [
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Название')), name ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Действие')), actSel ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Готовые списки')), cat ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, 'meta-rules-dat'), chips, search, hits, metaState ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Свои сайты, подсети и ссылки на списки')), text,
				E('small', { 'class': 'st-dim' }, _('По одному в строке, поддомены учитываются.')) ]),
			E('div', { 'class': 'st-field' }, [ E('b', {}, _('Устройства')), mode, devList ]),
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
		return E('span', { 'class': 'st-scope' }, [ ' · ' + (l.devices_mode == 'only' ? _('только: %s') : _('кроме: %s')).format(names.join(', ')) ]);
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
				E('small', { 'class': 'st-dim' }, _('По одному в строке, строки с # пропускаются.')) ]),
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
					'click': ui.createHandlerFn(this, () => sui.saveSettings({
						zapret_bin: bin.value, zapret_opts: opts.value, zapret_strategy: '',
						zapret_tcp_ports: tcp.value.trim(), zapret_udp_ports: udp.value.trim()
					}).then((ok) => {
						if (!ok)
							return;
						ui.hideModal();
						return this.refresh();
					}))
				}, _('Сохранить'))
			])
		]);
	},

	renderZapret() {
		const zi = this.zi, cfg = this.cfg, zc = this.zc;
		const used = this.data.default_action == 'zapret' || this.data.lists.some((l) => l.enabled && l.action == 'zapret');
		const res = (zc.results && zc.results.items) || {};
		const score = (name) => {
			const r = res[name];
			return (r && r.ok >= 0) ? '%d из %d'.format(r.ok, r.total) : (r ? _('ошибка') : '');
		};

		// Выбор стратегии: каталог по источникам (без YouTube — у неё свой выбор ниже);
		// смена применяется сразу.
		const groups = {};
		for (const st of zc.strategies)
			if (st.family == 'v' || st.family == 'fs')
				(groups[st.family] = groups[st.family] || []).push(st);

		// YouTube, Discord и игры — отдельные наборы, как в Zapret Manager; «1» от прежних
		// версий — первый вариант набора.
		const fam = (f) => zc.strategies.filter((st) => st.family == f);
		const cur = (key, f) => (!cfg[key] || cfg[key] == '0') ? '' : (cfg[key] == '1' ? ((fam(f)[0] || {}).name || '') : cfg[key]);
		const setSel = (key, f) => {
			const v = cur(key, f);
			return E('select', { 'class': 'cbi-input-select', 'change': (ev) => this.saveSetting({ [key]: ev.target.value }) }, [
				E('option', { 'value': '', 'selected': v ? null : '' }, _('выключено')),
				...fam(f).map((st) => E('option', { 'value': st.name, 'selected': st.name == v ? '' : null }, [ st.name + (res[st.name] ? '  · ' + score(st.name) : '') ]))
			]);
		};
		const ytSel = setSel('zapret_yt', 'yv'), dvSel = setSel('zapret_discord', 'dv'), gvSel = setSel('zapret_games', 'gv');
		// Исключения: без выбора — список источника основной стратегии.
		const exN = zc.excluded || {};
		const exLabel = (k) => ({ zms: 'Zapret Manager', fs: 'Flowseal', all: _('все вместе') })[k] + ' (' +
			(exN[k] ? exN[k] + ' ' + sui.plural(exN[k], _('домен'), _('домена'), _('доменов')) : _('нет списка')) + ')';
		const exSel = E('select', { 'class': 'cbi-input-select', 'change': (ev) => this.saveSetting({ zapret_exclude: ev.target.value }) }, [
			E('option', { 'value': '', 'selected': cfg.zapret_exclude ? null : '' }, _('как у основной: %s').format(exLabel(zc.exclude_auto))),
			...[ 'zms', 'fs', 'all' ].map((k) => E('option', { 'value': k, 'selected': k == cfg.zapret_exclude ? '' : null }, exLabel(k)))
		]);
		const fakeName = (f) => f.replace(/^.*\//, '').replace(/\.bin$/, '');
		const fakeSel = (key) => [ E('span', { 'class': 'st-dim' }, _('подделка')), E('select', { 'class': 'cbi-input-select',
			'change': (ev) => this.saveSetting({ [key]: ev.target.value }) }, [
			E('option', { 'value': '', 'selected': cfg[key] ? null : '' }, _('stun (по умолчанию)')),
			...(zc.fakes || []).map((f) => E('option', { 'value': f, 'selected': f == cfg[key] ? '' : null }, fakeName(f)))
		]) ];
		const sel = E('select', { 'class': 'cbi-input-select', 'change': (ev) => {
			if (ev.target.value == '__custom')
				return this.showZapret();
			// Без основной работают только YouTube, Discord и игры.
			if (ev.target.value == '')
				return this.saveSetting({ zapret_opts: '', zapret_strategy: '' });
			return this.call(callZApply(ev.target.value));
		} }, [
			E('option', { 'value': '', 'selected': (!zc.current && !zc.custom) ? '' : null }, _('выключено')),
			...Object.keys(groups).map((f) => E('optgroup', { 'label': FAMILIES[f] || f },
				groups[f].map((st) => E('option', { 'value': st.name, 'selected': (!zc.custom && st.name == zc.current) ? '' : null },
					[ st.name + (res[st.name] ? '  · ' + score(st.name) : '') ])))),
			E('option', { 'value': '__custom', 'selected': zc.custom ? '' : null }, zc.custom ? _('своя стратегия') : _('своя стратегия…'))
		]);

		let state;
		if (!used)
			state = E('span', { 'class': 'st-dim' }, _('не используется'));
		else if (!cfg.zapret_opts && !cur('zapret_yt', 'yv') && !cur('zapret_discord', 'dv') && !cur('zapret_games', 'gv'))
			state = E('span', { 'class': 'st-bad' }, _('стратегия не выбрана'));
		else if (zi.stella_nfqws)
			state = E('span', { 'class': 'st-ok' }, _('работает'));
		else
			state = E('span', { 'class': 'st-bad' }, [ (zc.missing && zc.missing.length)
				? _('не запущен, нет файлов: %s').format(zc.missing.join(', '))
				: _('не запущен, nfqws не принял стратегию') ]);

		// Автоподбор — у каждой категории свой: кнопка и расписание. Во время проверки у её
		// категории — ход проверки и «Остановить», у остальных — ничего.
		const p = zc.progress || {};
		const pick = (scope, key, has) => {
			if (zc.testing)
				return (p.scope && p.scope != scope) ? [] : [
					(this.zProgress = E('em', { 'class': 'spinning' }, [ p.total ? _('проверяю %d из %d: %s').format(p.done + 1, p.total, p.current || '') : _('готовлюсь…') ])),
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, () => this.call(callZTestStop())) }, _('Остановить'))
				];
			return [
				E('button', { 'class': 'btn cbi-button', 'disabled': zc.strategies.some(has) ? null : '',
					'title': _('Проверить стратегии и применить лучшую'),
					'click': ui.createHandlerFn(this, () => { this.zStarted = true; return this.call(callZTest(scope, true)); }) }, _('подобрать')),
				sui.combo(cfg[key] || '0', [ [ '0', _('вручную') ], [ '7', _('раз в неделю, ночью') ], [ '30', _('раз в месяц, ночью') ] ],
					(v) => sui.saveSettings({ [key]: v }), { custom_placeholder: _('дней…') })
			];
		};

		// Результаты: лучшие сверху, с кнопкой «Применить».
		const names = Object.keys(res).filter((n) => res[n].family != 'current').sort((a, b) => res[b].ok - res[a].ok);
		const base = zc.results && zc.results.baseline;
		const baseText = base ? Object.keys(base).map((k) => (k == 'yv' ? _('YouTube') : _('общие')) + ' ' + base[k].ok + '/' + base[k].total).join(', ') : '';
		const isCur = (n, r) => (r.family == 'yv') ? n == cur('zapret_yt', 'yv') : (n == zc.current && !zc.custom);
		const apply = (n) => this.call(callZApply(n));
		const results = names.length ? E('details', {}, [
			E('summary', { 'style': 'cursor:pointer' }, _('Результаты проверки (%d)').format(names.length) +
				(zc.results.at ? ' · ' + new Date(zc.results.at * 1000).toLocaleString('ru-RU') : '') + (baseText ? ' · ' + _('без обхода: %s').format(baseText) : '')),
			E('div', { 'class': 'st-zres' }, E('table', {}, names.map((n) => {
				const r = res[n];
				const pct = (r.ok > 0 && r.total) ? Math.round(100 * r.ok / r.total) : 0;
				return E('tr', { 'class': isCur(n, r) ? 'st-cur' : '' }, [
					E('td', {}, [ n ]),
					E('td', { 'class': 'st-dim' }, FAMILIES[r.family] || r.family),
					// У ошибки — причина: nfqws не принял ключи, нет файла и т. п.
					r.ok >= 0 ? E('td', { 'style': 'white-space:nowrap' }, [ E('span', { 'class': 'st-bar-bg' }, E('span', { 'style': 'width:' + pct + '%' })), ' ', score(n) ])
						: E('td', { 'class': 'st-bad' }, [ r.error ? _('ошибка: %s').format(r.error) : _('ошибка') ]),
					E('td', { 'class': 'st-act' }, isCur(n, r) ? _('текущая') :
						E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, () => apply(n)) }, _('Применить')))
				]);
			})))
		]) : '';

		const svcBad = zi.service_running || zi.service_enabled || zi.leftover_tables;
		const svc = E('span', { 'class': 'st-inline' }, [
			_('служба zapret:') + ' ',
			zi.service_running ? E('span', { 'class': 'st-bad' }, _('запущена и мешает')) :
			zi.service_enabled ? E('span', { 'class': 'st-bad' }, _('включена в автозапуск')) :
			_('остановлена, остались её правила'),
			E('button', {
				'class': 'btn cbi-button-negative', 'style': 'padding:0 .6em;line-height:1.7em;min-height:0',
				'click': ui.createHandlerFn(this, () => callZapretOff().then((r) => {
					if (r.running)
						ui.addNotification(null, E('p', {}, _('nfqws службы zapret всё ещё запущен. Проверьте zapret2 и zapret-manager.')), 'warning');
					return this.refresh();
				}))
			}, (zi.service_running || zi.service_enabled) ? _('Остановить и отключить') : _('Убрать правила'))
		]);

		if (!zi.binaries.length)
			return dom.content(this.zapretBox, [
				E('h3', { 'style': 'margin-top:0' }, 'Zapret'),
				E('div', { 'class': 'st-zrow' }, [ E('span', { 'class': 'st-dim' }, _('Пакет zapret не установлен.')),
					zi.installing ? E('em', { 'class': 'spinning' }, _('устанавливаю…')) :
					E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, () => callUpdateInstall('zapret').then(() => this.refresh())) }, _('Установить')) ])
			]);
		dom.content(this.zapretBox, [
			E('div', { 'style': 'display:flex;align-items:baseline;gap:1em;flex-wrap:wrap' }, [
				E('h3', { 'style': 'margin:0' }, 'Zapret'),
				E('span', {}, state),
				E('span', { 'class': 'st-dim' }, [
					zc.strategies.length ? _('каталог: %d стратегий').format(zc.strategies.length) : _('каталог не загружен'),
					zc.updated ? ' · ' + new Date(zc.updated * 1000).toLocaleDateString('ru-RU') : '', ' ',
					zc.updating ? E('em', { 'class': 'spinning' }, _('обновляю…')) : E('a', { 'href': '#', 'click': (ev) => { ev.preventDefault(); this.call(callZCatalogUpdate()); } }, _('обновить'))
				])
			]),
			E('div', { 'class': 'st-zgrid' }, [
				E('b', {}, _('Основная')), E('div', {}, [ sel, ...pick('main', 'zapret_test_main', (st) => st.family == 'v' || st.family == 'fs') ]),
				E('b', {}, 'YouTube'), E('div', {}, [ ytSel, ...pick('yv', 'zapret_test_yt', (st) => st.family == 'yv') ]),
				E('b', {}, 'Discord'), E('div', {}, [ dvSel, ...(cur('zapret_discord', 'dv') ? fakeSel('zapret_discord_fake') : []) ]),
				E('b', {}, _('Игры')), E('div', {}, [ gvSel, ...(cur('zapret_games', 'gv') ? fakeSel('zapret_games_fake') : []) ]),
				E('b', {}, _('Исключения')), E('div', {}, [ exSel, E('span', { 'class': 'st-dim', 'title': _('Эти сайты идут напрямую, без Zapret') },
					(exN.zms || exN.fs) ? _('всегда напрямую') : _('обновите каталог')) ]),
			]),
			(cur('zapret_games', 'gv') || cur('zapret_discord', 'dv')) && this.data.default_action != 'zapret' ? E('div', { 'class': 'st-dim' },
				_('Для игр и голоса Discord выберите вверху «Остальной трафик: через Zapret».')) : '',
			results,
			// Внизу — только предупреждение о конфликте с отдельной службой zapret.
			svcBad ? E('div', { 'class': 'st-zfoot st-dim' }, svc) : ''
		]);
	},

	renderAll() {
		const d = this.data;

		dom.content(this.defaultBox, [
			E('span', {}, _('Остальной трафик:')),
			E('select', { 'class': 'cbi-input-select', 'change': (ev) => this.call(callDefault(ev.target.value)) }, [
				E('option', { 'value': 'vpn', 'selected': d.default_action == 'vpn' ? '' : null }, _('через VPN')),
				E('option', { 'value': 'zapret', 'selected': d.default_action == 'zapret' ? '' : null }, _('через Zapret')),
				E('option', { 'value': 'direct', 'selected': d.default_action == 'direct' ? '' : null }, _('напрямую'))
			]),
			E('span', { 'class': 'st-dim' }, _('Списки проверяются сверху вниз.'))
		]);

		this.renderZapret();

		if (!d.lists.length) {
			dom.content(this.tableBox, E('p', {}, _('Списков пока нет.')));
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
			E('td', {}, [ E('div', {}, [ l.name ]), E('div', { 'class': 'st-dim' }, [ sourceLabel(l), this.scopeLabel(l) ]) ]),
			E('td', { 'class': 'st-dim' }, [
				E('div', {}, countLabel(l)),
				l.updated ? E('div', {}, new Date(l.updated * 1000).toLocaleString('ru-RU')) : ''
			]),
			E('td', { 'class': 'st-act' }, [
				l.urls.length ? sui.iconButton('refresh', _('Обновить'), () => this.call(callUpdate(l.id))) : '',
				' ',
				sui.iconButton('edit', _('Изменить'), () => this.showList(l))
			])
		]));

		dom.content(this.tableBox, [
			d.updating ? E('p', {}, E('em', { 'class': 'spinning' }, _('Загружаю списки…'))) : '',
			E('table', { 'class': 'st-table' }, [
				E('tr', {}, [ E('th', {}, ''), E('th', {}, ''), E('th', {}, _('Список')), E('th', {}, _('Содержимое')), E('th', {}, '') ]),
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
			this.defaultBox,
			E('div', { 'class': 'st-bar' }, [
				E('button', { 'class': 'btn cbi-button-add', 'click': () => this.showList(null) }, _('Добавить')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, () => this.call(callUpdate(undefined))) }, _('Обновить все')),
				E('span', { 'class': 'st-inline' }, [ _('автообновление'),
					sui.combo(cfg.lists_interval, INTERVALS, (v) => sui.saveSettings({ lists_interval: v }), { custom_placeholder: _('часов…') }) ])
			]),
			this.tableBox,
			this.zapretBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
