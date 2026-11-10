# Блокировка, токен Telegram, шифрование бэкапов, Compose v2, поиск без UTF-8, проверка подлинности, сборка
source "$(dirname "$0")/lib.sh"
F=$(funcs)
check "remnapilot.sh собран из src/" 'python3 "$ROOT/tools/build.py" --check'

# --- блокировка: второе действие ждёт первое ---
LOCK="$T/l.lock"
( bash -c 'source "'"$F"'"; RP_LOCK="'"$LOCK"'"; with_lock "Автобэкап" bash -c "echo A1 >> '"$T"'/order; sleep 2; echo A2 >> '"$T"'/order"' ) &
sleep 0.5
out=$(bash -c 'source "'"$F"'"; RP_LOCK="'"$LOCK"'"; with_lock "Смена доменов" bash -c "echo B >> '"$T"'/order"' 2>&1 | nocolor)
wait
check "второе действие выполнилось после первого" '[ "$(tr "\n" " " < "$T/order")" = "A1 A2 B " ]'
out_has "пользователь видит, чего ждёт" "Сейчас выполняется: Автобэкап" "$out"
out=$(bash -c 'source "'"$F"'"; RP_LOCK="'"$LOCK"'"; with_lock X with_lock Y echo nested-ok' 2>&1)
out_has "вложенная блокировка не зависает" "nested-ok" "$out"

# --- токен Telegram не попадает в аргументы curl ---
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<C
#!/bin/bash
echo "ARGS: \$*" >> "$T/curl.log"; cat >> "$T/curl.log"; echo '{"ok":true}'
C
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; TG_CONF="'"$T"'/tg.conf"; printf "TOKEN=123:SECRETTOKENxxxxxxxxxxxxxxxxxxxxxxxxx\nCHAT=5\n" > "$TG_CONF"; tg_text "привет"' >/dev/null 2>&1
check "токена нет в аргументах curl (их видно в ps)" '! grep "^ARGS:" "$T/curl.log" | grep -q SECRETTOKEN'
check "токен передан через stdin" 'grep -q "url = \"https://api.telegram.org/bot123:SECRETTOKEN" "$T/curl.log"'

# --- шифрование бэкапов ---
mkdir -p "$T/rw/backups"; echo 'FRONT_END_DOMAIN=p.example.com' > "$T/rw/.env"
bk() { bash -c 'source "'"$F"'"; RW_DIR="'"$T"'/rw"; JOURNAL=/dev/null; NODES_FILE=/none; BK_CONF="'"$T"'/bk.conf"; BK_PASS="'"$T"'/pass"
  need_panel(){ :; }; mkdir(){ command mkdir "$@" 2>/dev/null; return 0; }
  backup_db(){ local f="$RW_DIR/backups/db-$(date +%s%N)-auto.sql.gz"; echo SECRET_DUMP | gzip > "$f"; }
  tg_on(){ :; }; tg_file(){ echo "[file $1]"; cp "$1" "'"$T"'/sent"; }; tg_text(){ echo "[text $1]"; }
  '"$1" 2>&1 | nocolor; }
rm -f "$T/bk.conf"; out=$(bk 'bk_run')
out_has "без пароля архив в Telegram не уходит" "[text" "$out"
check "...и файл не отправлен" '! grep -q "\[file" <<< "$out"'
printf 'MyStrongPass123' > "$T/pass"; echo ENC=on > "$T/bk.conf"
out=$(bk 'bk_run')
out_has "с паролем уходит .enc" ".tar.gz.enc]" "$out"
check "в отправленном файле нет открытых данных" '! zcat -f "$T/sent" 2>/dev/null | grep -qa SECRET_DUMP'
check "расшифровывается паролем" 'printf "MyStrongPass123" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass stdin -in "$T/sent" | tar -xzO 2>/dev/null | zcat -f | grep -qa SECRET_DUMP'
cp "$T/sent" "$T/x.tar.gz.enc"
out=$(printf 'wrong\n' | bash -c 'source "'"$F"'"; BK_PASS=/nonexistent; bk_decrypt "'"$T"'/x.tar.gz.enc"' 2>&1 | nocolor)
out_has "неверный пароль — понятная ошибка" "Неверный пароль" "$out"
out=$(printf 'MyStrongPass123\n' | bash -c 'source "'"$F"'"; BK_PASS=/nonexistent; bk_decrypt "'"$T"'/x.tar.gz.enc"' 2>&1 | nocolor)
out_has "rw --decrypt с верным паролем" "Расшифровано" "$out"
echo ENC=off > "$T/bk.conf"; out=$(bk 'bk_run'); out_has "шифрование выключено явно — отправка как раньше" ".tar.gz]" "$out"

# --- Docker Compose v2 ---
printf '#!/bin/sh\n[ "$1" = compose ] && { echo "unknown command: docker compose" >&2; exit 1; }\nexit 0\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
out=$(PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; RW_DIR="'"$T"'/rw"; need_panel; echo "rc=$?"' 2>&1 | nocolor)
out_has "нет Compose v2 — понятная ошибка" "Нет Docker Compose v2" "$out"
out_has "…с причиной и что делать" "apt install docker-compose-plugin" "$out"
out_has "...и действие не выполняется" "rc=1" "$out"

# --- поиск без UTF-8-локали ---
out=$(LC_ALL=C LANG=C bash -c 'source "'"$F"'"; LC_ALL=C; menu_lookup "СЕРТ" >/dev/null; echo "pick=$MENU_PICK"' 2>&1)
check "поиск «СЕРТ» без UTF-8-локали → сертификаты" 'grep -q "pick=9" <<< "$out"'

# --- проверка подлинности: старый релиз без .sha256 сравнивается по файлу ---
cp "$SCRIPT" "$T/me.sh"
fake='curl(){ local o="" u=""; while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift;; https://*) u="$1";; esac; shift; done
  case "$u" in *.sha256) return 22;; *releases/download/*/remnapilot.sh) cp "$REL" "$o";; *) return 22;; esac; }'
out=$(REL="$T/me.sh" bash -c 'source "'"$F"'"; '"$fake"'; RP_SELF="'"$T"'/me.sh"; rp_verify_self')
check "релиз без .sha256, файл тот же — подлинный" '[ "$out" = ok ]'
echo "# правка" >> "$T/me.sh"; cp "$SCRIPT" "$T/rel.sh"
out=$(REL="$T/rel.sh" bash -c 'source "'"$F"'"; '"$fake"'; RP_SELF="'"$T"'/me.sh"; rp_verify_self')
check "файл отличается — распознан" '[ "$out" = modified ]'
out=$(PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; RW_DIR="'"$T"'/rw"; clear(){ :; }; curl(){ return 7; }; rp_selftest' 2>&1 | nocolor)
out_has "самопроверка: итог" "ИТОГ" "$out"
out_has "самопроверка видит отсутствие Compose v2" "нет Docker Compose v2" "$out"
check "самопроверка считает ошибки" 'grep -qE "[1-9][0-9]* ошибок" <<< "$out"'
finish
