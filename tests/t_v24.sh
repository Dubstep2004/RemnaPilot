# Исправления v2.4: stderr после блокировки, блокировка при перезапуске, сбой архива, истёкшее ожидание
source "$(dirname "$0")/lib.sh"
F=$(funcs)
LOCK="$T/l.lock"

# --- после действия под блокировкой ошибки и подсказки (stderr) по-прежнему видны ---
out=$(bash -c 'source "'"$F"'"; RP_LOCK="'"$LOCK"'"; with_lock X bash -c "echo INSIDE >&2"; echo AFTER >&2' 2>&1 >/dev/null)
out_has "stderr виден внутри действия" "INSIDE" "$out"
out_has "stderr виден после действия" "AFTER" "$out"

# --- перезапуск скрипта (самообновление, смена языка) не уносит блокировку ---
bash -c 'source "'"$F"'"; RP_LOCK="'"$LOCK"'"; with_lock "Обновление RemnaPilot" rp_reexec sleep 3' &
sleep 0.7
check "блокировка свободна, пока живёт перезапущенный процесс" 'flock -n "$LOCK" true'
check "файл «кто держит» убран" '[ ! -e "$LOCK.who" ]'
wait

# --- архив не собрался: не «успех» ---
mkdir -p "$T/rw/backups" "$T/bin"; echo 'FRONT_END_DOMAIN=p.example.com' > "$T/rw/.env"
printf '#!/bin/sh\nexit 2\n' > "$T/bin/tar"; chmod +x "$T/bin/tar"
PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; RW_DIR="'"$T"'/rw"; JOURNAL="'"$T"'/j.log"; NODES_FILE=/none; BK_CONF="'"$T"'/bk.conf"; TG_CONF=/none
  need_panel() { :; }; backup_db() { echo x | gzip > "$RW_DIR/backups/db-1-auto.sql.gz"; }
  bk_run; echo "rc=$?" > "'"$T"'/rc"' >/dev/null 2>&1
has "сбой tar → код ошибки" "rc=1" "$T/rc"
has "сбой tar → запись в журнале" "не удалось собрать архив" "$T/j.log"
check "битого архива не осталось" '! ls "$T"/rw/backups/remnawave-*.tar.gz >/dev/null 2>&1'

# --- задача по расписанию не дождалась очереди: запись и уведомление ---
echo "Смена доменов · pid 1 · с 03:00" > "$LOCK.who"
bash -c 'source "'"$F"'"; RP_LOCK="'"$LOCK"'"; JOURNAL="'"$T"'/j2.log"; tg_text() { echo "TG: $1" > "'"$T"'/tg"; }; mkdir() { :; }
  lock_timeout "Автобэкап" "'"$T"'/last"'
has "результат: не выполнен" "|FAIL|Автобэкап не выполнен" "$T/last"
has "названо, кто мешал" "Смена доменов" "$T/last"
has "журнал" "не дождался очереди" "$T/j2.log"
has "уведомление в Telegram" "TG: " "$T/tg"
rm -f "$LOCK.who"
finish
