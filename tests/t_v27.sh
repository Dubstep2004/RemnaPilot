# v2.7: удаление панели и ноды — подтверждение словом, бэкап перед удалением, ничего лишнего
source "$(dirname "$0")/lib.sh"
F=$(funcs)
run() { bash -c 'source "'"$F"'"; C_WARN= C_ACC= C0= C_MUT= C_OK= C_ERR= CB= C_LINE=; '"$1" 2>&1 | nocolor; }
mkdir -p "$T/bin"
printf '#!/bin/bash\necho "docker $*  [в $PWD]" >> "$CALLS"\ncase "$*" in *"ps -a --format"*) echo remnawave ;; esac\nexit 0\n' > "$T/bin/docker"
printf '#!/bin/sh\necho "acme $*" >> "$CALLS"\nexit 0\n' > "$T/bin/acme.sh"; chmod +x "$T/bin"/*
mkp() { # каталог панели с nginx и хуками продления
  rm -rf "$T/p" "$T/hooks" "$T/out"; mkdir -p "$T/p/nginx" "$T/p/backups" "$T/hooks" "$T/out"
  printf 'FRONT_END_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > "$T/p/.env"
  echo 'services: {}' > "$T/p/docker-compose.yml"; echo 'services: {}' > "$T/p/nginx/docker-compose.yml"
  printf 'server {\n  server_name panel.example.com;\n  ssl_certificate /etc/nginx/ssl/fullchain.pem;\n}\nserver {\n  server_name sub.example.com;\n  ssl_certificate /etc/nginx/ssl/fullchain.pem;\n}\n' > "$T/p/nginx/nginx.conf"
  touch "$T/hooks/panel.example.com-pre.sh" "$T/hooks/panel.example.com-post.sh" "$T/hooks/other.example.com-pre.sh"
  : > "$T/calls"
}
rm_panel() { CALLS="$T/calls" PATH="$T/bin:$PATH" run 'RW_DIR="'"${2:-$T/p}"'"; HOOK_DIR="'"$T"'/hooks"; RP_REMOVED_DIR="'"$T"'/out"; JOURNAL=/dev/null
  NODES_FILE=/nonexistent; BK_CONF="'"$T"'/bk.conf"; bk_install_cron(){ echo CRON-OFF; }; acme_bin(){ echo acme.sh; }
  backup_db(){ [ -n "$FAILBK" ] && { BK_ERR="password authentication failed"; return 1; }; echo dump | gzip > "$RW_DIR/backups/db-1-removed.sql.gz"; }
  printf "'"$1"'" | panel_uninstall; echo "rc=$?"'; }

mkp; o=$(rm_panel 'нет\n')
out_has "панель: без слова УДАЛИТЬ — отмена (код 10)" "rc=10" "$o"
check "…каталог на месте" '[ -f "$T/p/.env" ]'
check "…ничего не остановлено" '! grep -q "down" "$T/calls"'
out_has "панель: показано, что удалится (сертификаты)" "panel.example.com sub.example.com" "$o"

mkp; echo "SCHED=daily" > "$T/bk.conf"; o=$(rm_panel 'УДАЛИТЬ\n')
out_has "панель: удалена" "Панель удалена" "$o"
out_has "панель: 4 шага" "4/4" "$o"
check "панель: каталог удалён" '[ ! -e "$T/p" ]'
bk=$(ls "$T"/out/remnawave-removed-*.tar.gz 2>/dev/null | head -1)
check "панель: бэкап вне каталога панели" '[ -s "$bk" ]'
check "…в нём дамп, .env и конфиг nginx" 'l=$(tar -tzf "$bk"); grep -q "db-1-removed.sql.gz" <<< "$l" && grep -q "\.env" <<< "$l" && grep -q "nginx-nginx.conf" <<< "$l"'
check "…и он доступен только root" '[ "$(stat -c %a "$bk")" = 600 ]'
check "панель: контейнеры и тома удалены (down -v)" '[ "$(grep -c "compose -f .* down -v --rmi all" "$T/calls")" = 2 ]'
check "панель: сначала nginx, потом панель" 'grep "down -v" "$T/calls" | head -1 | grep -q "nginx/docker-compose.yml"'
check "панель: сертификаты удалены из acme.sh" 'grep -q "acme --remove -d panel.example.com" "$T/calls" && grep -q "acme --remove -d sub.example.com" "$T/calls"'
check "панель: хуки продления этих доменов удалены, чужие — нет" '[ ! -e "$T/hooks/panel.example.com-pre.sh" ] && [ -e "$T/hooks/other.example.com-pre.sh" ]'
has "панель: автобэкап выключен" "SCHED=off" "$T/bk.conf"

mkp; o=$(FAILBK=1 rm_panel 'УДАЛИТЬ\nнет\n')
out_has "панель: бэкап не получился — сказано почему" "Бэкап базы не получился: логин или пароль базы" "$o"
out_has "…и второе подтверждение, «нет» — отмена" "rc=10" "$o"
check "…каталог на месте" '[ -f "$T/p/.env" ]'
mkp; o=$(rm_panel 'DELETE\n'); out_has "панель: английское DELETE тоже принимается" "Панель удалена" "$o"
o=$(rm_panel 'УДАЛИТЬ\n' /opt); out_has "панель: системный каталог не удаляется" "удалять опасно" "$o"
o=$(rm_panel 'УДАЛИТЬ\n' "$T/nopanel"); out_has "панель: нет панели — понятная ошибка" "Панель не найдена" "$o"

# ───────── нода ─────────
N="$T/nodes.list"
rm_node() { run 'NODES_FILE="'"$N"'"; JOURNAL=/dev/null; node_dir(){ '"${LOCAL:-return 1}"'; }; local_node_port(){ echo 2222; }
  run_on(){ echo "RUN_ON $1" >> "'"$T"'/calls"; echo "${RESULT:-REMOVED /opt/remnanode}"; }
  printf "'"$1"'" | node_uninstall; echo "rc=$?"'; }
printf 'de-1 root@198.51.100.1 22\nnl-1 root@198.51.100.2 22\n' > "$N"
: > "$T/calls"; o=$(RESULT="REMOVED /opt/remnanode" rm_node '2\nУДАЛИТЬ\n')
out_has "нода по SSH: удалена" "Нода «nl-1» удалена" "$o"
has "…команда ушла на нужный сервер" "RUN_ON nl-1|root@198.51.100.2|22" "$T/calls"
check "…и убрана из списка, другая осталась" '! grep -q nl-1 "$N" && grep -q de-1 "$N"'
out_has "…напоминание удалить её в панели" "Ноды → нода → Удалить" "$o"
: > "$T/calls"; o=$(rm_node '1\nнет\n')
out_has "нода: без УДАЛИТЬ — отмена" "rc=10" "$o"
check "…на сервер ничего не ушло" '[ ! -s "$T/calls" ]'
printf 'de-1 root@198.51.100.1 22\nnl-1 root@198.51.100.2 22\n' > "$N"
o=$(rm_node 'a\n'); out_has "нода: «все сразу» — отказ" "по одной ноде" "$o"
o=$(LOCAL='echo /opt/remnanode' RESULT=NO_NODE_DIR rm_node '1\nУДАЛИТЬ\n')
out_has "нода здесь: уже нет — честно" "ноды уже нет" "$o"
o=$(LOCAL='echo /opt/remnanode' rm_node '1\nУДАЛИТЬ\n')
out_has "нода здесь: напоминание про порт firewall" "Правило firewall для порта 2222" "$o"
o=$(RESULT="ssh: connect to host x port 22: Connection refused" rm_node '1\nУДАЛИТЬ\n')
out_has "нода по SSH: нет связи — причина" "на этом порту не работает SSH" "$o"
check "…и из списка не убрана" 'grep -q de-1 "$N"'
# скрипт удаления: синтаксис и что он делает
s=$(run 'node_rm_script'); check "скрипт удаления ноды без ошибок sh" 'sh -n <<< "$s"'
out_has "скрипт удаления: down --rmi all" "down --rmi all" "$s"
# ───────── пункт «Обновить RemnaPilot» в главном меню ─────────
o=$(run 'echo 9.9 > "'"$T"'/lv"; cat(){ [[ "$1" == /etc/rw/.latest_version ]] && command cat "'"$T"'/lv" || command cat "$@"; }; item_info 40')
out_has "меню: «Обновить RemnaPilot» — доступна новая" "Обновить RemnaPilot|доступна v9.9" "$o"
o=$(run 'item_info 40'); check "меню: без новой версии — текущая" 'grep -q "сейчас v" <<< "$o"'
o=$(run 'for s in "${MENU_SECTIONS[@]}"; do echo "$s"; done'); check "меню: пункт в разделе «Прочее»" 'grep "^Прочее" <<< "$o" | grep -qw 40'
finish
