# ---------- API панели ----------
# RemnaPilot ходит в API панели напрямую (127.0.0.1:3000) с заголовками, как от reverse proxy.
# Токен хранится в /etc/rw/api.token (только root). Его можно вставить из панели
# (Настройки → API-токены) или RemnaPilot создаст его сам по логину и паролю админа.
API_CONF="/etc/rw/api.token"

api_url() {
  local p; p=$(grep -oE '127\.0\.0\.1:[0-9]+:' "$RW_DIR/docker-compose.yml" 2>/dev/null | head -1 | cut -d: -f2)
  echo "${RP_API_URL:-http://127.0.0.1:${p:-3000}}"
}

api() { # метод путь [json] → API_OUT (тело), API_CODE; 0 при 2xx. Токен — из API_TOKEN (если задан) или из файла
  local tok out m="$1" p="$2" d="${3:-}"
  if [[ -n "${API_TOKEN+x}" ]]; then tok="$API_TOKEN"; else tok=$(cat "$API_CONF" 2>/dev/null); fi
  local a=(-s -m 25 -X "$m" -H "X-Forwarded-For: 127.0.0.1" -H "X-Forwarded-Proto: https" -H "X-Remnawave-Client-Type: browser" -H "Content-Type: application/json" -w $'\n%{http_code}')
  [[ -n "$d" ]] && a+=(--data-binary @-)
  # токен — заголовком из файла-канала: в списке процессов (ps) его не видно
  out=$(printf '%s' "$d" | curl "${a[@]}" -H @<([[ -n "$tok" ]] && printf 'Authorization: Bearer %s\n' "$tok") "$(api_url)$p" 2>&1)
  API_CODE="${out##*$'\n'}"; API_OUT="${out%$'\n'*}"
  [[ "$API_CODE" =~ ^2 ]]
}

need_py() { command -v python3 >/dev/null || pkg_install python3 || { fail "Не установлен python3" apt "$PKG_LOG"; return 1; }; }

jget() { # выражение над j (разобранный JSON из stdin) → строка или JSON
  python3 -c 'import json,sys
j=json.load(sys.stdin); r=eval(sys.argv[1])
print(r if isinstance(r,str) else ("" if r is None else json.dumps(r, ensure_ascii=False)))' "$1" 2>/dev/null
}

api_msg() { # понятная строка ошибки API
  local m; m=$(jget 'j.get("message") or j.get("error") or ""' <<< "$API_OUT")
  case "$API_CODE" in
    000) echo "панель не отвечает на $(api_url) — она запущена?" ;;
    401) echo "API-токен не подходит или истёк${m:+ ($m)}" ;;
    403) echo "доступ запрещён${m:+ ($m)}" ;;
    404) echo "в этой версии панели нет нужного API — обнови панель${m:+ ($m)}" ;;
    *)   echo "HTTP $API_CODE${m:+: $m}" ;;
  esac
}

api_ready() { # проверить или получить доступ к API; 0 — можно работать
  need_py || return 1
  if [[ -s "$API_CONF" ]] && api GET /api/keygen; then return 0; fi
  if [[ "$API_CODE" == 000 ]]; then fail "Панель не отвечает"; cause "$(api_msg)"; todo "проверь: Панель → Настройки и контейнеры"; return 1; fi
  [[ -s "$API_CONF" ]] && yel "⚠ Сохранённый API-токен не подходит ($(api_msg)) — нужен новый."
  echo "RemnaPilot нужен доступ к API панели. Два способа:"
  echo "  • вставь API-токен (в панели: Настройки → API-токены → Создать)"
  echo "  • или нажми Enter — войду логином и паролем админа и создам токен сам (пароль нигде не сохраняется)"
  local t u pw body jwt
  ask "API-токен"; read -rs t; echo
  if [[ -z "$t" ]]; then
    ask "Логин админа панели"; read -r u; [[ -n "$u" ]] || { echo "  Отменено."; return $RP_CANCEL; }
    ask "Пароль"; read -rs pw; echo
    body=$(U="$u" P="$pw" python3 -c 'import json,os; print(json.dumps({"username":os.environ["U"],"password":os.environ["P"]}))')
    API_TOKEN="" api POST /api/auth/login "$body" || { fail "Не вошёл в панель"; cause "$( [[ "$API_CODE" =~ ^(400|401|403)$ ]] && echo "неверный логин или пароль" || api_msg)"; return 1; }
    jwt=$(jget 'j["response"]["accessToken"]' <<< "$API_OUT")
    API_TOKEN="$jwt" api POST /api/tokens '{"name":"RemnaPilot","expiresInDays":3650}' \
      || API_TOKEN="$jwt" api POST /api/tokens '{"tokenName":"RemnaPilot","tokenDescription":"RemnaPilot"}' \
      || { fail "Токен не создался"; cause "$(api_msg)"; todo "создай его в панели: Настройки → API-токены и вставь сюда"; return 1; }
    t=$(jget 'j["response"]["token"]' <<< "$API_OUT")
  fi
  API_TOKEN="$t" api GET /api/keygen || { fail "Токен не подошёл"; cause "$(api_msg)"; return 1; }
  mkdir -p /etc/rw; ( umask 077; printf '%s\n' "$t" > "$API_CONF" ); chmod 600 "$API_CONF"
  green "✔ Доступ к API сохранён ($API_CONF, читает только root)"
}

# ---------- правка конфигов nginx / Caddy панели ----------
caddy_ct() { docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$2 ~ /caddy/ && $1 !~ /selfsteal/ {print $1; exit}'; }

proxy_find() { # PROXY_KIND (nginx|caddy) и PROXY_FILE — конфиг, где описан домен панели
  local f panel; panel=$(detect_old); PROXY_KIND=""; PROXY_FILE=""
  [[ -n "$panel" ]] || return 1
  while IFS= read -r f; do
    case "$f" in
      *Caddyfile) D="$panel" perl -ne 'BEGIN{$d=quotemeta $ENV{D}} $h=1 if /^[^#{]*(?<![\w.-])$d(?![\w-])[^#]*\{/; END{exit !$h}' "$f" && { PROXY_KIND=caddy; PROXY_FILE="$f"; return 0; } ;;
      *.conf)     D="$panel" perl -ne 'BEGIN{$d=quotemeta $ENV{D}} $h=1 if /^\s*server_name[^;#]*(?<![\w.-])$d(?![\w-])/; END{exit !$h}' "$f" && { PROXY_KIND=nginx; PROXY_FILE="$f"; return 0; } ;;
    esac
  done < <(proxy_confs)
  return 1
}

need_proxy() {
  proxy_find && return 0
  fail "Не нашёл конфиг nginx или Caddy панели"; cause "в $RW_DIR нет конфига с доменом $(detect_old)"
  todo "эта функция работает с nginx или Caddy, которые стоят по инструкции docs.rw (или установлены RemnaPilot)"; return 1
}

block_edit() { # файл домен 'perl-код над $_' — правит блок сервера/сайта домена, inode файла сохраняется
  local f="$1" new; new=$(D="$2" P="$3" perl -e '
    my $d = quotemeta $ENV{D}; my ($depth, $buf, $out) = (0, "", "");
    sub flush { my $hit = $buf =~ /\A[^\n{]*(?<![\w.-])$d(?![\w-])[^\n]*\{/ || $buf =~ /^\s*server_name[^;]*(?<![\w.-])$d(?![\w-])/m;
                if ($hit) { local $_ = $buf; eval $ENV{P}; die $@ if $@; $buf = $_ } $out .= $buf; $buf = "" }
    while (my $l = <STDIN>) {
      (my $s = $l) =~ s/#.*//; my $o = () = $s =~ /\{/g; my $c = () = $s =~ /\}/g;
      if ($depth == 0 && !$o) { $out .= $l; next }
      $buf .= $l; $depth += $o - $c;
      if ($depth <= 0) { $depth = 0; flush() }
    }
    $out .= $buf; print $out;' < "$f") || return 1
  [[ "$new" == "$(cat "$f")" ]] && return 1
  printf '%s\n' "$new" > "$f"
}

http_edit() { # файл маркер текст — блок верхнего уровня (http) между «# маркер begin/end»; пустой текст — убрать
  local f="$1" new; new=$(M="$2" X="$3" perl -0777 -e '
    my $t = <STDIN>; my $m = quotemeta $ENV{M};
    $t =~ s/^[ \t]*# $m begin\n.*?^[ \t]*# $m end\n//gms;
    if ($ENV{X} ne "") {
      my $b = "# $ENV{M} begin\n$ENV{X}\n# $ENV{M} end\n";
      if ($t =~ /^\s*http\s*\{[^\n]*\n/m) { $t =~ s/^(\s*http\s*\{[^\n]*\n)/$1$b/m }
      elsif ($t =~ /\A((?:#[^\n]*\n)+)/) { my $h = $1; substr($t, 0, length $h) = "$h$b" }
      else { $t = $b . $t }
    }
    print $t;' < "$f") || return 1
  [[ "$new" == "$(cat "$f")" ]] && return 1
  printf '%s\n' "$new" > "$f"
}

proxy_reload() { # проверить конфиг и применить без перезапуска; 1 — ошибка в конфиге (текст в PROXY_LOG)
  local c
  if [[ "$PROXY_KIND" == nginx ]]; then c=$(nginx_ct)
    PROXY_LOG=$(docker exec "$c" nginx -t 2>&1) || return 1
    docker exec "$c" nginx -s reload >/dev/null 2>&1 || docker restart "$c" >/dev/null 2>&1
  else c=$(caddy_ct); c="${c:-caddy}"
    PROXY_LOG=$(docker exec "$c" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1) || return 1
    docker exec "$c" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || docker restart "$c" >/dev/null 2>&1
  fi
  sleep 1; return 0
}

proxy_apply() { # копия_до_правки — применить; при ошибке вернуть как было
  if proxy_reload; then return 0; fi
  cat "$1" > "$PROXY_FILE"; proxy_reload >/dev/null 2>&1
  fail "Веб-сервер не принял новый конфиг — вернул как было"; log_tail "$PROXY_LOG" 6; return 1
}

proxy_backup() { local b; b="$RW_DIR/backups/$(basename "$PROXY_FILE").$1-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RW_DIR/backups"; cp -a "$PROXY_FILE" "$b"; echo "$b"; }

panel_code() { # [куки] → HTTP-код главной страницы панели (запрос с этого сервера)
  local p; p=$(detect_old)
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 ${1:+-H "Cookie: $1"} --resolve "$p:443:127.0.0.1" "https://$p/" 2>/dev/null
}

# ---------- страница подписки ----------
SP_CT="remnawave-subscription-page"
sp_dir() { echo "$RW_DIR/subscription"; }

sp_compose() {
  cat <<EOF
# Создано RemnaPilot по docs.rw (Subscription page → bundled)
services:
  $SP_CT:
    image: remnawave/subscription-page:latest
    container_name: $SP_CT
    hostname: $SP_CT
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF
}

sp_installed() { [[ -f "$(sp_dir)/docker-compose.yml" ]]; }

sp_status() {
  local st; st=$(docker inspect -f '{{.State.Status}}' "$SP_CT" 2>/dev/null)
  box_top
  if sp_installed; then
    box_line "$(dot "$([[ "$st" == running ]] && echo ok || echo err)") $(padr "Страница" 10)${C0}${CB}https://$(sub_host)${C0}"
    box_line "  $(padr "Контейнер" 10)${C0}${st:-не найден}"
  else
    box_line "$(dot warn) $(padr "Страница" 10)${C0}не установлена"
    box_line "  $(padr "Подписка" 10)https://$(sub_current)"
  fi
  box_bottom
}

subpage_install() {
  need_panel || return 1; need_proxy || return 1
  local panel cur dom new_block=0 d tok out bk c k host_c host_k doms
  panel=$(detect_old); cur=$(sub_host)
  echo "Страница подписки — красивая страница для клиентов: ссылки для приложений, QR-код, инструкции."
  echo "Ставлю по docs.rw рядом с панелью; ссылки подписки клиентов остаются прежними."
  if [[ -n "$cur" && "$cur" != "$panel" ]]; then
    pi_ask_domain "Домен страницы подписки [$cur]" dom 1 || return $RP_CANCEL
    dom="${dom:-$cur}"
  else
    echo "  Сейчас подписка отдаётся с домена панели ($panel/api/sub). Странице нужен свой домен."
    pi_ask_domain "Домен страницы подписки (например sub.example.com)" dom || { echo "  Отменено."; return $RP_CANCEL; }
  fi
  [[ "$dom" == "$panel" ]] && { fail "Это домен панели"; todo "страница подписки работает только на своём домене или поддомене"; return 1; }
  [[ "$dom" != "$cur" ]] && new_block=1
  if (( new_block )); then
    D="$dom" perl -ne 'BEGIN{$d=quotemeta $ENV{D}} $h=1 if /(?<![\w.-])$d(?![\w-])/; END{exit !$h}' "$PROXY_FILE" && new_block=0
    DNS_WARN=""; check_dns "$dom"; dns_confirm || { echo "  Отменено."; return $RP_CANCEL; }
  fi
  api_ready || return $?
  tok=$(cat "$API_CONF")

  steps 4
  step "Создаю $(sp_dir)"
  mkdir -p "$(sp_dir)"; sp_compose > "$(sp_dir)/docker-compose.yml"
  ( umask 077; printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://remnawave:3000\nREMNAWAVE_API_TOKEN=%s\nCUSTOM_SUB_PREFIX=\nMARZBAN_LEGACY_LINK_ENABLED=false\nTRUST_PROXY=1\n' "$tok" > "$(sp_dir)/.env" )

  step "Запускаю страницу подписки"
  out=$(cd "$(sp_dir)" && docker compose pull -q 2>&1 && docker compose up -d 2>&1) || { fail "Страница подписки не запустилась" docker "$out"; steps_done; return 1; }
  # у образа есть healthcheck (/internal/health) — ждём «healthy»
  wait_healthy "$SP_CT" 90 && [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$SP_CT" 2>/dev/null)" =~ ^(healthy|)$ ]] \
    || { fail "Страница подписки не запустилась" container "$(docker logs --tail 40 "$SP_CT" 2>&1)"; steps_done; return 1; }
  green "✔ Контейнер $SP_CT работает"

  step "Направляю домен $dom на страницу"
  bk=$(proxy_backup subpage)
  if [[ "$PROXY_KIND" == nginx ]]; then
    if (( new_block )); then
      IFS=$'\t' read -r c k _ < <(nginx_blocks | awk -F'\t' -v d="$panel" '{n=" "$3" "; if (index(n," "d" ")) {print; exit}}')
      local blk; blk=$(echo; pi_server "$dom" "http://$SP_CT:3010" | sed "s|/etc/nginx/ssl/fullchain.pem|${c:-/etc/nginx/ssl/fullchain.pem}|; s|/etc/nginx/ssl/privkey.key|${k:-/etc/nginx/ssl/privkey.key}|")
      # новый server перед «server_name _» (default), иначе в конец
      out=$(B="$blk" perl -0777 -pe 's/(\nserver\s*\{\s*\n\s*listen 443 ssl default_server)/$ENV{B}$1/ or $_ .= $ENV{B}' "$PROXY_FILE"); printf '%s\n' "$out" > "$PROXY_FILE"
    else
      ! nginx_blocks | awk -F'\t' -v d="$dom" -v p="$panel" '{n=" "$3" "; if (index(n," "d" ") && index(n," "p" ")) f=1} END{exit !f}' \
        || { fail "Домен подписки в одном блоке nginx с панелью"; todo "раздели их: Домены → Сменить домены"; steps_done; return 1; }
      block_edit "$PROXY_FILE" "$dom" 's{proxy_pass\s+[^;]+;}{proxy_pass http://'"$SP_CT"':3010;}g; s{^\s*rewrite\s+[^\n]*api/sub[^\n]*\n}{}mg'
    fi
  else
    if (( new_block )); then
      printf '\nhttps://%s {\n    encode gzip zstd\n    reverse_proxy * http://%s:3010\n}\n' "$dom" "$SP_CT" >> "$PROXY_FILE"
    else
      block_edit "$PROXY_FILE" "$dom" 's{^\s*rewrite\s+\*\s+/api/sub\{uri\}\s*\n}{}mg; s{reverse_proxy\s+(\*\s+)?\S+}{reverse_proxy * http://'"$SP_CT"':3010}g'
    fi
  fi
  proxy_apply "$bk" || { steps_done; return 1; }
  green "✔ $dom → страница подписки (копия конфига: $bk)"

  step "Сертификат и адрес подписки в панели"
  if (( new_block )) && [[ "$PROXY_KIND" == nginx ]]; then
    if host_c=$(host_path "$c") && host_k=$(host_path "$k"); then
      doms=$(nginx_blocks | awk -F'\t' -v c="$c" '$1==c {print $3}' | tr ' ' '\n' | grep -v '^\*\|^_$' | awk 'NF && !s[$0]++' | tr '\n' ' ')
      CERT_FULL="$host_c" CERT_KEY="$host_k" CERT_EXTRA="$doms" issue_cert "$panel" \
        || { yel "⚠ Сертификат для $dom не выпущен — страница откроется с предупреждением браузера."; todo "выпусти позже: Панель → Сертификаты"; }
    fi
  fi
  if [[ "$(sub_current)" != "$dom" ]]; then
    env_set SUB_PUBLIC_DOMAIN "$dom"
    out=$(cd "$RW_DIR" && docker compose up -d 2>&1) || log_tail "$out" 3
    wait_healthy remnawave 120 >/dev/null
    info "Адрес подписки в панели: $dom (старые ссылки $panel/api/sub/… продолжают работать)"
  fi
  steps_done "Страница подписки"
  echo; green "Страница подписки: https://$dom/<shortUuid>"
  echo "  Оформление (приложения, тексты): в панели → Страница подписки."
}

subpage_remove() {
  sp_installed || { echo "  Страница подписки не установлена."; return 0; }
  need_proxy || return 1
  local dom bk out; dom=$(sub_host)
  echo "Уберу страницу подписки. Домен $dom останется и будет отдавать подписку напрямую из панели — ссылки клиентов не сломаются."
  ask "Убрать страницу подписки? [y/N]"; read -r out; [[ "$out" =~ ^[YyДд]$ ]] || { echo "  Отменено."; return $RP_CANCEL; }
  bk=$(proxy_backup subpage-off)
  if [[ "$PROXY_KIND" == nginx ]]; then
    block_edit "$PROXY_FILE" "$dom" 's{proxy_pass\s+http://'"$SP_CT"':3010;}{proxy_pass http://remnawave/api/sub/;}g'
  else
    block_edit "$PROXY_FILE" "$dom" 's{(\n\s*)reverse_proxy\s+\*\s+http://'"$SP_CT"':3010}{$1rewrite * /api/sub{uri}$1reverse_proxy * http://remnawave:3000}g'
  fi
  proxy_apply "$bk" || return 1
  out=$(cd "$(sp_dir)" && docker compose down --rmi all 2>&1) || log_tail "$out" 3
  rm -rf "$(sp_dir)"
  green "✔ Страница подписки убрана; https://$dom/<shortUuid> отдаёт подписку из панели"
}

subpage_menu() {
  local c
  while true; do
    screen "Страница подписки"; echo; sp_status
    section "ДЕЙСТВИЯ"
    item 1 "$(sp_installed && echo "Переустановить или сменить домен" || echo "Установить страницу подписки")" "remnawave/subscription-page"
    sp_installed && item 2 "Убрать страницу подписки" "подписка снова отдаётся панелью"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Страница подписки" subpage_install; pause ;;
      2) sp_installed && { run_action "Страница подписки: убрать" subpage_remove; pause; } ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- переустановка панели с сохранением данных ----------
panel_reinstall() {
  need_panel || return 1
  local dir="$RW_DIR" f out keep main="$RW_DIR/docker-compose.yml" a
  [[ -f "$main" ]] || main=$(compose_of "$dir") || { fail "Нет docker-compose.yml панели в $dir"; return 1; }
  echo "Переустановка: свежие образы и контейнеры, база создаётся заново и заполняется из бэкапа."
  echo "Помогает, когда панель сломалась после обновления, ручных правок или сбоя диска."
  green "Сохранится: пользователи, ноды, хосты, настройки (из бэкапа), .env, домены, сертификаты, nginx/Caddy."
  ask "Переустановить панель? [y/N]"; read -r a; [[ "$a" =~ ^[YyДд]$ ]] || { echo "  Отменено."; return $RP_CANCEL; }

  steps 5
  step "Бэкап базы и настроек"
  backup_db reinstall >/dev/null 2>&1 || { fail "Бэкап базы не получился — без него переустанавливать нельзя" db "$BK_ERR"; steps_done; return 1; }
  f=$(ls -1t "$dir"/backups/db-*-reinstall.sql.gz 2>/dev/null | head -1)
  [[ -s "$f" ]] || { fail "Бэкап базы пустой"; steps_done; return 1; }
  keep="$dir/backups/reinstall-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$keep"
  cp -a "$dir/.env" "$main" "$keep/"
  green "✔ Бэкап: $f"

  step "Удаляю контейнеры, образы и старую базу"
  stack_down >/dev/null 2>&1
  out=$(cd "$dir" && docker compose -f "$main" down -v --rmi all --remove-orphans 2>&1) || log_tail "$out" 3

  step "Ставлю свежие образы и запускаю"
  out=$(cd "$dir" && docker compose -f "$main" pull 2>&1 && docker compose -f "$main" up -d 2>&1) \
    || { fail "Панель не запустилась" docker "$out"; todo "бэкап на месте: $f" "восстановить: Панель → Восстановить из дампа"; steps_done; return 1; }
  wait_healthy remnawave 180 || { fail "Панель не запустилась" container "$(docker logs --tail 60 remnawave 2>&1)"; todo "бэкап на месте: $f"; steps_done; return 1; }

  step "Возвращаю данные из бэкапа"
  RESTORE_FILE="$f" RESTORE_YES=1 restore_db >/dev/null 2>&1 \
    || { fail "Данные не вернулись из бэкапа"; todo "повтори вручную: Панель → Восстановить из дампа → ${f##*/}"; steps_done; return 1; }

  step "Запускаю веб-сервер и проверяю"
  stack_up >/dev/null 2>&1
  wait_healthy remnawave 120 || { fail "Панель не запустилась после восстановления" container "$(docker logs --tail 60 remnawave 2>&1)"; steps_done; return 1; }
  local code; code=$(panel_code)
  steps_done "Переустановка панели"
  green "✔ Панель переустановлена, данные на месте"
  [[ "$code" =~ ^[234] ]] && echo "  https://$(detect_old) отвечает (HTTP $code)"
  echo "  Копия .env и compose до переустановки: $keep"
}

# ---------- закрыть вход в панель ----------
ACCESS_CONF="/etc/rw/access.conf"
acc_get() { grep -m1 "^$1=" "$ACCESS_CONF" 2>/dev/null | cut -d= -f2-; }
acc_set() { mkdir -p /etc/rw; touch "$ACCESS_CONF"; chmod 600 "$ACCESS_CONF"; perl -i -ne "print unless /^\Q$1\E=/" "$ACCESS_CONF"; [[ -n "$2" ]] && echo "$1=$2" >> "$ACCESS_CONF"; return 0; }
acc_on() { [[ -n "$(acc_get IPS)$(acc_get KEY)" ]]; }

acc_name() {
  local i k; i=$(acc_get IPS); k=$(acc_get KEY)
  if [[ -n "$i" && -n "$k" ]]; then echo "только мои IP и секретная ссылка"
  elif [[ -n "$i" ]]; then echo "только IP: $i"
  elif [[ -n "$k" ]]; then echo "по секретной ссылке"
  else echo "открыт для всех"; fi
}

valid_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ || "$1" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]]; }

acc_nginx_http() { # $1 IP, $2 ключ
  local ip
  printf 'geo $rp_ip_ok {\n    default 0;\n'; for ip in $1; do printf '    %s 1;\n' "$ip"; done; printf '}\n'
  printf 'map $cookie_rp_key $rp_key_ok {\n    default 0;\n'; [[ -n "$2" ]] && printf '    "%s" 1;\n' "$2"; printf '}'
}

acc_nginx_srv() { # $1 ключ
  printf '    # rp-access begin\n    set $rp_pass "$rp_ip_ok$rp_key_ok";\n    if ($uri ~ "^/api/sub/") { set $rp_pass "1"; }\n'
  [[ -n "$1" ]] && printf '    if ($uri = "/%s") { set $rp_pass "1"; }\n' "$1"
  printf '    if ($rp_pass !~ "1") { return 404; }\n'
  [[ -n "$1" ]] && printf '    location = /%s {\n        add_header Set-Cookie "rp_key=%s; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax" always;\n        return 302 /;\n    }\n' "$1" "$1"
  printf '    # rp-access end\n'
}

acc_caddy_srv() { # $1 IP, $2 ключ
  printf '    # rp-access begin\n'
  [[ -n "$2" ]] && printf '    @rp_key path /%s\n    handle @rp_key {\n        header Set-Cookie "rp_key=%s; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax"\n        redir / 302\n    }\n' "$2" "$2"
  printf '    @rp_deny {\n'
  [[ -n "$1" ]] && printf '        not remote_ip %s\n' "$1"
  [[ -n "$2" ]] && printf '        not header_regexp Cookie (^|;\\s*)rp_key=%s(;|$)\n        not path /%s\n' "$2" "$2"
  printf '        not path /api/sub/*\n    }\n    respond @rp_deny 404\n    # rp-access end\n'
}

acc_apply() { # записать текущие настройки в конфиг веб-сервера
  need_proxy || return 1
  local ips key bk panel; ips=$(acc_get IPS); key=$(acc_get KEY); panel=$(detect_old)
  bk=$(proxy_backup access)
  if [[ "$PROXY_KIND" == nginx ]]; then
    if acc_on; then http_edit "$PROXY_FILE" rp-access-http "$(acc_nginx_http "$ips" "$key")"; else http_edit "$PROXY_FILE" rp-access-http ""; fi
    S="$(acc_on && acc_nginx_srv "$key")" block_edit "$PROXY_FILE" "$panel" \
      's/^[ \t]*# rp-access begin\n.*?^[ \t]*# rp-access end\n//gms; s/^(\s*server_name[^;]*;[^\n]*\n)/$1$ENV{S}\n/m if $ENV{S} ne ""'
  else
    S="$(acc_on && acc_caddy_srv "$ips" "$key")" block_edit "$PROXY_FILE" "$panel" \
      's/^[ \t]*# rp-access begin\n.*?^[ \t]*# rp-access end\n//gms; s/\A([^\n]*\{[^\n]*\n)/$1$ENV{S}\n/ if $ENV{S} ne ""'
  fi
  proxy_apply "$bk" || return 1
  local c0 c1; c0=$(panel_code)
  if acc_on; then
    if [[ "$c0" == 404 ]]; then green "✔ Вход в панель закрыт: $(acc_name)"
    else yel "⚠ Панель всё ещё открывается с этого сервера (HTTP ${c0:-нет ответа}) — проверь конфиг: $PROXY_FILE"; fi
    if [[ -n "$key" ]]; then
      c1=$(panel_code "rp_key=$key")
      [[ "$c1" != 404 ]] && green "✔ По секретной ссылке пускает (HTTP $c1)"
      echo; bold "  Секретная ссылка: https://$panel/$key"
      echo "  Открой её один раз в браузере — дальше панель открывается как обычно (запомнится на год)."
      echo "  Сохрани ссылку в надёжном месте: без неё и без своих IP войти в панель нельзя."
    fi
    echo "  Подписка клиентов работает как раньше. Остальные видят «404 Not Found»."
  else green "✔ Вход в панель открыт для всех (HTTP $c0)"; fi
  echo "  Копия конфига до изменения: $bk"
}

acc_ips_ask() {
  local me ips ip; me="${SSH_CLIENT%% *}"
  echo "Панель будет открываться только с этих IP (через пробел; можно подсеть, например 203.0.113.0/24)."
  [[ -n "$me" ]] && echo "  Твой IP сейчас: $me"
  echo "  Если IP домашнего интернета меняется — включи ещё и секретную ссылку, чтобы не потерять вход."
  ask "IP${me:+ [$me]}"; read -r ips; ips="${ips:-$me}"; ips=$(echo "$ips" | tr ',;' '  ' | xargs)
  [[ -n "$ips" ]] || { echo "  Отменено."; return $RP_CANCEL; }
  for ip in $ips; do valid_ip "$ip" || { fail "«$ip» — не похоже на IP"; return 1; }; done
  acc_set IPS "$ips"; acc_apply
}

acc_key_new() {
  local k; k=$(openssl rand -hex 16)
  [[ -n "$(acc_get KEY)" ]] && yel "Старая секретная ссылка перестанет работать (у кого она уже открыта — тоже)."
  acc_set KEY "$k"; acc_apply
}

acc_off() { acc_set IPS ""; acc_set KEY ""; acc_apply; }

access_menu() {
  local c
  need_panel || { pause; return; }
  while true; do
    screen "Закрыть вход в панель"; echo
    box_top; box_line "$(dot "$(acc_on && echo ok || echo warn)") $(padr "Вход" 10)${C0}$(acc_name)"; box_bottom
    echo "  Посторонние увидят «404 Not Found» вместо страницы входа. Подписка клиентов не трогается."
    section "ДЕЙСТВИЯ"
    item 1 "Только мои IP" "$( [[ -n "$(acc_get IPS)" ]] && echo "сейчас: $(acc_get IPS)")"
    item 2 "$( [[ -n "$(acc_get KEY)" ]] && echo "Новая секретная ссылка" || echo "Секретная ссылка")" "вход только после её открытия"
    [[ -n "$(acc_get KEY)" ]] && item 3 "Показать секретную ссылку"
    acc_on && item 4 "Открыть вход для всех" "выключить защиту"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Вход в панель: только IP" acc_ips_ask; pause ;;
      2) run_action "Вход в панель: секретная ссылка" acc_key_new; pause ;;
      3) [[ -n "$(acc_get KEY)" ]] && { bold "  https://$(detect_old)/$(acc_get KEY)"; pause; } ;;
      4) acc_on && { run_action "Вход в панель: открыть" acc_off; pause; } ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- защита от перебора пароля панели ----------
BF_LOG_DIR="/var/log/remnawave-panel"
F2B_JAIL="/etc/fail2ban/jail.d/remnawave-panel.local"
F2B_FILTER="/etc/fail2ban/filter.d/remnawave-panel.conf"
bf_on() { [[ -f "$F2B_JAIL" ]] || grep -qs 'rp-bf begin' "$PROXY_FILE" 2>/dev/null; }

bf_logpath() { # путь лога входов на хосте
  if [[ "$PROXY_KIND" == nginx ]]; then echo "$BF_LOG_DIR/auth.log"
  else local m; m=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$(caddy_ct)" 2>/dev/null); [[ -n "$m" ]] && echo "$m/rp-access.log"; fi
}

bf_nginx_mount() { # подключить каталог логов в compose nginx → 0, если подключён
  local ng cf out; ng=$(nginx_ct)
  docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$ng" 2>/dev/null | grep -qw /var/log/rp && return 0
  cf=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$ng" 2>/dev/null | cut -d, -f1)
  [[ -f "$cf" ]] || return 1
  grep -q "$BF_LOG_DIR:/var/log/rp" "$cf" || {
    cp -a "$cf" "$cf.bak-bf"
    L="$BF_LOG_DIR:/var/log/rp" perl -0777 -i -pe '$ok = s/^([ \t]*)(- [^\n]*:\/etc\/nginx\/[^\n]*\n)/$1$2$1- $ENV{L}\n/m; END { exit !$ok }' "$cf" \
      || { cp -a "$cf.bak-bf" "$cf"; return 1; }
  }
  mkdir -p "$BF_LOG_DIR"
  out=$(cd "$(dirname "$cf")" && docker compose -f "$cf" up -d 2>&1) || { cp -a "$cf.bak-bf" "$cf"; log_tail "$out" 3; return 1; }
  wait_healthy "$ng" 30
}

bf_enable() {
  need_panel || return 1; need_proxy || return 1
  local bk panel tgt lp f2b=1 out; panel=$(detect_old)
  steps 3
  step "Ограничение попыток входа в $PROXY_KIND"
  bk=$(proxy_backup bruteforce)
  if [[ "$PROXY_KIND" == nginx ]]; then
    bf_nginx_mount || { f2b=0; yel "⚠ Не смог подключить каталог логов к nginx — будет только ограничение частоты, без бана"; }
    tgt=$(D="$panel" perl -0777 -ne 'BEGIN{$d=quotemeta $ENV{D}} while (/server\s*\{(.*?)\n\}/gs) { my $b=$1; if ($b =~ /server_name[^;]*(?<![\w.-])$d(?![\w-])/ && $b =~ /location\s+\/\s*\{[^}]*?proxy_pass\s+([^;]+);/s) { print $1; last } }' "$PROXY_FILE")
    tgt="${tgt:-http://remnawave}"
    http_edit "$PROXY_FILE" rp-bf-http "$(printf 'limit_req_zone $binary_remote_addr zone=rp_login:10m rate=10r/m;\nlog_format rp_auth '"'"'$remote_addr [$time_local] "$request" $status'"'"';')"
    S="$(printf '    # rp-bf begin\n    location = /api/auth/login {\n        limit_req zone=rp_login burst=10 nodelay;\n        limit_req_status 429;\n%s        proxy_http_version 1.1;\n        proxy_pass %s;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_set_header X-Forwarded-Host $host;\n        proxy_set_header X-Forwarded-Port $server_port;\n    }\n    # rp-bf end\n' "$( (( f2b )) && printf '        access_log /var/log/rp/auth.log rp_auth;\n')" "${tgt%/}")" \
      block_edit "$PROXY_FILE" "$panel" 's/^[ \t]*# rp-bf begin\n.*?^[ \t]*# rp-bf end\n//gms; s/^(\s*server_name[^;]*;[^\n]*\n)/$1$ENV{S}\n/m'
  else
    S="$(printf '    # rp-bf begin\n    log {\n        output file /data/rp-access.log {\n            roll_size 10MiB\n            roll_keep 3\n        }\n    }\n    # rp-bf end\n')" \
      block_edit "$PROXY_FILE" "$panel" 's/^[ \t]*# rp-bf begin\n.*?^[ \t]*# rp-bf end\n//gms; s/\A([^\n]*\{[^\n]*\n)/$1$ENV{S}\n/'
  fi
  proxy_apply "$bk" || { steps_done; return 1; }
  [[ "$PROXY_KIND" == nginx ]] && green "✔ Не больше 10 попыток входа в минуту с одного IP (лишние получают 429)"

  step "fail2ban: бан за перебор"
  lp=$(bf_logpath)
  if (( f2b )) && [[ -n "$lp" ]]; then
    command -v fail2ban-client >/dev/null || { pkg_install fail2ban || { fail "fail2ban не установился" apt "$PKG_LOG"; steps_done; return 1; }; }
    mkdir -p "$(dirname "$lp")"; touch "$lp"
    if [[ "$PROXY_KIND" == nginx ]]; then
      printf '[Definition]\nfailregex = ^<HOST> [^"]*"POST /api/auth/login[^"]*" (400|401|403|429)\nignoreregex =\n' > "$F2B_FILTER"
    else
      printf '[Definition]\nfailregex = "client_ip":"<HOST>".*"method":"POST".*"uri":"/api/auth/login[^"]*".*"status":(400|401|403|429)\\b\nignoreregex =\ndatepattern = "ts":{EPOCH}\n' > "$F2B_FILTER"
    fi
    cat > "$F2B_JAIL" <<EOF
# RemnaPilot: перебор пароля панели Remnawave. Бан в цепочке DOCKER-USER — панель работает в Docker.
[remnawave-panel]
enabled  = true
filter   = remnawave-panel
logpath  = $lp
backend  = auto
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
ignoreip = 127.0.0.1/8 ::1 172.16.0.0/12
action   = iptables-allports[name=remnawave-panel, chain=DOCKER-USER]
EOF
    systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban 2>/dev/null || service fail2ban restart >/dev/null 2>&1
    local i; for i in 1 2 3 4 5; do fail2ban-client status remnawave-panel >/dev/null 2>&1 && break; sleep 2; done
    if fail2ban-client status remnawave-panel >/dev/null 2>&1; then green "✔ 5 неверных паролей за 10 минут → бан IP на час (повторно — дольше)"
    else fail "fail2ban не запустил защиту панели"; log_tail "$(journalctl -u fail2ban -n 15 --no-pager 2>/dev/null; fail2ban-client -t 2>&1)" 6; steps_done; return 1; fi
  fi

  step "Проверяю"
  steps_done "Защита от перебора"
  echo "  Разбанить IP: fail2ban-client set remnawave-panel unbanip 1.2.3.4"
}

bf_disable() {
  need_proxy || return 1
  local bk panel; panel=$(detect_old); bk=$(proxy_backup bruteforce-off)
  if [[ "$PROXY_KIND" == nginx ]]; then http_edit "$PROXY_FILE" rp-bf-http ""; fi
  block_edit "$PROXY_FILE" "$panel" 's/^[ \t]*# rp-bf begin\n.*?^[ \t]*# rp-bf end\n//gms'
  proxy_apply "$bk" || return 1
  rm -f "$F2B_JAIL" "$F2B_FILTER"
  command -v fail2ban-client >/dev/null && fail2ban-client reload >/dev/null 2>&1
  green "✔ Защита от перебора выключена (забаненные IP разбанены)"
}

bf_status() {
  local b f
  box_top
  if bf_on; then
    b=$(fail2ban-client status remnawave-panel 2>/dev/null | awk -F: '/Currently banned/ {gsub(/ /,"",$2); print $2}')
    f=$(fail2ban-client status remnawave-panel 2>/dev/null | awk -F: '/Total failed/ {gsub(/ /,"",$2); print $2}')
    box_line "$(dot ok) $(padr "Защита" 10)${C0}включена"
    [[ -n "$b" ]] && box_line "  $(padr "Забанено" 10)${C0}${b} IP сейчас · ошибок входа: ${f:-0}"
  else box_line "$(dot warn) $(padr "Защита" 10)${C0}выключена"; fi
  box_bottom
}

bf_menu() {
  local c
  need_panel || { pause; return; }
  while true; do
    proxy_find >/dev/null 2>&1
    screen "Защита от перебора пароля"; echo; bf_status
    echo "  Бан IP после 5 неверных паролей к панели (fail2ban) и не больше 10 попыток в минуту (nginx)."
    section "ДЕЙСТВИЯ"
    item 1 "$(bf_on && echo "Включить заново" || echo "Включить")"
    bf_on && item 2 "Выключить"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Защита от перебора: включить" bf_enable; pause ;;
      2) bf_on && { run_action "Защита от перебора: выключить" bf_disable; pause; } ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- мультипанель: другие серверы с панелью ----------
PANELS_FILE="/etc/rw/panels.list"   # имя user@host порт_ssh

mp_ssh() { # цель «имя|user@host|порт», команда → по SSH (без вопросов пароля)
  local nm h p; IFS='|' read -r nm h p <<< "$1"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$p" "$h" "$2"
}

mp_sudo() { [[ "$(cut -d'|' -f2 <<< "$1" | cut -d@ -f1)" == root ]] && echo "" || echo "sudo -n "; }

mp_list() {
  [[ -s "$PANELS_FILE" ]] || { echo "  Список пуст — добавь сервер панели (пункт 2)."; return 1; }
  local nm h p st i=0
  while read -r nm h p; do
    [[ -n "$nm" ]] || continue; i=$((i+1))
    st=$(mp_ssh "$nm|$h|$p" "$(mp_sudo "$nm|$h|$p")sh -c 'docker inspect -f \"{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}\" remnawave 2>/dev/null || echo none; grep -m1 ^FRONT_END_DOMAIN= /opt/remnawave/.env 2>/dev/null | cut -d= -f2; command -v rw >/dev/null && rw --version 2>/dev/null | head -1'" 2>/dev/null </dev/null)
    local s1 dom rv; s1=$(sed -n 1p <<< "$st"); dom=$(sed -n 2p <<< "$st" | tr -d '"'); rv=$(sed -n 3p <<< "$st" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    case "$s1" in
      "running healthy"|"running ") printf '  %2d) %s %-16s %-22s %s\n' "$i" "$(dot ok)" "$nm" "${dom:-$h}" "${rv:+RemnaPilot v$rv}" ;;
      none) printf '  %2d) %s %-16s %-22s %s\n' "$i" "$(dot warn)" "$nm" "$h" "$(T "панели нет")" ;;
      "")   printf '  %2d) %s %-16s %-22s %s\n' "$i" "$(dot err)" "$nm" "$h" "$(T "нет связи по SSH")" ;;
      *)    printf '  %2d) %s %-16s %-22s %s\n' "$i" "$(dot err)" "$nm" "${dom:-$h}" "$s1" ;;
    esac
  done < "$PANELS_FILE"
}

mp_add() {
  local name host port out
  ask "Сервер панели (user@IP, по умолчанию root@)"; read -r host; [[ -n "$host" ]] || { echo "  Отменено."; return $RP_CANCEL; }
  [[ "$host" == *@* ]] || host="root@$host"
  ask "SSH-порт [22]"; read -r port; port="${port:-22}"
  [[ "$port" =~ ^[0-9]+$ ]] || { fail "Некорректный порт: $port"; return 1; }
  ask "Имя [${host#*@}]"; read -r name; name="${name:-${host#*@}}"; name="${name// /_}"
  mkdir -p /etc/rw; touch "$PANELS_FILE"; chmod 600 "$PANELS_FILE"
  grep -qE "^[^ ]+ $host $port$" "$PANELS_FILE" && { yel "Уже в списке."; return 0; }
  echo "$name $host $port" >> "$PANELS_FILE"; green "✔ Добавлен: $name ($host:$port)"
  if ! out=$(mp_ssh "$name|$host|$port" true 2>&1 </dev/null); then
    yel "⚠ Без пароля по SSH не пускает — RemnaPilot нужен вход по ключу."
    local key="$HOME/.ssh/id_ed25519"
    [[ -f "$key" ]] || ssh-keygen -t ed25519 -N "" -f "$key" -q
    ask "Скопировать ключ на сервер сейчас (спросит пароль SSH один раз)? [Y/n]"; read -r out
    [[ "$out" =~ ^[NnНн]$ ]] || ssh-copy-id -i "$key.pub" -p "$port" -o StrictHostKeyChecking=accept-new "$host"
  fi
}

mp_remove() {
  mp_pick "Убрать из списка" || return $RP_CANCEL
  local nm h p; IFS='|' read -r nm h p <<< "$MP_T"
  H="$h" P="$p" perl -i -ne 'print unless /^\S+ \Q$ENV{H}\E \Q$ENV{P}\E$/' "$PANELS_FILE"
  green "✔ $nm убран из списка (на самом сервере ничего не менялось)"
}

mp_pick() { # заголовок → MP_T
  [[ -s "$PANELS_FILE" ]] || { echo "  Список пуст."; return 1; }
  local lines=() i c; mapfile -t lines < <(grep -v '^\s*$' "$PANELS_FILE")
  section "$1"
  for i in "${!lines[@]}"; do read -r nm h p <<< "${lines[$i]}"; item $((i+1)) "$nm" "$h"; done
  hr; item 0 "Отмена"; ask; read -r c
  [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#lines[@]} )) || return 1
  read -r nm h p <<< "${lines[$((c-1))]}"; MP_T="$nm|$h|$p"
}

mp_ensure_rw() { # поставить RemnaPilot на сервер, если его там нет или он старее
  local v sudo; sudo=$(mp_sudo "$1")
  v=$(mp_ssh "$1" "command -v rw >/dev/null && rw --version 2>/dev/null | head -1" </dev/null 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if [[ -z "$v" ]] || ver_newer "$v" "$RP_VERSION"; then
    info "Ставлю RemnaPilot v$RP_VERSION на ${1%%|*}..."
    mp_ssh "$1" "${sudo}sh -c 'cat > /usr/local/bin/rw.new && chmod 755 /usr/local/bin/rw.new && mv /usr/local/bin/rw.new /usr/local/bin/rw'" < "$RP_SELF" \
      || { fail "Не получилось поставить RemnaPilot на ${1%%|*}" ssh ""; return 1; }
  fi
}

mp_open() {
  mp_pick "Открыть RemnaPilot на сервере" || return $RP_CANCEL
  mp_ensure_rw "$MP_T" || return 1
  local nm h p; IFS='|' read -r nm h p <<< "$MP_T"
  info "Открываю меню на $nm — выход из него вернёт сюда."
  ssh -t -o StrictHostKeyChecking=accept-new -p "$p" "$h" "$(mp_sudo "$MP_T")rw${RP_LANG:+ --lang $RP_LANG}"
  return 0
}

mp_all() { # заголовок, аргументы rw — выполнить на всех серверах из списка
  [[ -s "$PANELS_FILE" ]] || { echo "  Список пуст."; return 1; }
  local nm h p t rc bad=0 out
  while read -r nm h p; do
    [[ -n "$nm" ]] || continue; t="$nm|$h|$p"
    section "$nm"
    mp_ensure_rw "$t" </dev/null || { bad=$((bad+1)); continue; }
    out=$(mp_ssh "$t" "$(mp_sudo "$t")rw $2" </dev/null 2>&1); rc=$?
    printf '%s\n' "$out" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -v '^\s*$' | tail -8 | sed 's/^/   /'
    if (( rc == 0 )); then green "✔ $nm"; else red "✖ $nm"; why_first "$out" ssh; bad=$((bad+1)); fi
  done < <(grep -v '^\s*$' "$PANELS_FILE")
  echo; (( bad )) && { yel "⚠ $1: не получилось на $bad сервер(ах)"; return 1; }
  green "✔ $1: готово на всех серверах"
}

multi_menu() {
  local c
  while true; do
    screen "Мультипанель"; echo
    echo "  Другие серверы с панелью Remnawave — управление отсюда по SSH."
    echo; mp_list
    section "ДЕЙСТВИЯ"
    item 1 "Обновить статус"
    item 2 "Добавить сервер панели"
    item 3 "Убрать из списка"
    item 4 "Открыть RemnaPilot на сервере" "его меню по SSH"
    item 5 "Бэкап всех панелей" "rw --backup на каждом"
    item 6 "Обновить все панели" "с бэкапом перед обновлением"
    item 7 "Проверить обновления на всех"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) ;;
      2) mp_add; pause ;;
      3) mp_remove; pause ;;
      4) mp_open; pause ;;
      5) run_action "Мультипанель: бэкап" mp_all "Бэкап" "--backup"; pause ;;
      6) run_action "Мультипанель: обновление" mp_all "Обновление" "--update"; pause ;;
      7) mp_all "Проверка обновлений" "--check-updates"; pause ;;
      0|q|"") return ;;
    esac
  done
}
