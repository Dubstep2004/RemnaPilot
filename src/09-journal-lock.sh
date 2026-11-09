# ---------- журнал ----------
JOURNAL="/var/log/remnapilot.log"

jlog() { # уровень (OK|FAIL|INFO|START), текст
  printf '%s | %-5s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$JOURNAL" 2>/dev/null
}

# ---------- блокировка: одно изменяющее действие за раз ----------
RP_LOCK="/run/remnapilot.lock"
RP_LOCKED=""

with_lock() { # название, команда… — выполнить, пока никто другой (меню, cron) ничего не меняет
  local name="$1" rc who; shift
  if [[ -n "$RP_LOCKED" ]] || ! command -v flock >/dev/null; then "$@"; return; fi
  { exec 8>"$RP_LOCK"; } 2>/dev/null || { "$@"; return; }     # 2>/dev/null именно снаружи: иначе exec навсегда отключит вывод ошибок
  if ! flock -n 8; then
    who=$(cat "$RP_LOCK.who" 2>/dev/null)
    if [[ -n "${RP_AUTO:-}" ]]; then
      flock -w 1800 8 || { exec 8>&-; return 75; }          # задача по расписанию ждёт до 30 минут
    else
      yel "⏳ Сейчас выполняется: ${who:-другая копия RemnaPilot}. Жду, пока закончится…"
      flock -w 900 8 || { exec 8>&-; red "✖ Не дождался — попробуй позже"; return 75; }
    fi
  fi
  printf '%s · pid %s · с %s\n' "$name" "$$" "$(date +%H:%M)" > "$RP_LOCK.who" 2>/dev/null
  RP_LOCKED=1; "$@"; rc=$?; RP_LOCKED=""
  rm -f "$RP_LOCK.who"; flock -u 8; exec 8>&-
  return $rc
}

lock_timeout() { # название, файл результата — задача по расписанию не дождалась очереди: не молчим
  local who; who=$(cat "$RP_LOCK.who" 2>/dev/null)
  mkdir -p /etc/rw
  printf '%s|FAIL|%s не выполнен: 30 минут было занято (%s)\n' "$(date '+%d.%m %H:%M')" "$1" "${who:-другое действие RemnaPilot}" > "$2"
  jlog FAIL "$1: не дождался очереди (${who:-другое действие})"
  tg_text "⚠️ $(hostname): $1 не выполнен — 30 минут было занято: ${who:-другое действие RemnaPilot}"
  return 0
}

run_action() { # название, команда… — журнал + блокировка
  local name="$1" rc; shift
  jlog START "$name"
  with_lock "$name" "$@"; rc=$?
  if (( rc )); then jlog FAIL "$name (код $rc)"; else jlog OK "$name"; fi
  return $rc
}

journal_menu() {
  local c n
  while true; do
    screen "Журнал действий"; echo
    if [[ -s "$JOURNAL" ]]; then
      tail -n 25 "$JOURNAL" | while IFS= read -r l; do
        case "$l" in
          *"| FAIL "*)  printf '  %s%s%s\n' "$C_ERR"  "$l" "$C0" ;;
          *"| OK "*)    printf '  %s%s%s\n' "$C_OK"   "$l" "$C0" ;;
          *"| START "*) printf '  %s%s%s\n' "$C_MUT"  "$l" "$C0" ;;
          *)            printf '  %s\n' "$l" ;;
        esac
      done
    else echo "  Журнал пуст."; fi
    echo; echo "  Файл: $JOURNAL"
    section "ДЕЙСТВИЯ"
    item 1 "Весь журнал"
    item 2 "Только ошибки"
    item 3 "Очистить журнал"
    hr; item 0 "Назад"
    ask; read -r c
    case "$c" in
      1) [[ -f "$JOURNAL" ]] && show_paged < "$JOURNAL" ;;
      2) grep -F '| FAIL' "$JOURNAL" 2>/dev/null | show_paged ;;
      3) ask "Удалить все записи? [y/N]"; read -r n; [[ "$n" =~ ^[Yy]$ ]] && : > "$JOURNAL" && green "✔ Журнал очищен"; pause ;;
      0|q|"") return ;;
    esac
  done
}

