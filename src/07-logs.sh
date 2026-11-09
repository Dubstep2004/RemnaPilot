# ---------- логи ----------
ERR_RE='error|fatal|exception|panic|fail(ed)?|refused|denied|timeout|unhealthy|warn|critical|crash'

show_paged() {
  local tr=(cat); [[ "$RP_LANG" == en ]] && tr=(rp_translate)
  if command -v less >/dev/null && { : >/dev/tty; } 2>/dev/null; then "${tr[@]}" | less -R $( [[ -n "${RP_PAGER_TOP:-}" ]] || echo +G ) >/dev/tty; else "${tr[@]}"; fi
}

logs_menu() {
  local list=() i n src mode since word
  while true; do
    screen "Логи"; echo
    mapfile -t list < <(
      docker ps -a --format '{{.Names}}' | grep -iE 'remna|nginx|caddy|traefik|angie|xray|sub' | sed 's/^/ct:/'
      ls -1 /var/log/remnanode/*.log 2>/dev/null | sed 's/^/file:/'
    )
    (( ${#list[@]} )) || { yel "Контейнеры не найдены."; return; }
    section "ИСТОЧНИК"
    for i in "${!list[@]}"; do
      src="${list[$i]}"
      if [[ "$src" == ct:* ]]; then
        local st d; st=$(docker ps -a --filter "name=^${src#ct:}$" --format '{{.Status}}')
        case "$st" in *unhealthy*|*Restarting*) d=warn ;; Up*) d=ok ;; *) d=err ;; esac
        printf '   %s%3d%s  %s %-24s %s%s%s\n' "$C_ACC$CB" $((i+1)) "$C0" "$(dot $d)" "${src#ct:}" "$C_MUT" "$st" "$C0"
      else
        printf '   %s%3d%s  %s %s\n' "$C_ACC$CB" $((i+1)) "$C0" "$(dot off)" "${src#file:}"
      fi
    done
    hr; item 0 "Назад"
    ask "Источник"; read -r n
    [[ "$n" == 0 || -z "$n" ]] && return
    [[ "$n" =~ ^[0-9]+$ ]] && (( n <= ${#list[@]} )) || continue
    src="${list[$((n-1))]}"

    section "РЕЖИМ"
    item 1 "Последние 300 строк"
    item 2 "В реальном времени" "Ctrl+C — выход"
    item 3 "Ошибки за 1 час"
    item 4 "Ошибки за 24 часа"
    item 5 "Ошибки за всё время"
    item 6 "Поиск по слову"
    ask "Режим"; read -r mode
    case "$mode" in 6) ask "Слово или regex"; read -r word ;; esac
    echo

    if [[ "$src" == ct:* ]]; then
      local ct="${src#ct:}"
      case "$mode" in
        1) docker logs -t --tail 300 "$ct" 2>&1 | show_paged ;;
        2) trap ':' INT; docker logs -t -f --tail 50 "$ct" 2>&1; trap - INT ;;
        3) since=1h ;; 4) since=24h ;; 5) since="" ;;
        6) docker logs -t "$ct" 2>&1 | grep -iE --color=always -- "$word" | show_paged ;;
      esac
      if [[ "$mode" =~ ^[345]$ ]]; then
        local out; out=$(docker logs -t ${since:+--since "$since"} "$ct" 2>&1 | grep -iE --color=always -- "$ERR_RE")
        [[ -n "$out" ]] && echo "$out" | show_paged || green "Ошибок не найдено."
      fi
    else
      local fl="${src#file:}"
      case "$mode" in
        1) tail -n 300 "$fl" | show_paged ;;
        2) trap ':' INT; tail -n 50 -F "$fl"; trap - INT ;;
        3|4|5) grep -iE --color=always -- "$ERR_RE" "$fl" | tail -n 500 | show_paged ;;
        6) grep -iE --color=always -- "$word" "$fl" | tail -n 500 | show_paged ;;
      esac
    fi
    pause
  done
}

