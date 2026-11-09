# Stella

Приложение LuCI для OpenWrt 25.12, которое пускает трафик домашней сети через
[xray-core](https://github.com/XTLS/Xray-core), Zapret или напрямую — по спискам
сайтов и по устройствам.

## Установка

В консоли роутера:

```sh
wget -qO- https://yeru.cc/stella.sh | sh
```

Или напрямую с GitHub:

```sh
wget -qO- https://raw.githubusercontent.com/ExRyuske/Stella/main/install.sh | sh
```

Обе команды запускают один и тот же скрипт [install.sh](install.sh). Он ставит последний [релиз](../../releases) с зависимостями
(`xray-core`, `curl`, модули ucode). Пакет не подписан, поэтому ставится с `--allow-untrusted`.
Дальше — LuCI → Службы → Stella: dnsmasq-full (без него не работают списки по доменам), zapret
и mwan3 ставятся на «Обзоре» в «Обновлениях», там же обновляется сама Stella.

## Что умеет

- **Серверы** — подписки и отдельные ссылки: VLESS (REALITY, XHTTP, Vision, gRPC, WS),
  VMess, Trojan, Shadowsocks 2022, Hysteria2, WireGuard. Проверка задержки, автовыбор самого
  быстрого из отмеченных узлов, обновление подписок по расписанию.
- **WARP** — бесплатный узел Cloudflare WARP одной кнопкой: роутер сам регистрируется,
  проверяет несколько адресов WARP и берёт лучший. API Cloudflare в России закрыт — без VPN
  регистрация идёт через Zapret (стратегии по очереди, пока одна не пропустит запрос). Перед рукопожатием WireGuard xray шлёт
  пакет QUIC, чтобы DPI не узнал WireGuard (идея и маски — из
  [warp-config-generator-vercel](https://github.com/nellimonix/warp-config-generator-vercel)).
- **Резервный канал (mwan3)** — когда основной провайдер падает и mwan3 пускает трафик через
  резервный канал (например, мобильного оператора с белыми списками), xray работает через узел,
  выбранный для этого канала; вернулся основной — через прежний. Пока работает резервный канал,
  через VPN можно пустить весь трафик: списки и устройства тогда не действуют, кроме блокировки.
  Нужна nftables-версия mwan3
  ([mwan3-nft](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3-nft)) — Stella
  ставит её в «Обновлениях».
- **Списки** — готовые списки [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains),
  поиск по наборам geosite и geoip из [russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat),
  ссылки на любые списки и свои сайты. Для каждого списка — действие: VPN, Zapret, напрямую
  или блок, и для каких устройств он действует.
- **Устройства** — «по спискам», «всё через VPN» или «всё напрямую».
- **Zapret** — каталог стратегий (Zapret Manager, его набор для YouTube, Flowseal) и
  автоподбор: каждая стратегия проверяется в изоляции, лучшая применяется, только если
  она открывает больше текущей.
- **DNS** — через VPN по DoH, запасной напрямую, перехват DNS устройств и блокировка
  DNS-over-HTTPS в браузерах.

## Как устроено

Трафик устройств LAN перехватывается в своей таблице nftables (`inet stella`): dnsmasq
кладёт IP доменов из списков в сеты, по ним пакет уходит в TPROXY → xray, в очередь nfqws,
напрямую или в блок. Настройки на страницах LuCI меняются, как везде в OpenWrt: правки полей копятся
до «Сохранить», добавление, удаление и «Сохранить» в окне сразу видны в «Unsaved Changes»,
а применяются кнопкой «Сохранить и применить» (служба перезагружается сама); состояние и действия
(проверки, обновления, WARP) — через плагин rpcd на ucode.

| Путь | Что там |
|---|---|
| `root/usr/share/ucode/stella/` | разбор ссылок, подписок и списков, генерация конфигов xray, nftables и dnsmasq, каталог Zapret |
| `root/usr/bin/stella` | CLI: обновления, проверка задержки, правила, автоподбор Zapret |
| `root/usr/share/rpcd/ucode/stella.uc` | объект ubus `stella`: состояние и действия для страниц |
| `htdocs/luci-static/resources/view/stella/` | страницы LuCI |
| `tests/` | тесты на ucode той же ревизии, что в OpenWrt 25.12 |

## Разработка

```sh
UCODE=/путь/к/ucode tests/run.sh    # модульные тесты и смоук rpcd
UCODE=/путь/к/ucode tests/cli.sh    # сквозной сценарий CLI
scripts/check_web.sh                # синтаксис страниц LuCI
```

Нужны ucode ревизии `85922056` с модулем zlib и xray из пакета `xray-core` OpenWrt 25.12 — как в CI.
