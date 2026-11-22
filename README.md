# scriptest

Мульти-тест VPS / VDS / Dedicated серверов с красивыми скриншотами — удобно для постов в Telegram-чатах про хостинги.

Один скрипт, без установки: качается и запускается одной командой прямо на сервере.

## Запуск

```bash
bash <(curl -sL https://raw.githubusercontent.com/pashtetusss777/scriptest/main/scriptest.sh)
```

или так:

```bash
curl -sL https://raw.githubusercontent.com/pashtetusss777/scriptest/main/scriptest.sh -o scriptest.sh
bash scriptest.sh
```

## Что делает

Открывает меню, где можно выбрать отдельный тест или запустить всё сразу. После выполнения тестов:

- генерирует **PNG-скриншоты** каждого теста в монохромной теме «инь-ян» (белый фон) через [freeze](https://github.com/charmbracelet/freeze),
- складывает **текстовые логи**,
- собирает **summary.md** (характеристики сервера + статус тестов),
- пакует всё в **один zip** — скачай через `scp` и выкладывай.

## Тесты

| # | Тест | Что проверяет |
|---|------|---------------|
| 1 | sysbench | Процессор (`sysbench cpu run --threads=1`) — чтобы понять % выделенного CPU |
| 2 | ipcheck | Блокировки IP зарубежными сервисами ([IP.Check.Place](https://ip.check.place)) |
| 3 | ipregion | Какой регион видят сайты по IP |
| 4 | dpi | Блокировка по DPI (для российских серверов) |
| 5 | insta | Блокировка аудио в Instagram |
| 6 | speed-ru | Скорость к российским провайдерам (bench.gig.ovh → bench.tlab.pw) |
| 7 | speed-world | Скорость к зарубежным провайдерам (bench.sh → speed.tlab.pw) |
| 8 | yabs | Диск, сеть iperf3, GeekBench ([YABS](https://yabs.sh)) |

## Поддерживаемые ОС

Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, Fedora, RHEL, Arch, openSUSE, Alpine (x86_64 и arm64).

Скрипт сам определяет дистрибутив, ставит недостающие зависимости (`curl`, `wget`, `zip`, `sysbench`) и скачивает бинарник `freeze`.

## Флаги

```bash
-a, --all              запустить все тесты без меню
-o, --only <ids>       только выбранные тесты: --only sysbench,yabs
-s, --skip <ids>       пропустить тесты: --skip yabs,speed-world
-l, --list             список тестов
-t, --theme <name>     тема скриншотов: light (инь-ян) | dark
    --no-png           без PNG-скриншотов
    --no-zip           без zip-архива
    --workdir <dir>    рабочая папка
-h, --help             справка
```

Пример: быстрый тест CPU и IP-блокировок без YABS:

```bash
bash scriptest.sh -o sysbench,ipcheck,ipregion
```

## Как забрать результаты

После завершения тестов скрипт покажет путь к архиву. Скачивание на локальную машину:

```bash
scp user@server_ip:/путь/к/scriptest-*.zip .
```

## Лицензия

MIT
