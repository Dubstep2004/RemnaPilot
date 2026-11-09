#!/usr/bin/env bash
# Запуск всех тестов: sudo bash tests/run.sh   (нужен root — скрипт проверяет EUID и пишет в /opt, /etc/rw)
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "Запусти от root: sudo bash tests/run.sh"; exit 1; }
total=0; failed=()
for t in t_*.sh; do
  total=$((total+1))
  printf '\n\e[1m▶ %s\e[0m\n' "${t%.sh}"
  if timeout 300 bash "$t"; then :; else failed+=("$t"); fi
done
echo
if (( ${#failed[@]} )); then
  printf '\e[31mУпало %d из %d: %s\e[0m\n' "${#failed[@]}" "$total" "${failed[*]}"; exit 1
fi
printf '\e[32mВсе тесты пройдены: %d\e[0m\n' "$total"
