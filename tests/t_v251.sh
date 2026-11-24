# v2.5.1: точные объяснения ошибок, отмена не считается успехом, ожидание ввода без perl, справка EN
source "$(dirname "$0")/lib.sh"
F=$(funcs)
run() { bash -c 'source "'"$F"'"; C_WARN= C_ACC= C0= C_MUT=; '"$1" 2>&1 | nocolor; }

# --- 1. строки про миграции есть в каждом запуске Remnawave — это не повод советовать откат ---
o=$(run "why container \$'Running migrations...\nNo pending migrations to apply.\n[Nest] ERROR TypeError: Cannot read properties of undefined (reading \"xray\")'")
check "обычный лог с миграциями + другая ошибка — не «миграция»" '! grep -q "миграция" <<< "$o"'
o=$(run "why container \$'Error: P3009 migrate found failed migrations in the target database'")
out_has "настоящий сбой миграции (P3009) — «миграция»" "не прошла миграция" "$o"
o=$(run "why container \$'Migration \`20261101_add_nodes\` failed to apply cleanly to the shadow database.'")
out_has "«Migration … failed» — «миграция»" "не прошла миграция" "$o"

# --- 2. Redis — не база данных ---
o=$(run "why container '[Nest] ERROR [RedisService] Error: connect ECONNREFUSED 172.18.0.3:6379'")
check "ECONNREFUSED :6379 — не «база данных»" '! grep -q "базы данных" <<< "$o"'
out_has "…а Redis" "Redis" "$o"
o=$(run "why container 'Error: connect ECONNREFUSED 172.18.0.2:5432'")
out_has "ECONNREFUSED :5432 — база данных" "до базы данных" "$o"

# --- 3. отмена: в журнале «отменено», а не успех; код выхода не 0 ---
J="$T/j.log"; D="$T/p"; mkdir -p "$D"; echo 'FRONT_END_DOMAIN=a.example.com' > "$D/.env"
o=$(run "RW_DIR='$D'; JOURNAL='$J'; RP_LOCK='$D/l'; check_dns(){ DNS_WARN=1; return 1; }; find_files(){ echo '$D/.env'; }
  run_action 'Смена домена' change_domain b.example.com '' 0 </dev/null; echo rc=\$?")
check "отмена смены домена → код не 0" '! grep -q "rc=0" <<< "$o"'
check "отмена не записана как успех" '! grep -q "| OK    | Смена домена" "$J"'
has "в журнале — «отменено»" "Смена домена (отменено)" "$J"
check ".env не изменился" 'grep -q "a.example.com" "$D/.env"'
o=$(run "JOURNAL='$J'; journal_fmt all '' 20")
check "журнал: отмена закрывает START (не «прервано»)" '! grep -q "прервано" <<< "$o"'
out_has "журнал: значок отмены" "– Смена домена (отменено)" "$o"
o=$(run "RW_DIR='$D'; touch '$D/.env'; need_panel(){ :; }; app_containers(){ echo remnawave; }; local_ver(){ echo 1; }
  docker(){ :; }; backup_db(){ return 1; }; pull_up(){ echo PULLED; }
  script -qc 'bash -c \"source $F; RW_DIR=$D; need_panel(){ :; }; app_containers(){ echo r; }; local_ver(){ :; }; docker(){ :; }; backup_db(){ return 1; }; pull_up(){ echo PULLED; }; update_panel; echo rc=\\\$?\"' /dev/null <<< n")
check "«продолжить без бэкапа? — нет» → не обновляет" '! grep -q PULLED <<< "$o"'
check "…и код не 0 (это не успех)" 'grep -q "rc=10" <<< "$o"'

# --- 4. ожидание ввода без perl (дробные секунды) ---
o=$( (sleep 1) | bash -c 'source "'"$F"'"; command(){ [[ "$2" == perl ]] && return 1; builtin command "$@"; }; tty_wait 0.05; echo rc=$?' 2>&1)
check "tty_wait без perl: нет ошибки bash" '! grep -q "syntax error" <<< "$o"'
out_has "tty_wait без perl: тишина — 1" "rc=1" "$o"
o=$(printf x | bash -c 'source "'"$F"'"; command(){ [[ "$2" == perl ]] && return 1; builtin command "$@"; }; tty_wait 0.3; echo rc=$?')
out_has "tty_wait без perl: ввод есть — 0" "rc=0" "$o"

# --- 5. справка на английском в терминале — с цветами; Cloudflare — без противоречия ---
o=$(TERM=xterm-256color script -qc "bash '$SCRIPT' --help --lang en" /dev/null 2>&1)
check "EN-справка в терминале цветная" 'grep -q $'"'"'\e\['"'"' <<< "$o"'
o=$(TERM=xterm-256color script -qc "bash '$SCRIPT' --help" /dev/null 2>&1)
check "RU-справка в терминале цветная" 'grep -q $'"'"'\e\['"'"' <<< "$o"'
o=$(bash "$SCRIPT" --help --lang en 2>&1 | cat)
check "справка в файл/канал — без цветов" '! grep -q $'"'"'\e\['"'"' <<< "$o"'
o=$(run 'curl(){ echo 203.0.113.9; }; getent(){ echo "104.16.1.1 STREAM x"; }; DNS_WARN=""; check_dns x.example.com; dns_confirm <<< n; echo rc=$?')
check "Cloudflare: нет «ок» рядом с «не откроется»" '! { grep -q "ок, если" <<< "$o" && grep -q "не откроется" <<< "$o"; }'
out_has "Cloudflare: вопрос задаётся" "Всё равно применить" "$o"
# --- новый Docker (containerd) пишет про несуществующую версию иначе, чем «manifest unknown» ---
o=$(run "why docker 'Error response from daemon: failed to resolve reference \"docker.io/remnawave/backend:9.99.99-does-not-exist\": docker.io/remnawave/backend:9.99.99-does-not-exist: not found'")
out_has "новый Docker: «failed to resolve reference … not found» → нет такой версии" "такой версии образа нет" "$o"
o=$(run "why docker 'Error response from daemon: manifest for remnawave/backend:9.9 not found: manifest unknown'")
out_has "старый Docker: «manifest unknown» → нет такой версии" "такой версии образа нет" "$o"
o=$(run "why docker 'failed to resolve reference \"docker.io/remnawave/backend:2.3\": failed to do request: Head \"https://registry-1.docker.io/v2/remnawave/backend/manifests/2.3\": dial tcp: i/o timeout'")
check "нет связи с Docker Hub — не «нет такой версии»" '! grep -q "такой версии" <<< "$o" && grep -q "Docker Hub не отвечает" <<< "$o"'

finish
