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
finish
