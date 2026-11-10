# Английский перевод: в EN-режиме не остаётся русского текста — в меню, справке, журнале и объяснениях ошибок
source "$(dirname "$0")/lib.sh"
stub_docker
F=$(funcs)
cyr() { perl -CSD -Mutf8 -ne 'print if /\p{Cyrillic}/ && !/Язык|Русский|\.рф/' | sed 's/^ *//' | sort -u; }
show_left() { [ -n "$1" ] && printf '%s\n' "$1" | head -10 | sed 's/^/      /'; }

# 1. Все строки кода покрыты словарём
if command -v python3 >/dev/null; then
  check "словарь покрывает все строки с кириллицей в src/" 'python3 "$ROOT/tools/i18n_check.py" >/dev/null 2>&1'
  python3 "$ROOT/tools/i18n_check.py" 2>/dev/null | head -10 | sed 's/^/      /'
fi

# 2. Объяснения ошибок (why) — все виды и причины
en() { bash -c '. "'"$F"'"; RP_SELF="'"$SCRIPT"'"; RP_LANG=en; rp_load_dict; apply_ui; port_owner() { echo nginx; }; '"$1" 2>&1 | RP_SELF="$SCRIPT" bash -c '. "'"$F"'"; RP_SELF="'"$SCRIPT"'"; rp_translate'; }
samples=(
  "docker|no space left on device" "docker|toomanyrequests: rate limit" "docker|manifest unknown"
  "docker|Get https://registry-1.docker.io/v2/: dial tcp: i/o timeout" "docker|Bind for 0.0.0.0:443 failed: port is already allocated"
  "docker|Cannot connect to the Docker daemon" "docker|permission denied while trying to connect to the docker.sock"
  "docker|yaml: line 3: did not find expected key" "docker|что-то странное"
  "container|password authentication failed for user" "container|connect ECONNREFUSED 10.0.0.2:5432" "container|EADDRINUSE: address already in use :::3000"
  "container|OOMKilled" "container|migration failed" "container|ZodError: invalid environment" "container|непонятно"
  "db|password authentication failed" "db|database \"x\" does not exist" "db|No such container" "db|???"
  "apt|Could not get lock /var/lib/dpkg/lock" "apt|dpkg was interrupted" "apt|Temporary failure resolving" "apt|Unable to locate package x" "apt|no space left"
  "ssh|Host key verification failed." "ssh|ssh: Could not resolve hostname x" "ssh|ssh: connect to host x port 22: Connection refused"
  "ssh|ssh: connect to host x port 22: Connection timed out" "ssh|root@x: Permission denied (publickey)."
  "net|curl: (6) Could not resolve host" "net|curl: (28) Operation timed out" "net|curl: (22) 404"
  "telegram|{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" "telegram|chat not found" "telegram|bot was blocked by the user"
  "telegram|Too Many Requests" "telegram|curl: (7) Failed to connect"
)
all=""
for s in "${samples[@]}"; do
  k="${s%%|*}"; t="${s#*|}"
  all+=$(en "fail \"Не обновилось:\" $k $(printf %q "$t")")$'\n'
done
out_has "объяснение: причина" "Cause:" "$all"
out_has "объяснение: что делать" "What to do:" "$all"
left=$(cyr <<< "$all" | grep -v "что-то странное\|непонятно")
check "объяснения ошибок полностью на английском" '[ -z "$left" ]'; show_left "$left"

# 3. Справка
h=$(RP_LANG=en bash "$SCRIPT" --help 2>&1)
out_has "справка на английском" "change the panel domain" "$h"
left=$(cyr <<< "$h"); check "в справке нет русского" '[ -z "$left" ]'; show_left "$left"
h=$(bash "$SCRIPT" --help --lang en 2>&1); out_has "--lang en после --help тоже работает" "open the menu" "$h"

# 4. Журнал по дням
J="$T/j.log"
printf '%s 10:00:00 | START | Смена домена\n%s 10:00:30 | OK    | Смена домена\n%s 11:00:00 | FAIL  | Обновление панели (код 1)\n%s 12:00:00 | START | Перенос панели\n' \
  "$(date +%F)" "$(date +%F)" "$(date -d yesterday +%F)" "$(date +%F)" > "$J"
jo=$(en "JOURNAL='$J'; journal_fmt all '' 20" | nocolor)
out_has "журнал: «Сегодня»" "Today," "$jo"
out_has "журнал: «Вчера»" "Yesterday," "$jo"
out_has "журнал: прервано" "interrupted" "$jo"
left=$(cyr <<< "$jo"); check "журнал на английском" '[ -z "$left" ]'; show_left "$left"

# 5. Все пункты меню (каждый — отдельный запуск: открыть и выйти)
saved=""; for d in /opt/remnawave /etc/rw; do [ -e "$d" ] && { mkdir -p "$T/saved"; cp -a "$d" "$T/saved/"; saved+=" $d"; }; done
rm -rf /opt/remnawave /etc/rw; mkdir -p /opt/remnawave/backups /etc/rw
printf 'FRONT_END_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > /opt/remnawave/.env
printf 'de-1 root@192.0.2.1 22\n' > /etc/rw/nodes.list
touch "$HOME/.rw-nocmd" /etc/rw/autoupdate.conf /etc/rw/.latest_version
JS=/var/log/remnapilot.log; [ -f "$JS" ] && cp -a "$JS" "$T/journal.saved"
printf '%s 10:00:00 | OK    | Смена домена\n' "$(date +%F)" > "$JS"
menu_all=""
for n in $(seq 1 33); do
  [ "$n" = 30 ] && continue                                  # переключатель языка
  menu_all+=$(printf '%s\n' "$n" "" "" 0 "" 0 0 0 0 | PATH="$T/bin:$PATH" TERM=xterm-256color RP_NO_LIVE=1 RP_LANG=en \
              timeout 40 script -qc "bash '$SCRIPT'" /dev/null 2>&1 | nocolor)$'\n'
done
out_has "меню: обход дошёл до журнала" "Browse the whole log" "$menu_all"
check "меню без ошибок bash" '! grep -qE "line [0-9]+:|command not found|syntax error|unbound variable|bad substitution" <<< "$menu_all"'
left=$(cyr <<< "$menu_all"); check "все экраны меню на английском" '[ -z "$left" ]'; show_left "$left"

rm -rf /opt/remnawave /etc/rw "$HOME/.rw-nocmd"; rm -f "$JS"; [ -f "$T/journal.saved" ] && cp -a "$T/journal.saved" "$JS"
for d in $saved; do cp -a "$T/saved/$(basename "$d")" "$(dirname "$d")/"; done
finish
