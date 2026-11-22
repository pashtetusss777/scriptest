#!/usr/bin/env bash

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
source ./scriptest.sh

scratch="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$scratch"' EXIT
export TMPDIR="$scratch"
OUT="$scratch/отчёт с пробелами"
mkdir -p "$OUT/bin" || exit 1
SYSINFO_FILE="$OUT/sysinfo.txt"
printf 'OS       : Linux\n' > "$SYSINFO_FILE"
REPORT_LOGS=(sysinfo.txt)

run_speed speed-test 'Тест скорости' 5 'false | cat' 'printf "\033[?25l\033[38;2;10;20;30mTRUE\033[0m \033[38;5;208mORANGE\033[0m \033[32mGREEN\033[0m\n"'
run_test deadline 'Лимит времени' 1 'touch transient.txt; sleep 5'
[[ "${RESULTS[0]}" == 'speed-test|FAILED|'* &&
   "${RESULTS[1]}" == 'speed-test-fallback|OK|'* &&
   "${RESULTS[2]}" == 'deadline|TIMEOUT|'* ]] || die "Неверные итоги тестов."
grep -qxF $'\033[38;5;208mORANGE\033[0m \033[32mGREEN\033[0m' "$OUT/speed-test-fallback.txt" ||
  die "Цвета в логе не сохранились."
grep -qF '38;2;' "$OUT/speed-test-fallback.txt" && die "Truecolor не вычищен из лога."
if compgen -G "$OUT/.bench-*" >/dev/null; then die "Временные файлы теста не удалены."; fi

ensure_freeze
render_pngs
for id in sysinfo speed-test speed-test-fallback deadline; do
  signature="$(od -An -tx1 -N8 "$OUT/$id.png" | tr -d ' \n')"
  [ "$signature" = 89504e470d0a1a0a ] || die "Не создан PNG для $id."
done

make_summary
grep -Fq 'speed-test-fallback.png' "$OUT/summary.md" || die "Скриншот отсутствует в сводке."
make_zip
[ "$(unzip -Z1 "$OUT.zip" | wc -l)" -eq 9 ] || die "Архив содержит неверный набор файлов."
unzip -tq "$OUT.zip" || exit 1

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
