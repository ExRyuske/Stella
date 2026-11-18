# Stella

Приложение LuCI для OpenWrt 25.12, которое пускает трафик домашней сети через
[xray-core](https://github.com/XTLS/Xray-core), Zapret или напрямую — по спискам
сайтов и по устройствам.

## Установка

В консоли роутера:

```sh
wget -qO- https://yeru.cc/stella.sh | sh
```

Или с GitHub:

```sh
wget -qO- https://raw.githubusercontent.com/ExRyuske/Stella/main/install.sh | sh
```

[Скрипт](install.sh) устанавливает последний [релиз](../../releases) и зависимости:
`xray-core`, `curl`, модули ucode, `dnsmasq-full`, `zapret`.
Неподписанный пакет устанавливается с `--allow-untrusted`.

## Возможности

- **Серверы:** подписки и ссылки VLESS (REALITY, XHTTP, Vision, gRPC, WS), VMess, Trojan,
  Shadowsocks 2022, Hysteria2 и WireGuard. Проверка задержки, автовыбор узла и обновления по расписанию.
- **WARP:** автоматическая регистрация Cloudflare WARP, подбор адреса и восстановление соединения.
  Для регистрации доступен обход через Zapret; WireGuard использует маскировку QUIC.
  Данные обновляются из [warp-config-generator-vercel](https://github.com/nellimonix/warp-config-generator-vercel).
- **Резервный канал:** отдельный VPN-узел при переключении mwan3. Можно направить весь трафик
  резерва через VPN, сохранив блок-списки. Нужен [mwan3-nft](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3-nft),
  доступный в «Обновлениях».
- **Списки:** [itdoginfo](https://github.com/itdoginfo/allow-domains), geosite/geoip из
  [russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat), свои домены и ссылки.
  Для каждого списка — действие и устройства, а также автоматическая проверка и отображение пересечений
  доменов и подсетей между списками. Отдельное правило для BitTorrent (по умолчанию напрямую; можно
  направить через VPN, заблокировать или пускать как остальной трафик).
  По умолчанию YouTube идёт через Zapret, «Заблокировано в России» — через VPN, остальное — напрямую.
- **Устройства:** «по спискам», «всё через VPN» или «всё напрямую».
  Перехват работает только с IPv4; IPv6 по умолчанию закрыт, это можно отключить.
- **Zapret:** основные стратегии, YouTube, Discord и игры из Zapret Manager и Flowseal.
  Автоподбор применяет стратегию, если она открывает больше проверяемых сайтов, чем текущая.
  Отдельные профили работают и при режиме «остальной трафик напрямую»;
  явные правила списков и устройств имеют приоритет.
- **DNS:** цепочка DoH/DNS-серверов с запасными, автоподбор DNS для обхода геоблокировок
  и перехват обычных DNS-запросов устройств.

Настройки LuCI применяются сразу.

## Ограничения и устройство

Доменные списки зависят от DNS роутера: dnsmasq добавляет адреса в наборы nftables
(`inet stella`), которые направляют трафик в xray через TPROXY, в nfqws или напрямую.
Перехват DNS охватывает TCP/UDP-порт 53. Частный DNS Android, DoH/DoT приложений и
заранее известные IP могут обходить доменные списки.

В прозрачном VPN VLESS Vision использует `xtls-rprx-vision-udp443` для QUIC.
Специальные профили Zapret идут перед основной стратегией; для прямого маршрута
используется отдельная очередь без основной стратегии.

## Разработка

| Путь | Назначение |
|---|---|
| `root/usr/share/ucode/stella/` | Разбор данных, генерация конфигов и каталог Zapret |
| `root/usr/bin/stella` | CLI, обновления и автоподбор |
| `root/usr/share/rpcd/ucode/stella.uc` | API ubus для LuCI |
| `htdocs/luci-static/resources/view/stella/` | Интерфейс LuCI |
| `tests/` | Модульные и интеграционные тесты |

Нужны ucode ревизии `85922056` с zlib и xray из пакета `xray-core` OpenWrt 25.12, как в CI.

```sh
UCODE=/путь/к/ucode tests/run.sh  # модульные тесты и rpcd
UCODE=/путь/к/ucode tests/cli.sh  # сквозной сценарий CLI
scripts/check_web.sh              # синтаксис LuCI
```
