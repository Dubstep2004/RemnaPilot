# ---------- самопроверка на реальном сервере (только чтение) ----------
rp_selftest() {
  local ok=0 warn=0 bad=0 v d
  st() { case "$1" in
    ok)   printf '   %s %s\n' "$(dot ok)" "$2"; ok=$((ok+1)) ;;
    warn) printf '   %s %s%s%s\n' "$(dot warn)" "$C_WARN" "$2" "$C0"; warn=$((warn+1)) ;;
    *)    printf '   %s %s%s%s\n' "$(dot err)" "$C_ERR" "$2" "$C0"; bad=$((bad+1)) ;;
  esac; }
  screen "Самопроверка"; echo
  echo "  Только проверяет — ничего не меняет."
  section "СИСТЕМА"
  [[ -r /etc/os-release ]] && st ok "$(. /etc/os-release; echo "$PRETTY_NAME")"
  (( BASH_VERSINFO[0] >= 5 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) && st ok "bash $BASH_VERSION" || st bad "bash $BASH_VERSION — нужен 4.4+"
  for v in perl openssl curl flock awk sed tar gzip; do command -v "$v" >/dev/null && st ok "$v" || st bad "нет $v"; done
  command -v python3 >/dev/null && st ok "python3" || st warn "нет python3 — лимиты логов Docker настроятся упрощённо"
  if systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1; then st ok "cron работает"; else st warn "cron не запущен — расписания включат его сами"; fi
  d=$(df -Pm / | awk 'NR==2{print $4}'); (( d > 2048 )) && st ok "свободно на диске: $d МБ" || st warn "мало места на диске: $d МБ"
  section "DOCKER"
  if command -v docker >/dev/null; then st ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"; else st bad "docker не установлен"; fi
  if docker compose version >/dev/null 2>&1; then st ok "docker compose $(docker compose version --short 2>/dev/null)"; else st bad "нет Docker Compose v2"; fi
  if [[ -f "$RW_DIR/.env" ]]; then
    st ok "панель: $RW_DIR"
    local DPS; dps_refresh
    while IFS='|' read -r n s; do      # не через конвейер — иначе счётчики итога не обновятся
      case "$s" in Up*unhealthy*|Restarting*) st warn "$n: $s" ;; Up*) st ok "$n: $s" ;; *) st bad "$n: $s" ;; esac
    done < <(awk -F'|' '$2 ~ /remna/ {print $2"|"$3}' <<< "$DPS")
  else st warn "панели нет в $RW_DIR (для сервера-ноды это нормально)"; fi
  node_dir >/dev/null 2>&1 && st ok "нода: $(node_dir)"
  section "СЕТЬ"
  for v in github.com api.telegram.org acme-v02.api.letsencrypt.org; do
    curl -fsS --max-time 8 -o /dev/null "https://$v" 2>/dev/null || curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "https://$v" 2>/dev/null | grep -q '^[1-5]' \
      && st ok "доступен $v" || st warn "нет связи с $v"
  done
  for v in 80 443; do
    if port_busy "$v"; then st ok "порт $v занят: $(port_owner "$v")"; else st warn "порт $v свободен (сертификат через него выпустится без остановки сервисов)"; fi
  done
  if [[ -f "$RW_DIR/.env" ]]; then
    local dom ip sip; dom=$(detect_old); sip=$(curl -4 -s --max-time 6 https://ifconfig.me)
    [[ -n "$dom" ]] && { ip=$(getent ahostsv4 "$dom" | awk 'NR==1{print $1}')
      if [[ -z "$ip" ]]; then st bad "$dom не резолвится"
      elif [[ "$ip" == "$sip" ]]; then st ok "$dom → $ip (этот сервер)"
      else st warn "$dom → $ip, а сервер $sip (норм, если за Cloudflare)"; fi; }
  fi
  section "ВРЕМЯ И СЕРТИФИКАТЫ"
  v=$(time_offset 2>/dev/null); [[ -n "$v" ]] && { (( ${v#-} <= 2 )) && st ok "часы точные (${v} с)" || st bad "часы спешат/отстают на ${v} с — Reality может не работать"; }
  acme_bin >/dev/null && st ok "acme.sh установлен" || st warn "acme.sh не установлен — поставится при первом выпуске"
  command -v socat >/dev/null && st ok "socat" || st warn "нет socat — поставится при выпуске через порт 80/443"
  section "ИТОГ"
  printf '   %s%d ок%s · %s%d предупреждений%s · %s%d ошибок%s\n' "$C_OK" "$ok" "$C0" "$C_WARN" "$warn" "$C0" "$C_ERR" "$bad" "$C0"
  (( bad )) && echo "   Исправь ошибки — иначе часть функций не сработает. Вывод можно прислать автору в Issue."
  return 0
}

# ---------- удаление RemnaPilot ----------
rp_uninstall() {
  local self ans dst arc
  self=$(readlink -f "$RP_SELF" 2>/dev/null)
  screen "Удаление RemnaPilot"; echo
  section "БУДЕТ УДАЛЕНО"
  echo "   ✖ команда rw (/usr/local/bin/rw)"
  [[ -f "$self" && "$self" != /usr/local/bin/rw ]] && echo "   ✖ файл скрипта $self"
  echo "   ✖ настройки RemnaPilot (/etc/rw): оформление, язык, список нод, Telegram"
  [[ -s "$BK_PASS" ]] && yel "   ⚠ пароль шифрования бэкапов (/etc/rw/backup.pass) — без него архивы из Telegram не открыть; проверь, что он у тебя записан"
  echo "   ✖ задачи по расписанию: автообновление, автобэкап, geo"
  echo "   ✖ журнал действий"
  section "ОСТАНЕТСЯ"
  echo "   ✔ панель Remnawave, ноды, база — работают как прежде"
  echo "   ✔ сертификаты и их автопродление"
  echo "   ✔ бэкапы базы в $RW_DIR/backups"
  echo "   ✔ настройки сервера: firewall, SSH, BBR, swap"
  echo
  dst="$RW_DIR/backups"; [[ -d "$dst" ]] || dst=/root
  if [[ -d /etc/rw ]]; then
    ask "Сохранить настройки и список нод в $dst, чтобы вернуть после переустановки? [Y/n]"; read -r ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      arc="$dst/remnapilot-settings-$(date +%Y%m%d-%H%M%S).tar.gz"
      tar -C /etc -czf "$arc" rw 2>/dev/null && chmod 600 "$arc" && green "✔ Сохранено: $arc"
    fi
  fi
  red "Для подтверждения введи YES"; ask; read -r ans
  [[ "$ans" == YES ]] || { echo "  Отменено."; return 0; }

  rm -f /etc/cron.d/remnapilot-update /etc/cron.d/remnapilot-backup /etc/cron.d/remnapilot-geo
  rm -rf /etc/rw /run/remnapilot; rm -f "$RP_LOCK" "$RP_LOCK.who"
  rm -f /var/log/remnapilot.log /var/log/remnapilot-cron.log /var/log/remnapilot-geo.log
  rm -f "$HOME/.rw-nocmd" /root/.rw-nocmd /usr/local/bin/rw
  if [[ -f "$self" && "$self" != /usr/local/bin/rw ]]; then
    ask "Удалить и файл $self? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] && rm -f "$self"
  fi
  echo; green "✔ RemnaPilot удалён. Спасибо, что пользовался!"
  echo "  Вернуть:  bash <(curl -sSL https://raw.githubusercontent.com/$RP_DEFAULT_SOURCE/main/remnapilot.sh)"
  [[ -n "$arc" && -f "$arc" ]] && echo "  Настройки после переустановки:  tar -C /etc -xzf $arc"
  exit 0
}

# ---------- оформление ----------
ui_preview() {
  section "ПРИМЕР"
  item 1 "Сменить домены" "панель и/или подписка"
  item 2 "Обновления" "панель · ноды"
}

ui_menu() {
  local c i t
  while true; do
    apply_ui
    screen "Оформление"; echo
    banner
    ui_preview
    section "НАСТРОЙКИ"
    item 1 "Тема" "$(theme_name "$UI_THEME")"
    item 2 "Номера пунктов" "$(num_fmt 1 | tr -d ' ')"
    item 3 "Логотип" "$(case $UI_LOGO in big) echo большой;; small) echo маленький;; none) echo без логотипа;; esac)"
    item 4 "Подсказки у пунктов" "$( [[ $UI_HINTS == off ]] && echo скрыты || echo показаны)"
    item 5 "Статус сервера" "$(case $UI_STATUS in full) echo рамка;; compact) echo одна строка;; off) echo скрыт;; esac)"
    item 6 "Вид меню" "$( [[ "$(menu_mode)" == flat ]] && echo "полный список" || echo "разделы" )"
    item 7 "Компактный режим" "$( [[ "$UI_COMPACT" == on ]] && echo "включён" || echo "выключен")"
    item 8 "Живой статус" "$( [[ "$UI_LIVE" == off ]] && echo "выключен" || echo "каждые $UI_LIVE с")"
    item 9 "Сбросить по умолчанию"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) section "ТЕМА"
         for i in "${!RP_THEMES[@]}"; do
           t="${RP_THEMES[$i]}"
           printf '  %s%s%s  %s  %s\n' "$C_ACC$CB" "$(num_fmt $((i+1)))" "$C0" "$(padr "$(theme_name "$t")" 8)" "$(theme_swatch "$t")"
         done
         ask; read -r c; [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#RP_THEMES[@]} )) && ui_set THEME "${RP_THEMES[$((c-1))]}" ;;
      2) section "НОМЕРА"
         local st=(plain paren bracket dot circle) ex=("1  2  3" "1)  2)  3)" "[1] [2] [3]" "1.  2.  3." "①  ②  ③")
         for i in "${!st[@]}"; do item $((i+1)) "${ex[$i]}"; done
         ask; read -r c; [[ "$c" =~ ^[1-5]$ ]] && ui_set NUMS "${st[$((c-1))]}" ;;
      3) section "ЛОГОТИП"; item 1 "Большой"; item 2 "Маленький" "одна строка"; item 3 "Без логотипа"
         ask; read -r c; case "$c" in 1) ui_set LOGO big;; 2) ui_set LOGO small;; 3) ui_set LOGO none;; esac ;;
      4) [[ "$UI_HINTS" == off ]] && ui_set HINTS on || ui_set HINTS off ;;
      5) section "СТАТУС"; item 1 "Рамка"; item 2 "Одна строка"; item 3 "Скрыть"
         ask; read -r c; case "$c" in 1) ui_set STATUS full;; 2) ui_set STATUS compact;; 3) ui_set STATUS off;; esac ;;
      6) menu_mode_toggle ;;
      7) [[ "$UI_COMPACT" == on ]] && ui_set COMPACT off || ui_set COMPACT on ;;
      8) section "ЖИВОЙ СТАТУС"; info "Рамка статуса сама обновляется, пока меню открыто"
         item 1 "Каждые 3 с"; item 2 "Каждые 5 с"; item 3 "Каждые 10 с"; item 4 "Каждые 30 с"; item 5 "Выключить"
         ask; read -r c; case "$c" in 1) ui_set LIVE 3;; 2) ui_set LIVE 5;; 3) ui_set LIVE 10;; 4) ui_set LIVE 30;; 5) ui_set LIVE off;; esac ;;
      9) rm -f "$UI_CONF"; rm -f /etc/rw/menu_mode ;;
      0|q|"") return ;;
    esac
  done
}

theme_swatch() { # цветные блоки темы
  local saved=("${GRAD[@]}") sa="$C_ACC" sb="$C_ACC2" out="" g
  local f; f=$(mktemp); printf 'THEME=%s\n' "$1" > "$f"
  UI_CONF="$f" apply_ui; for g in "${GRAD[@]}"; do out+="${g}██"; done; out+="$C0"
  rm -f "$f"; GRAD=("${saved[@]}"); C_ACC="$sa"; C_ACC2="$sb"
  printf '%s' "$out"
}

