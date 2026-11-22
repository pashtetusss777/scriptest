#!/usr/bin/env bash

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
source ./scriptest.sh

(
  for ONLY in '' __all__; do
    select_tests
    [[ " ${SELECTED[*]} " != *' geocheck '* ]] || exit 1
  done
  ONLY=geocheck
  select_tests
  [[ "${SELECTED[*]}" == geocheck ]]
) || die "GeoCheck должен запускаться только по выбору."

scratch="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$scratch"' EXIT
export TMPDIR="$scratch"
# stdin несёт код, а ответ q приходит через отдельный управляющий терминал.
printf 'q\n' | timeout 10 script -qec 'cat scriptest.sh | bash' /dev/null > "$scratch/menu" ||
  die "Не удалось выйти из меню при запуске через пайп."
[ "$(grep -c 'Доступные тесты' "$scratch/menu")" = 1 ] && grep -Fq 'Выход.' "$scratch/menu" ||
  die "Меню не приняло ввод или перерисовалось."
if setsid --wait bash < scriptest.sh > "$scratch/headless" 2>&1; then die "Меню запустилось без терминала."; fi
grep -Fq 'Нет терминала.' "$scratch/headless" || die "Не обработано отсутствие терминала."
OUT="$scratch/отчёт с пробелами"
mkdir -p "$OUT" || exit 1
OUT_CREATED=1
SYSINFO_FILE="$OUT/sysinfo.txt"
printf 'OS       : Linux\n' > "$SYSINFO_FILE"
REPORT_LOGS=(sysinfo.txt)

run_speed speed-test 'Тест скорости' 5 'false | cat' 'printf "\033[?25l\033[38;2;10;20;30mTRUE\033[0m \033[38;5;208mORANGE\033[0m \033[32mGREEN\033[0m\n"'
run_test deadline 'Лимит времени' 1 'touch transient.txt; sleep 5'
[[ "${RESULTS[0]}" == 'speed-test|FAILED|'* &&
   "${RESULTS[1]}" == 'speed-test-fallback|OK|'* &&
   "${RESULTS[2]}" == 'deadline|TIMEOUT|'* ]] || die "Неверные итоги тестов."
grep -qF $'\033[38;5;208mORANGE\033[0m' "$OUT/speed-test-fallback.txt" ||
  die "Цвет 256-палитры не сохранился."
grep -qF $'\033[32mGREEN\033[0m' "$OUT/speed-test-fallback.txt" ||
  die "Базовый цвет не сохранился."
grep -q '^TRUE' "$OUT/speed-test-fallback.txt" || die "Текст после truecolor потерялся."
grep -qF '38;2;' "$OUT/speed-test-fallback.txt" && die "Truecolor не вычищен из лога."
if compgen -G "$OUT/.bench-*" >/dev/null; then die "Временные файлы теста не удалены."; fi

ensure_freeze
export REAL_FREEZE="$FREEZE_BIN"
FREEZE_BIN="$scratch/freeze"
cat > "$FREEZE_BIN" <<'SH'
#!/usr/bin/env bash
[[ "$3" == */sysinfo.png ]] && exit 1
exec "$REAL_FREEZE" "$@"
SH
chmod +x "$FREEZE_BIN"
detect_pkg
setup_privileges
render_pngs
for id in sysinfo speed-test speed-test-fallback deadline; do
  signature="$(od -An -tx1 -N8 "$OUT/$id.png" | tr -d ' \n')"
  [ "$signature" = 89504e470d0a1a0a ] || die "Не создан PNG для $id."
done

make_summary
grep -Fq 'speed-test-fallback.png' "$OUT/summary.md" || die "Скриншот отсутствует в сводке."
echo previous > "$scratch/report.zip"
make_zip || exit 1
[ "$(cat "$scratch/report.zip")" = previous ] && [ ! -e "$OUT" ] ||
  die "Старый архив изменён или временная папка осталась."
[ "$(unzip -Z1 "$scratch/report-2.zip" | sort)" = "$(printf '%s\n' sysinfo.png speed-test.png speed-test-fallback.png deadline.png | sort)" ] ||
  die "Архив содержит неверный набор файлов."
unzip -tq "$scratch/report-2.zip" || exit 1

SUDO="" # Следующие проверки используют функцию sysctl, не системную команду через sudo.
sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_congestion_control') printf '%s\n' cubic ;;
    '-n net.ipv4.tcp_available_congestion_control') printf '%s\n' 'reno cubic bbr' ;;
    '-n net.ipv6.conf.default.disable_ipv6') printf '%s\n' 0 ;;
    -w*) printf '%s\n' "$2" >> "$scratch/sysctl-writes" ;;
    *) return 1 ;;
  esac
}
offer_bbr <<< n
[ ! -e "$scratch/sysctl-writes" ] || die "BBR включён без согласия."
offer_bbr <<< y
if SSH_CONNECTION='2001:db8::1 999 2001:db8::2 22' disable_ipv6 <<< y; then
  die "IPv6 отключён внутри IPv6 SSH-сессии."
fi
[ "$(cat "$scratch/sysctl-writes")" = 'net.ipv4.tcp_congestion_control=bbr' ] ||
  die "Неожиданные сетевые настройки."
SSH_CONNECTION='192.0.2.1 999 192.0.2.2 22' disable_ipv6 <<< y || die "IPv6 не отключён."
grep -qxF 'net.ipv6.conf.all.disable_ipv6=1' "$scratch/sysctl-writes" || die "Не изменены текущие интерфейсы."
