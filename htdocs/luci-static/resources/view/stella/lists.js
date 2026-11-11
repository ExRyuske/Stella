'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require uci';
'require stella.common as sui';

const callLists = rpc.declare({ object: 'stella', method: 'lists' });
const callUpdate = rpc.declare({ object: 'stella', method: 'lists_update', params: [ 'id' ] });
const callGeoIndex = rpc.declare({ object: 'stella', method: 'geo_index', params: [ 'update' ] });
const callSettings = rpc.declare({ object: 'stella', method: 'settings' });
const callZapretInfo = rpc.declare({ object: 'stella', method: 'zapret_info' });
const callZapretOff = rpc.declare({ object: 'stella', method: 'zapret_service_off' });
const callZCatalog = rpc.declare({ object: 'stella', method: 'zapret_catalog' });
const callZApply = rpc.declare({ object: 'stella', method: 'zapret_apply', params: [ 'name' ] });
const callZTest = rpc.declare({ object: 'stella', method: 'zapret_test', params: [ 'scope', 'apply' ] });
const callZTestStop = rpc.declare({ object: 'stella', method: 'zapret_test_stop' });
const callUpdateInstall = rpc.declare({ object: 'stella', method: 'update_install', params: [ 'what' ] });

const FAMILIES = { v: 'Zapret Manager', fs: 'Flowseal' };

const ITD = 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/';

// Готовые списки itdoginfo/allow-domains — по содержимому репозитория (его присылает роутер:
// stella geo-index), так новые списки появляются сами. Названия — как в репозитории: папка —
// группа, файл — пункт.
function itdogLabel(files) {
	return files[0].replace(/^.*\//, '').replace(/\.lst$/, '');
}

// Сколько секунд удалённый список можно вернуть.
const REMOVE_DELAY = 10;

const ACTIONS = [
	[ 'vpn', _('VPN') ],
	[ 'zapret', _('Zapret') ],
	[ 'direct', _('Напрямую') ],
	[ 'block', _('Блокировать') ]
];


const CSS = `
.st-table tr.st-off td, .st-table .tr.st-off .td { opacity:.5 }
.modal .cbi-value-field textarea, .modal .cbi-value-field input[type=text] { width:100% }
.st-table select { width:auto }
.st-order .btn { line-height:1.8em; min-height:0 }
.st-order { white-space:nowrap; width:1% }
@media (max-width:854px) { .st-lists .td.st-act { flex:1 1 100%; text-align:left } }
.st-scope { color:#39f }
.st-cat h5 { margin:.4em 0 .15em; font-size:90%; opacity:.8 }
.st-cols { columns:2 }
.st-cols label { display:block; padding:.12em 0; break-inside:avoid }
.st-devs { margin-top:.4em; max-height:14em; overflow-y:auto; border:1px solid rgba(128,128,128,.25); border-radius:4px }
.st-dev { display:flex; align-items:center; gap:.6em; padding:.3em .6em; border-bottom:1px solid rgba(128,128,128,.12); cursor:pointer }
.st-dev:last-child { border-bottom:0 }
.st-dev input { margin:0 }
.st-dev .st-name { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
.st-dev .st-dim { white-space:nowrap; font-size:85% }
.st-chips { display:flex; flex-wrap:wrap; gap:.3em; margin-bottom:.35em }
.st-chips:empty { display:none }
.st-chip { display:inline-flex; gap:.4em; align-items:center; padding:.1em .5em; border-radius:3px; background:rgba(60,140,220,.18); font-size:90% }
.st-chip a { text-decoration:none; opacity:.7 }
`;

function actionSelect(value, onchange) {
	return sui.select(value, ACTIONS, onchange);
}

function countLabel(l) {
	const p = [];
	if (l.domains)
		p.push('%d %s'.format(l.domains, sui.plural(l.domains, _('домен'), _('домена'), _('доменов'))));
	if (l.cidrs)
		p.push('%d %s'.format(l.cidrs, sui.plural(l.cidrs, _('подсеть'), _('подсети'), _('подсетей'))));
	return p.length ? p.join(' · ') : ((l.urls.length || l.geo.length) ? _('не загружен') : _('пусто'));
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
		return sui.need(21).then(() => Promise.all([ callLists(), sui.devices(), callSettings(), callZapretInfo(), callZCatalog() ]));
	},

	setDevices(dr) {
		this.devices = dr;
		this.devNames = {};
		for (const d of dr)
			this.devNames[d.mac] = d.name || d.hostname || d.ip || d.mac;
	},

	refresh() {
		// Настройки тоже: стратегию меняют и выбор из каталога, и автоподбор.
		return Promise.all([ callLists(), sui.devices(), callZapretInfo(), callZCatalog(), callSettings() ]).then(([ d, dr, zi, zc, cfg ]) => {
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

	// Записать список (секция list): новый — в конец; sources — его ссылки и наборы изменились,
	// роутер скачивает их сразу.
	saveList(id, v, sources) {
		return this.call(sui.edit(() => {
			// Новый — только когда в нём есть название; прежнего уже нет (удалили в другом окне) —
			// не создавать его обрывком.
			if (!uci.get('stella', id)) {
				if (v.name == null)
					return false;
				uci.add('stella', 'list', id);
			}
			for (const key in v)
				sui.set(id, key, v[key]);
		}).then((ok) => (ok && sources) ? callUpdate(id) : null));
	},

	// Порядок важен: срабатывает первый совпавший список. dir: -1 — выше, 1 — ниже.
	moveList(id, dir) {
		const ids = this.data.lists.map((l) => l.id), other = ids[ids.indexOf(id) + dir];
		return this.call(sui.edit(() => other ? uci.move('stella', id, other, dir > 0) : false));
	},

	// Одно окно для создания и изменения. Для нового списка — ещё и каталог itdoginfo.
	showList(l) {
		const isNew = !l;
		l = l || { name: '', action: 'vpn', urls: [], geo: [], entries: [], devices_mode: 'all', macs: [] };

		// Каталог itdoginfo — и при создании, и при изменении: уже входящие в список пункты
		// отмечены, а их ссылки не дублируются в поле ниже. Пункты — из индекса, который присылает
		// роутер; пока он загружается — «загружаю…».
		let action = l.action;
		const actSel = actionSelect(action, (v) => action = v);
		const checks = [];
		const cat = E('div', { 'class': 'st-cat' }, E('em', { 'class': 'spinning' }, _('загружаю списки…')));
		let catDrawn = false, textEdited = false, text = null;
		const drawCat = (items) => {
			// Отметки при перерисовке сохраняются — по ссылкам.
			const was = {};
			for (const [ cb, , urls ] of checks)
				if (cb.checked)
					urls.forEach((u) => was[u] = true);
			const first = !catDrawn;
			checks.length = 0;
			const groups = [ ...new Set(items.map((it) => it.group)) ].map((g) => [ g, g ]);
			const byName = (a, b) => itdogLabel(a.files).localeCompare(itdogLabel(b.files), undefined, { sensitivity: 'base' });
			dom.content(cat, groups.map(([ key, title ]) => [ title, items.filter((it) => it.group == key).sort(byName) ]).filter((g) => g[1].length).map(([ title, its ]) =>
				E('div', {}, [ E('h5', {}, title), E('div', { 'class': 'st-cols' }, its.map((it) => {
					const urls = it.files.map((f) => ITD + f);
					const on = first ? (!isNew && urls.every((u) => l.urls.indexOf(u) >= 0)) : urls.every((u) => was[u]);
					const cb = E('input', { 'type': 'checkbox', 'checked': on ? '' : null });
					const name = itdogLabel(it.files);
					checks.push([ cb, name, urls ]);
					return E('label', {}, [ cb, ' ', name ]);
				})) ])));
			catDrawn = true;
			if (first && text && !textEdited)
				text.value = ownText();
		};
		// Свои ссылки и сайты: всё, что не покрыто отмеченными пунктами каталога.
		const ownText = () => {
			const covered = {};
			for (const [ cb, , urls ] of checks)
				if (cb.checked)
					urls.forEach((u) => covered[u] = true);
			return [ ...l.urls.filter((u) => !covered[u]), ...l.entries ].join('\n');
		};

		// Наборы geosite и geoip из russia-v2ray-rules-dat — поиском по именам, как в 3x-ui. В списке
		// хранятся именами (geosite:youtube) и скачиваются вместе с ним.
		const geoSel = l.geo.map((g) => g.split(':')).filter((p) => p.length == 2 && (p[0] == 'geosite' || p[0] == 'geoip'));
		const chips = E('div', { 'class': 'st-chips' });
		const search = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'disabled': '', 'placeholder': _('загружаю наборы…') });
		const hits = E('div', { 'class': 'st-devs', 'style': 'display:none' });
		const geoState = E('small', { 'class': 'st-dim' });
		const geoIdx = (p) => geoSel.findIndex((x) => x[0] == p[0] && x[1] == p[1]);
		const toggle = (p) => {
			const i = geoIdx(p);
			if (i >= 0)
				geoSel.splice(i, 1);
			else
				geoSel.push(p);
			drawChips();
			drawHits();
		};
		const drawChips = () => dom.content(chips, geoSel.map((p) => E('span', { 'class': 'st-chip' }, [
			p[0] + ':' + p[1],
			E('a', { 'href': '#', 'title': _('Убрать'), 'click': (ev) => { ev.preventDefault(); toggle(p); } }, '×')
		])));
		// Сначала точное совпадение, потом начинающиеся с запроса. «geoip:» или «geosite:» в начале
		// запроса — искать только среди них.
		const drawHits = () => {
			const m = search.value.trim().toLowerCase().match(/^(?:(geosite|geoip):)?(.*)$/);
			const q = m[2];
			if (!this.geo || !q) {
				hits.style.display = 'none';
				return;
			}
			const rank = (n) => (n == q) ? 0 : (n.indexOf(q) == 0) ? 1 : 2;
			const found = [];
			for (const kind of [ 'geosite', 'geoip' ])
				if (!m[1] || m[1] == kind)
					for (const n of this.geo[kind])
						if (n.indexOf(q) >= 0)
							found.push([ kind, n ]);
			found.sort((a, b) => rank(a[1]) - rank(b[1]) || a[1].length - b[1].length || a[1].localeCompare(b[1]));
			hits.style.display = '';
			dom.content(hits, found.length ? found.slice(0, 50).map((p) => E('label', { 'class': 'st-dev' }, [
				E('input', { 'type': 'checkbox', 'checked': geoIdx(p) >= 0 ? '' : null, 'change': () => toggle(p) }),
				E('span', { 'class': 'st-name' }, p[1]),
				E('span', { 'class': 'st-dim' }, p[0])
			])) : E('div', { 'class': 'st-dev st-dim' }, _('ничего не найдено')));
		};
		search.addEventListener('input', drawHits);
		// Что в индексе: время и сколько чего (часть могла не скачаться — время тогда прежнее).
		const geoSig = (r) => [ r.at, r.geosite.length, r.geoip.length, (r.itdog || []).length ].join();
		const useGeo = (r) => {
			this.geo = r;
			if ((r.itdog || []).length)
				drawCat(r.itdog);
			search.disabled = false;
			search.placeholder = _('поиск: youtube, ru-blocked, geoip:ru');
			drawHits();
		};
		// Имён нет или им больше недели — роутер скачивает их заново; пока качает — опрашиваем.
		let asked = false;
		const loadGeo = (update) => callGeoIndex(update).then((r) => {
			const have = r.geosite.length + r.geoip.length + (r.itdog || []).length > 0;
			if (have && (!this.geo || geoSig(this.geo) != geoSig(r)))
				useGeo(r);
			// Нет наборов или списков itdoginfo (часть не скачалась) либо индексу больше недели.
			const full = r.geosite.length && r.geoip.length && (r.itdog || []).length;
			if (!r.loading && !asked && (!full || Date.now() / 1000 - r.at > 7 * 86400)) {
				asked = true;
				return loadGeo(true);
			}
			if (r.loading)
				return new Promise((res) => window.setTimeout(res, 1500)).then(() => document.body.contains(search) && loadGeo(false));
			const retry = (box, text) => dom.content(box, [ text + ' ', E('a', { 'href': '#', 'click': (ev) => {
				ev.preventDefault();
				dom.content(geoState, '');
				if (!catDrawn)
					dom.content(cat, E('em', { 'class': 'spinning' }, _('загружаю списки…')));
				loadGeo(true);
			} }, _('Повторить')) ]);
			if (!catDrawn)
				retry(cat, _('Списки itdoginfo не загружены.'));
			if (!r.geosite.length && !r.geoip.length) {
				search.placeholder = '';
				retry(geoState, _('Не удалось загрузить наборы.'));
			}
		}).catch((e) => dom.content(geoState, [ _('Поиск недоступен: %s').format(e.message) ]));
		drawChips();
		// Индекс со страницы — сразу, и всегда сверка с роутером: без неё окно, открытое после
		// неполной загрузки, так и показывало бы «загружаю списки…».
		if (this.geo)
			useGeo(this.geo);
		loadGeo(false);

		const name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': l.name, 'placeholder': isNew ? _('необязательно') : '' });
		text = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 4, 'input': () => textEdited = true,
			'placeholder': 'mysite.ru\n203.0.113.0/24\nhttps://example.com/list.lst' }, [ ownText() ]);
		// Каталог уже был нарисован из индекса — поле своих ссылок по нему.
		if (catDrawn)
			text.value = ownText();

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
		let devMode = l.devices_mode;
		const syncDevs = () => devList.style.display = (devMode == 'all') ? 'none' : '';
		const mode = sui.select(devMode, [ [ 'all', _('все') ], [ 'only', _('только выбранные') ], [ 'except', _('все, кроме выбранных') ] ],
			(v) => { devMode = v; syncDevs(); });
		syncDevs();

		const save = () => {
			const macs = boxes.filter(([ , cb ]) => cb.checked).map(([ d ]) => d.mac);
			if (devMode != 'all' && !macs.length)
				return ui.addNotification(null, E('p', {}, _('Выберите хотя бы одно устройство.')), 'warning');
			const all = lines(text.value).map(puny);
			const urls = all.filter(isListUrl), sites = all.filter((s) => !isListUrl(s));
			const geo = geoSel.map((p) => p[0] + ':' + p[1]);

			// Для каких устройств: «все» — без отметок.
			const scope = { devices_mode: devMode == 'all' ? null : devMode, mac: devMode == 'all' ? null : macs };
			if (!isNew) {
				const all_urls = [ ...new Set([ ...checks.filter(([ cb ]) => cb.checked).flatMap(([ , , u ]) => u), ...urls ]) ];
				if (!all_urls.length && !geo.length && !sites.length)
					return ui.addNotification(null, E('p', {}, _('Список пуст.')), 'warning');
				ui.hideModal();
				return this.saveList(l.id, Object.assign({ name: name.value.trim() || l.name, action, url: all_urls, geo, entry: sites }, scope),
					all_urls.join() != l.urls.join() || geo.join() != l.geo.join());
			}

			// Всё выбранное — один список: пункты каталога, наборы, свои ссылки и сайты.
			const picked = checks.filter(([ cb ]) => cb.checked);
			const all_urls = [ ...new Set([ ...picked.flatMap(([ , , u ]) => u), ...urls ]) ];
			if (!all_urls.length && !geo.length && !sites.length)
				return ui.addNotification(null, E('p', {}, _('Ничего не выбрано.')), 'warning');
			const names = [ ...picked.map(([ , n ]) => n), ...geo, ...urls.map(listName),
				...(sites.length ? [ _('свои сайты') ] : []) ];
			const auto = (names.length > 3) ? names.slice(0, 3).join(', ') + _(' и ещё %d').format(names.length - 3) : names.join(', ');
			ui.hideModal();
			return this.saveList(sui.newId('list'), Object.assign({ name: name.value.trim() || auto, action, enabled: '1', url: all_urls, geo, entry: sites }, scope),
				all_urls.length + geo.length > 0);
		};

		ui.showModal([ isNew ? _('Новый список') : _('Список «%s»').format(l.name) ], [
			sui.card([
				sui.field(_('Название'), name),
				sui.field(_('Действие'), actSel),
				sui.field(_('Готовые списки'), cat),
				sui.field(_('Наборы geosite и geoip'), [ chips, search, hits, geoState ]),
				sui.field(_('Свои сайты и ссылки'), [ text, sui.hint(_('Сайты, подсети и ссылки на списки, по одному в строке.')) ]),
				sui.field(_('Устройства'), [ mode, devList ])
			]),
			E('div', { 'class': 'st-buttons' }, [
				isNew ? '' : E('button', { 'class': 'btn cbi-button-negative', 'click': () => { ui.hideModal(); this.handleRemove(l); } }, _('Удалить')),
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, save) }, isNew ? _('Добавить') : _('Сохранить'))
			])
		]);
	},

	// Удаление без подтверждения, но не сразу: REMOVE_DELAY секунд список остаётся на роутере
	// как был, а в таблице на его месте — «удалён» и «Вернуть», которая просто отменяет удаление.
	handleRemove(l) {
		this.pending[l.id] = window.setTimeout(() => this.commitRemove(l.id), REMOVE_DELAY * 1000);
		this.renderAll();
	},

	commitRemove(id) {
		window.clearTimeout(this.pending[id]);
		delete this.pending[id];
		return this.call(sui.edit(() => uci.remove('stella', id)));
	},

	handleRestore(id) {
		window.clearTimeout(this.pending[id]);
		delete this.pending[id];
		this.renderAll();
	},

	goneRow(l) {
		return sui.tr([
			sui.td(null, _('Список «%s» удалён').format(l.name), 'st-dim', { 'colspan': 5 }),
			sui.td(null, E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': () => this.handleRestore(l.id) }, _('Вернуть')), 'st-act')
		]);
	},

	scopeLabel(l) {
		if (l.devices_mode == 'all')
			return '';
		const names = l.macs.map((m) => this.devNames[m] || m);
		return E('div', { 'class': 'st-dim st-scope' }, [ (l.devices_mode == 'only' ? _('только: %s') : _('кроме: %s')).format(names.join(', ')) ]);
	},

	/* Zapret */

	showZapret() {
		const zi = this.zi, cfg = this.cfg;
		let binV = cfg.zapret_bin || zi.binaries[0] || '/opt/zapret/nfq/nfqws';
		const bin = sui.select(binV, [ ...new Set([ ...zi.binaries, binV ]) ].map((b) => [ b, b ]), (v) => binV = v);
		const opts = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 12, 'style': 'font-family:monospace;font-size:12px' }, [ cfg.zapret_opts || '' ]);
		const tcp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': cfg.zapret_tcp_ports || '', 'placeholder': '80,443' });
		const udp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': cfg.zapret_udp_ports || '', 'placeholder': '443' });

		ui.showModal(_('Своя стратегия Zapret'), [
			sui.card([
				sui.field(_('Программа'), bin),
				sui.field(_('Параметры nfqws'), [ opts, sui.hint(_('По одному в строке.')) ]),
				sui.field(_('Порты TCP'), tcp),
				sui.field(_('Порты UDP'), udp)
			]),
			E('div', { 'class': 'st-buttons' }, [
				zi.import_opts ? E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': () => {
					opts.value = String(zi.import_opts).trim();
					if (zi.import_tcp) tcp.value = zi.import_tcp;
					if (zi.import_udp) udp.value = zi.import_udp;
				} }, _('Взять из zapret')) : '',
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, () => sui.saveSettings({
						zapret_bin: binV, zapret_opts: opts.value, zapret_strategy: '',
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

		// Стратегии в списках — по итогам последней проверки: лучшие сверху, за ними непроверенные
		// (по порядку каталога), ошибки — в конце. Оценка — серой припиской к названию; у «выключено»
		// — сколько открывается без обхода.
		const rank = (st) => {
			const r = res[st.name];
			return !r ? -1 : (r.ok < 0) ? -2 : r.ok / (r.total || 1);
		};
		const byScore = (list) => list.map((st, i) => [ st, i ]).sort((a, b) => rank(b[0]) - rank(a[0]) || a[1] - b[1]).map((x) => x[0]);
		const base = (zc.results && zc.results.baseline) || {};
		const off = (k) => base[k] ? sui.label(_('выключено'), _('без обхода %d из %d').format(base[k].ok, base[k].total)) : _('выключено');
		const tested = (zc.results && zc.results.at) ? _('проверено %s').format(sui.time(zc.results.at)) : '';

		// YouTube, Discord и игры — отдельные наборы, как в Zapret Manager.
		const fam = (f) => byScore(zc.strategies.filter((st) => st.family == f));
		const cur = (key) => cfg[key] || '';
		const stLabel = (st) => res[st.name] ? sui.label(st.name, score(st.name)) : st.name;
		const setSel = (key, f) => sui.select(cur(key, f), [ [ '', f == 'yv' ? off('yv') : _('выключено') ], ...fam(f).map((st) => [ st.name, stLabel(st) ]) ],
			(v) => this.saveSetting({ [key]: v }));
		const ytSel = setSel('zapret_yt', 'yv'), dvSel = setSel('zapret_discord', 'dv'), gvSel = setSel('zapret_games', 'gv');
		const fakeName = (f) => f.replace(/^.*\//, '').replace(/\.bin$/, '');
		const fakeSel = (key) => [ sui.dim(_('подделка')), sui.select(cfg[key] || '', [ [ '', _('stun (по умолчанию)') ],
			...(zc.fakes || []).map((f) => [ f, fakeName(f) ]) ], (v) => this.saveSetting({ [key]: v })) ];
		// Основная: стратегии Zapret Manager и Flowseal одним списком (источник — серой припиской),
		// выключено и своя; смена применяется сразу.
		const sel = sui.select(zc.custom ? '__custom' : (zc.current || ''), [
			[ '', off('general') ],
			...byScore(zc.strategies.filter((st) => st.family == 'v' || st.family == 'fs')).map((st) =>
				[ st.name, sui.label(st.name, (FAMILIES[st.family] || st.family) + (res[st.name] ? ', ' + score(st.name) : '')) ]),
			[ '__custom', zc.custom ? _('своя стратегия') : _('своя стратегия…') ]
		], (v) => {
			if (v == '__custom')
				return this.showZapret();
			// Без основной работают только YouTube, Discord и игры.
			if (v == '')
				return this.saveSetting({ zapret_opts: '', zapret_strategy: '' });
			return this.call(callZApply(v));
		});

		let state;
		if (!used)
			state = E('span', { 'class': 'st-dim' }, _('не используется'));
		else if (!zi.enabled)
			state = E('span', { 'class': 'st-dim' }, _('Stella выключена'));
		else if (!zc.strategies.length)
			state = E('span', { 'class': 'st-dim' }, zc.updating ? _('загружаю каталог…') : _('каталог ещё не загружен'));
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
					E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, () => this.call(callZTestStop())) }, _('Остановить'))
				];
			return [
				sui.dim(_('автоподбор')),
				sui.combo(cfg[key] || '0', [ [ '0', _('вручную') ], [ '1', _('раз в сутки, ночью') ], [ '7', _('раз в неделю, ночью') ], [ '30', _('раз в месяц, ночью') ] ],
					(v) => sui.saveSettings({ [key]: v }), { custom_placeholder: _('дней…') }),
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': zc.strategies.some(has) ? null : '',
					'title': _('Проверить стратегии и применить лучшую'),
					'click': ui.createHandlerFn(this, () => { this.zStarted = true; return this.call(callZTest(scope, true)); }) }, _('Подобрать сейчас'))
			];
		};

		const svcBad = zi.service_running || zi.service_enabled || zi.leftover_tables;
		const svc = [
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
		];

		if (!zi.binaries.length)
			return dom.content(this.zapretBox, sui.kv(_('Пакет'), [ sui.dim(_('не установлен')),
				zi.installing ? E('em', { 'class': 'spinning' }, _('устанавливаю…')) :
				E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, () => callUpdateInstall('zapret').then(() => this.refresh())) }, _('Установить')) ]));
		const needDefault = (cur('zapret_games', 'gv') || cur('zapret_discord', 'dv')) && this.data.default_action != 'zapret';
		dom.content(this.zapretBox, [
			// Состояние и каталог — одной строкой; каталог обновляется вместе со всем остальным
			// (расписание и кнопка на «Обзоре») — когда, видно там.
			...sui.kv(_('Состояние'), [ state, tested ? sui.dim(tested) : '', zc.updating ? E('em', { 'class': 'spinning' }, _('обновляю каталог…')) : '' ]),
			...sui.kv(_('Основная'), [ sel, ...pick('main', 'zapret_test_main', (st) => st.family == 'v' || st.family == 'fs') ]),
			...sui.kv('YouTube', [ ytSel, ...pick('yv', 'zapret_test_yt', (st) => st.family == 'yv') ]),
			...sui.kv('Discord', [ dvSel, ...(cur('zapret_discord', 'dv') ? fakeSel('zapret_discord_fake') : []) ]),
			...sui.kv(_('Игры'), [ gvSel, ...(cur('zapret_games', 'gv') ? fakeSel('zapret_games_fake') : []),
				needDefault ? sui.hint(_('Работает, когда остальной трафик идёт через Zapret.')) : '' ]),
			// Конфликт с отдельной службой zapret — только если он есть.
			...(svcBad ? sui.kv(_('Служба zapret'), svc) : [])
		]);
	},

	renderAll() {
		const d = this.data;

		// Списки обновляются вместе со всем остальным — расписание и кнопка на «Обзоре».
		dom.content(this.defaultBox, [
			...sui.kv(_('Остальной трафик'), [ sui.select(d.default_action,
				[ [ 'vpn', _('через VPN') ], [ 'zapret', _('через Zapret') ], [ 'direct', _('напрямую') ] ], (v) => this.saveSetting({ default_action: v })),
				d.updating ? E('em', { 'class': 'spinning' }, _('загружаю списки…')) : '' ])
		]);

		this.renderZapret();

		const n = d.lists.length;
		const rows = d.lists.map((l, i) => (l.id in this.pending) ? this.goneRow(l) : sui.tr([
			sui.td(null, [
				E('button', { 'class': 'btn cbi-button cbi-button-up', 'title': _('Выше'), 'disabled': i == 0 ? '' : null,
					'click': ui.createHandlerFn(this, () => this.moveList(l.id, -1)) }, '▲'),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-down', 'title': _('Ниже'), 'disabled': i == n - 1 ? '' : null,
					'click': ui.createHandlerFn(this, () => this.moveList(l.id, 1)) }, '▼')
			], 'st-order'),
			sui.td(null, E('input', { 'type': 'checkbox', 'title': _('Включён'), 'checked': l.enabled ? '' : null,
				'change': (ev) => this.saveList(l.id, { enabled: ev.target.checked ? '1' : '0' }) }), 'st-order'),
			sui.td(_('Список'), [ E('div', {}, [ l.name ]), this.scopeLabel(l) ]),
			sui.td(_('Содержимое'), countLabel(l)),
			sui.td(_('Обновлён'), l.updated ? sui.time(l.updated) : '—'),
			sui.td(null, [
				(l.urls.length || l.geo.length) ? sui.rowButton(_('Обновить'), 'action', () => this.call(callUpdate(l.id))) : '',
				' ',
				sui.rowButton(_('Изменить'), 'edit', () => this.showList(l)),
				' ',
				sui.rowButton(_('Удалить'), 'remove', () => this.handleRemove(l))
			], 'st-act')
		], l.enabled ? '' : 'st-off'));

		dom.content(this.tableBox, sui.table([
			[ _('Проверка сверху вниз'), { 'colspan': 2, 'style': 'white-space:nowrap', 'title': _('Срабатывает первый подходящий список') } ],
			_('Список'), _('Содержимое'), _('Обновлён'), ''
		], rows, 'st-lists', _('Списков пока нет.')));
	},

	render([ data, dr, cfg, zi, zc ]) {
		this.data = data;
		this.cfg = cfg;
		this.zi = zi;
		this.zc = zc;
		this.setDevices(dr);
		this.pending = {};
		// Ушли со страницы раньше — удалить сейчас: обычный запрос при уходе может не дойти.
		window.addEventListener('pagehide', () => {
			const req = (method, args) => ({ jsonrpc: '2.0', id: 0, method: 'call', params: [ rpc.getSessionID(), 'uci', method, args ] });
			const ids = Object.keys(this.pending);
			if (ids.length)
				navigator.sendBeacon(rpc.getBaseURL(), JSON.stringify([ ...ids.map((id) => req('delete', { config: 'stella', section: id })),
					req('commit', { config: 'stella' }) ]));
		});
		this.defaultBox = sui.card([]);
		this.tableBox = E('div');
		this.zapretBox = sui.card([]);
		this.renderAll();
		if (data.updating || zc.testing || zc.updating)
			this.refresh();

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Списки сайтов')),
			sui.section(null, [
				this.defaultBox,
				this.tableBox,
				sui.create(_('Добавить'), () => this.showList(null))
			]),
			sui.section('Zapret', this.zapretBox)
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

