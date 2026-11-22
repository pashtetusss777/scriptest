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

# Настоящий Ctrl+C в PTY; даже процесс, игнорирующий INT/TERM, не должен пережить тест.
cat > "$scratch/interrupt.sh" <<'SH'
source ./scriptest.sh
OUT="$TMPDIR/отчёт с пробелами"
SYSINFO_FILE="$OUT/sysinfo.txt"
# В шапке лога заявлен лимит 30 секунд, но его фактическое прерывание проверяется выше.
run_speed interrupt interrupt 30 'trap "" INT TERM; echo $$ > "$TMPDIR/ready"; exec sleep 30' 'touch "$TMPDIR/fallback"'
RESULTS=()
REPORT_LOGS=(sysinfo.txt)
SH
(
  for ((i=0; i<100; i++)); do [[ ! -s "$scratch/ready" ]] || break; sleep .05; done
  printf '\003'
) | timeout 8 script -qec 'bash "$TMPDIR/interrupt.sh"' /dev/null > "$scratch/interrupt.log"
[[ $? == 130 && -s "$scratch/ready" && ! -e "$scratch/fallback" ]] ||
  { cat "$scratch/interrupt.log"; die "Ctrl+C не прервал тест."; }
if kill -0 "$(cat "$scratch/ready")" 2>/dev/null && [[ "$(ps -o stat= -p "$(cat "$scratch/ready")")" != Z* ]]; then
  die "После Ctrl+C остался процесс теста."
fi
# Логи прерванного теста больше не нужны: полный прогон дальше проходит без них.
rm -f -- "$OUT"/interrupt*.txt

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
printf 'BAD1\nBAD2\n\033[2K\033[1A\033[2K\033[1A\033[2KREPORT_OK\n' | sanitize_stream > "$scratch/sanitized.txt"
grep -qF 'REPORT_OK' "$scratch/sanitized.txt" &&
  ! grep -qF 'BAD' "$scratch/sanitized.txt" ||
  die "Стёртый скриптом баннер остался в логе."
printf 'old\rNEW\n' | sanitize_stream > "$scratch/sanitized.txt"
grep -qF 'NEW' "$scratch/sanitized.txt" &&
  ! grep -qF 'old' "$scratch/sanitized.txt" ||
  die "Предыдущий CR-кадр остался в логе."
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
render_pngs sysinfo.txt speed-test.txt speed-test-fallback.txt deadline.txt
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

SUDO="" # Следующие проверки используют функции-заглушки вместо системных команд.
BBR_CONF="$scratch/bbr.conf"
printf 'cubic\n'    > "$scratch/cc"
printf 'fq_codel\n' > "$scratch/qdisc"
sysctl_read() {
  case "$1" in
    net.ipv4.tcp_congestion_control)           cat "$scratch/cc" ;;
    net.core.default_qdisc)                    cat "$scratch/qdisc" ;;
    net.ipv4.tcp_available_congestion_control) printf '%s\n' 'reno cubic bbr' ;;
    net.ipv6.conf.default.disable_ipv6)        printf '%s\n' 0 ;;
    *) return 1 ;;
  esac
}
sysctl_write() {
  printf '%s\n' "$1" >> "$scratch/sysctl-writes"
  case "$1" in
    net.ipv4.tcp_congestion_control=*) printf '%s\n' "${1#*=}" > "$scratch/cc" ;;
    net.core.default_qdisc=*)          printf '%s\n' "${1#*=}" > "$scratch/qdisc" ;;
  esac
}
systemctl() { printf '%s\n' "$*" >> "$scratch/systemctl-calls"; }
modprobe_load() { return 0; }
default_iface() { return 0; }

offer_bbr <<< n
[ ! -e "$BBR_CONF" ] || die "BBR включён без согласия."
offer_bbr <<< y
grep -qxF 'net.ipv4.tcp_congestion_control=bbr' "$BBR_CONF" || die "BBR не записан в sysctl.d."
grep -qxF 'net.core.default_qdisc=cake' "$BBR_CONF" || die "Cake не записан в sysctl.d."
[ "$(cat "$scratch/cc")" = bbr ] && [ "$(cat "$scratch/qdisc")" = cake ] ||
  die "BBR/Cake не применились."
grep -qxF 'restart systemd-sysctl' "$scratch/systemctl-calls" ||
  die "systemd-sysctl не перезапущен."
disable_bbr || die "BBR не выключился."
[ ! -e "$BBR_CONF" ] || die "Конфиг BBR не удалён."
[ "$(cat "$scratch/cc")" = cubic ] && [ "$(cat "$scratch/qdisc")" = fq_codel ] ||
  die "Прежние настройки TCP не вернулись."
if SSH_CONNECTION='2001:db8::1 999 2001:db8::2 22' disable_ipv6 <<< y; then
  die "IPv6 отключён внутри IPv6 SSH-сессии."
fi
SSH_CONNECTION='192.0.2.1 999 192.0.2.2 22' disable_ipv6 <<< y || die "IPv6 не отключён."
grep -qxF 'net.ipv6.conf.all.disable_ipv6=1' "$scratch/sysctl-writes" || die "Не изменены текущие интерфейсы."
