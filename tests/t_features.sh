# Автобэкап, автообновление, Telegram, оформление
source "$(dirname "$0")/lib.sh"
F=$(funcs)
mkdir -p "$T/rw/backups" "$T/etc"
echo 'FRONT_END_DOMAIN=p.example.com' > "$T/rw/.env"
common='source "'"$F"'"; RW_DIR="'"$T"'/rw"; JOURNAL=/dev/null; NODES_FILE="'"$T"'/nodes.list"
  BK_CONF="'"$T"'/etc/backup.conf"; TG_CONF="'"$T"'/etc/tg.conf"; AU_CONF="'"$T"'/etc/au.conf"; UI_CONF="'"$T"'/etc/ui.conf"
  need_panel(){ return 0; }; docker(){ :; }
  mkdir(){ command mkdir "$@" 2>/dev/null; return 0; }'
mkdir -p /etc/rw

# --- автобэкап: архив, хранение N, Telegram ---
echo 'de-1 root@1.1.1.1 22' > "$T/nodes.list"
out=$(bash -c "$common"'
  backup_db(){ local f="$RW_DIR/backups/db-$(date +%s%N)-auto.sql.gz"; echo dump | gzip > "$f"; cp "$RW_DIR/.env" "${f%.sql.gz}.env"; }
  tg_api(){ echo "[tg $1 $*]" >> "'"$T"'/tg.log"; }
  bk_set KEEP 2; printf "TOKEN=1:x\nCHAT=5\n" > "$TG_CONF"
  for i in 1 2 3; do bk_run; sleep 1; done; echo "rc=$?"' 2>&1 | nocolor)
check "архивов хранится ровно 2" '[ "$(ls "$T"/rw/backups/remnawave-*.tar.gz | wc -l)" = 2 ]'
check "в архиве дамп, .env и список нод" 'tar -tzf "$(ls -1t "$T"/rw/backups/remnawave-*.tar.gz | head -1)" | grep -q remnawave.env && tar -tzf "$(ls -1t "$T"/rw/backups/remnawave-*.tar.gz | head -1)" | grep -q nodes.list'
check "архив закрыт от чужих (600)" '[ "$(stat -c %a "$(ls -1t "$T"/rw/backups/remnawave-*.tar.gz | head -1)")" = 600 ]'
check "архив отправлен в Telegram" 'grep -q "sendDocument" "$T/tg.log"'
check "результат записан для подсказки в меню" 'grep -q "|OK|Бэкап" /etc/rw/.backup_last'
out=$(bash -c "$common"'; backup_db(){ return 1; }; tg_api(){ echo "[tg $*]" >> "'"$T"'/tg2.log"; }; printf "TOKEN=1:x\nCHAT=5\n" > "$TG_CONF"; bk_run; echo "rc=$?"' 2>&1 | nocolor)
out_has "сбой бэкапа — код ошибки" "rc=1" "$out"
check "о сбое приходит в Telegram" 'grep -q "не удался" "$T/tg2.log"'
check "сбой виден в меню" 'grep -q "|FAIL|" /etc/rw/.backup_last'
out=$(bash -c "$common"'; bk_set SCHED daily; bk_install_cron; cat /etc/cron.d/remnapilot-backup; bk_set SCHED off; bk_install_cron; ls /etc/cron.d/remnapilot-backup 2>&1' 2>&1)
out_has "cron автобэкапа ставится" "30 3 * * * root RP_AUTO=1" "$out"
out_has "и снимается" "No such file" "$out"

# --- автообновление: режимы ---
run_au() { bash -c "$common"'
  rp_remote_version(){ echo 99.0 > /etc/rw/.latest_version; }; gh_latest(){ case "$1" in *backend) echo 2.3.0;; *) echo 2.2.4;; esac; }
  rp_fetch_latest(){ sed "s/^RP_VERSION=.*/RP_VERSION=\"99.0\"/" "'"$SCRIPT"'" > "$1"; }
  install(){ echo "[install $*]"; }; app_containers(){ echo remnawave; }; local_ver(){ echo 2.2.4; }; node_dir(){ return 1; }
  update_panel(){ echo "[update_panel]"; }; tg_api(){ echo "[tg $*]"; }
  echo '"$1"' > "$AU_CONF"; au_run; echo "rc=$?"; cat /etc/rw/.autoupdate_last' 2>&1 | nocolor; }
out=$(run_au check); out_has "check: только сообщает" "Доступен RemnaPilot v99.0" "$out"; check "check: ничего не ставит" '! grep -q "→" <<< "$out"'
out=$(run_au self);  out_has "self: ставит RemnaPilot" "RemnaPilot → v99.0" "$out"; check "self: панель не трогает" '! grep -q "Панель v" <<< "$out"'
out=$(run_au all);   out_has "all: обновляет и RemnaPilot, и панель" "RemnaPilot → v99.0. Панель v2.2.4 → v2.3.0" "$out"
rm -f /etc/rw/.autoupdate_last; out=$(run_au off); check "off: ничего не делает" '! grep -q "→" <<< "$out"'
out=$(bash -c "$common"'; echo check > "$AU_CONF"; au_install_cron; cat /etc/cron.d/remnapilot-update' 2>&1)
out_has "cron автообновления ночью" "4 * * * root RP_AUTO=1" "$out"
rm -f /etc/cron.d/remnapilot-update /etc/cron.d/remnapilot-backup /etc/rw/.backup_last /etc/rw/.autoupdate_last /etc/rw/.latest_version

# --- подсказки об обновлениях в меню ---
echo 99.0 > /etc/rw/.latest_version
out=$(bash -c "$common"'; update_hints' 2>&1 | nocolor)
out_has "подсказка о новой версии" "Доступен RemnaPilot v99.0" "$out"
rm -f /etc/rw/.latest_version

# --- оформление ---
out=$(bash -c "$common"'; for st in plain paren bracket dot circle; do UI_NUMS=$st; printf "[%s]" "$(num_fmt 3)"; done; UI_NUMS=circle; printf "[%s]" "$(num_fmt 25)"')
check "стили номеров" '[ "$out" = "[   3][  3)][ [3]][  3.][   ③][(25)]" ]'
out=$(TERM=xterm-256color bash -c "$common"'; C0=x; tput(){ echo 256; }; ui_set THEME forest; apply_ui; printf "%q" "$C_ACC"; ui_set THEME ocean; apply_ui; printf " %q" "$C_ACC"')
check "тема меняет цвета" '[[ "$out" == *"38;5;114m"*" "*"38;5;45m"* ]]'
finish
