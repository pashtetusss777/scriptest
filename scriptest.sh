#!/usr/bin/env bash
# ============================================================================
#  scriptest — мульти-тест VPS / VDS / Dedicated серверов
#
#  Запуск:
#    bash <(curl -sL https://raw.githubusercontent.com/pashtetusss777/scriptest/main/scriptest.sh)
#
#  Лицензия: MIT
# ============================================================================
set -u
VERSION="0.1.9"

# ----------------------------------------------------------------------------
# Внешний вид
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_OK=''; C_ERR=''; C_INFO=''
fi

info()  { printf '%s\n' "${C_BOLD}[scriptest]${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_BOLD}[scriptest]${C_RESET} ${C_OK}OK${C_RESET} $*"; }
err()   { printf '%s\n' "${C_BOLD}[scriptest]${C_RESET} ${C_ERR}ERROR${C_RESET} $*" >&2; }
warn()  { printf '%s\n' "${C_BOLD}[scriptest]${C_RESET} ${C_INFO}WARN${C_RESET} $*"; }
die()   { err "$*"; exit 1; }
clear_screen() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then printf '\033[2J\033[H'; fi
}

# ----------------------------------------------------------------------------
# Настройки по умолчанию (меняются флагами)
# ----------------------------------------------------------------------------
THEME="dark"           # dark | light
MAKE_PNG=1
MAKE_ZIP=1
ASK_BBR=0
ONLY=""                # список id через запятую
SKIP=""                # список id через запятую
OUT=""                 # рабочая папка (задаётся позже)
OUT_CREATED=0
FREEZE_BIN=""
FREEZE_DIR=""
declare -a REPORT_LOGS=() REPORT_IMAGES=()

# ----------------------------------------------------------------------------
# Тесты: id|name — description|timeout
# ----------------------------------------------------------------------------
TESTS=(
  "sysbench|sysbench — тест процессора|180"
  "ipcheck|IP Check Place — блокировки IP зарубежными сервисами|240"
  "ipregion|IP Region — регион по IP|120"
  "dpi|CensorCheck — блок по DPI (серверы РФ)|360"
  "insta|Instagram — проверка аудио|300"
  "speed-ru|bench.gig.ovh — скорость к РФ-провайдерам|1500"
  "speed-world|bench.sh — скорость к зарубежным провайдерам|1500"
  "yabs|YABS — диск, сеть iperf3, GeekBench|1800"
)

# test_field <id> title|tmo — достать поле теста из TESTS
test_field() {
  local t rest
  for t in "${TESTS[@]}"; do
    [ "${t%%|*}" = "$1" ] || continue
    rest="${t#*|}"
    case "$2" in
      title) printf '%s' "${rest%%|*}" ;;
      tmo)   printf '%s' "${rest#*|}" ;;
    esac
    return 0
  done
  return 1
}

# ----------------------------------------------------------------------------
# Флаги
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
scriptest v$VERSION — мульти-тест VPS / VDS / Dedicated

Использование:
  scriptest.sh [опции]

Опции:
  -a, --all              запустить все тесты (в терминале спросит про BBR)
  -o, --only <ids>       только выбранные тесты (через запятую), например: --only sysbench,yabs
  -s, --skip <ids>       пропустить указанные тесты
  -l, --list             показать список тестов и выйти
  -t, --theme <name>     тема скриншотов: dark (по умолчанию) | light
      --no-png           не генерировать скриншоты
      --no-zip           не собирать zip-архив
      --workdir <dir>    рабочая папка для результатов
  -h, --help             эта справка
  -v, --version          версия
EOF
}

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--all)     ONLY="__all__"; shift ;;
      -o|--only)    ONLY="$2"; shift 2 ;;
      -s|--skip)    SKIP="$2"; shift 2 ;;
      -l|--list)    list_tests; exit 0 ;;
      -t|--theme)   THEME="$2"; shift 2 ;;
      --no-png)     MAKE_PNG=0; shift ;;
      --no-zip)     MAKE_ZIP=0; shift ;;
      --workdir)    OUT="$2"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      -v|--version) echo "scriptest v$VERSION"; exit 0 ;;
      --banner)     print_banner; exit 0 ;;
      *)            err "Неизвестный флаг: $1"; usage; exit 1 ;;
    esac
  done
}

list_tests() {
  local i=1
  printf '%s\n' "Доступные тесты:"
  for t in "${TESTS[@]}"; do
    IFS='|' read -r id title tmo <<< "$t"
    printf '  %2d) %s\n' "$i" "$title"
    i=$((i+1))
  done
}

# ----------------------------------------------------------------------------
# Права / окружение
# ----------------------------------------------------------------------------
SUDO=""
setup_privileges() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    warn "Запущено не от root, и sudo не найден. Часть тестов может не работать (YABS требует root)."
  fi
}

enable_bbr() {
  local available
  if ! available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"; then
    warn "Не удалось проверить поддержку BBR."
    return 1
  fi
  if [[ " $available " != *" bbr "* ]] && ! $SUDO modprobe tcp_bbr; then
    warn "BBR недоступен в этом ядре или нет прав загрузить модуль."
    return 1
  fi
  if ! $SUDO sysctl -w net.ipv4.tcp_congestion_control=bbr; then
    warn "Не удалось включить BBR. Алгоритм не изменён."
    return 1
  fi
  ok "BBR включён до перезагрузки."
}

disable_ipv6() {
  local peer address previous
  IFS=' ' read -r peer _ address _ <<< "${SSH_CONNECTION:-}"
  if [[ "$peer" == *:* || "$address" == *:* ]]; then
    warn "Нельзя отключить IPv6 из обнаруженной IPv6 SSH-сессии."
    return 1
  fi
  warn "Отключение IPv6 может оборвать соединения. Продолжай только при доступе по IPv4 или через консоль."
  confirm "Отключить IPv6 до перезагрузки?" || return 1
  if ! previous="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" ||
     ! $SUDO sysctl -w net.ipv6.conf.default.disable_ipv6=1; then
    warn "Не удалось отключить IPv6."
    return 1
  fi
  if ! $SUDO sysctl -w net.ipv6.conf.all.disable_ipv6=1; then
    $SUDO sysctl -w "net.ipv6.conf.default.disable_ipv6=$previous" ||
      warn "Не удалось вернуть настройку IPv6 по умолчанию."
    warn "Не удалось отключить IPv6 на текущих интерфейсах."
    return 1
  fi
  ok "IPv6 отключён до перезагрузки."
}

# ----------------------------------------------------------------------------
# Пакеты
# ----------------------------------------------------------------------------
detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
  elif command -v zypper >/dev/null 2>&1; then PKG="zypper"
  elif command -v apk >/dev/null 2>&1; then PKG="apk"
  else PKG=""
  fi
}

install_deps() {
  local need=() p
  command -v curl >/dev/null 2>&1 || need+=("curl")
  command -v wget >/dev/null 2>&1 || need+=("wget")
  command -v zip  >/dev/null 2>&1 || need+=("zip")
  command -v timeout >/dev/null 2>&1 || need+=("coreutils")

  [ ${#need[@]} -eq 0 ] || info "Устанавливаю зависимости: ${need[*]}"
  case "$PKG" in
    apt)
      $SUDO apt-get update -y >/dev/null 2>&1
      $SUDO apt-get install -y curl wget zip sysbench ca-certificates jq bc netcat-openbsd dnsutils iproute2 >/dev/null 2>&1
      ;;
    dnf)
      $SUDO dnf install -y epel-release >/dev/null 2>&1 || true
      $SUDO dnf install -y curl wget zip sysbench jq bc nmap-ncat bind-utils iproute >/dev/null 2>&1
      ;;
    yum)
      $SUDO yum install -y epel-release >/dev/null 2>&1 || true
      $SUDO yum install -y curl wget zip sysbench jq bc nmap-ncat bind-utils iproute >/dev/null 2>&1
      ;;
    pacman)
      # sysbench в Arch только в AUR — ставим базу, sysbench пропустим
      $SUDO pacman -Sy --noconfirm --needed curl wget zip jq bc gnu-netcat bind iproute2 >/dev/null 2>&1
      ;;
    zypper)
      $SUDO zypper --non-interactive install curl wget zip sysbench jq bc netcat-openbsd bind-utils iproute2 >/dev/null 2>&1
      ;;
    apk)
      $SUDO apk add curl wget zip sysbench jq bc netcat-openbsd bind-tools iproute2 >/dev/null 2>&1
      ;;
    "")
      warn "Пакетный менеджер не определён — зависимости не устанавливаю."
      ;;
  esac

  # Sysbench: если не поставился пакетом — предупреждаем (Arch/AUR-случай)
  if ! command -v sysbench >/dev/null 2>&1; then
    warn "sysbench не найден — тест CPU будет пропущен."
  fi
}

# ----------------------------------------------------------------------------
# freeze: скачивание бинарника
# ----------------------------------------------------------------------------
ensure_freeze() {
  [ "$MAKE_PNG" -eq 1 ] || return 0
  if command -v freeze >/dev/null 2>&1; then
    FREEZE_BIN="$(command -v freeze)"
  else
    local os arch url api bin_dir
    os="$(uname -s)"; arch="$(uname -m)"
    case "$os" in
      Linux)  os="Linux" ;;
      Darwin) os="Darwin" ;;
      *) warn "freeze не поддерживает $os — PNG не будут сгенерированы."; MAKE_PNG=0; return 0 ;;
    esac
    case "$arch" in
      x86_64)          arch="x86_64" ;;
      aarch64|arm64)   arch="arm64" ;;
      armv7*|armv8*)   arch="arm" ;;
      *) warn "freeze недоступен для $arch — PNG не будут сгенерированы."; MAKE_PNG=0; return 0 ;;
    esac

    info "Скачиваю freeze ($os/$arch)..."
    api="$(curl -fsSL --max-time 20 https://api.github.com/repos/charmbracelet/freeze/releases/latest)" || api=""
    url="$(printf '%s' "$api" |
      grep -oE "https://github\\.com/charmbracelet/freeze/releases/download/[^\"/]+/freeze_[0-9.]+_${os}_${arch}\\.tar\\.gz\"" |
      head -n1)"
    url="${url%\"}"
    if [ -z "$url" ]; then
      warn "Не удалось получить ссылку на freeze — PNG не будут сгенерированы."
      MAKE_PNG=0; return 0
    fi
    FREEZE_DIR="$(mktemp -d)" || { warn "Нет временной папки для freeze."; MAKE_PNG=0; return 0; }
    bin_dir="${url##*/}"
    bin_dir="${bin_dir%.tar.gz}"
    curl -fsSL --max-time 120 "$url" -o "$FREEZE_DIR/freeze.tar.gz" ||
      { warn "Ошибка скачивания freeze."; MAKE_PNG=0; return 0; }
    tar -xzf "$FREEZE_DIR/freeze.tar.gz" -C "$FREEZE_DIR" "$bin_dir/freeze" ||
      { warn "Ошибка распаковки freeze."; MAKE_PNG=0; return 0; }
    FREEZE_BIN="$FREEZE_DIR/$bin_dir/freeze"
  fi
  if ! "$FREEZE_BIN" --version >/dev/null; then
    warn "freeze не запускается на этой системе — скриншоты не будут сгенерированы."
    MAKE_PNG=0; return 0
  fi
  ok "freeze: $FREEZE_BIN"
}

# ----------------------------------------------------------------------------
# Результаты: папка, метаданные
# ----------------------------------------------------------------------------
SYSINFO_FILE=""

os_name() {
  local name
  name="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
  if [ -n "$name" ]; then printf '%s\n' "$name"; else uname -s; fi
}

setup_workdir() {
  if [ -z "$OUT" ]; then
    OUT="$(mktemp -d "$PWD/scriptest-$(date +%Y%m%d-%H%M%S)-XXXXXX")" ||
      die "Не удалось создать папку отчёта."
    OUT_CREATED=1
  else
    mkdir -p -- "$OUT" || die "Не удалось создать папку: $OUT"
    OUT="$(cd -- "$OUT" && pwd -P)" || die "Не удалось открыть папку отчёта."
    (shopt -s dotglob nullglob; files=("$OUT"/*); ((${#files[@]} == 0))) ||
      die "Укажи пустую папку для отчёта: $OUT"
  fi
  info "Результаты: $OUT"

  # sysinfo.txt — шапка для summary и скриншотов
  SYSINFO_FILE="$OUT/sysinfo.txt"
  REPORT_LOGS=(sysinfo.txt)
  local os_pretty cpu_model cores ram_gb disk ip virt kernel
  os_pretty="$(os_name)"
  cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || true)"
  [ -n "$cpu_model" ] || cpu_model="$(uname -m)"
  cores="$(nproc 2>/dev/null || echo '?')"
  if command -v free >/dev/null 2>&1; then
    ram_gb="$(( $(free -b | awk '/Mem:/{print $2}') / 1024 / 1024 / 1024 ))"
  else
    ram_gb="?"
  fi
  disk="$(df -h / 2>/dev/null | awk 'NR==2{print $2}')"
  ip="$(curl -4 -fs --max-time 10 https://ifconfig.me 2>/dev/null || curl -4 -fs --max-time 10 https://api.ipify.org 2>/dev/null || echo 'unknown')"
  kernel="$(uname -r)"
  virt="$(systemd-detect-virt 2>/dev/null || echo '?')"

  {
    echo "scriptest v$VERSION"
    echo "Hostname : $(hostname 2>/dev/null || echo '?')"
    echo "IP       : $ip"
    echo "OS       : $os_pretty"
    echo "Kernel   : $kernel"
    echo "Virt     : $virt"
    echo "CPU      : $cpu_model ($cores vCPU)"
    echo "RAM      : ${ram_gb} GB"
    echo "Disk /   : $disk"
    echo "TCP CC   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    echo "Date     : $(date -u '+%Y-%m-%d %H:%M UTC')"
  } > "$SYSINFO_FILE" || die "Не удалось записать $SYSINFO_FILE"

  cat "$SYSINFO_FILE"
}

# ----------------------------------------------------------------------------
# Запуск тестов
# ----------------------------------------------------------------------------
declare -a RESULTS=()
TESTS_ELAPSED=0

ANSI_STRIP_SED='s/\x1B\[[0-?]*[ -/]*[@-~]//g; s/\x1B\][^\x07\x1B]*(\x07|\x1B\\)//g; s/\x1B[>=]//g; s/\r$//'

format_duration() {
  local seconds="$1"
  printf '%02d:%02d:%02d' "$((seconds / 3600))" "$((seconds / 60 % 60))" "$((seconds % 60))"
}

# run_test <id> <title> <timeout> <command>
run_test() {
  local id="$1" title="$2" tmo="$3" cmd="$4"
  local log="$OUT/$id.txt" start duration status size rc
  local -a codes

  {
    echo "================================================================"
    echo "  $title"
    echo "================================================================"
    cat "$SYSINFO_FILE"
    echo "================================================================"
  } > "$log" || die "Не удалось записать $log"
  size="$(wc -c < "$log")"

  info ">> $title (лимит $(format_duration "$tmo"))"
  start=$SECONDS
  # Каждый тест пишет временные файлы в отдельный каталог, а не в папку пользователя.
  (
    work="$(mktemp -d "$OUT/.bench-$id-XXXXXX")" || exit 125
    trap 'rm -rf -- "$work"' EXIT
    cd -- "$work" || exit 125
    timeout -k 15 "$tmo" bash -o pipefail -c "$cmd"
  ) 2>&1 </dev/null | sed -u -E "$ANSI_STRIP_SED" | tee -a "$log"
  codes=("${PIPESTATUS[@]}")
  duration="$(format_duration "$((SECONDS - start))")"
  rc="${codes[0]}"
  ((codes[1] == 0 && codes[2] == 0)) || die "Не удалось сохранить вывод в $log"

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    status="TIMEOUT"
    warn "Тест '$id' прерван по таймауту ($duration)."
  elif [ "$rc" -ne 0 ]; then
    status="FAILED"
    warn "Тест '$id' завершился с ошибкой (код $rc, $duration)."
  elif [ "$(wc -c < "$log")" -eq "$size" ]; then
    status="FAILED"
    warn "Тест '$id' не выдал результатов ($duration)."
  else
    status="OK"
    ok "Тест '$id' завершён ($duration)."
  fi
  printf '\n[scriptest] %s · %s · exit %s\n' "$status" "$duration" "$rc" >> "$log" ||
    die "Не удалось дописать $log"
  [[ " ${REPORT_LOGS[*]} " == *" $id.txt "* ]] || REPORT_LOGS+=("$id.txt")
  RESULTS+=("$id|$status|$duration")
}

# run_speed <id> <title> <timeout> <primary_cmd> <fallback_cmd>
run_speed() {
  local id="$1" title="$2" tmo="$3" primary="$4" fallback="$5"
  run_test "$id" "$title" "$tmo" "$primary"

  if [[ "${RESULTS[-1]}" != "$id|OK|"* ]]; then
    warn "Первичный скрипт для '$id' не дал результата — пробую фоллбек."
    run_test "$id-fallback" "Резервный тест — ${title#* — }" "$tmo" "$fallback"
  fi
}

run_sysbench() {
  if ! command -v sysbench >/dev/null 2>&1; then
    info ">> Sysbench пропущен (не установлен)."
    RESULTS+=("sysbench|SKIPPED|—")
    return
  fi
  run_test "sysbench" "$(test_field sysbench title)" "$(test_field sysbench tmo)" "sysbench cpu run --threads=1"
}

run_yabs() {
  local cmd="curl -sL yabs.sh | bash -s -- -4"
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    cmd="curl -sL yabs.sh | $SUDO bash -s -- -4"
  fi
  run_test "yabs" "$(test_field yabs title)" "$(test_field yabs tmo)" "$cmd"
}

run_test_by_id() {
  local id="$1" title tmo
  title="$(test_field "$id" title)"
  tmo="$(test_field "$id" tmo)"
  case "$id" in
    ipcheck)     run_test "$id" "$title" "$tmo" "bash <(curl -Ls IP.Check.Place) -l en" ;;
    ipregion)    run_test "$id" "$title" "$tmo" "bash <(wget -qO - https://github.com/vernette/ipregion/raw/master/ipregion.sh)" ;;
    dpi)         run_test "$id" "$title" "$tmo" "bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi" ;;
    insta)       run_test "$id" "$title" "$tmo" "bash <(curl -L -s https://bench.openode.xyz/checker_inst.sh)" ;;
    speed-ru)    run_speed "$id" "$title" "$tmo" "wget -qO- bench.gig.ovh | bash" "wget -qO- bench.tlab.pw | bash" ;;
    speed-world) run_speed "$id" "$title" "$tmo" "wget -qO- bench.sh | bash" "wget -qO- speed.tlab.pw | bash" ;;
    yabs)        run_yabs ;;
    sysbench)    run_sysbench ;;
    *) warn "Неизвестный тест: $id" ;;
  esac
}

select_tests() {
  # Возвращает список id тестов (учитывая --only / --skip / меню)
  local -a ids=()
  local t id
  for t in "${TESTS[@]}"; do
    ids+=("${t%%|*}")
  done

  if [ -n "$ONLY" ] && [ "$ONLY" != "__all__" ]; then
    IFS=',' read -r -a ids <<< "$ONLY"
  fi

  local -a result=()
  for id in "${ids[@]}"; do
    if [ -n "$SKIP" ] && [[ ",$SKIP," == *",$id,"* ]]; then continue; fi
    result+=("$id")
  done
  SELECTED=("${result[@]}")
}

# ----------------------------------------------------------------------------
# Скриншоты
# ----------------------------------------------------------------------------
render_image() {
  local input="$1" output="$2"
  shift 2
  timeout -k 5 60 "$FREEZE_BIN" - --output "$output" --language text --wrap 120 "$@" < "$input"
}

render_pngs() {
  [ "$MAKE_PNG" -eq 1 ] || return 0
  [ -n "$FREEZE_BIN" ] && [ -x "$FREEZE_BIN" ] || { warn "freeze недоступен — пропускаю PNG."; return 0; }

  info "Генерирую PNG-скриншоты..."
  local name f image message
  local -a style=(--config full)
  if [ "$THEME" = light ]; then
    style=(--config base --theme monokailight --border.color '#d4d4d4' --border.width 1
      --border.radius 8 --font.size 14 --padding 20,28)
  fi
  for name in "${REPORT_LOGS[@]}"; do
    f="$OUT/$name"
    [ -s "$f" ] || continue
    image="${f%.txt}.png"
    if ! message="$(render_image "$f" "$image" "${style[@]}" 2>&1)" || [ ! -s "$image" ]; then
      rm -f -- "$image"
      warn "PNG для ${f##*/} не создан${message:+: ${message%%$'\n'*}}. Пробую SVG."
      image="${f%.txt}.svg"
      if ! message="$(render_image "$f" "$image" "${style[@]}" 2>&1)" || [ ! -s "$image" ]; then
        rm -f -- "$image"
        warn "SVG тоже не создан${message:+: ${message%%$'\n'*}}."
        continue
      fi
    fi
    ok "Скриншот: ${image##*/}"
    REPORT_IMAGES+=("${image##*/}")
  done
  info "Скриншотов создано: ${#REPORT_IMAGES[@]}"
}

# ----------------------------------------------------------------------------
# Отчёт и ZIP
# ----------------------------------------------------------------------------
make_summary() {
  local md="$OUT/summary.md"
  {
    echo "# scriptest — отчёт"
    echo
    echo '```'
    cat "$SYSINFO_FILE"
    echo '```'
    echo
    echo "## Тесты (общее время: $(format_duration "$TESTS_ELAPSED"))"
    echo
    echo "| Тест | Статус | Время |"
    echo "|------|--------|-------|"
    local r id status duration
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r id status duration <<< "$r"
      printf '| %s | %s | %s |\n' "$id" "$status" "$duration"
    done
    echo
    echo "## Файлы"
    echo
    local f
    for f in "${REPORT_LOGS[@]}" "${REPORT_IMAGES[@]}"; do
      printf -- '- `%s`\n' "$f"
    done
  } > "$md" || die "Не удалось создать $md"
  ok "Summary: $md"
}

make_zip() {
  [ "$MAKE_ZIP" -eq 1 ] || return 0
  command -v zip >/dev/null 2>&1 || { warn "zip не найден — архив не собран (файлы лежат в $OUT)."; return 0; }
  local archive="$OUT.zip"
  local -a files=(summary.md "${REPORT_LOGS[@]}" "${REPORT_IMAGES[@]}")
  if [ -e "$archive" ] || [ -L "$archive" ]; then
    warn "Архив уже существует: $archive. Не перезаписываю."
    return 0
  fi
  ( cd -- "$OUT" && zip -q "$archive" "${files[@]}" ) ||
    { warn "Ошибка сборки архива. Отчёт остался в $OUT."; return 0; }
  ok "Архив: $archive"
  info "Скачай с компьютера (замени SERVER на адрес, по которому подключаешься по SSH):"
  printf '  scp %q .\n' "$(id -un)@SERVER:$archive"
}

print_results() {
  info "Итоги:"
  local r id st duration
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r id st duration <<< "$r"
    case "$st" in
      OK)      ok   "  $id · $st · $duration" ;;
      SKIPPED) warn "  $id · $st" ;;
      *)       warn "  $id · $st · $duration" ;;
    esac
  done
  info "Общее время тестов: $(format_duration "$TESTS_ELAPSED")"
}

# ----------------------------------------------------------------------------
# Баннер / меню
# ----------------------------------------------------------------------------
print_banner() {
  local ver="v$VERSION"
  local host ip os
  host="$(hostname 2>/dev/null || echo '?')"
  IFS=' ' read -r _ _ ip _ <<< "${SSH_CONNECTION:-}"
  os="$(os_name)"
  cat <<'BANNER'

  █████  █████  ████   ███  ████   █████  █████  █████  █████
  █      █      █   █   █   █   █    █    █      █        █
  █████  █      ████    █   ████     █    ████   █████    █
      █  █      █  █    █   █        █    █          █    █
  █████  █████  █   █  ███  █        █    █████  █████    █

BANNER
  printf '  %bscriptest %s%b %b· мульти-тест сервера%b\n' \
    "${C_BOLD}" "$ver" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  printf '  %bHost:%b %s %b· IP:%b %s %b· %s%b\n' \
    "${C_BOLD}" "${C_RESET}" "${host}" "${C_DIM}" "${C_RESET}" "${ip:-?}" "${C_DIM}" "${os}" "${C_RESET}"
  printf '  %b─────────────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"
}

confirm() {
  local answer
  printf '%s [y/N]: ' "$1"
  read -r answer || return 1
  case "$answer" in y|Y|yes|Yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

offer_bbr() {
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
    info "BBR уже включён."
  elif confirm "Включить BBR перед прогоном (до перезагрузки)?"; then
    enable_bbr || warn "Продолжаю тесты без изменения алгоритма TCP."
  fi
}

utilities_menu() {
  local choice cc ipv6
  while true; do
    clear_screen
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '?')"
    ipv6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf '?')"
    case "$ipv6" in 0) ipv6="включён" ;; 1) ipv6="отключён" ;; esac
    printf '\n  %bУтилиты%b · изменения до перезагрузки\n\n' "$C_BOLD" "$C_RESET"
    printf '  1) Включить BBR (текущий алгоритм TCP: %s)\n' "$cc"
    printf '  2) Отключить IPv6 (сейчас: %s)\n' "$ipv6"
    printf '  0) Назад\n\n  ▸ Выбор: '
    read -r choice || return
    case "$choice" in
      1) if confirm "Включить BBR?"; then enable_bbr; fi ;;
      2) disable_ipv6 ;;
      0|q|Q) return ;;
      *) continue ;;
    esac
    printf '\n  Enter — продолжить: '
    read -r _ || return
  done
}

menu() {
  while true; do
    clear_screen
    print_banner
    echo
    printf '  %bДоступные тесты%b\n' "${C_BOLD}" "${C_RESET}"
    echo
    local i=1 t id title tmo mins name desc
    for t in "${TESTS[@]}"; do
      IFS='|' read -r id title tmo <<< "$t"
      mins=$(( (tmo + 59) / 60 ))
      name="${title%% — *}"
      desc="${title#* — }"
      printf '  %b%2d)%b %s %b— %s · лимит %d мин%b\n' \
        "${C_OK}${C_BOLD}" "$i" "${C_RESET}" "${name}" \
        "${C_DIM}" "${desc}" "$mins" "${C_RESET}"
      i=$((i+1))
    done
    echo
    printf '  %b a)%b %sЗапустить ВСЕ тесты%s\n' \
      "${C_OK}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
    printf '  %b u)%b Утилиты (BBR, IPv6)\n' "${C_BOLD}" "${C_RESET}"
    printf '  %b q)%b Выход\n' "${C_BOLD}" "${C_RESET}"
    echo
    printf '  %b─────────────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"
    printf '  %b▸%b Номера через запятую · a — все · u — утилиты · q — выход: ' "${C_INFO}" "${C_RESET}"
    local choice
    read -r choice || return 1
    case "$choice" in
      q|Q) clear_screen; info "Выход."; exit 0 ;;
      u|U) utilities_menu ;;
      a|A)
        if confirm_all; then
          select_tests
          ASK_BBR=1
          return
        fi
        ;;
      '')
        ;;
      *)
        # Преобразуем номера в id
        local -a picked=()
        local IFS=',' item n bad=0
        read -r -a picked <<< "$choice"
        local -a mapped=()
        for item in "${picked[@]}"; do
          n="$(echo "$item" | tr -d ' ')"
          if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#TESTS[@]} ]; then
            mapped+=("${TESTS[$((n-1))]%%|*}")
          else
            warn "Некорректный номер: $item"; bad=1
          fi
        done
        [ $bad -eq 0 ] && [ ${#mapped[@]} -gt 0 ] && { SELECTED=("${mapped[@]}"); return; }
        ;;
    esac
  done
}

confirm_all() {
  printf '%s\n' "${C_INFO}${C_DIM}Сетевые тесты расходуют трафик. Лимиты указаны на одну попытку; резервные тесты запускаются отдельно.${C_RESET}"
  confirm "Запустить все тесты?"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
  parse_flags "$@"
  case "$THEME" in light|dark) ;; *) die "Тема должна быть light или dark." ;; esac

  clear_screen
  info "scriptest v$VERSION"
  # apt/dnf не должны задавать вопросов из дочерних скриптов
  export DEBIAN_FRONTEND=noninteractive
  setup_privileges

  if [ -n "$ONLY" ]; then
    select_tests
    if [ "$ONLY" = "__all__" ] && [ -t 0 ]; then ASK_BBR=1; fi
  else
    SELECTED=()
    menu || die "Нет ввода. Укажи --all или --only <id>."
  fi

  [ ${#SELECTED[@]} -gt 0 ] || die "Не выбран ни один тест."
  if (( ASK_BBR )); then offer_bbr; fi
  detect_pkg
  install_deps
  umask 077
  setup_workdir

  info "Тестов к запуску: ${#SELECTED[@]} (${SELECTED[*]})"
  local id start=$SECONDS
  for id in "${SELECTED[@]}"; do
    run_test_by_id "$id"
  done
  TESTS_ELAPSED=$((SECONDS - start))

  print_results
  trap '[ -z "$FREEZE_DIR" ] || rm -rf -- "$FREEZE_DIR"' EXIT
  ensure_freeze
  render_pngs
  make_summary
  make_zip
  info "Готово. Архив и файлы отчёта: $(dirname "$OUT")"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
