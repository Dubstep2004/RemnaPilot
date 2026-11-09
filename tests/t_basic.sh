# Базовые проверки: синтаксис, версия, справка, флаги
source "$(dirname "$0")/lib.sh"
check "синтаксис bash" 'bash -n "$SCRIPT"'
check "RP_VERSION указана" 'grep -qE "^RP_VERSION=\"[0-9]+(\.[0-9]+)+\"" "$SCRIPT"'
v=$(bash "$SCRIPT" --version); out_has "--version" "RemnaPilot" "$v"
h=$(bash "$SCRIPT" --help); out_has "--help показывает все флаги" "--cert-status" "$h"
check "флаг без значения не вешает скрипт" 'timeout 5 bash "$SCRIPT" --dir >/dev/null 2>&1; [ $? -eq 1 ]'
check "--cert-method проверяет значение" 'timeout 5 bash "$SCRIPT" --cert-method foo >/dev/null 2>&1; [ $? -eq 1 ]'
check "версия в CHANGELOG.md" 'v=$(grep -m1 "^RP_VERSION=" "$SCRIPT" | cut -d\" -f2); [ ! -f "$ROOT/CHANGELOG.md" ] || grep -qx "## v$v" "$ROOT/CHANGELOG.md"'
check "версия в RP_CHANGELOG" 'v=$(grep -m1 "^RP_VERSION=" "$SCRIPT" | cut -d\" -f2); grep -qF "\"$v|" "$SCRIPT"'
check "у каждой записи истории есть категория" '! sed -n "/^RP_CHANGELOG=(/,/^)/p" "$SCRIPT" | grep -E "^  \"" | grep -vqE "^  \"[0-9.]+\|(new|improve|fix|security|change)\|"'
check "CHANGELOG и README собраны из скрипта" 'python3 "$ROOT/tools/changelog.py" --check'
notes=$(python3 "$ROOT/tools/changelog.py" --release "$(grep -m1 "^RP_VERSION=" "$SCRIPT" | cut -d\" -f2)")
out_has "описание релиза: заголовок" "# 🛰️ RemnaPilot v" "$notes"
out_has "описание релиза: английская часть" "🇬🇧" "$notes"
out_has "описание релиза: проверка подлинности" "rw --verify" "$notes"
F=$(funcs); mkdir -p /etc/rw; old=$(cat /etc/rw/.seen_version 2>/dev/null)
echo 1.0 > /etc/rw/.seen_version
out=$(bash -c 'source "'"$F"'"; clear(){ :; }; pause(){ :; }; check_whats_new' 2>&1 | nocolor)
out_has "после обновления — экран «Что нового»" "Ты обновился до" "$out"
out_has "изменения по категориям" "✦ Новое" "$out"
out=$(bash -c 'source "'"$F"'"; clear(){ :; }; pause(){ :; }; check_whats_new' 2>&1 | nocolor)
check "второй раз не показывается" '[ -z "$out" ]'
[ -n "$old" ] && echo "$old" > /etc/rw/.seen_version || rm -f /etc/rw/.seen_version
out=$(bash "$SCRIPT" --changelog 2>&1 | nocolor)
out_has "rw --changelog — вся история" "v1.0" "$out"
finish
