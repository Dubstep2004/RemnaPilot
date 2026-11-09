# ---------- меню ----------
# Пункты меню: номер|название|подсказка. Номера внутренние, на экране — номера внутри раздела.
item_info() {
  case "$1" in
    1)  echo "Сменить домены|панель и/или подписка" ;;
    2)  echo "Удалить старые домены|алиасы и ненужные" ;;
    3)  echo "Предпросмотр смены|без изменений" ;;
    4)  echo "Откатить смену домена|" ;;
    5)  echo "Настройки и контейнеры|" ;;
    6)  echo "Обновления|панель · ноды · RemnaPilot" ;;
    7)  echo "Пересоздать контейнеры|" ;;
    8)  echo "Логи|" ;;
    9)  echo "Сертификаты|" ;;
    10) echo "Безопасность|секреты · БД · админ" ;;
    11) echo "Сделать бэкап|" ;;
    12) echo "Восстановить из дампа|" ;;
    13) echo "Установка и обновление нод|" ;;
    14) echo "Статус всех нод|CPU · RAM · диск · версия" ;;
    15) echo "Обновить geoip / geosite|" ;;
    16) echo "WARP на ноде|Cloudflare для ChatGPT и др." ;;
    17) echo "Firewall|ufw" ;;
    18) echo "Защита SSH|порт · fail2ban · ключи" ;;
    19) echo "Ускорение сети|BBR" ;;
    20) echo "Swap|если мало RAM" ;;
    21) echo "Время и часовой пояс|" ;;
    22) echo "Очистка диска|" ;;
    23) echo "Перенос панели на другой сервер|" ;;
    24) echo "Проверка IP сервера|РФ · пинг · скорость" ;;
    25) echo "Подбор SNI для Reality|" ;;
    26) echo "Журнал действий|" ;;
    27) echo "Language / Язык|$( [[ "$RP_LANG" == en ]] && echo English || echo Русский )" ;;
    28) echo "Установить команду rw|" ;;
    29) echo "Сменить каталог панели|$RW_DIR" ;;
    30) echo "О программе и версии|v$RP_VERSION" ;;
    31) echo "Вид меню|$( [[ "$(menu_mode)" == flat ]] && echo "полный список" || echo "разделы" )" ;;
    32) echo "Автобэкап|$(bk_sched_name "$(bk_get SCHED off)")" ;;
    33) echo "Оформление|тема · номера · логотип" ;;
    34) echo "Уведомления в Telegram|$(tg_on && echo подключено || echo выключено)" ;;
    35) echo "Удалить RemnaPilot|панель и ноды не трогаются" ;;
  esac
}

MENU_SECTIONS=(
  "Домены|смена · удаление · откат|1 2 3 4"
  "Панель|обновления · сертификаты · логи|5 6 7 8 9 10"
  "База|бэкап · автобэкап · восстановление|11 32 12"
  "Ноды|статус · geo · WARP|13 14 15 16"
  "Сервер|firewall · SSH · BBR · swap|17 18 19 20 21 22 23"
  "Проверки|IP · SNI для Reality|24 25"
  "Прочее|оформление · Telegram · язык|33 34 26 27 28 29 30 35"
)

menu_mode() { local m; m=$(cat /etc/rw/menu_mode 2>/dev/null); [[ "$m" == sections ]] && echo sections || echo flat; }

menu_mode_toggle() {
  mkdir -p /etc/rw
  if [[ "$(menu_mode)" == flat ]]; then echo sections > /etc/rw/menu_mode; else echo flat > /etc/rw/menu_mode; fi
}

print_item() { # номер_на_экране внутренний_номер
  local info hint; info=$(item_info "$2"); hint="${info#*|}"; [[ "${UI_HINTS:-on}" == off ]] && hint=""
  item "$1" "${info%%|*}" "$hint"
}

run_item() { # внутренний номер пункта → действие
  local ch="$1"
  case "$ch" in
    1|2|3|4|5|7|9|10|11|12|23) need_panel || { pause; return 1; } ;;
  esac
  case "$ch" in
    1|2|3|4|5|7|11|12|14|23|24|28|29) screen "$(case $ch in
        1) echo "Смена доменов";; 2) echo "Удаление доменов";; 3) echo "Предпросмотр смены доменов";; 4) echo "Откат смены домена";;
        5) echo "Настройки и контейнеры";; 7) echo "Пересоздание контейнеров";;
        11) echo "Бэкап базы";; 12) echo "Восстановление базы";; 14) echo "Статус всех нод";;
        23) echo "Перенос панели";; 24) echo "Проверка IP сервера";; 28) echo "Команда rw";; 29) echo "Каталог панели";;
      esac)"; echo ;;
  esac
  case "$ch" in
    1)  run_action "Смена доменов" change_domains 0; pause ;;
    2)  run_action "Удаление доменов" remove_domains; pause ;;
    3)  change_domains 1; pause ;;
    4)  run_action "Откат смены домена" rollback; pause ;;
    5)  show_current; pause ;;
    6)  update_menu ;;
    7)  run_action "Пересоздание контейнеров" restart_all; pause ;;
    8)  logs_menu ;;
    9)  cert_menu ;;
    10)  security_menu ;;
    11) run_action "Бэкап базы" backup_db; pause ;;
    12) run_action "Восстановление базы" restore_db; pause ;;
    13) node_menu ;;
    14) nodes_status; pause ;;
    15) run_action "geoip/geosite" geo_update; pause ;;
    16) warp_menu ;;
    17) firewall_menu ;;
    18) ssh_menu ;;
    19) net_menu ;;
    20) swap_menu ;;
    21) time_menu ;;
    22) cleanup_menu ;;
    23) run_action "Перенос панели" migrate_panel; pause ;;
    24) run_action "Проверка IP" ip_check; pause ;;
    25) sni_menu ;;
    26) journal_menu ;;
    27) lang_toggle ;;
    31) menu_mode_toggle ;;
    32) bk_menu ;;
    33) ui_menu ;;
    34) tg_menu ;;
    35) with_lock "Удаление RemnaPilot" rp_uninstall ;;
    28) install_cmd; pause ;;
    29) change_dir; pause ;;
    30) about_screen; pause ;;
    *) ;;
  esac
}

# ----- поиск по слову -----
MENU_PICK=""

lc_utf8() { perl -CSA -e 'print lc $ARGV[0]' -- "$1" 2>/dev/null || printf '%s' "${1,,}"; }   # нижний регистр для кириллицы без UTF-8-локали

all_items() { local x n; for x in "${MENU_SECTIONS[@]}"; do for n in ${x##*|}; do echo "$n"; done; done; }

menu_lookup() { # слово → MENU_PICK = внутренний номер пункта
  local q id name hint hits=() i c hay
  q=$(lc_utf8 "$1")
  MENU_PICK=""
  q="${q#"${q%%[![:space:]]*}"}"; q="${q%"${q##*[![:space:]]}"}"
  (( ${#q} >= 2 )) || return 1
  while read -r id; do
    IFS='|' read -r name hint <<< "$(item_info "$id")"
    hay=$(lc_utf8 "$name $hint $(T "$name") $(T "$hint")")
    [[ "$hay" == *"$q"* ]] && hits+=("$id")
  done < <(all_items)
  case ${#hits[@]} in
    0) yel "  Ничего не найдено: «$1»"; sleep 1; return 1 ;;
    1) MENU_PICK="${hits[0]}"; return 0 ;;
  esac
  section "НАЙДЕНО"
  for i in "${!hits[@]}"; do print_item $((i+1)) "${hits[$i]}"; done
  item 0 "Назад"
  ask; read -r c
  [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#hits[@]} )) && MENU_PICK="${hits[$((c-1))]}"
  [[ -n "$MENU_PICK" ]]
}

# ---------- живой статус ----------
# Пока меню открыто и ничего не вводится, раз в несколько секунд проверяем, изменилось ли то,
# что показывает рамка статуса; изменилось — перерисовываем экран. Без изменений экран не трогаем.
RP_STTY=""
tty_restore() { [[ -n "$RP_STTY" ]] && { stty "$RP_STTY" 2>/dev/null; RP_STTY=""; }; return 0; }
trap tty_restore EXIT

live_sig() { # отпечаток состояния: контейнеры (без «3 minutes ago»), файлы настроек, дата
  docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null \
    | sed -E 's/(About )?(an?|[0-9]+|Less than a) (second|minute|hour|day|week|month|year)s?( ago)?//g'
  stat -c '%n %Y %s' "$RW_DIR/.env" "$RW_DIR/nginx/fullchain.pem" "${NODES_FILE:-/etc/rw/nodes.list}" \
    /etc/rw/.latest_version /etc/rw/.latest_panel /etc/rw/.latest_node \
    /etc/rw/.autoupdate_last /etc/rw/.backup_last 2>/dev/null
  date +%F
}

buf_chop() { # убрать последний символ из buf (и в UTF-8, и в байтовой локали)
  local LC_ALL=C last
  while [[ -n "$buf" ]]; do last="${buf: -1}"; buf="${buf%?}"; [[ "$last" == [$'\x80'-$'\xbf'] ]] || break; done
}

tty_wait() { # секунд → 0, если в терминале есть ввод; 1 — тишина. Ничего не читает
  if command -v perl >/dev/null; then
    perl -e 'my $r = ""; vec($r, 0, 1) = 1; exit(select($r, undef, undef, $ARGV[0]) > 0 ? 0 : 1)' "$1" <&0
  else
    local i; for ((i = 0; i < $1 * 10; i++)); do read -t 0 2>/dev/null && return 0; sleep 0.1; done; return 1
  fi
}

menu_read() { # имя_переменной → 0: ввод готов; 2: статус изменился, экран надо перерисовать
  local -n _out="$1"; local iv="${UI_LIVE:-5}" buf="" k rc sig
  _out=""
  if [[ ! -t 0 || "$iv" == off || "${UI_STATUS:-full}" == off ]] || ! RP_STTY=$(stty -g 2>/dev/null) || [[ -z "$RP_STTY" ]]; then
    RP_STTY=""; read -r _out; return 0
  fi
  stty -echo -icanon min 1 time 0 2>/dev/null
  sig=$(live_sig)
  while true; do
    # Ждём ввода, ничего не забирая из терминала, и только потом читаем символ. У «read -t» есть гонка:
    # если клавиша приходит ровно в момент таймаута, bash её считывает и теряет.
    if read -t 0 2>/dev/null || tty_wait "$iv"; then IFS= read -rs -n1 k; rc=$?; else rc=142; fi
    if (( rc > 128 )); then                      # тишина: проверяем, не изменилось ли что-то
      [[ -n "$buf" ]] && continue                # человек печатает — не мешаем
      [[ "$(live_sig)" == "$sig" ]] && continue
      tty_restore; return 2
    fi
    if (( rc != 0 )); then tty_restore; echo; _out=0; return 0; fi   # терминал закрыт
    case "$k" in
      "")            # ввод «с запасом» (вставили несколько строк разом) отбрасываем: иначе он попал бы не в тот вопрос
                     while IFS= read -rs -n1 -t 0.001 k; do :; done
                     tty_restore; echo; _out="$buf"; return 0 ;;
      $'\x7f'|$'\b') [[ -n "$buf" ]] && { buf_chop; printf '\b \b'; } ;;
      $'\x15')       while [[ -n "$buf" ]]; do buf_chop; printf '\b \b'; done ;;
      $'\e')         # стрелки и F-клавиши — пропустить ровно одну последовательность
                     if tty_wait 0.05 && IFS= read -rs -n1 k && [[ "$k" == '[' || "$k" == O ]]; then
                       while tty_wait 0.05 && IFS= read -rs -n1 k; do [[ "$k" == [@-~] ]] && break; done
                     fi ;;
      [[:cntrl:]])   ;;
      *)             buf+="$k"; printf '%s' "$k" ;;
    esac
  done
}

menu_handle() { # ввод, массив номеров на экране (имя) → выполнить; 1 — выход/назад
  local ch="$1"; local -n _ids="$2"
  case "$ch" in 0|q|Q|й|Й) return 1 ;; "") return 0 ;; esac
  if [[ "$ch" =~ ^[0-9]+$ ]]; then
    (( ch >= 1 && ch <= ${#_ids[@]} )) || return 0
    case "${_ids[$((ch-1))]}" in s:*) section_menu "${_ids[$((ch-1))]#s:}" ;; *) run_item "${_ids[$((ch-1))]}" ;; esac
  elif menu_lookup "$ch"; then
    run_item "$MENU_PICK"
  fi
  return 0
}

section_menu() { # $1 = индекс раздела
  local name hint nums c n ids
  IFS='|' read -r name hint nums <<< "${MENU_SECTIONS[$1]}"
  while true; do
    clear; banner; echo
    status_box
    section "${name^^}"
    ids=()
    for n in $nums; do ids+=("$n"); print_item "${#ids[@]}" "$n"; done
    hr; item 0 "Назад"
    ask; menu_read c; (( $? == 2 )) && continue
    menu_handle "$c" ids || return
    [[ "$(menu_mode)" == flat ]] && return      # сменили вид меню — сразу показать
  done
}

menu() {
  local ch i n name hint nums ids
  while true; do
    apply_ui
    clear
    banner
    echo
    status_box
    ids=()
    if [[ "$(menu_mode)" == flat ]]; then
      # полный список: все пункты со сквозной нумерацией
      for i in "${!MENU_SECTIONS[@]}"; do
        IFS='|' read -r name hint nums <<< "${MENU_SECTIONS[$i]}"
        section "${name^^}"
        for n in $nums; do ids+=("$n"); print_item "${#ids[@]}" "$n"; done
      done
    else
      # разделы: на главном экране только они, пункты — внутри
      section "РАЗДЕЛЫ"
      for i in "${!MENU_SECTIONS[@]}"; do
        IFS='|' read -r name hint nums <<< "${MENU_SECTIONS[$i]}"
        ids+=("s:$i"); item "${#ids[@]}" "$name" "$( [[ "${UI_HINTS:-on}" == off ]] || echo "$hint")"
      done
    fi
    item 0 "Выход"; hr
    ask; menu_read ch; (( $? == 2 )) && continue
    menu_handle "$ch" ids || exit 0
  done
}

