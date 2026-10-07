# Stella

Приложение LuCI для OpenWrt 25.12, которое пускает трафик домашней сети через
[xray-core](https://github.com/XTLS/Xray-core), Zapret или напрямую — по спискам
сайтов и по устройствам. Проверяется на OpenWrt One.

## Что умеет

- **Серверы** — подписки и отдельные ссылки: VLESS (REALITY, XHTTP, Vision, gRPC, WS),
  VMess, Trojan, Shadowsocks 2022, Hysteria2. Проверка задержки, автовыбор самого
  быстрого из отмеченных узлов, обновление подписок по расписанию.
- **Резервный канал (mwan3)** — когда основной провайдер падает и mwan3 пускает трафик через
  резервный канал (например, мобильного оператора с белыми списками), xray работает через узел,
  выбранный для этого канала; вернулся основной — через прежний.
- **Списки** — готовые списки [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains),
  ссылки на любые списки (например, [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat))
  и свои сайты. Для каждого списка — действие: VPN, Zapret, напрямую или блок, и для каких
  устройств он действует.
- **Устройства** — «по спискам», «всё через VPN» или «всё напрямую».
- **Zapret** — каталог стратегий (Zapret Manager, его набор для YouTube, Flowseal) и
  автоподбор: каждая стратегия проверяется в изоляции, лучшая применяется, только если
  она открывает больше текущей.
- **DNS** — через VPN по DoH, запасной напрямую, перехват DNS устройств и блокировка
  DNS-over-HTTPS в браузерах.

## Как устроено

Трафик устройств LAN перехватывается в своей таблице nftables (`inet stella`): dnsmasq
кладёт IP доменов из списков в сеты, по ним пакет уходит в TPROXY → xray, в очередь nfqws,
напрямую или в блок. Всё, что делает интерфейс, идёт через плагин rpcd на ucode.

| Путь | Что там |
|---|---|
| `root/usr/share/ucode/stella/` | разбор ссылок, подписок и списков, генерация конфигов xray, nftables и dnsmasq, каталог Zapret |
| `root/usr/bin/stella` | CLI: обновления, проверка задержки, правила, автоподбор Zapret |
| `root/usr/share/rpcd/ucode/stella.uc` | объект ubus `stella` для интерфейса |
| `htdocs/luci-static/resources/view/stella/` | страницы LuCI |
| `tests/` | тесты на ucode той же ревизии, что в OpenWrt 25.12 |

## Установка

Пакет `.apk` — в [релизах](../../releases). Он не подписан, поэтому:

```sh
apk add --allow-untrusted ./luci-app-stella-*.apk
```

Зависимости (`xray-core`, `curl`, модули ucode) ставятся из репозитория OpenWrt. Для
действия «Zapret» нужен установленный пакет zapret.

## Разработка

```sh
UCODE=/путь/к/ucode tests/run.sh    # модульные тесты и смоук rpcd
UCODE=/путь/к/ucode tests/cli.sh    # сквозной сценарий CLI
scripts/check_web.sh                # синтаксис страниц LuCI
```

Нужны ucode ревизии `85922056` и xray `26.3.27` — как в CI.
