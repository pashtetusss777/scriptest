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

run_speed speed-test 'Тест скорости' 5 'false | cat' 'printf "\033[?25l900 Mbit/s\n"'
run_test deadline 'Лимит времени' 1 'sleep 5'
[[ "${RESULTS[0]}" == 'speed-test|FAILED|'* &&
   "${RESULTS[1]}" == 'speed-test-fallback|OK|'* &&
   "${RESULTS[2]}" == 'deadline|TIMEOUT|'* ]] || die "Неверные итоги тестов."
grep -qxF '900 Mbit/s' "$OUT/speed-test-fallback.txt" || die "Лог содержит управляющие символы."

(
  ensure_freeze
  render_pngs
  for id in sysinfo speed-test speed-test-fallback deadline; do
    signature="$(od -An -tx1 -N8 "$OUT/$id.png" | tr -d ' \n')"
    [ "$signature" = 89504e470d0a1a0a ] || die "Не создан PNG для $id."
  done
) || exit 1

make_summary
grep -Fq 'speed-test-fallback.png' "$OUT/summary.md" || die "Скриншот отсутствует в сводке."
make_zip
[ "$(unzip -Z1 "$OUT.zip" | wc -l)" -eq 9 ] || die "Архив содержит неверный набор файлов."
unzip -tq "$OUT.zip" || exit 1
