# ---------- утилиты ----------
env_get() { grep -E "^$1=" "$RW_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' \r'; }

env_set() { # key value
  local k="$1" v="$2" f="$RW_DIR/.env"
  if grep -qE "^$k=" "$f"; then
    K="$k" V="$v" perl -pi -e 's/^\Q$ENV{K}\E=.*/$ENV{K}=$ENV{V}/' "$f"
  else
    echo "$k=$v" >> "$f"
  fi
}

clean_domain() { local d="${1//[[:space:]]/}"; d="${d,,}"; d="${d#http://}"; d="${d#https://}"; echo "${d%%/*}"; }

wrap() { # перенос по словам с учётом UTF-8: текст, ширина
  local w cur=""
  for w in $1; do
    if [[ -z "$cur" ]]; then cur="$w"
    elif (( ${#cur} + 1 + ${#w} <= $2 )); then cur+=" $w"
    else echo "$cur"; cur="$w"; fi
  done
  [[ -n "$cur" ]] && echo "$cur"
}

padr() { set -- "$(T "$1")" "$2"; local pad=$(( $2 - ${#1} )); (( pad < 1 )) && pad=1; printf '%s%s' "$1" "$(repeat ' ' $pad)"; }

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+([A-Za-z]{2,}|xn--[A-Za-z0-9-]{2,})$ ]]; }

detect_old() {
  local d; d=$(env_get FRONT_END_DOMAIN)
  [[ -z "$d" || "$d" == "*" ]] && d=$(env_get PANEL_DOMAIN)
  [[ "$d" == "*" ]] && d=""
  echo "$d"
}

find_files() { # $1 = old domain
  find "$RW_DIR" -maxdepth 3 \
    \( -path '*/data' -o -path '*/db' -o -path '*/postgres*' -o -path '*/backup-*' -o -path '*/backups' \) -prune -o \
    -type f \( -name '.env' -o -name '*.env' -o -name '*.yml' -o -name '*.yaml' \
               -o -name '*.conf' -o -name 'Caddyfile' -o -name '*.toml' \) -print0 2>/dev/null |
  xargs -0 -r grep -lF -- "$1" 2>/dev/null || true
}

find_composes() {
  find "$RW_DIR" -maxdepth 2 \( -path '*/backup-*' -prune \) -o -type f \
    \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) -print
}

check_dns() { # $1 = domain
  local sip dip
  sip=$(curl -4 -s --max-time 5 https://ifconfig.me || true)
  dip=$(getent ahostsv4 "$1" | awk 'NR==1{print $1}' || true)
  if [[ -z "$dip" ]]; then
    yel "⚠ $1 не резолвится — сертификат может не выпуститься."
  elif [[ -n "$sip" && "$dip" != "$sip" ]]; then
    yel "⚠ $1 -> $dip, IP сервера $sip (ок, если домен за Cloudflare)."
  else
    green "✓ DNS: $1 -> $dip"
  fi
}

stack_down() {
  local c all; mapfile -t all < <(find_composes)
  for c in "${all[@]}"; do [[ "$(dirname "$c")" != "$RW_DIR" ]] && (cd "$(dirname "$c")" && docker compose -f "$c" down </dev/null); done
  for c in "${all[@]}"; do [[ "$(dirname "$c")" == "$RW_DIR" ]] && (cd "$RW_DIR" && docker compose -f "$c" down </dev/null); done
  return 0
}

stack_up() {
  local c all; mapfile -t all < <(find_composes)
  for c in "${all[@]}"; do [[ "$(dirname "$c")" == "$RW_DIR" ]] && (cd "$RW_DIR" && docker compose -f "$c" up -d); done
  for c in "${all[@]}"; do [[ "$(dirname "$c")" != "$RW_DIR" ]] && (cd "$(dirname "$c")" && docker compose -f "$c" up -d); done
  return 0
}

issue_cert() { # $1 = домен; доп. домены в CERT_EXTRA, пути в CERT_KEY/CERT_FULL; при остановленном nginx
  local ngx="$RW_DIR/nginx" acme="${ACME:-$HOME/.acme.sh/acme.sh}"
  local key="${CERT_KEY:-}" full="${CERT_FULL:-}" x cp
  if [[ -z "$full" ]] && cp=$(cert_paths_for "$1") && [[ -n "$cp" ]]; then
    full="${cp%%$'\t'*}"; key="${cp#*$'\t'}"
  fi
  full="${full:-$ngx/fullchain.pem}"; key="${key:-$ngx/privkey.key}"
  local extra="${CERT_EXTRA:-}"; [[ -z "$extra" ]] && extra=$(names_sharing_cert "$1" 2>/dev/null)
  local dargs=(-d "$1"); for x in $extra; do [[ "$x" != "$1" ]] && dargs+=(-d "$x"); done
  if ! nginx_has_ssl; then
    echo "Nginx с ssl не найден — сертификат выпустит Caddy/Traefik."; return 0
  fi
  acme=$(acme_bin) || acme=""
  if [[ -z "$acme" ]]; then
    ask "acme.sh не установлен. Установить? [Y/n]"; read -r x
    [[ "$x" =~ ^[Nn]$ ]] && { yel "⚠ Сертификат для $1 не выпущен."; return 1; }
    curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1; acme=$(acme_bin) || { red "✖ acme.sh не установился"; return 1; }
    green "✔ acme.sh установлен"
  fi
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1

  CERT_DOMAIN="$1"; CERT_ARGS=("${dargs[@]}"); CERT_K="$key"; CERT_F="$full"; ACME_BIN="$acme"
  local method="${CERT_METHOD:-}" tried=" " ch
  [[ -z "$method" ]] && method=$(auto_cert_method)

  while true; do
    [[ "$method" == cancel ]] && { yel "Сертификат не выпущен — сделай это позже в разделе «Сертификаты»."; return 1; }
    if try_cert_method "$method"; then
      green "✔ Сертификат: $full"
      acme_forget_others "$full" "$1"
      ensure_acme_cron "$acme"
      [[ "$method" == manual ]] && yel "⚠ Ручной DNS не продлевается сам — через ~60 дней повтори выпуск (раздел «Сертификаты»)." \
                                || green "✔ Автопродление настроено (acme.sh cron, способ: $(method_name "$method"))"
      return 0
    fi
    tried+="$method "
    echo
    yel "Попробовать другой способ?"
    local opts=() o n=0
    for o in http alpn dns manual; do [[ "$tried" == *" $o "* ]] || opts+=("$o"); done
    for o in "${opts[@]}"; do n=$((n+1)); item $n "$(method_name "$o")" "$(method_hint "$o")"; done
    item 0 "Отмена"
    ask; read -r ch
    if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#opts[@]} )); then method="${opts[$((ch-1))]}"; else method=cancel; fi
  done
}

method_name() { case "$1" in http) echo "Порт 80 (HTTP)";; alpn) echo "Порт 443 (TLS-ALPN)";; dns) echo "DNS Cloudflare";; manual) echo "DNS вручную";; esac; }

method_hint() {
  case "$1" in
    http)   port_busy 80  && echo "занят: $(port_owner 80) — остановлю на время" || echo "свободен" ;;
    alpn)   port_busy 443 && echo "занят: $(port_owner 443) — остановлю на время" || echo "свободен" ;;
    dns)    echo "порты не нужны, нужен API-токен" ;;
    manual) echo "любой DNS-провайдер, без автопродления" ;;
  esac
}

auto_cert_method() { # выбирает способ; при занятых портах спрашивает
  if   ! port_busy 80;  then echo http
  elif ! port_busy 443; then echo alpn
  else
    {
      yel "Заняты оба порта: 80 — $(port_owner 80), 443 — $(port_owner 443)"
      item 1 "Порт 80" "временно остановлю $(port_owner 80) и верну обратно"
      item 2 "DNS Cloudflare" "порты не нужны"
      item 3 "DNS вручную" "добавишь TXT-запись у регистратора"
      item 0 "Отмена"
      ask
    } >&2
    local ch; read -r ch
    case "$ch" in 1) echo http ;; 2) echo dns ;; 3) echo manual ;; *) echo cancel ;; esac
  fi
}

try_cert_method() { # $1 = http|alpn|dns|manual -> 0 при успехе
  local m="$1" port="" rc=0 log; log=$(mktemp)
  STOPPED_CT=(); STOPPED_SVC=(); FW_OPENED=()
  case "$m" in http) port=80 ;; alpn) port=443 ;; esac

  if [[ -n "$port" ]]; then
    if port_busy "$port"; then free_port "$port" || { restore_after_cert; return 1; }; fi
    if ! command -v socat >/dev/null; then       # acme.sh standalone/alpn без socat не работает
      info "Устанавливаю socat..."
      { apt-get install -y socat || dnf install -y socat || yum install -y socat; } >/dev/null 2>&1
      command -v socat >/dev/null || { red "✖ Нужен socat: apt install socat"; restore_after_cert; return 1; }
    fi
    fw_open "$port"
    if [[ "$m" == alpn ]] && behind_proxy "$CERT_DOMAIN"; then
      yel "⚠ $CERT_DOMAIN смотрит не на этот сервер (похоже на прокси Cloudflare) — TLS-ALPN через прокси не работает."
    fi
  fi

  write_renew_hooks "$CERT_DOMAIN" "$port"
  local common=("${CERT_ARGS[@]}" --force --server letsencrypt
    --key-file "$CERT_K" --fullchain-file "$CERT_F" --reloadcmd "$HOOK_DIR/$CERT_DOMAIN-reload.sh")
  local hooks=(--pre-hook "$HOOK_DIR/$CERT_DOMAIN-pre.sh" --post-hook "$HOOK_DIR/$CERT_DOMAIN-post.sh")

  local names="" x; for x in "${CERT_ARGS[@]}"; do [[ "$x" != -d ]] && names+="${names:+, }$x"; done
  info "Выпускаю сертификат для $names — $(method_name "$m")"
  case "$m" in
    http) "$ACME_BIN" --issue --standalone "${common[@]}" "${hooks[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]} ;;
    alpn) "$ACME_BIN" --issue --alpn       "${common[@]}" "${hooks[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]} ;;
    dns)
      if [[ -z "${CF_Token:-}" ]] && ! grep -q '^SAVED_CF_Token=' "$HOME/.acme.sh/account.conf" 2>/dev/null; then
        echo "  Нужен API-токен Cloudflare: dash.cloudflare.com → My Profile → API Tokens → «Edit zone DNS»."
        read -rsp "  CF_Token: " CF_Token; echo
        [[ -n "$CF_Token" ]] || { restore_after_cert; return 1; }
        export CF_Token
      fi
      "$ACME_BIN" --issue --dns dns_cf "${common[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]} ;;
    manual) manual_dns_issue "$log"; rc=$? ;;
  esac
  restore_after_cert

  (( rc == 0 )) && { rm -f "$log"; return 0; }
  red "✖ Не получилось ($(method_name "$m"))"
  explain_acme_error "$log" "$m"
  rm -f "$log"; return 1
}

behind_proxy() { # домен резолвится не в IP сервера
  local sip dip; sip=$(curl -4 -s --max-time 5 https://ifconfig.me); dip=$(getent ahostsv4 "$1" | awk 'NR==1{print $1}')
  [[ -n "$sip" && -n "$dip" && "$sip" != "$dip" ]]
}

manual_dns_issue() { # $1 = лог; ручной DNS-01: показать TXT, дождаться, выпустить
  local log="$1" d rec ok ans
  local flag=--yes-I-know-dns-manual-mode-enough-go-ahead-please
  "$ACME_BIN" --issue --dns "${CERT_ARGS[@]}" --force --server letsencrypt "$flag" >"$log" 2>&1
  mapfile -t rec < <(grep -oE "Domain: '[^']+'|TXT value: '[^']+'" "$log" | sed -E "s/^[^']*'//; s/'$//")
  (( ${#rec[@]} >= 2 )) || { cat "$log"; return 1; }
  section "ДОБАВЬ TXT-ЗАПИСИ У РЕГИСТРАТОРА"
  for ((i=0; i<${#rec[@]}; i+=2)); do
    printf '   Имя:      %s%s%s\n   Значение: %s%s%s\n\n' "$CB" "${rec[i]}" "$C0" "$C_ACC" "${rec[i+1]}" "$C0"
  done
  echo "  TTL — минимальный. Если у домена несколько имён, записей будет несколько с одним именем — добавь все."
  while true; do
    ask "Добавил? Enter — проверить, q — отмена"; read -r ans; [[ "$ans" == q ]] && return 1
    ok=1
    for ((i=0; i<${#rec[@]}; i+=2)); do
      if command -v dig >/dev/null; then
        dig +short TXT "${rec[i]}" @1.1.1.1 | tr -d '"' | grep -qxF "${rec[i+1]}" || ok=0
      else
        curl -fsS "https://dns.google/resolve?name=${rec[i]}&type=TXT" | grep -qF "${rec[i+1]}" || ok=0
      fi
    done
    (( ok )) && { green "✔ TXT-записи видны"; break; }
    yel "  Пока не видно — DNS обновляется от минуты до получаса. Подожди и нажми Enter ещё раз."
  done
  "$ACME_BIN" --renew "${CERT_ARGS[@]}" --force "$flag" >>"$log" 2>&1 || { tail -15 "$log"; return 1; }
  "$ACME_BIN" --install-cert "${CERT_ARGS[@]}" --key-file "$CERT_K" --fullchain-file "$CERT_F" \
    --reloadcmd "$HOOK_DIR/$CERT_DOMAIN-reload.sh" >>"$log" 2>&1
}

explain_acme_error() { # $1 лог acme.sh, $2 способ — человеческое объяснение причины
  local l="$1" m="$2"
  if   grep -qiE 'rateLimited|too many (certificates|failed)' "$l"; then
    yel "  Причина: лимит Let's Encrypt (слишком много попыток). Подожди час (или неделю при лимите сертификатов)."
  elif grep -qiE 'NXDOMAIN|no valid A records|DNS problem' "$l"; then
    yel "  Причина: домен не найден в DNS или не указывает на сервер. Проверь A-запись."
  elif grep -qiE 'already used|Address already in use|Cannot listen|is not free' "$l"; then
    yel "  Причина: порт занят другой программой."
  elif grep -qiE 'Timeout|Connection refused|connection reset|Fetching .* Timeout' "$l"; then
    yel "  Причина: Let's Encrypt не достучался до сервера — порт $( [[ $m == alpn ]] && echo 443 || echo 80 ) закрыт снаружи."
    yel "  Открой его в панели хостера (firewall / security group) или выбери DNS — порты не нужны."
  elif grep -qiE 'Invalid response|unauthorized|403|404' "$l"; then
    yel "  Причина: проверку получил не этот сервер — домен смотрит на другой IP или включён прокси Cloudflare."
    [[ "$m" == alpn ]] && yel "  Через прокси Cloudflare работает только порт 80 или DNS."
  elif grep -qiE 'CF_Token|Invalid (api|request headers)|Authentication error|9109|10000' "$l"; then
    yel "  Причина: неверный токен Cloudflare или у него нет прав Zone → DNS → Edit."
    sed -i '/^SAVED_CF_/d' "$HOME/.acme.sh/account.conf" 2>/dev/null; unset CF_Token
  else
    echo "  Последние строки лога:"; grep -v '^\s*$' "$l" | tail -6 | sed 's/^/    /'
  fi
}

