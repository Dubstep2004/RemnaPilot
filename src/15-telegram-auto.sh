# ---------- Telegram ----------
TG_CONF="/etc/rw/telegram.conf"
tg_get() { grep -m1 "^$1=" "$TG_CONF" 2>/dev/null | cut -d= -f2-; }
tg_on()  { [[ -n "$(tg_get TOKEN)" && -n "$(tg_get CHAT)" ]]; }
tg_curl() { # токен, метод, аргументы curl… — адрес с токеном идёт через stdin, а не в командной строке (её видно в ps)
  local tok="$1" m="$2"; shift 2
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$tok" "$m" | curl -fsS --max-time 60 -K - "$@"
}
tg_api() { tg_curl "$(tg_get TOKEN)" "$@"; }
tg_text() { tg_on || return 0; tg_api sendMessage -d chat_id="$(tg_get CHAT)" --data-urlencode text="$1" >/dev/null 2>&1; }
tg_file() { # файл, подпись
  tg_on || return 0
  (( $(stat -c %s "$1") < 49000000 )) || { tg_text "$2 (файл больше 49 МБ — не отправлен)"; return 1; }
  tg_api sendDocument -F chat_id="$(tg_get CHAT)" -F document=@"$1" -F caption="$2" >/dev/null 2>&1
}

tg_setup() {
  local tok chat ans name
  echo "  1. В Telegram открой @BotFather → /newbot → получи токен."
  echo "  2. Напиши своему боту любое сообщение (например /start)."
  ask "Токен бота"; read -r tok; tok="${tok// /}"
  [[ "$tok" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { err "непохоже на токен бота"; return 1; }
  name=$(tg_curl "$tok" getMe 2>/dev/null | grep -oP '"username":"\K[^"]+')
  [[ -n "$name" ]] || { err "Telegram не принял токен (или нет связи с api.telegram.org)"; return 1; }
  info "Бот: @$name. Ищу твой чат..."
  chat=$(tg_curl "$tok" getUpdates 2>/dev/null | grep -oP '"chat":\{"id":\K-?[0-9]+' | tail -1)
  if [[ -z "$chat" ]]; then ask "Не нашёл сообщений боту. Напиши ему и нажми Enter (или введи chat_id)"; read -r ans
    chat="${ans:-$(tg_curl "$tok" getUpdates 2>/dev/null | grep -oP '"chat":\{"id":\K-?[0-9]+' | tail -1)}"; fi
  [[ "$chat" =~ ^-?[0-9]+$ ]] || { err "chat_id не найден"; return 1; }
  mkdir -p /etc/rw; printf 'TOKEN=%s\nCHAT=%s\n' "$tok" "$chat" > "$TG_CONF"; chmod 600 "$TG_CONF"
  if tg_text "✅ RemnaPilot подключён к этому чату ($(hostname))"; then green "✔ Готово — проверь сообщение в Telegram"
  else red "✖ Сообщение не отправилось — проверь токен и chat_id"; return 1; fi
  jlog INFO "Telegram подключён"
}

tg_menu() {
  local c
  while true; do
    screen "Уведомления в Telegram"; echo
    box_top
    if tg_on; then box_line "$(dot ok) подключено  ${C_MUT}chat $(tg_get CHAT)${C0}"; else box_line "$(dot off) ${C_MUT}не подключено${C0}"; fi
    box_bottom
    echo "  Сюда приходят: автобэкапы базы, результаты автообновления, ошибки."
    section "ДЕЙСТВИЯ"
    item 1 "Подключить бота"
    item 2 "Отправить тестовое сообщение"
    item 3 "Отключить"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Telegram: подключение" tg_setup; pause ;;
      2) tg_on && { tg_text "🔔 Тест RemnaPilot ($(hostname))" && green "✔ Отправлено" || red "✖ Не отправилось"; } || yel "Сначала подключи бота."; pause ;;
      3) rm -f "$TG_CONF"; yel "Telegram отключён."; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- автообновление ----------
AU_CONF="/etc/rw/autoupdate.conf"
au_mode() { local m; m=$(cat "$AU_CONF" 2>/dev/null); echo "${m:-check}"; }
au_mode_name() { case "$1" in off) echo "выключено";; check) echo "только проверять";; self) echo "RemnaPilot сам";; all) echo "всё сам (ночью, с бэкапом)";; esac; }

rp_bin() { [[ -x /usr/local/bin/rw ]] && echo /usr/local/bin/rw || echo "$RP_SELF"; }

ensure_cron() { # без демона cron файлы в /etc/cron.d ничего не делают
  if systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1; then return 0; fi
  command -v cron >/dev/null || command -v crond >/dev/null || pkg_install cron || pkg_install cronie || { yel "⚠ cron не установлен — расписание работать не будет (apt install cron)"; return 1; }
  systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1
  return 0
}

cron_log_cap() { # журнал cron-задач не больше 5 МБ
  local f=/var/log/remnapilot-cron.log
  [[ -f "$f" ]] && (( $(stat -c %s "$f") > 5242880 )) && tail -c 1048576 "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  return 0
}

au_install_cron() { # раз в сутки, в случайную минуту 4-го часа — чтобы не было пика на GitHub
  local m=$(( RANDOM % 50 + 5 ))
  if [[ "$(au_mode)" == off ]]; then rm -f /etc/cron.d/remnapilot-update; return; fi
  ensure_cron
  echo "$m 4 * * * root RP_AUTO=1 bash $(rp_bin) --auto-update >> /var/log/remnapilot-cron.log 2>&1" > /etc/cron.d/remnapilot-update
  chmod 644 /etc/cron.d/remnapilot-update
}

au_check_all() { # обновить кэш последних версий (RemnaPilot, панель, нода)
  mkdir -p /etc/rw
  rm -f /etc/rw/.latest_version; rp_remote_version >/dev/null 2>&1
  local v
  v=$(gh_latest remnawave/backend); [[ -n "$v" ]] && echo "$v" > /etc/rw/.latest_panel
  v=$(gh_latest remnawave/node);    [[ -n "$v" ]] && echo "$v" > /etc/rw/.latest_node
  return 0
}

au_run() { # то, что делает cron
  local mode msg="" rc=0 lv lp ln app pv nv t
  mode=$(au_mode); [[ "$mode" == off ]] && return 0
  cron_log_cap
  au_check_all
  lv=$(cat /etc/rw/.latest_version 2>/dev/null); lp=$(cat /etc/rw/.latest_panel 2>/dev/null); ln=$(cat /etc/rw/.latest_node 2>/dev/null)
  if [[ "$mode" == self || "$mode" == all ]] && ver_newer "$RP_VERSION" "$lv"; then
    t=$(mktemp)
    if rp_fetch_latest "$t" && (( RP_FETCH_VERIFIED )) && RP_AUTO=1 self_update "$t" >/dev/null 2>&1; then msg+="RemnaPilot → v$lv. "
    elif (( RP_FETCH_BAD )); then msg+="RemnaPilot: контрольная сумма не совпала — обновление отменено. "; rc=1
    elif [[ -s "$t" ]] && (( ! RP_FETCH_VERIFIED )); then msg+="RemnaPilot v$lv: без контрольной суммы — обнови вручную. "
    else msg+="RemnaPilot: ошибка обновления. "; rc=1; fi
    rm -f "$t"
  fi
  if [[ "$mode" == all ]]; then
    if [[ -f "$RW_DIR/.env" ]]; then
      app=$(app_containers | head -1); pv=$(local_ver "$app")
      if ver_newer "$pv" "$lp"; then
        UPD_LOG=""; if update_panel 1 >/dev/null 2>&1; then msg+="Панель v$pv → v$lp. "; else msg+="Панель: ошибка обновления — откати: Панель → Обновления → 6. "; rc=1; fi
      fi
    fi
    if node_dir >/dev/null 2>&1; then
      nv=$(local_ver remnanode)
      if ver_newer "$nv" "$ln"; then UPD_LOG=""; update_local_node >/dev/null 2>&1 && msg+="Нода v$nv → v$ln. " || { msg+="Нода: ошибка обновления. "; rc=1; }; fi
    fi
  elif [[ "$mode" == check ]]; then
    ver_newer "$RP_VERSION" "$lv" && msg+="Доступен RemnaPilot v$lv. "
    [[ -f "$RW_DIR/.env" ]] && { app=$(app_containers | head -1); pv=$(local_ver "$app"); ver_newer "$pv" "$lp" && msg+="Доступна панель v$lp. "; }
  fi
  printf '%s|%s|%s\n' "$(date '+%d.%m %H:%M')" "$( ((rc)) && echo FAIL || echo OK)" "${msg:-Всё актуально}" > /etc/rw/.autoupdate_last
  jlog "$( ((rc)) && echo FAIL || echo INFO)" "Автообновление: ${msg:-всё актуально}"
  [[ -n "$msg" ]] && tg_text "$( ((rc)) && echo "⚠️" || echo "🔄") $(hostname): $msg"
  return $rc
}

au_menu() {
  local c last
  while true; do
    screen "Автообновление"; echo
    last=$(cat /etc/rw/.autoupdate_last 2>/dev/null)
    box_top
    box_line "${C_MUT}$(padr "Режим" 11)${C0}${CB}$(au_mode_name "$(au_mode)")${C0}"
    box_line "${C_MUT}$(padr "Когда" 11)${C0}$( [[ -f /etc/cron.d/remnapilot-update ]] && echo "каждую ночь в $(awk '{printf "04:%02d", $1}' /etc/cron.d/remnapilot-update)" || echo "—")"
    [[ -n "$last" ]] && box_line "${C_MUT}$(padr "Последний" 11)${C0}$(cut -d'|' -f1 <<< "$last")  $(cut -d'|' -f3 <<< "$last")"
    box_line "${C_MUT}$(padr "Telegram" 11)${C0}$(tg_on && echo "$(dot ok) отчёты приходят" || echo "$(dot off) ${C_MUT}не подключён${C0}")"
    box_bottom
    section "РЕЖИМ"
    item 1 "Выключено"
    item 2 "Только проверять" "подсказка в меню и в Telegram"
    item 3 "Обновлять RemnaPilot сам"
    item 4 "Обновлять всё сам" "панель и ноду — с бэкапом базы"
    section "ДЕЙСТВИЯ"
    item 5 "Проверить сейчас"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1|2|3|4) local m; m=$(case $c in 1) echo off;; 2) echo check;; 3) echo self;; 4) echo all;; esac)
         if [[ "$m" == all ]]; then
           yel "Панель будет обновляться без тебя. Перед каждым обновлением — бэкап базы, при сбое — уведомление и откат вручную."
           ask "Включить? [y/N]"; read -r a; [[ "$a" =~ ^[Yy]$ ]] || continue
         fi
         mkdir -p /etc/rw; echo "$m" > "$AU_CONF"; au_install_cron
         green "✔ Автообновление: $(au_mode_name "$m")"; jlog INFO "Автообновление: $m"; pause ;;
      5) info "Проверяю..."; au_check_all; printf '\e[1A\e[2K'; update_hints; [[ -z "$(update_hints)" ]] && green "✔ Всё актуально"; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- автобэкап ----------
BK_CONF="/etc/rw/backup.conf"
bk_get() { local v; v=$(grep -m1 "^$1=" "$BK_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
bk_set() { mkdir -p /etc/rw; touch "$BK_CONF"; if grep -q "^$1=" "$BK_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$BK_CONF"; else echo "$1=$2" >> "$BK_CONF"; fi; }
bk_sched_name() { case "$1" in daily) echo "каждый день в 03:30";; 12h) echo "каждые 12 часов";; weekly) echo "раз в неделю (вс 03:30)";; *) echo "выключен";; esac; }

bk_install_cron() {
  local when
  case "$(bk_get SCHED off)" in
    daily)  when="30 3 * * *" ;; 12h) when="30 3,15 * * *" ;; weekly) when="30 3 * * 0" ;;
    *) rm -f /etc/cron.d/remnapilot-backup; return ;;
  esac
  ensure_cron
  echo "$when root RP_AUTO=1 bash $(rp_bin) --backup >> /var/log/remnapilot-cron.log 2>&1" > /etc/cron.d/remnapilot-backup
  chmod 644 /etc/cron.d/remnapilot-backup
}

bk_run() { # бэкап по расписанию: дамп + .env + список нод → один архив, хранение N, отправка в Telegram
  local keep dump arc tmp rc=0 sz
  keep=$(bk_get KEEP 7)
  cron_log_cap
  need_panel >/dev/null 2>&1 || { echo "$(date '+%d.%m %H:%M')|FAIL|Автобэкап: панель не найдена" > /etc/rw/.backup_last; return 1; }
  if ! backup_db auto >/dev/null 2>&1; then
    printf '%s|FAIL|Автобэкап базы не удался\n' "$(date '+%d.%m %H:%M')" > /etc/rw/.backup_last
    jlog FAIL "Автобэкап базы не удался"; tg_text "⚠️ $(hostname): автобэкап базы не удался"; return 1
  fi
  dump=$(ls -1t "$RW_DIR"/backups/db-*-auto.sql.gz | head -1)
  tmp=$(mktemp -d); cp "$dump" "$tmp/"; cp "$RW_DIR/.env" "$tmp/remnawave.env"
  [[ -s "$NODES_FILE" ]] && cp "$NODES_FILE" "$tmp/nodes.list"
  arc="$RW_DIR/backups/remnawave-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
  if ! tar -C "$tmp" -czf "$arc" . 2>/dev/null; then
    rm -rf "$tmp"; rm -f "$arc"
    printf '%s|FAIL|Автобэкап: не удалось собрать архив (нет места на диске?)\n' "$(date '+%d.%m %H:%M')" > /etc/rw/.backup_last
    jlog FAIL "Автобэкап: не удалось собрать архив"; tg_text "⚠️ $(hostname): автобэкап не удался — не собрался архив (проверь место на диске)"; return 1
  fi
  chmod 600 "$arc"; rm -rf "$tmp"
  # хранить последние N архивов и автодампов
  ls -1t "$RW_DIR"/backups/remnawave-*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
  ls -1t "$RW_DIR"/backups/db-*-auto.sql.gz 2>/dev/null | tail -n +$((keep + 1)) | while read -r f; do rm -f "$f" "${f%.sql.gz}.env"; done
  sz=$(du -h "$arc" | cut -f1)
  local tgst=""
  if tg_on; then
    case "$(bk_get ENC "")" in
      on)  local enc="$arc.enc"
           if bk_encrypt "$arc" "$enc"; then
             tg_file "$enc" "💾🔒 $(hostname): бэкап Remnawave $(date '+%d.%m %H:%M'), $sz — зашифрован" && tgst=", 🔒 отправлен в Telegram" || { rc=1; tgst=", в Telegram не отправился"; }
           else rc=1; tgst=", не удалось зашифровать"; fi
           rm -f "$enc" ;;
      off) tg_file "$arc" "💾 $(hostname): бэкап Remnawave $(date '+%d.%m %H:%M'), $sz" && tgst=", отправлен в Telegram" || { rc=1; tgst=", в Telegram не отправился"; } ;;
      *)   # пароль не задан — архив с секретами в открытом виде не отправляем
           tg_text "💾 $(hostname): бэкап сделан ($sz), но в Telegram не отправлен — задай пароль шифрования: rw → База → Автобэкап → Шифрование"
           tgst=", в Telegram не отправлен — задай пароль шифрования" ;;
    esac
  fi
  printf '%s|%s|Бэкап %s%s\n' "$(date '+%d.%m %H:%M')" "$( ((rc)) && echo FAIL || echo OK)" "$sz" "$tgst" > /etc/rw/.backup_last
  jlog "$( ((rc)) && echo FAIL || echo OK)" "Автобэкап: $(basename "$arc") ($sz)"
  return $rc
}

# ----- шифрование архивов для Telegram -----
BK_PASS="/etc/rw/backup.pass"
bk_encrypt() { openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$BK_PASS" -in "$1" -out "$2" 2>/dev/null; }

bk_enc_setup() {
  local a p1 p2
  echo "  Архив для Telegram будет зашифрован паролем (AES-256). Без пароля его не открыть —"
  echo "  даже если чат или аккаунт Telegram взломают."
  yel "  ⚠ Сохрани пароль в менеджере паролей: если сервер сгорит, без пароля бэкап бесполезен."
  echo
  item 1 "Придумать пароль самому"
  item 2 "Сгенерировать надёжный"
  item 3 "Не шифровать" "архив уйдёт в Telegram как есть"
  item 0 "Отмена"
  ask; read -r a; echo
  case "$a" in
    1) read -rsp "  Пароль (от 10 символов): " p1; echo; read -rsp "  Ещё раз: " p2; echo
       [[ "$p1" == "$p2" ]] || { err "пароли не совпали"; return 1; }
       (( ${#p1} >= 10 )) || { err "пароль короче 10 символов"; return 1; }
       mkdir -p /etc/rw; ( umask 077; printf '%s' "$p1" > "$BK_PASS" ); bk_set ENC on
       green "✔ Шифрование включено" ;;
    2) p1=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
       mkdir -p /etc/rw; ( umask 077; printf '%s' "$p1" > "$BK_PASS" ); bk_set ENC on
       green "✔ Шифрование включено. Пароль (запиши его сейчас):"; echo; printf '      %s%s%s\n\n' "$CB" "$p1" "$C0" ;;
    3) bk_set ENC off; rm -f "$BK_PASS"; yel "Шифрование выключено — в архиве секреты панели." ;;
    *) return 0 ;;
  esac
  echo "  Расшифровать архив:  rw --decrypt файл.tar.gz.enc"
  jlog INFO "Шифрование бэкапов: $(bk_get ENC "")"
}

bk_enc_name() { case "$(bk_get ENC "")" in on) echo "$(dot ok) включено";; off) echo "$(dot warn) ${C_WARN}выключено${C0}";; *) echo "$(dot err) ${C_ERR}не настроено${C0}";; esac; }

bk_decrypt() { # файл .enc → рядом без .enc
  local f="$1" out="${1%.enc}" p
  [[ -f "$f" ]] || { err "файл не найден: $f"; return 1; }
  [[ "$out" == "$f" ]] && out="$f.dec"
  if [[ -s "$BK_PASS" ]]; then
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$BK_PASS" -in "$f" -out "$out" 2>/dev/null && { green "✔ Расшифровано: $out"; echo "  Распаковать:  tar -xzf $out"; return 0; }
  fi
  read -rsp "Пароль бэкапа: " p; echo
  if printf '%s' "$p" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass stdin -in "$f" -out "$out" 2>/dev/null; then
    green "✔ Расшифровано: $out"; echo "  Распаковать:  tar -xzf $out"
  else rm -f "$out"; red "✖ Неверный пароль или файл повреждён"; return 1; fi
}

bk_menu() {
  local c last n
  while true; do
    screen "Автобэкап"; echo
    last=$(cat /etc/rw/.backup_last 2>/dev/null)
    box_top
    box_line "${C_MUT}$(padr "Расписание" 11)${C0}${CB}$(bk_sched_name "$(bk_get SCHED off)")${C0}"
    box_line "${C_MUT}$(padr "Хранить" 11)${C0}последние $(bk_get KEEP 7)"
    [[ -n "$last" ]] && box_line "${C_MUT}$(padr "Последний" 11)${C0}$(cut -d'|' -f1 <<< "$last")  $(cut -d'|' -f3 <<< "$last")"
    box_line "${C_MUT}$(padr "Telegram" 11)${C0}$(tg_on && echo "$(dot ok) архив приходит в чат" || echo "$(dot off) ${C_MUT}не подключён${C0}")"
    tg_on && box_line "${C_MUT}$(padr "Шифрование" 11)${C0}$(bk_enc_name)"
    box_bottom
    echo "  В архиве: дамп базы, .env панели и список нод."
    if tg_on && [[ -z "$(bk_get ENC "")" ]]; then
      yel "  ⚠ В Telegram архив не уходит, пока не задан пароль шифрования — пункт 8."
    fi
    section "РАСПИСАНИЕ"
    item 1 "Выключить"
    item 2 "Каждый день"
    item 3 "Каждые 12 часов"
    item 4 "Раз в неделю"
    section "ДЕЙСТВИЯ"
    item 5 "Сколько хранить"
    item 6 "Telegram" "отправка архива в чат"
    item 7 "Сделать бэкап сейчас" "как по расписанию"
    item 8 "Шифрование для Telegram" "$(bk_enc_name)"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1|2|3|4) bk_set SCHED "$(case $c in 1) echo off;; 2) echo daily;; 3) echo 12h;; 4) echo weekly;; esac)"; bk_install_cron
         green "✔ Автобэкап: $(bk_sched_name "$(bk_get SCHED off)")"; jlog INFO "Автобэкап: $(bk_get SCHED off)"; pause ;;
      5) ask "Сколько последних бэкапов хранить [$(bk_get KEEP 7)]"; read -r n
         [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 365 )) && { bk_set KEEP "$n"; green "✔ Хранить: $n"; }; pause ;;
      6) tg_menu ;;
      8) run_action "Шифрование бэкапов" bk_enc_setup; pause ;;
      7) info "Делаю бэкап..."; if run_action "Автобэкап вручную" bk_run; then green "✔ $(cut -d'|' -f3 /etc/rw/.backup_last)"; else red "✖ $(cut -d'|' -f3 /etc/rw/.backup_last)"; fi; pause ;;
      0|q|"") return ;;
    esac
  done
}

