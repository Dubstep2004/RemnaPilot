# v2.5: журнал по дням и фильтры, прогресс шагов, обновление без бэкапа, причины ошибок
source "$(dirname "$0")/lib.sh"
F=$(funcs)
run() { bash -c 'source "'"$F"'"; '"$1" 2>&1 | nocolor; }

# --- журнал ---
J="$T/j.log"
cat > "$J" <<EOF
$(date -d yesterday +%F) 09:00:00 | START | Сертификат: выпуск
$(date -d yesterday +%F) 09:00:20 | FAIL  | Сертификат: выпуск (код 1)
$(date +%F) 08:00:00 | START | Смена домена
$(date +%F) 08:03:10 | OK    | Смена домена
$(date +%F) 08:10:00 | INFO  | Firewall выключен
EOF
o=$(run "JOURNAL='$J'; journal_fmt all '' 20")
out_has "журнал: группа «Вчера»" "Вчера," "$o"
out_has "журнал: группа «Сегодня»" "Сегодня," "$o"
out_has "журнал: длительность действия" "Смена домена · 3 мин" "$o"
check "журнал: строки «начато» скрыты, если действие закончилось" '! grep -q "⏸" <<< "$o"'
o=$(run "JOURNAL='$J'; journal_fmt fail '' 20")
check "фильтр «только ошибки»" 'grep -q "✖ Сертификат" <<< "$o" && ! grep -q "Смена домена" <<< "$o"'
o=$(run "JOURNAL='$J'; journal_fmt today '' 20")
check "фильтр «за сегодня»" 'grep -q "Смена домена" <<< "$o" && ! grep -q "Сертификат" <<< "$o"'
o=$(LC_ALL=C run "JOURNAL='$J'; journal_fmt all 'FIREWALL' 20")
check "поиск без учёта регистра (и без UTF-8-локали)" 'grep -q "Firewall выключен" <<< "$o" && ! grep -q "Смена" <<< "$o"'
o=$(run "JOURNAL='$J'; journal_fmt all 'нет-такого' 20"); out_has "поиск: ничего не нашлось" "Записей нет" "$o"
printf '%s 10:00:00 | START | Перенос панели\n' "$(date +%F)" >> "$J"
o=$(run "JOURNAL='$J'; journal_fmt all '' 20"); out_has "незаконченное действие — «прервано»" "Перенос панели — прервано" "$o"
o=$(run "JOURNAL='$J'; journal_fmt all '' 2"); check "лимит последних записей" '[ "$(grep -c "^   [0-9]" <<< "$o")" = 2 ]'

# --- прогресс ---
o=$(run 'steps 2; step "Первый"; steps 3; step "Вложенный"; steps_done "внутри"; step "Второй"; steps_done "Всё"')
out_has "шаг 1/2" "1/2  Первый" "$o"
out_has "шаг 2/2" "2/2  Второй" "$o"
check "вложенные шаги — подпунктами, без своего итога" 'grep -q "› Вложенный" <<< "$o" && ! grep -q "внутри за" <<< "$o"'
out_has "итог со временем" "✔ Всё за 0 сек" "$o"

# --- обновление: без бэкапа базы не обновляет (без терминала, как автообновление) ---
o=$(run 'RW_DIR="'"$T"'"; touch "$RW_DIR/.env"; need_panel(){ :; }; app_containers(){ echo remnawave; }; local_ver(){ echo 1; }
  docker(){ :; }; backup_db(){ return 1; }; pull_up(){ echo PULLED; }; update_panel </dev/null; echo "rc=$?"')
check "бэкап не удался → не обновляет" '! grep -q PULLED <<< "$o" && grep -q "rc=1" <<< "$o"'
out_has "…и объясняет почему" "без него не обновляю" "$o"

# --- сбой скачивания образа: причина из вывода docker ---
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "Error response from daemon: manifest for remnawave/backend:9.9 not found: manifest unknown" >&2\nexit 1\n' > "$T/bin/docker"
chmod +x "$T/bin/docker"; mkdir -p "$T/p"; echo 'services: {}' > "$T/p/docker-compose.yml"
o=$(PATH="$T/bin:$PATH" run 'pull_up "'"$T"'/p" || fail "Не обновилось" docker "$PULL_LOG"')
out_has "pull_up: вывод docker сохранён и разобран" "такой версии образа нет" "$o"

# --- Telegram: ответ API → причина ---
printf '#!/bin/sh\ncat >/dev/null; echo "{\\"ok\\":false,\\"error_code\\":400,\\"description\\":\\"Bad Request: chat not found\\"}"\n' > "$T/bin/curl"; chmod +x "$T/bin/curl"
o=$(PATH="$T/bin:$PATH" run 'TG_CONF="'"$T"'/tg"; printf "TOKEN=1:x\nCHAT=5\n" > "$TG_CONF"; tg_text hi; echo "rc=$?"; why telegram "$TG_ERR"')
check "tg_text: ошибка Telegram → код ошибки" 'grep -q "rc=1" <<< "$o"'
out_has "tg: «chat not found» → нажать Start" "нажми Start" "$o"
printf '#!/bin/sh\ncat >/dev/null; echo "{\\"ok\\":true}"\n' > "$T/bin/curl"
o=$(PATH="$T/bin:$PATH" run 'TG_CONF="'"$T"'/tg"; tg_text hi; echo "rc=$?"'); out_has "tg_text: успех" "rc=0" "$o"

# --- apt: вывод сохраняется, причина понятна ---
printf '#!/bin/sh\necho "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 123 (apt)" >&2\nexit 100\n' > "$T/bin/apt-get"; chmod +x "$T/bin/apt-get"
o=$(PATH="$T/bin:$PATH" run 'pkg_install ufw || fail "ufw не установился" apt "$PKG_LOG"')
out_has "apt занят → понятная причина" "установщик пакетов занят" "$o"

# --- восстановление из большого сжатого дампа (раньше pipefail + head давали «файл повреждён») ---
{ echo "-- PostgreSQL database dump"; for i in $(seq 1 20000); do echo "INSERT INTO t VALUES ($i, 'строка данных $i');"; done; } | gzip > "$T/big.sql.gz"
o=$(run 'RW_DIR="'"$T"'"; JOURNAL=/dev/null; db_info(){ DB_CT=db; DB_NAME=postgres; DB_USER=postgres; }; backup_db(){ :; }; app_containers(){ :; }
  docker(){ [[ "$1" == exec ]] && cat >/dev/null; return 0; }; sleep(){ :; }
  printf "YES\n" | RESTORE_FILE="'"$T"'/big.sql.gz" restore_db')
check "большой .sql.gz не считается повреждённым" '! grep -q "повреждён" <<< "$o"'
out_has "…и восстанавливается" "База восстановлена" "$o"
head -c 2000 "$T/big.sql.gz" > "$T/cut.sql.gz"
o=$(run 'RW_DIR="'"$T"'"; db_info(){ DB_CT=db; }; printf "YES\n" | RESTORE_FILE="'"$T"'/cut.sql.gz" restore_db')
out_has "обрезанный дамп — честно «повреждён»" "Дамп повреждён" "$o"

# --- код выхода команд без меню ---
mkdir -p "$T/rw2"; echo 'FRONT_END_DOMAIN=a.example.com' > "$T/rw2/.env"
printf '#!/bin/sh\n[ "$1 $2" = "compose version" ] && echo 2.29 && exit 0\nexit 1\n' > "$T/bin/docker"
PATH="$T/bin:$PATH" bash "$SCRIPT" --dir "$T/rw2" --update </dev/null >/dev/null 2>&1; rc=$?
check "rw --update при сбое → код ошибки (не 0)" '[ "$rc" != 0 ]'

# --- справка ---
h=$(bash "$SCRIPT" --help 2>&1 | nocolor)
for c in --update --backup --decrypt --selftest --sub --dry-run --cert-method; do
  check "справка: $c с описанием" 'grep -qe "rw $c\|rw .*$c" <<< "$h"'
done
out_has "справка: пример" "Пример:" "$h"
finish
