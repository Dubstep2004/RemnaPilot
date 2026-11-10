# ---------- проверка IP ----------
ch_api() { curl -fsS --max-time 15 -H 'Accept: application/json' "https://check-host.net/$1" 2>/dev/null; }

ip_check() {
  local ip port info rid res nodes=() n json
  ip=$(curl -4 -s --max-time 6 https://ifconfig.me)
  [[ -n "$ip" ]] || { fail "Не узнал внешний IP сервера" net "$(curl -4 -sS --max-time 6 -o /dev/null https://ifconfig.me 2>&1 || true)"; return 1; }
  ask "Порт для проверки [443]"; read -r port; port="${port:-443}"

  section "СЕРВЕР"
  info=$(curl -fsS --max-time 6 "https://ipinfo.io/$ip/json" 2>/dev/null)
  printf '   IP:       %s\n' "$ip"
  printf '   Страна:   %s, %s\n' "$(grep -oP '"country":\s*"\K[^"]+' <<< "$info")" "$(grep -oP '"city":\s*"\K[^"]+' <<< "$info")"
  printf '   Хостинг:  %s\n' "$(grep -oP '"org":\s*"\K[^"]+' <<< "$info")"

  # узлы check-host.net в России + пара зарубежных для сравнения
  json=$(ch_api "nodes/hosts")
  [[ -n "$json" ]] || { red "✖ check-host.net недоступен — проверка из РФ невозможна"; }
  if [[ -n "$json" ]]; then
    mapfile -t nodes < <(perl -0777 -ne 'while (/"([a-z0-9]+\.node\.check-host\.net)":\s*\{[^}]*?"location":\s*\[\s*"(\w\w)"/g) { print "$1 $2\n" }' <<< "$json")
    local ru=() other=() x
    for x in "${nodes[@]}"; do [[ "${x#* }" == ru ]] && ru+=("${x% *}") || other+=("${x% *}"); done
    ru=("${ru[@]:0:6}")
    local fx="" q=""
    for x in "${other[@]}"; do [[ "$x" =~ ^(de|nl|fi)[0-9] ]] && { fx="$x"; break; }; done
    local chk=("${ru[@]}"); [[ -n "$fx" ]] && chk+=("$fx")
    for x in "${chk[@]}"; do q+="&node=$x"; done

    section "ИЗ РОССИИ → ЭТОТ СЕРВЕР"
    if (( ${#ru[@]} == 0 )); then yel "  Сейчас у check-host.net нет узлов в РФ."; else
      local rid_tcp rid_ping
      rid_tcp=$(ch_api "check-tcp?host=$ip:$port$q" | grep -oP '"request_id":\s*"\K[^"]+')
      rid_ping=$(ch_api "check-ping?host=$ip$q" | grep -oP '"request_id":\s*"\K[^"]+')
      info "Жду ответы узлов (10 сек)..."; sleep 10; printf '\e[1A\e[2K'
      local rt rp ok_ru=0 total_ru=0
      rt=$(ch_api "check-result/$rid_tcp"); rp=$(ch_api "check-result/$rid_ping")
      printf '   %s%s %s %s%s\n' "$C_MUT" "$(padr "узел" 22)" "$(padr "TCP :$port" 12)" "пинг" "$C0"
      for x in "${chk[@]}"; do
        local tcp ping city
        tcp=$(perl -0777 -ne 'if (/"\Q'"$x"'\E":\s*(null|\[[^\]]*\])/) { my $v=$1; if ($v eq "null") {print "…"} elsif ($v =~ /"time":\s*([\d.]+)/) { printf "ok %.0fms", $1*1000 } else { print "✖ нет" } }' <<< "$rt")
        ping=$(perl -0777 -ne 'if (/"\Q'"$x"'\E":\s*\[\[(.*?)\]\]/s) { my @t = $1 =~ /"OK",\s*([\d.]+)/g; if (@t) { my $s=0; $s+=$_ for @t; printf "%.0fms (%d/4)", $s/@t*1000, scalar @t } else { print "✖ потери" } } elsif (/"\Q'"$x"'\E":\s*null/) { print "…" }' <<< "$rp")
        city=$(perl -0777 -ne 'if (/"\Q'"$x"'\E":\s*\{[^}]*?"location":\s*\[\s*"\w\w",\s*"[^"]*",\s*"([^"]+)"/) { print $1 }' <<< "$json")
        local lab="${city:-$x}"; [[ " ${ru[*]} " == *" $x "* ]] || lab="$lab (не РФ)"
        local cc="$C_OK"; [[ "$tcp" == ok* ]] || cc="$C_ERR"
        printf '   %s %s%s%s %s\n' "$(padr "${lab:0:22}" 22)" "$cc" "$(padr "$tcp" 12)" "$C0" "$ping"
        if [[ " ${ru[*]} " == *" $x "* ]]; then total_ru=$((total_ru+1)); [[ "$tcp" == ok* ]] && ok_ru=$((ok_ru+1)); fi
      done
      echo
      if (( total_ru && ok_ru == 0 )); then red "  ✖ Из РФ порт $port недоступен ни с одного узла — похоже на блокировку IP (или порт закрыт)."
      elif (( ok_ru < total_ru )); then yel "  ⚠ Доступен не со всех узлов РФ ($ok_ru из $total_ru) — возможна частичная блокировка."
      else green "  ✔ IP доступен из РФ по TCP ($ok_ru из $total_ru)."; fi
      echo "  ${C_MUT}TCP-проверка видит блокировку IP. Блокировку по SNI/DPI она не покажет — это проверяется реальным подключением.${C0}"
    fi
  fi

  section "СКОРОСТЬ (Cloudflare)"
  local dl ul
  info "Скачиваю 50 МБ..."
  dl=$(curl -o /dev/null -s --max-time 40 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=50000000')
  printf '\e[1A\e[2K'; info "Отдаю 20 МБ..."
  ul=$(head -c 20000000 /dev/zero | curl -o /dev/null -s --max-time 40 -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up')
  printf '\e[1A\e[2K'
  printf '   Загрузка:  %s Мбит/с\n   Отдача:    %s Мбит/с\n' "$(awk -v b="${dl:-0}" 'BEGIN{printf "%.0f", b*8/1e6}')" "$(awk -v b="${ul:-0}" 'BEGIN{printf "%.0f", b*8/1e6}')"

  section "ПИНГ С СЕРВЕРА"
  local tgt
  for tgt in "1.1.1.1|Cloudflare" "8.8.8.8|Google" "77.88.8.8|Яндекс DNS (Москва)" "95.217.0.1|Hetzner (Финляндия)"; do
    printf '   %s %s\n' "$(padr "${tgt#*|}" 24)" "$(ping -c 3 -W 2 -q "${tgt%%|*}" 2>/dev/null | awk -F/ '/rtt|round-trip/{printf "%.0f ms", $5}' || true)"
  done
  jlog INFO "Проверка IP $ip"
}

# ---------- подбор SNI для Reality ----------
sni_check_one() { # домен -> печатает строку оценки; возвращает 0 если подходит
  local d="$1" out tls13 h2 x25519 cert redir code loc tc score=0 notes=()
  out=$(timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 </dev/null 2>/dev/null)
  if grep -qE 'Protocol *: *TLSv1\.3|New, TLSv1\.3' <<< "$out"; then tls13=1; score=$((score+1)); else notes+=("нет TLS 1.3"); fi
  if grep -q 'ALPN protocol: h2' <<< "$out"; then h2=1; score=$((score+1)); else notes+=("нет H2"); fi
  if timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -groups X25519 </dev/null >/dev/null 2>&1; then x25519=1; score=$((score+1)); else notes+=("нет X25519"); fi
  if grep -q 'Verify return code: 0' <<< "$out"; then score=$((score+1)); else notes+=("сертификат не прошёл проверку"); fi
  code=$(curl -s -o /dev/null --max-time 8 -w '%{http_code} %{redirect_url}' "https://$d/")
  redir="${code#* }"; code="${code%% *}"
  if [[ -n "$redir" && "$redir" != *"//$d"* && "$redir" != /* ]]; then notes+=("редирект на ${redir#*//}"); else score=$((score+1)); fi
  tc=$(for _ in 1 2 3; do curl -s -o /dev/null --max-time 5 -w '%{time_connect}\n' "https://$d/"; done | sort -n | head -1)
  tc=$(awk -v t="${tc:-9}" 'BEGIN{printf "%.0f", t*1000}')
  if (( tc <= 20 )); then score=$((score+1)); elif (( tc > 80 )); then notes+=("далеко (${tc} мс)"); fi
  if curl -sI --max-time 6 "https://$d/" | grep -qiE '^server: *cloudflare|^cf-ray'; then notes+=("за Cloudflare — нежелательно"); else score=$((score+1)); fi
  local col="$C_OK" mark="✔"; (( score < 7 )) && { col="$C_WARN"; mark="⚠"; }; (( !tls13 || !h2 || !x25519 )) && { col="$C_ERR"; mark="✖"; }
  local nt="всё отлично"; (( ${#notes[@]} )) && nt=$(printf '%s, ' "${notes[@]}") && nt="${nt%, }"
  printf '  %s%s %-30s%s %3s мс  %s%s%s\n' "$col" "$mark" "${d:0:30}" "$C0" "$tc" "$C_MUT" "$nt" "$C0"
  [[ "$mark" != "✖" ]]
}

sni_scan_neighbors() { # ищет сайты в той же /24, что и сервер — лучший вариант маскировки
  local ip pfx tmp found
  ip=$(curl -4 -s --max-time 6 https://ifconfig.me); pfx="${ip%.*}"
  info "Сканирую $pfx.0/24 (254 адреса, ~1 минута)..."
  tmp=$(mktemp)
  seq 1 254 | xargs -P 48 -I{} sh -c '
    h='"$pfx"'.{}; [ "$h" = "'"$ip"'" ] && exit 0
    c=$(timeout 3 openssl s_client -connect "$h:443" -tls1_3 -alpn h2 </dev/null 2>/dev/null) || exit 0
    echo "$c" | grep -q "ALPN protocol: h2" || exit 0
    n=$(echo "$c" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | sed "s/DNS://; s/^\*\.//")
    [ -n "$n" ] && echo "$n"' 2>/dev/null | sort -u > "$tmp"
  printf '\e[1A\e[2K'
  found=$(wc -l < "$tmp")
  if (( found == 0 )); then yel "  Соседей с TLS 1.3 + H2 не нашлось. Попробуй проверить известные домены вручную."; rm -f "$tmp"; return 0; fi
  info "Найдено кандидатов: $found. Проверяю каждого..."
  local d; while read -r d; do sni_check_one "$d"; done < <(head -20 "$tmp")
  rm -f "$tmp"
}

sni_menu() {
  local c doms d
  while true; do
    screen "Подбор SNI для Reality"; echo
    echo "  Хороший SNI: TLS 1.3, H2, X25519, без редиректа на другой домен,"
    echo "  близко к серверу (в идеале — тот же дата-центр) и не за Cloudflare."
    section "ДЕЙСТВИЯ"
    item 1 "Проверить домены" "через пробел"
    item 2 "Найти соседей сервера" "сайты в той же подсети"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) ask "Домены"; read -r doms; echo
         printf '  %s  %-30s %6s  %s%s\n' "$C_MUT" "домен" "пинг" "замечания" "$C0"
         for d in $doms; do sni_check_one "$(clean_domain "$d")"; done; pause ;;
      2) sni_scan_neighbors; pause ;;
      0|q|"") return ;;
    esac
  done
}

