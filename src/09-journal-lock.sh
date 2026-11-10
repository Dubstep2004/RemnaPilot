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
  printf '%s · pid %s · запущено %s\n' "$name" "$$" "$(date +%H:%M)" > "$RP_LOCK.who" 2>/dev/null
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

journal_fmt() { # режим (all|fail|today), слово для поиска, сколько последних записей (0 — все) → по дням
  local mode="$1" word="$2" lim="${3:-0}" today yest
  today=$(date +%F); yest=$(date -d yesterday +%F 2>/dev/null || echo -)
  [[ -s "$JOURNAL" ]] || return 0
  perl -CSDA -ne 'BEGIN { $w = lc(shift // "") } chomp; print((($w eq "" || index(lc $_, $w) >= 0) ? 1 : 0), "\t", $_, "\n")' -- "$word" < "$JOURNAL" \
  | awk -F'\t' -v mode="$mode" -v lim="$lim" -v today="$today" -v yest="$yest" \
        -v cok="$C_OK" -v cerr="$C_ERR" -v cmut="$C_MUT" -v cacc="$C_ACC2$CB" -v cline="$C_LINE" -v c0="$C0" '
    function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    function trim(x) { sub(/^ +/, "", x); sub(/ +$/, "", x); return x }
    {
      m = $1; line = $2; n = split(line, f, "|"); if (n < 3) next
      ts = trim(f[1]); lvl = trim(f[2]); txt = f[3]; for (k = 4; k <= n; k++) txt = txt "|" f[k]; txt = trim(txt)
      d = substr(ts, 1, 10); t = substr(ts, 12, 8)
      if (lvl == "START") { open[txt] = NR; sd[NR] = d; st[NR] = t; R[NR] = 0; D[NR] = d; T[NR] = t; L[NR] = "START"; X[NR] = txt; Mt[NR] = m; next }
      # результат действия закрывает его START: «Имя» или «Имя (код N)»
      base = txt; sub(/ \(код [0-9]+\)$/, "", base)
      dur = ""
      if (base in open) { s0 = open[base]; delete open[base]; done[s0] = 1
        if (sd[s0] == d) { x = secs(t) - secs(st[s0]); if (x >= 60) dur = int(x / 60) " мин"; else if (x >= 10) dur = x " сек" } }
      D[NR] = d; T[NR] = t; L[NR] = lvl; X[NR] = txt; U[NR] = dur; Mt[NR] = m
    }
    END {
      cnt = 0
      for (i = 1; i <= NR; i++) {
        if (!(i in L)) continue
        if (L[i] == "START" && (i in done)) continue          # начато и закончено — показываем только итог
        if (!Mt[i]) continue
        if (mode == "fail" && L[i] != "FAIL" && L[i] != "START") continue
        if (mode == "today" && D[i] != today) continue
        keep[++cnt] = i
      }
      from = (lim > 0 && cnt > lim) ? cnt - lim + 1 : 1
      if (cnt == 0) { print "  " cmut "Записей нет." c0; exit }
      last = ""
      for (k = from; k <= cnt; k++) {
        i = keep[k]
        if (D[i] != last) {
          last = D[i]; split(D[i], q, "-")
          lab = (D[i] == today) ? "Сегодня, " q[3] "." q[2] : (D[i] == yest) ? "Вчера, " q[3] "." q[2] : q[3] "." q[2] "." q[1]
          printf "\n  %s%s%s\n", cacc, lab, c0
        }
        ic = "•"; col = ""; tail = ""
        if (L[i] == "OK")    { ic = "✔"; col = cok }
        if (L[i] == "FAIL")  { ic = "✖"; col = cerr }
        if (L[i] == "START") { ic = "⏸"; col = cmut; tail = " — прервано" }
        if (U[i] != "") tail = tail cmut " · " U[i] c0
        printf "   %s%s%s  %s%s %s%s%s\n", cmut, substr(T[i], 1, 5), c0, col, ic, X[i], c0, tail
      }
    }'
}

journal_menu() {
  local c n mode=all word="" all fails
  while true; do
    screen "Журнал действий"
    if [[ -s "$JOURNAL" ]]; then
      all=$(grep -cvE '\| START ' "$JOURNAL"); fails=$(grep -c '| FAIL' "$JOURNAL")
      printf '  %sВсего записей: %s · ошибок: %s%s\n' "$C_MUT" "$all" "$fails" "$C0"
      local f="все записи"; [[ $mode == fail ]] && f="только ошибки"; [[ $mode == today ]] && f="за сегодня"
      printf '  %sПоказано: %s%s · последние 20%s\n' "$C_MUT" "$f" "${word:+ · поиск «$word»}" "$C0"
      journal_fmt "$mode" "$word" 20
    else echo; echo "  Журнал пуст — сюда пишется каждое действие RemnaPilot."; fi
    echo; printf '  %sФайл: %s%s\n' "$C_MUT" "$JOURNAL" "$C0"
    section "ДЕЙСТВИЯ"
    item 1 "Листать весь журнал" "с текущим фильтром"
    item 2 "Только ошибки"
    item 3 "За сегодня"
    item 4 "Поиск по слову"
    [[ $mode != all || -n "$word" ]] && item 5 "Сбросить фильтр"
    item 6 "Очистить журнал"
    hr; item 0 "Назад"
    ask; read -r c
    case "$c" in
      1) journal_fmt "$mode" "$word" 0 | RP_PAGER_TOP= show_paged ;;
      2) mode=fail ;;
      3) mode=today ;;
      4) ask "Слово (например: сертификат, бэкап, ошибка)"; read -r word ;;
      5) mode=all; word="" ;;
      6) ask "Удалить все записи? Это нельзя отменить [y/N]"; read -r n; [[ "$n" =~ ^[Yy]$ ]] && : > "$JOURNAL" && green "✔ Журнал очищен"; pause ;;
      0|q|"") return ;;
    esac
  done
}

