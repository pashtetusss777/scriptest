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
VERSION="0.1.4"

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
clear_screen() { printf '\033[H\033[2J\033[3J'; }

# ----------------------------------------------------------------------------
# Настройки по умолчанию (меняются флагами)
# ----------------------------------------------------------------------------
THEME="light"          # light | dark
MAKE_PNG=1
MAKE_ZIP=1
ONLY=""                # список id через запятую
SKIP=""                # список id через запятую
OUT=""                 # рабочая папка (задаётся позже)
FREEZE_BIN=""
THEME_FILE=""

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
  -a, --all              запустить все тесты без меню
  -o, --only <ids>       только выбранные тесты (через запятую), например: --only sysbench,yabs
  -s, --skip <ids>       пропустить указанные тесты
  -l, --list             показать список тестов и выйти
  -t, --theme <name>     тема скриншотов: light (инь-ян, белый фон) | dark (по умолчанию: light)
      --no-png           не генерировать PNG-скриншоты
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
# freeze: скачивание бинарника и темы
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
      aarch64|arm64)   arch="aarch64" ;;
      armv7*|armv8*)   arch="arm" ;;
      *) warn "freeze недоступен для $arch — PNG не будут сгенерированы."; MAKE_PNG=0; return 0 ;;
    esac

    info "Скачиваю freeze ($os/$arch)..."
    api="$(curl -fsSL https://api.github.com/repos/charmbracelet/freeze/releases/latest 2>/dev/null)" || api=""
    url="$(printf '%s' "$api" | grep -o "https://[^\"]*freeze_[0-9.]*_${os}_${arch}\\.tar\\.gz" | head -n1)"
    if [ -z "$url" ]; then
      warn "Не удалось получить ссылку на freeze — PNG не будут сгенерированы."
      MAKE_PNG=0; return 0
    fi
    bin_dir="$OUT/bin"
    mkdir -p "$bin_dir"
    curl -fsSL "$url" -o "$bin_dir/freeze.tar.gz" || { warn "Ошибка скачивания freeze."; MAKE_PNG=0; return 0; }
    tar -xzf "$bin_dir/freeze.tar.gz" -C "$bin_dir" freeze 2>/dev/null \
      || tar -xzf "$bin_dir/freeze.tar.gz" -C "$bin_dir" || { warn "Ошибка распаковки freeze."; MAKE_PNG=0; return 0; }
    chmod +x "$bin_dir/freeze"
    FREEZE_BIN="$bin_dir/freeze"
  fi
  ok "freeze: $FREEZE_BIN"
}

write_theme() {
  [ "$MAKE_PNG" -eq 1 ] || return 0
  THEME_FILE="$OUT/theme-$THEME.json"
  if [ "$THEME" = "dark" ]; then
    # Тёмная тема: чёрный фон, белые оттенки
    cat > "$THEME_FILE" <<'EOF'
{
  "name": "scriptest-yinyang-dark",
  "styles": {
    "Background": "#0a0a0a",
    "Text": "#f2f2f2",
    "Comment": "#8a8a8a",
    "Keyword": "#ffffff",
    "String": "#d4d4d4",
    "Number": "#ffffff",
    "Literal": "#ffffff",
    "Name": "#e0e0e0",
    "Function": "#ffffff",
    "Operator": "#cccccc",
    "Punctuation": "#cccccc",
    "PunctuationBracket": "#aaaaaa",
    "PunctuationMarker": "#888888",
    "Heading": "#ffffff",
    "Error": "#ffffff",
    "GenericHeading": "#ffffff",
    "GenericSubheading": "#ffffff",
    "GenericDeleted": "#777777",
    "GenericInserted": "#f2f2f2",
    "GenericEmph": "#ffffff",
    "GenericStrong": "#ffffff"
  }
}
EOF
  else
    # Светлая тема "инь-ян": белый фон, чёрный и оттенки серого
    cat > "$THEME_FILE" <<'EOF'
{
  "name": "scriptest-yinyang",
  "styles": {
    "Background": "#ffffff",
    "Text": "#171717",
    "Comment": "#8f8f8f",
    "Keyword": "#000000",
    "String": "#3d3d3d",
    "Number": "#000000",
    "Literal": "#000000",
    "Name": "#262626",
    "Function": "#000000",
    "Operator": "#404040",
    "Punctuation": "#404040",
    "PunctuationBracket": "#737373",
    "PunctuationMarker": "#999999",
    "Heading": "#000000",
    "Error": "#000000",
    "GenericHeading": "#000000",
    "GenericSubheading": "#000000",
    "GenericDeleted": "#a3a3a3",
    "GenericInserted": "#171717",
    "GenericEmph": "#000000",
    "GenericStrong": "#000000"
  }
}
EOF
  fi
}

# ----------------------------------------------------------------------------
# Результаты: папка, метаданные
# ----------------------------------------------------------------------------
SYSINFO_FILE=""

setup_workdir() {
  if [ -z "$OUT" ]; then
    OUT="$PWD/scriptest-$(hostname 2>/dev/null || echo server)-$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$OUT"
  info "Результаты: $OUT"

  # sysinfo.txt — шапка для summary и скриншотов
  SYSINFO_FILE="$OUT/sysinfo.txt"
  local os_pretty cpu_model cores ram_gb disk ip virt kernel
  os_pretty="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  [ -n "$os_pretty" ] || os_pretty="$(uname -s)"
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
    echo "Date     : $(date -u '+%Y-%m-%d %H:%M UTC')"
  } > "$SYSINFO_FILE"

  cat "$SYSINFO_FILE"
}

# ----------------------------------------------------------------------------
# Запуск тестов
# ----------------------------------------------------------------------------
declare -a RESULTS=()

ANSI_STRIP_SED='s/\x1B\[[0-9;]*[A-Za-z]//g; s/\x1B\][^\x07]*\x07//g; s/\x1B[>=]//g'

# run_test <id> <title> <timeout> <command>
run_test() {
  local id="$1" title="$2" tmo="$3" cmd="$4"
  local log="$OUT/$id.txt" rc=0

  {
    echo "================================================================"
    echo "  $title"
    echo "================================================================"
    cat "$SYSINFO_FILE"
    echo "================================================================"
  } > "$log"

  info ">> $title (таймаут ${tmo}s)"
  set +e
  # stdin закрыт: дочерние скрипты не смогут «повиснуть» в ожидании ввода (apt-подтверждения и т.п.)
  # sed -u — без буферизации, чтобы вывод появлялся на экран сразу
  timeout --preserve-status --kill-after=15 "$tmo" bash -c "$cmd" 2>&1 </dev/null \
    | tee -a "$log" | sed -u -E "$ANSI_STRIP_SED"
  rc="${PIPESTATUS[0]}"
  set -e

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    warn "Тест '$id' прерван по таймауту."
    echo "" >> "$log"; echo "[scriptest] TIMEOUT (${tmo}s)" >> "$log"
    RESULTS+=("$id|TIMEOUT")
  elif [ "$rc" -ne 0 ]; then
    warn "Тест '$id' завершился с ошибкой (код $rc)."
    echo "" >> "$log"; echo "[scriptest] FAILED (exit $rc)" >> "$log"
    RESULTS+=("$id|FAILED")
  else
    ok "Тест '$id' завершён."
    echo "" >> "$log"; echo "[scriptest] OK" >> "$log"
    RESULTS+=("$id|OK")
  fi

  # Чистим ANSI-последовательности для читаемого текстового лога
  local clean="$OUT/$id.clean.txt"
  sed -E "$ANSI_STRIP_SED" "$log" > "$clean" && mv "$clean" "$log"
}

# run_speed <id> <title> <timeout> <primary_cmd> <fallback_cmd>
run_speed() {
  local id="$1" title="$2" tmo="$3" primary="$4" fallback="$5"
  run_test "$id" "$title" "$tmo" "$primary"

  local status="${RESULTS[-1]#*|}"
  local lines; lines="$(wc -l < "$OUT/$id.txt")"
  if [ "$status" != "OK" ] || [ "$lines" -lt 6 ]; then
    warn "Первичный скрипт для '$id' не дал результата — пробую фоллбек."
    # убираем последнюю запись, чтобы не дублировать
    unset 'RESULTS[-1]'
    run_test "$id" "$title" "$tmo" "$fallback"
  fi
}

run_sysbench() {
  if ! command -v sysbench >/dev/null 2>&1; then
    info ">> Sysbench пропущен (не установлен)."
    RESULTS+=("sysbench|SKIPPED")
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
render_pngs() {
  [ "$MAKE_PNG" -eq 1 ] || return 0
  [ -n "$FREEZE_BIN" ] && [ -x "$FREEZE_BIN" ] || { warn "freeze недоступен — пропускаю PNG."; return 0; }

  info "Генерирую PNG-скриншоты..."
  local f id png
  for f in "$OUT"/*.txt; do
    [ -e "$f" ] || return 0
    id="$(basename "${f%.txt}")"
    png="$OUT/$id.png"
    if "$FREEZE_BIN" "$f" \
        -o "$png" \
        -c full \
        --theme "$THEME_FILE" \
        --font.family "JetBrains Mono" \
        --font.size 13 \
        --line-height 1.3 \
        --padding 24,40 \
        --margin 24 \
        --background "#ffffff" >/dev/null 2>&1 \
       || "$FREEZE_BIN" "$f" -o "$png" -c full --theme "$THEME_FILE" >/dev/null 2>&1; then
      ok "PNG: $(basename "$png")"
    else
      warn "Не удалось создать PNG для $id"
    fi
  done
}

# ----------------------------------------------------------------------------
# Summary + zip
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
    echo "## Тесты"
    echo
    echo "| Тест | Статус |"
    echo "|------|--------|"
    local r
    for r in "${RESULTS[@]}"; do
      echo "| ${r%%|*} | ${r#*|} |"
    done
    echo
    echo "## Файлы"
    echo
    local f
    for f in "$OUT"/*; do
      echo "- \`$(basename "$f")\`"
    done
  } > "$md"
  ok "Summary: $md"
}

make_zip() {
  [ "$MAKE_ZIP" -eq 1 ] || return 0
  command -v zip >/dev/null 2>&1 || { warn "zip не найден — архив не собран (файлы лежат в $OUT)."; return 0; }
  local zipname
  zipname="$(basename "$OUT").zip"
  ( cd "$OUT" && zip -qr "../$zipname" . ) || { warn "Ошибка сборки архива."; return 0; }
  ok "Архив: $(dirname "$OUT")/$zipname"
  info "Скачать на локальную машину:"
  info "  scp user@$(hostname -I 2>/dev/null | awk '{print $1}' || echo SERVER):\"$(dirname "$OUT")/$zipname\" ."
}

print_results() {
  info "Итоги:"
  local r
  for r in "${RESULTS[@]}"; do
    local st="${r#*|}"
    case "$st" in
      OK)      ok   "  $(printf '%-12s' "${r%%|*}") $st" ;;
      SKIPPED) warn "  $(printf '%-12s' "${r%%|*}") $st" ;;
      *)       err  "  $(printf '%-12s' "${r%%|*}") $st" ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Баннер / меню
# ----------------------------------------------------------------------------
print_banner() {
  local ver="v$VERSION"
  local host ip os
  host="$(hostname 2>/dev/null || echo '?')"
  ip="?" os="?"
  [ -n "${SYSINFO_FILE:-}" ] && [ -f "$SYSINFO_FILE" ] && {
    ip="$(awk -F': *' '/^IP/{print $2}' "$SYSINFO_FILE")"
    os="$(awk -F': *' '/^OS/{print $2}' "$SYSINFO_FILE")"
  }
  cat <<'BANNER'

  ███████╗ ██████╗ ██████╗ ██╗██████╗ ████████╗███████╗███████╗████████╗
  ██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝
  ███████╗██║     ██████╔╝██║██████╔╝   ██║   ███████╗█████╗     ██║
  ╚════██║██║     ██╔══██╗██║██╔══██╗   ██║   ██╔══╝  ██╔══╝     ██║
  ███████║╚██████╗██║  ██║██║██║       ██║   ███████║███████╗   ██║
  ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝       ╚═╝   ╚══════╝╚══════╝   ╚═╝

BANNER
  printf '  %bscriptest %s%b %b· мульти-тест сервера%b\n' \
    "${C_BOLD}" "$ver" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  printf '  %bHost:%b %s %b· IP:%b %s %b· %s%b\n' \
    "${C_BOLD}" "${C_RESET}" "${host}" "${C_DIM}" "${C_RESET}" "${ip}" "${C_DIM}" "${os}" "${C_RESET}"
  printf '  %b─────────────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"
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
      printf '  %b%2d)%b %s %b— %s %b· ~%d мин%b\n' \
        "${C_OK}${C_BOLD}" "$i" "${C_RESET}" "${name}" \
        "${C_DIM}" "${desc}" "${C_DIM}" "$mins" "${C_RESET}"
      i=$((i+1))
    done
    echo
    printf '  %b a)%b %sЗапустить ВСЕ тесты%s %b· ~60 мин%b\n' \
      "${C_OK}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    printf '  %b q)%b Выход\n' "${C_BOLD}" "${C_RESET}"
    echo
    printf '  %b─────────────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"
    printf '  %b▸%b Номера через запятую (напр. 1,3,5) · a — все · q — выход: ' "${C_INFO}" "${C_RESET}"
    local choice
    read -r choice
    case "$choice" in
      q|Q) clear_screen; info "Выход."; exit 0 ;;
      a|A)
        if confirm_all; then
          SELECTED=()
          local t; for t in "${TESTS[@]}"; do SELECTED+=("${t%%|*}"); done
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
  printf '%s\n' "${C_INFO}${C_DIM}Внимание: полный тест гоняет трафик (speed-тесты, YABS ~15-20 мин).${C_RESET}"
  printf 'Запустить все тесты? [y/N]: '
  local ans
  read -r ans
  case "$ans" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
  parse_flags "$@"

  [ -t 1 ] && clear_screen
  info "scriptest v$VERSION"
  # apt/dnf не должны задавать вопросов из дочерних скриптов
  export DEBIAN_FRONTEND=noninteractive
  setup_privileges
  detect_pkg
  install_deps
  setup_workdir
  ensure_freeze
  write_theme

  if [ "$ONLY" = "__all__" ]; then
    SELECTED=()
    local t; for t in "${TESTS[@]}"; do SELECTED+=("${t%%|*}"); done
  elif [ -n "$ONLY" ]; then
    select_tests
  else
    SELECTED=()
    menu
    # select_tests уже мог заполнить SELECTED через меню
  fi

  [ ${#SELECTED[@]} -gt 0 ] || die "Не выбран ни один тест."

  info "Тестов к запуску: ${#SELECTED[@]} (${SELECTED[*]})"
  local id
  for id in "${SELECTED[@]}"; do
    run_test_by_id "$id"
  done

  print_results
  make_summary
  render_pngs
  make_zip
  info "Готово. Все файлы: $OUT"
}

main "$@"
