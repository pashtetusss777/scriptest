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
VERSION="0.3.14"

# ----------------------------------------------------------------------------
# Внешний вид
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_WHITE=$'\033[97m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_OK=''; C_ERR=''; C_INFO=''; C_WHITE=''
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
# Анимация: тесты пишут в лог, поэтому в терминале держим живую строку
# ----------------------------------------------------------------------------
SPINNER_PID=""

spinner_stop() {
  if [ -n "${SPINNER_PID}" ]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    SPINNER_PID=""
    if [ -t 1 ]; then printf '\r\033[2K'; fi
  fi
  return 0
}

# spinner_start <подпись>
spinner_start() {
  local label="$1" frames n cols
  [ -t 1 ] || return 0
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" ;;
    *)                             frames="|/-\\" ;;
  esac
  n=${#frames}
  cols="${COLUMNS:-}"
  [ -n "$cols" ] || cols="$(tput cols 2>/dev/null || printf 80)"
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  # Оставляем место под спиннер, таймер и «тест выполняется…», чтобы строка
  # не переносилась: иначе \r не сотрёт её хвост.
  if [ "$cols" -gt 40 ]; then label="${label:0:$((cols - 34))}"; fi
  (
    trap 'exit 0' INT TERM
    local i=0 start=$SECONDS elapsed dots
    while :; do
      elapsed=$((SECONDS - start))
      case $((i % 4)) in
        0) dots="   " ;; 1) dots=".  " ;; 2) dots=".. " ;; 3) dots="..." ;;
      esac
      printf '\r\033[2K  %b%s%b %b%s%b  %b%02d:%02d%b  %bтест выполняется%s%b' \
        "${C_WHITE}${C_BOLD}" "${frames:i%n:1}" "${C_RESET}" \
        "${C_BOLD}" "$label" "${C_RESET}" \
        "${C_DIM}" "$((elapsed / 60))" "$((elapsed % 60))" "${C_RESET}" \
        "${C_DIM}" "$dots" "${C_RESET}"
      i=$((i + 1))
      sleep 0.15
    done
  ) &
  SPINNER_PID=$!
}

# ----------------------------------------------------------------------------
# Настройки по умолчанию (меняются флагами)
# ----------------------------------------------------------------------------
THEME="dark"           # dark | light
MAKE_PNG=1
MAKE_ZIP=1
ASK_BBR=0
TEST_NO=0
TEST_TOTAL=0
ONLY=""                # список id через запятую
SKIP=""                # список id через запятую
OUT=""                 # рабочая папка (задаётся позже)
OUT_CREATED=0
MONO_FONT=""
FREEZE_BIN=""
FREEZE_DIR=""
declare -a REPORT_LOGS=() REPORT_IMAGES=()

# ----------------------------------------------------------------------------
# Тесты: id|name — description|timeout
# ----------------------------------------------------------------------------
TESTS=(
  "sysbench|sysbench — тест процессора|180"
  "ipcheck|IP Check Place — блокировки IP зарубежными сервисами|360"
  "ipregion|IP Region — регион по IP|120"
  "dpi|CensorCheck — блок по DPI (серверы РФ)|360"
  "insta|Instagram — проверка аудио|300"
  "speed-ru|bench.tlab.pw — скорость к РФ-провайдерам|1500"
  "speed-world|bench.sh — скорость к зарубежным провайдерам|1500"
  "yabs|YABS — диск, сеть iperf3, GeekBench|1800"
  "geocheck|GeoCheck — геолокация IP (только по выбору)|300"
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
  # Для флагов с аргументом: без значения при set -u падает "$2": unbound variable.
  need_arg() {
    [ $# -ge 2 ] || { err "Для $1 нужен аргумент."; usage; exit 1; }
  }
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--all)     ONLY="__all__"; shift ;;
      -o|--only)    need_arg "$@"; ONLY="$2"; shift 2 ;;
      -s|--skip)    need_arg "$@"; SKIP="$2"; shift 2 ;;
      -l|--list)    list_tests; exit 0 ;;
      -t|--theme)   need_arg "$@"; THEME="$2"; shift 2 ;;
      --no-png)     MAKE_PNG=0; shift ;;
      --no-zip)     MAKE_ZIP=0; shift ;;
      --workdir)    need_arg "$@"; OUT="$2"; shift 2 ;;
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

# sysctl часто лежит в /usr/sbin, которого нет в PATH обычного пользователя,
# а в минимальных образах его может не быть вовсе. Читаем /proc напрямую,
# пишем через sysctl, а если его нет — тоже через /proc.
sysctl_read() {
  cat "/proc/sys/${1//./\/}" 2>/dev/null
}

sysctl_write() {
  local key="${1%%=*}" value="${1#*=}"
  if command -v sysctl >/dev/null 2>&1; then
    $SUDO sysctl -w "$1" >/dev/null 2>&1 && return 0
  fi
  printf '%s\n' "$value" | $SUDO tee "/proc/sys/${key//./\/}" >/dev/null 2>&1
}

modprobe_load() {
  local m
  if command -v modprobe >/dev/null 2>&1; then
    $SUDO modprobe "$1" >/dev/null 2>&1 && return 0
  fi
  for m in /sbin/modprobe /usr/sbin/modprobe; do
    [ -x "$m" ] && $SUDO "$m" "$1" >/dev/null 2>&1 && return 0
  done
  return 1
}

default_iface() {
  local bin=""
  if command -v ip >/dev/null 2>&1; then bin="ip"
  elif [ -x /usr/sbin/ip ]; then bin="/usr/sbin/ip"
  elif [ -x /sbin/ip ]; then bin="/sbin/ip"
  fi
  [ -n "$bin" ] || return 0
  "$bin" route show default 2>/dev/null | awk '{print $5; exit}'
}

set_qdisc() {
  local dev="$1" q="$2" bin=""
  [ -n "$dev" ] || return 0
  if command -v tc >/dev/null 2>&1; then bin="tc"
  elif [ -x /usr/sbin/tc ]; then bin="/usr/sbin/tc"
  elif [ -x /sbin/tc ]; then bin="/sbin/tc"
  fi
  [ -n "$bin" ] || return 0
  $SUDO "$bin" qdisc replace dev "$dev" root "$q" >/dev/null 2>&1 || true
}

# BBR + Cake: файл в /etc/sysctl.d применяет systemd-sysctl при каждой загрузке.
BBR_CONF="/etc/sysctl.d/99-scriptest-bbr.conf"

# Значение до включения BBR хранится в первой строке конфига комментарием.
bbr_previous() {
  local key="$1" fallback="$2" value
  value="$($SUDO sed -n "s/^# scriptest: было .*${key}=\([^ ]*\).*/\1/p" "$BBR_CONF" 2>/dev/null | head -1)"
  [ -n "$value" ] || value="$fallback"
  printf '%s\n' "$value"
}

enable_bbr() {
  local cc qdisc note avail
  if ! cc="$(sysctl_read net.ipv4.tcp_congestion_control)" || [ -z "$cc" ]; then
    warn "Не удалось прочитать текущий алгоритм TCP."
    return 1
  fi
  qdisc="$(sysctl_read net.core.default_qdisc)"
  [ -n "$qdisc" ] || qdisc="?"

  # BBR и cake обычно модули: без modprobe sysctl их не увидит.
  modprobe_load tcp_bbr || true
  modprobe_load sch_cake || true

  avail="$(sysctl_read net.ipv4.tcp_available_congestion_control)"
  if [ -n "$avail" ] && [[ " $avail " != *" bbr "* ]]; then
    warn "BBR недоступен в этом ядре — настройки не меняю."
    return 1
  fi

  # Исходные значения запоминаем один раз, чтобы повторный запуск их не затёр.
  note="$($SUDO grep -m1 '^# scriptest: было ' "$BBR_CONF" 2>/dev/null || true)"
  [ -n "$note" ] || note="# scriptest: было cc=${cc:-?} qdisc=${qdisc:-?}"

  if ! printf '%s\nnet.core.default_qdisc=cake\nnet.ipv4.tcp_congestion_control=bbr\n' "$note" |
       $SUDO tee "$BBR_CONF" >/dev/null; then
    warn "Не удалось записать $BBR_CONF."
    return 1
  fi
  sysctl_write net.core.default_qdisc=cake || true
  sysctl_write net.ipv4.tcp_congestion_control=bbr || true

  # systemd-sysctl читает /etc/sysctl.d при загрузке: включаем и перезапускаем,
  # чтобы настройка применилась сразу и пережила перезагрузку.
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable systemd-sysctl >/dev/null 2>&1 || true
    $SUDO systemctl restart systemd-sysctl >/dev/null 2>&1 || true
  elif command -v rc-update >/dev/null 2>&1; then
    $SUDO rc-update add sysctl default >/dev/null 2>&1 || true
    $SUDO rc-service sysctl restart >/dev/null 2>&1 || true
  fi

  # Cake есть не во всех ядрах — тогда честно оставляем fq_codel.
  if [ "$(sysctl_read net.core.default_qdisc)" = cake ]; then
    qdisc="cake"
  else
    qdisc="fq_codel"
    printf '%s\nnet.core.default_qdisc=%s\nnet.ipv4.tcp_congestion_control=bbr\n' "$note" "$qdisc" |
      $SUDO tee "$BBR_CONF" >/dev/null
    sysctl_write "net.core.default_qdisc=$qdisc" || true
    warn "Cake недоступен в этом ядре — оставил $qdisc."
  fi

  # default_qdisc действует на новые интерфейсы, текущий переключаем вручную.
  set_qdisc "$(default_iface)" "$qdisc"

  if [ "$(sysctl_read net.ipv4.tcp_congestion_control)" = bbr ]; then
    ok "BBR + $qdisc включены и сохранены после перезагрузки."
    return 0
  fi
  $SUDO rm -f "$BBR_CONF"
  warn "BBR не включился: проверь поддержку ядра и права. Конфиг не сохранён."
  return 1
}

disable_bbr() {
  local cc qdisc avail now_cc now_qd
  cc="$(bbr_previous cc cubic)"
  qdisc="$(bbr_previous qdisc fq_codel)"

  # Если запомненного алгоритма нет в ядре, берём первый доступный.
  avail="$(sysctl_read net.ipv4.tcp_available_congestion_control)"
  if [ -n "$avail" ] && [[ " $avail " != *" $cc "* ]]; then
    cc="${avail%% *}"
  fi

  $SUDO rm -f "$BBR_CONF"
  sysctl_write "net.ipv4.tcp_congestion_control=$cc" || true
  sysctl_write "net.core.default_qdisc=$qdisc" || true
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl restart systemd-sysctl >/dev/null 2>&1 || true
  fi

  set_qdisc "$(default_iface)" "$qdisc"

  now_cc="$(sysctl_read net.ipv4.tcp_congestion_control)"
  now_qd="$(sysctl_read net.core.default_qdisc)"
  if [ "$now_cc" = "$cc" ] && [ "$now_qd" = "$qdisc" ]; then
    ok "Вернул прежние настройки TCP: $cc / $qdisc."
    return 0
  fi
  warn "Не удалось вернуть настройки TCP (сейчас $now_cc / $now_qd)."
  return 1
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
  if ! previous="$(sysctl_read net.ipv6.conf.default.disable_ipv6)" ||
     ! sysctl_write net.ipv6.conf.default.disable_ipv6=1; then
    warn "Не удалось отключить IPv6."
    return 1
  fi
  if ! sysctl_write net.ipv6.conf.all.disable_ipv6=1; then
    sysctl_write "net.ipv6.conf.default.disable_ipv6=$previous" ||
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
  local need=()
  command -v curl >/dev/null 2>&1 || need+=("curl")
  command -v wget >/dev/null 2>&1 || need+=("wget")
  command -v zip  >/dev/null 2>&1 || need+=("zip")
  command -v timeout >/dev/null 2>&1 || need+=("coreutils")

  [ ${#need[@]} -eq 0 ] || info "Устанавливаю зависимости: ${need[*]}"
  case "$PKG" in
    apt)
      $SUDO apt-get update -y >/dev/null 2>&1
      $SUDO apt-get install -y curl wget zip unzip sysbench ca-certificates jq bc netcat-openbsd dnsutils iproute2 >/dev/null 2>&1
      ;;
    dnf)
      $SUDO dnf install -y epel-release >/dev/null 2>&1 || true
      $SUDO dnf install -y curl wget zip unzip sysbench jq bc nmap-ncat bind-utils iproute >/dev/null 2>&1
      ;;
    yum)
      $SUDO yum install -y epel-release >/dev/null 2>&1 || true
      $SUDO yum install -y curl wget zip unzip sysbench jq bc nmap-ncat bind-utils iproute >/dev/null 2>&1
      ;;
    pacman)
      # sysbench в Arch только в AUR — ставим базу, sysbench пропустим
      $SUDO pacman -Sy --noconfirm --needed curl wget zip unzip jq bc gnu-netcat bind iproute2 >/dev/null 2>&1
      ;;
    zypper)
      $SUDO zypper --non-interactive install curl wget zip unzip sysbench jq bc netcat-openbsd bind-utils iproute2 >/dev/null 2>&1
      ;;
    apk)
      $SUDO apk add curl wget zip unzip sysbench jq bc netcat-openbsd bind-tools iproute2 >/dev/null 2>&1
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
    local os arch url bin_dir
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
    url="https://github.com/charmbracelet/freeze/releases/download/v0.2.2/freeze_0.2.2_${os}_${arch}.tar.gz"
    FREEZE_DIR="$(mktemp -d)" || { warn "Нет временной папки для freeze."; MAKE_PNG=0; return 0; }
    bin_dir="${url##*/}"
    bin_dir="${bin_dir%.tar.gz}"
    local tarball sum want
    tarball="${url##*/}"
    want="$(curl -fsSL --max-time 60 "${url%$tarball}checksums.txt" 2>/dev/null |
            awk -v n="$tarball" '$NF == n {print $1}')"
    for attempt in 1 2; do
      curl -fsSL --max-time 120 "$url" -o "$FREEZE_DIR/freeze.tar.gz" ||
        { warn "Ошибка скачивания freeze."; MAKE_PNG=0; return 0; }
      # CDN иногда отдаёт битый архив: на CI он ловился как SIGSEGV в рантайме Go.
      if [ -z "$want" ]; then break; fi
      sum="$(sha256sum "$FREEZE_DIR/freeze.tar.gz" 2>/dev/null | cut -d' ' -f1)"
      [ "$sum" = "$want" ] && break
      warn "Контрольная сумма freeze не сошлась, качаю ещё раз."
      rm -f "$FREEZE_DIR/freeze.tar.gz"
    done
    if [ -n "$want" ] && [ "$sum" != "$want" ]; then
      warn "Битый freeze с CDN - PNG не будут сгенерированы."
      MAKE_PNG=0; return 0
    fi
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
# Шрифт: используем уже установленный моноширинный, без скачивания
# ----------------------------------------------------------------------------
resolve_font() {
  local f
  for f in "DejaVu Sans Mono" "Liberation Mono" "Noto Sans Mono" "Consolas"; do
    if command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  printf 'monospace\n'
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
    ram_gb="$(free -b 2>/dev/null | awk '/Mem:/{printf "%d", $2/1073741824; exit}')"
    [ -n "$ram_gb" ] || ram_gb="?"
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
    echo "TCP CC   : $(sysctl_read net.ipv4.tcp_congestion_control || echo '?')"
    echo "Date     : $(date -u '+%Y-%m-%d %H:%M UTC')"
  } > "$SYSINFO_FILE" || die "Не удалось записать $SYSINFO_FILE"

  cat "$SYSINFO_FILE"
}

# ----------------------------------------------------------------------------
# Запуск тестов
# ----------------------------------------------------------------------------
declare -a RESULTS=()
TESTS_ELAPSED=0

# Оставляем в потоке ANSI-цвета (включая truecolor и фоны — freeze 0.2.2 их
# понимает) и стили. Выбрасываем курсорные CSI, OSC и прочие C0: они ломают
# конвертацию в PNG и не несут информации для отчёта.
sanitize_stream() {
  # C0-символы (кроме \n, \t и ESC=033) убирает tr: не полагаемся на то,
  # понимает ли awk \r, \010 и прочие escape в регулярках (у mawk с этим беда).
  tr -d '\000-\006\013\014\016-\032\034-\037\177' |
  awk '
  BEGIN {
    esc = sprintf("%c", 27); cr = sprintf("%c", 13); bs = sprintf("%c", 8)
    nb = 0; cur = ""
  }
  # Текст в текущую строку; backspace удаляет предыдущий символ (с учётом UTF-8).
  function put(s,   p, pre, i, b) {
    # CR возвращает курсор в начало строки: остаётся только последний кадр.
    while ((p = index(s, cr)) > 0) { cur = ""; s = substr(s, p + 1) }
    while ((p = index(s, bs)) > 0) {
      pre = substr(s, 1, p - 1)
      i = length(pre)
      while (i > 0) { b = substr(pre, i, 1); if (b < "\200" || b > "\277") break; i-- }
      if (i > 0) i--
      s = substr(pre, 1, i) substr(s, p + 1)
    }
    cur = cur s
  }
  # Скрипты рисуют баннеры/прогресс, а затем стирают их курсором вверх.
  # Без этого реклама IPQuality остаётся в логе и портит скриншот.
  function cursor_up(n) {
    while (n-- > 0) {
      if (cur != "") cur = ""
      else if (nb > 0) nb--
    }
  }
  # freeze рисует только truecolor-фоны: стандартные 40-47 и 100-107
  # он выбрасывает. Переводим их в 48;2 в обычную палитру терминалов.
  function sgr_params(params,   n, pa, i, v, res) {
    if (params == "") params = "0"
    if (params !~ /^[0-9;]+$/ || length(params) > 60) return esc "[0m"
    n = split(params, pa, ";"); res = ""
    for (i = 1; i <= n; i++) {
      v = pa[i]
      if (v == 38 || v == 48) {
        # цвет или фон с палитрой/truecolor: копируем его параметры целиком,
        # чтобы значения 40-47 внутри 48;2;R;G;B не принять за фон.
        # Форма с colorspace (38;2;cs;R;G;B) занимает на один параметр больше.
        if (pa[i+1] == 5) {
          res = res v ";" pa[i+1] ";" pa[i+2] ";"; i += 2
        } else if (pa[i+1] == 2) {
          if (n - i - 1 == 4) { res = res v ";" pa[i+1] ";" pa[i+2] ";" pa[i+3] ";" pa[i+4] ";" pa[i+5] ";"; i += 5 }
          else { res = res v ";" pa[i+1] ";" pa[i+2] ";" pa[i+3] ";" pa[i+4] ";"; i += 4 }
        } else {
          res = res v ";"
        }
      }
      else if (v == "") continue
      else if (v == 40) res = res "48;2;0;0;0;"
      else if (v == 41) res = res "48;2;205;49;49;"
      else if (v == 42) res = res "48;2;13;188;121;"
      else if (v == 43) res = res "48;2;229;229;16;"
      else if (v == 44) res = res "48;2;36;114;200;"
      else if (v == 45) res = res "48;2;188;63;188;"
      else if (v == 46) res = res "48;2;17;168;205;"
      else if (v == 47) res = res "48;2;229;229;229;"
      else if (v == 100) res = res "48;2;102;102;102;"
      else if (v == 101) res = res "48;2;241;76;76;"
      else if (v == 102) res = res "48;2;35;209;139;"
      else if (v == 103) res = res "48;2;245;245;67;"
      else if (v == 104) res = res "48;2;59;142;234;"
      else if (v == 105) res = res "48;2;209;107;165;"
      else if (v == 106) res = res "48;2;41;184;219;"
      else if (v == 107) res = res "48;2;255;255;255;"
      else res = res v ";"
    }
    sub(/;$/, "", res)
    return esc "[" res "m"
  }
  {
    line = $0
    # Завершающие CR — перевод строки, а не новый кадр.
    while (substr(line, length(line), 1) == cr) line = substr(line, 1, length(line) - 1)
    while (line != "") {
      e = index(line, esc)
      if (!e) { put(line); break }
      if (e > 1) put(substr(line, 1, e - 1))
      rest = substr(line, e + 1)
      kind = substr(rest, 1, 1)
      if (kind == "[") {
        body = substr(rest, 2); L = length(body); k = 1
        while (k <= L) { ch = substr(body, k, 1); if (ch >= "@" && ch <= "~") break; k++ }
        if (k > L) break
        params = substr(body, 1, k - 1); final = substr(body, k, 1)
        line = substr(body, k + 1)
        if (final == "m") {
          put(sgr_params(params))
        } else if (final == "A") {
          cursor_up(params == "" ? 1 : params + 0)
        } else if (final == "K") {
          cur = ""
        }
        # прочие CSI (курсоры, режимы, очистка экрана) выбрасываем
      } else if (kind == "]") {
        # OSC (заголовок окна и т.п.): глотаем до BEL или ESC-\
        rest = substr(rest, 2)
        bel = index(rest, "\007"); st = index(rest, esc "\\")
        if (bel && (!st || bel < st)) line = substr(rest, bel + 1)
        else if (st) line = substr(rest, st + 2)
        else line = ""
      } else {
        line = rest
      }
    }
    buf[++nb] = cur
    cur = ""
  }
  END {
    for (i = 1; i <= nb; i++) { gsub(/\007/, "", buf[i]); print buf[i] }
  }'
}

format_duration() {
  local seconds="$1"
  printf '%02d:%02d:%02d' "$((seconds / 3600))" "$((seconds / 60 % 60))" "$((seconds % 60))"
}

# GNU timeout умеет -k, а busybox до 1.35 нет: проверяем один раз и звеним
# через обёртку, чтобы на Alpine каждый тест не падал мгновенно.
T_K=""
timeout_has_k() {
  if [ -z "$T_K" ]; then
    if timeout -k 1 true 2>/dev/null; then T_K=1; else T_K=0; fi
  fi
  [ "$T_K" = 1 ]
}
timeout_run() {
  local k="$1" limit="$2"; shift 2
  if timeout_has_k; then timeout -k "$k" "$limit" "$@"; else timeout "$limit" "$@"; fi
}

# run_test <id> <title> <timeout> <command>
run_test() {
  local id="$1" title="$2" tmo="$3" cmd="$4"
  local log="$OUT/$id.txt" start duration status rc

  # Лог содержит только заголовок теста и его вывод: шапка с характеристиками
  # сервера - отдельный скрин sysinfo.png, дублировать её перед каждым тестом не нужно.
  {
    echo "================================================================"
    echo "  $title"
    echo "================================================================"
  } > "$log" || die "Не удалось записать $log"

  info ">> $title (лимит $(format_duration "$tmo"))"
  start=$SECONDS
  local label="$title"
  if [ "${TEST_TOTAL:-0}" -gt 0 ]; then
    label="[$TEST_NO/$TEST_TOTAL] ${title%% — *}"
  fi
  spinner_start "$label"
  # wait прерывается сразу; отдельная группа позволяет остановить и потомков теста.
  # Тест пишет во временный файл, а не в FIFO: если потомок оставит фоновый
  # процесс с открытым stdout, ожидание конца записи не зависнет навсегда.
  (
    work="$(mktemp -d "$OUT/.bench-$id-XXXXXX")" || exit 125
    trap 'rm -rf -- "$work"' EXIT
    cd -- "$work" || exit 125
    local runner=''
    trap '[[ -z "$runner" ]] || kill -KILL -- "-$runner" 2>/dev/null; wait 2>/dev/null; exit 130' INT TERM
    set -m
    # timeout у GNU уводит ребёнка в свою группу (setpgid): --foreground держит
    # его в группе раннера, иначе kill по группе после Ctrl+C его не достанет.
    # Запускаем сам бинарник: фон с функцией-обёрткой сломал бы группу раннера.
    local -a timeout_cmd=(timeout "$tmo")
    if timeout_has_k; then timeout_cmd=(timeout -k 15 --foreground "$tmo"); fi
    "${timeout_cmd[@]}" bash -o pipefail -c "$cmd" </dev/null > raw 2>&1 &
    runner=$!
    wait "$runner"; rc=$?
    runner=''
    sanitize_stream < raw >> "$log" || exit 125
    exit "$rc"
  )
  rc=$?
  spinner_stop
  if (( rc == 130 )); then exit 130; fi
  if (( rc == 125 )); then die "Не удалось запустить тест или сохранить вывод в $log"; fi
  local elapsed=$((SECONDS - start))
  TESTS_ELAPSED=$((TESTS_ELAPSED + elapsed))
  duration="$(format_duration "$elapsed")"

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    status="TIMEOUT"
    warn "Тест '$id' прерван по таймауту ($duration)."
  elif [ "$rc" -ge 128 ]; then
    status="KILLED"
    warn "Тест '$id' убит сигналом SIG$((rc - 128)) ($duration)."
  elif [ "$rc" -ne 0 ]; then
    status="FAILED"
    warn "Тест '$id' завершился с ошибкой (код $rc, $duration)."
  elif [ ! -s "$log" ]; then
    status="FAILED"
    warn "Тест '$id' не выдал результатов ($duration)."
  else
    status="OK"
    ok "Тест '$id' завершён ($duration)."
  fi
  printf '\n[scriptest] %s · %s\n' "$status" "$duration" >> "$log" ||
    die "Не удалось дописать $log"
  [[ " ${REPORT_LOGS[*]} " == *" $id.txt "* ]] || REPORT_LOGS+=("$id.txt")
  RESULTS+=("$id|$status|$duration")
  cat "$log"
  render_pngs "$id.txt"
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
    # ipregion включает цвета только если stdout — терминал. В логе его нет,
    # поэтому убираем проверку -t 1 прямо в скачиваемом скрипте (NO_COLOR работает).
    ipregion)
      run_test "$id" "$title" "$tmo" "wget -qO- https://github.com/vernette/ipregion/raw/master/ipregion.sh | sed 's/-t 1 \&\& //' | bash -s --"
      grep -qF $'\033[' "$OUT/$id.txt" ||
        warn "В логе ipregion нет ANSI-цветов — замена '-t 1' могла перестать работать."
      ;;
    dpi)         run_test "$id" "$title" "$tmo" "bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi" ;;
    insta)       run_test "$id" "$title" "$tmo" "bash <(curl -L -s https://bench.openode.xyz/checker_inst.sh)" ;;
    speed-ru)    run_test "$id" "$title" "$tmo" "wget -qO- bench.tlab.pw | bash" ;;
    speed-world) run_speed "$id" "$title" "$tmo" "wget -qO- bench.sh | bash" "wget -qO- speed.tlab.pw | bash" ;;
    yabs)        run_yabs ;;
    geocheck)    run_test "$id" "$title" "$tmo" "curl -fsSL https://geocheck.ing | sh" ;;
    sysbench)    run_sysbench ;;
    *) warn "Неизвестный тест: $id" ;;
  esac
}

select_tests() {
  # Возвращает список id тестов (учитывая --only / --skip / меню)
  local -a ids=()
  local t id
  for t in "${TESTS[@]}"; do
    [[ "${t%%|*}" == geocheck ]] && continue
    ids+=("${t%%|*}")
  done

  if [ -n "$ONLY" ] && [ "$ONLY" != "__all__" ]; then
    IFS=',' read -r -a ids <<< "$ONLY"
  fi

  local -a result=()
  for id in "${ids[@]}"; do
    if [ -n "$SKIP" ] && [[ ",$SKIP," == *",$id,"* ]]; then continue; fi
    # без дублей: повтор в --only ломает пары «лог/PNG» и очистку отчёта
    [[ " ${result[*]} " == *" $id "* ]] || result+=("$id")
  done
  SELECTED=(${result[@]+"${result[@]}"})
}

# ----------------------------------------------------------------------------
# Скриншоты
# ----------------------------------------------------------------------------
render_image() {
  local input="$1" output="$2"
  shift 2
  # --language ansi: freeze рисует текст с сохранением ANSI-цветов из лога.
  # GOMAXPROCS=1: у freeze 0.2.2 на многоядерных машинах изредка случается
  # SIGSEGV в рантайме Go — рендеру параллелизм всё равно не нужен.
  GOMAXPROCS=1 timeout_run 5 "${RENDER_TIMEOUT:-60}" "$FREEZE_BIN" - --output "$output" --language ansi --wrap 120 --font.family "$MONO_FONT" "$@" < "$input"
}

render_pngs() {
  [ "$MAKE_PNG" -eq 1 ] || return 0
  [ -n "$FREEZE_BIN" ] && [ -x "$FREEZE_BIN" ] || { warn "freeze недоступен — пропускаю PNG."; return 0; }

  local name f image message
  local -a style=(--config full)
  if [ "$THEME" = light ]; then
    style=(--config base --theme monokailight --border.color '#d4d4d4' --border.width 1
      --border.radius 8 --font.size 14 --padding 20,28)
  fi
  for name in "$@"; do
    f="$OUT/$name"
    [ -s "$f" ] || continue
    image="${f%.txt}.png"
    local attempt ok_png=0
    for attempt in 1 2 3; do
      if message="$(render_image "$f" "$image" "${style[@]}" 2>&1)" && [ -s "$image" ]; then
        ok_png=1; break
      fi
      # Битую или пустую картинку в отчёт не берём: лучше оставить .txt,
      # чем потерять текст теста из-за пустого PNG.
      rm -f -- "$image"
      { [ "$attempt" -lt 3 ] && sleep 1; } || true
    done
    # Если freeze скачан нами и стабильно падает - бинарник с CDN мог быть
    # битым: перекачиваем по контрольной сумме и пробуем ещё раз.
    # FREEZE_NO_REDOWNLOAD - тестовый выключатель.
    if (( ! ok_png )) && [ -n "$FREEZE_DIR" ] && [ -z "${FREEZE_NO_REDOWNLOAD:-}" ]; then
      warn "freeze стабильно падает - перекачиваю бинарник."
      rm -rf -- "$FREEZE_DIR"; FREEZE_DIR=""; FREEZE_BIN=""; MAKE_PNG=1
      ensure_freeze
      if [ -n "$FREEZE_BIN" ] && [ -x "$FREEZE_BIN" ]; then
        for attempt in 1 2 3; do
          if message="$(render_image "$f" "$image" "${style[@]}" 2>&1)" && [ -s "$image" ]; then
            ok_png=1; break
          fi
          rm -f -- "$image"
          { [ "$attempt" -lt 3 ] && sleep 1; } || true
        done
      fi
    fi
    if (( ! ok_png )); then
      warn "PNG для ${f##*/} не создан, исходник оставлен${message:+: ${message%%$'\n'*}}."
      continue
    fi
    ok "Скриншот: $image"
    REPORT_IMAGES+=("${image##*/}")
  done
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
    for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
      IFS='|' read -r id status duration <<< "$r"
      printf '| %s | %s | %s |\n' "$id" "$status" "$duration"
    done
    echo
    echo "## Файлы"
    echo
    local f
    for f in "${REPORT_LOGS[@]}" ${REPORT_IMAGES[@]+"${REPORT_IMAGES[@]}"}; do
      printf -- '- `%s`\n' "$f"
    done
  } > "$md" || die "Не удалось создать $md"
  ok "Summary: $md"
}

make_zip() {
  if (( ! MAKE_ZIP || ${#REPORT_IMAGES[@]} == 0 )); then
    info "Без архива. Файлы отчёта: $OUT"
    return 0
  fi
  local dir="${OUT%/*}" archive="$OUT/.images.zip" name=report.zip n=1 file
  # Сначала проверяем ZIP, затем публикуем без перезаписи даже при параллельных запусках.
  # Без -T: у busybox-ln его нет, а без -f обычный ln и так не перезапишет цель.
  ( cd -- "$OUT" && zip -q -T "$archive" "${REPORT_IMAGES[@]}" ) ||
    { warn "Не удалось собрать и проверить ZIP. Отчёт остался в $OUT."; return 1; }
  while ! ln "$archive" "$dir/$name" 2>/dev/null; do
    if [[ ! -e "$dir/$name" && ! -L "$dir/$name" ]]; then
      warn "Не удалось сохранить $dir/$name. Архив: $archive"; return 1
    fi
    n=$((n+1)); name="report-$n.zip"
  done
  rm -f -- "$archive"
  archive="$dir/$name"
  ok "Архив: $archive"
  info "Скачай с компьютера (замени SERVER на адрес, по которому подключаешься по SSH):"
  printf '  scp %q .\n' "$(id -un)@SERVER:$archive"
  if (( ${#REPORT_IMAGES[@]} == ${#REPORT_LOGS[@]} )); then
    for file in summary.md "${REPORT_LOGS[@]}" "${REPORT_IMAGES[@]}"; do
      rm -f -- "$OUT/$file" || return 1
    done
    if (( OUT_CREATED )); then rmdir -- "$OUT" || warn "В $OUT остались файлы."; fi
  else
    warn "Не все PNG созданы. Исходники оставлены в $OUT."
  fi
}

print_results() {
  info "Итоги:"
  local r id st duration
  for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
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

  ██████╗█████╗█████╗ ██╗█████╗ ███████╗██████╗██████▐██████╗
  ██╔═══██╔═══╝██╔═██╗██║██╔═██╗╚═██╔══╝██╔═══╝██╔═══╚═██╔══╝
  ██████▐█║    █████╔╝██║█████╔╝  ██║   ████╗  ██████╗ ██║
  ╚═══██▐█║    ██╔═██╗██║██╔══╝   ██║   ██╔═╝  ╚═══██║ ██║
  ██████╚█████╗██║ ██║██║██║      ██║   ██████║██████║ ██║
  ╚═════╝╚════╝╚═╝ ╚═╝╚═╝╚═╝      ╚═╝   ╚═════╝╚═════╝ ╚═╝

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
  if [ "$(sysctl_read net.ipv4.tcp_congestion_control)" = bbr ] && [ -f "$BBR_CONF" ]; then
    info "BBR уже включён и сохранён после перезагрузки."
  elif confirm "Включить BBR + Cake навсегда (сохранится после перезагрузки)?"; then
    enable_bbr || warn "Продолжаю тесты без изменения алгоритма TCP."
  fi
}

utilities_menu() {
  local choice cc qd ipv6 bbr_on
  while true; do
    clear_screen
    cc="$(sysctl_read net.ipv4.tcp_congestion_control)"
    qd="$(sysctl_read net.core.default_qdisc)"
    ipv6="$(sysctl_read net.ipv6.conf.all.disable_ipv6)"
    [ -n "$cc" ] || cc="?"
    [ -n "$qd" ] || qd="?"
    [ -n "$ipv6" ] || ipv6="?"
    case "$ipv6" in 0) ipv6="включён" ;; 1) ipv6="отключён" ;; esac
    bbr_on=0
    [[ "$cc" == bbr && -f "$BBR_CONF" ]] && bbr_on=1
    printf '\n  %bУтилиты%b · BBR — навсегда, IPv6 — до перезагрузки\n\n' "$C_BOLD" "$C_RESET"
    if (( bbr_on )); then
      printf '  1) BBR + Cake — включён (%s / %s) · выключить\n' "$cc" "$qd"
    else
      printf '  1) BBR + Cake — выключен (сейчас %s / %s) · включить\n' "$cc" "$qd"
    fi
    printf '  2) Отключить IPv6 (сейчас: %s)\n' "$ipv6"
    printf '  0) Назад\n\n  ▸ Выбор: '
    read -r choice || return
    case "$choice" in
      1)
        if (( bbr_on )); then
          if confirm "Выключить BBR и вернуть прежний алгоритм?"; then disable_bbr; fi
        elif confirm "Включить BBR + Cake навсегда?"; then
          enable_bbr
        fi
        ;;
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

# Выбор тестов по флагам или через меню + отсев неизвестных id
choose_tests() {
  if [ -n "$ONLY" ]; then
    select_tests
    if [ "$ONLY" = "__all__" ] && [ -t 0 ]; then ASK_BBR=1; fi
  else
    SELECTED=()
    menu || die "Нет ввода. Укажи --all или --only <id>."
  fi
  local -a valid=()
  local id
  for id in ${SELECTED[@]+"${SELECTED[@]}"}; do
    if test_field "$id" tmo >/dev/null; then valid+=("$id")
    else warn "Неизвестный тест: $id"
    fi
  done
  [ ${#valid[@]} -gt 0 ] || die "Не выбран ни один известный тест: ${SELECTED[*]:-пусто}."
  SELECTED=("${valid[@]}")
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
  parse_flags "$@"
  case "$THEME" in light|dark) ;; *) die "Тема должна быть light или dark." ;; esac

  info "scriptest v$VERSION"
  # apt/dnf не должны задавать вопросов из дочерних скриптов
  export DEBIAN_FRONTEND=noninteractive
  setup_privileges

  local interactive=0
  if [ -z "$ONLY" ]; then
    interactive=1
    # При curl | bash stdin содержит код. Все интерактивные вопросы читаем из терминала.
    if [ ! -t 0 ]; then
      # сам exec при неудаче фатален для неинтерактивного bash, проверяем в подоболочке
      ( exec </dev/tty ) 2>/dev/null ||
        die "Нет терминала. Укажи --all или --only <id>."
      exec </dev/tty
    fi
  fi

  choose_tests
  if (( ASK_BBR )); then
    offer_bbr
    ASK_BBR=0   # BBR спрашиваем один раз за сессию, а не перед каждым кругом
  fi
  detect_pkg
  MONO_FONT="$(resolve_font)"
  info "Шрифт для скриншотов: $MONO_FONT"
  install_deps
  umask 077
  trap 'spinner_stop; [ -z "$FREEZE_DIR" ] || rm -rf -- "$FREEZE_DIR"' EXIT
  ensure_freeze

  while true; do
    RESULTS=()
    TESTS_ELAPSED=0
    REPORT_IMAGES=()
    setup_workdir
    render_pngs sysinfo.txt

    info "Тестов к запуску: ${#SELECTED[@]} (${SELECTED[*]})"
    TEST_TOTAL=${#SELECTED[@]}
    TEST_NO=0
    local id
    for id in "${SELECTED[@]}"; do
      TEST_NO=$((TEST_NO + 1))
      run_test_by_id "$id"
    done

    make_summary
    make_zip

    # Отчёт готов и архив собран: с терминалом возвращаемся в меню,
    # без терминала (CI, пайп) завершаемся.
    (( interactive )) || break
    printf '\n  %bEnter - вернуться в меню, Ctrl+C - выход%b\n\n' "${C_DIM}" "${C_RESET}"
    read -r _ || break
    choose_tests
  done
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
