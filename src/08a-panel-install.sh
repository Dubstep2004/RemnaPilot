# ---------- установка панели ----------
# По официальной инструкции docs.rw: /opt/remnawave — docker-compose.yml и .env панели,
# /opt/remnawave/nginx — nginx (reverse proxy) с сертификатом Let's Encrypt.
# Раскладка та же, что у ручной установки, поэтому смена домена, продление и удаление доменов
# в RemnaPilot сразу работают с установленной панелью.
RW_SRC="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main"

pi_nginx_conf() { # домен панели, домен подписки (пусто — подписка на домене панели)
  cat <<'EOF'
# Создано RemnaPilot по docs.rw. Домены меняй через RemnaPilot: Домены → Сменить домены.
upstream remnawave {
    server remnawave:3000;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

EOF
  pi_server "$1" "http://remnawave"
  [[ -n "$2" ]] && pi_server "$2" "http://remnawave/api/sub/"
  cat <<'EOF'
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
}

pi_server() { # домен, куда проксировать
  cat <<EOF
server {
    server_name $1;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";

    location / {
        proxy_http_version 1.1;
        proxy_pass $2;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

EOF
}

pi_nginx_compose() {
  cat <<'EOF'
services:
  remnawave-nginx:
    image: nginx:1.30
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
    restart: always
    ports:
      - '0.0.0.0:443:443'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF
}

pi_caddyfile() { # домен панели, домен подписки (пусто — подписка на домене панели)
  echo "# Создано RemnaPilot по docs.rw. Сертификаты Caddy выпускает и продлевает сам."
  echo "# Домены меняй через RemnaPilot: Домены → Сменить домены."
  printf 'https://%s {\n    encode gzip zstd\n    reverse_proxy * http://remnawave:3000\n}\n\n' "$1"
  [[ -n "$2" ]] && printf 'https://%s {\n    encode gzip zstd\n    rewrite * /api/sub{uri}\n    reverse_proxy * http://remnawave:3000\n}\n\n' "$2"
  printf ':443 {\n    tls internal\n    respond 204\n}\n'
}

pi_caddy_compose() {
  cat <<'EOF'
services:
  caddy:
    image: caddy:2.9
    container_name: caddy
    hostname: caddy
    restart: always
    ports:
      - '0.0.0.0:443:443'
      - '0.0.0.0:80:80'
    networks:
      - remnawave-network
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy-ssl-data:/data

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true

volumes:
  caddy-ssl-data:
    driver: local
    external: false
    name: caddy-ssl-data
EOF
}

fw_allow_perm() { # порт — открыть насовсем, если firewall включён (fw_open открывает только на время)
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$1/tcp" >/dev/null && info "Открыл $1/tcp в ufw"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$1/tcp" >/dev/null && firewall-cmd --reload >/dev/null && info "Открыл $1/tcp в firewalld"; fi
  return 0
}

pi_ask_domain() { # подсказка, переменная; пустой ввод допустим, если $3=1
  local -n _d="$2"; local v
  while true; do
    ask "$1"; read -r v; v=$(clean_domain "$v")
    [[ -z "$v" && "${3:-0}" == 1 ]] && { _d=""; return 0; }
    [[ -z "$v" ]] && return 1
    valid_domain "$v" && { _d="$v"; return 0; }
    red "  «$v» — не похоже на домен (пример: panel.example.com)"
  done
}

panel_install() {
  local panel sub sub_env out pw k ok=1 code web dir="$RW_DIR"
  if [[ -f "$dir/.env" ]] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnawave; then
    fail "Панель уже установлена"; cause "уже есть .env или контейнер remnawave ($dir)"
    todo "сменить домены: Домены → Сменить домены" "обновить: Панель → Обновления"; return 1
  fi
  echo "Поставлю Remnawave по официальной инструкции docs.rw: панель, базу, nginx и сертификат Let's Encrypt."
  echo "Нужно: домен с A-записью на этот сервер и свободные порты 80 и 443."
  echo
  pi_ask_domain "Домен панели (например panel.example.com)" panel || { echo "  Отменено."; return $RP_CANCEL; }
  echo "  Ссылки подписки можно отдавать с домена панели или с отдельного домена."
  pi_ask_domain "Домен подписки (Enter — тот же, что у панели: $panel/api/sub)" sub 1 || return $RP_CANCEL
  [[ "$sub" == "$panel" ]] && sub=""
  DNS_WARN=""; check_dns "$panel"; [[ -n "$sub" ]] && check_dns "$sub"
  dns_confirm || { echo "  Отменено."; return $RP_CANCEL; }
  echo
  section "ВЕБ-СЕРВЕР"
  item 1 "Nginx" "сертификат через acme.sh, как в docs.rw"
  item 2 "Caddy" "сам выпускает и продлевает сертификат"
  ask "Выберите веб-сервер [1]"; read -r web
  case "${web:-1}" in 1) web=nginx ;; 2) web=caddy ;; *) echo "  Отменено."; return $RP_CANCEL ;; esac

  steps 6
  step "Проверяю сервер: Docker, порты"
  if ! command -v docker >/dev/null; then
    info "Устанавливаю Docker (get.docker.com)..."
    out=$(curl -fsSL https://get.docker.com | sh 2>&1) || { fail "Docker не установился" apt "$out"; steps_done; return 1; }
    green "✔ Docker установлен"
  fi
  need_compose || { steps_done; return 1; }
  command -v openssl >/dev/null || pkg_install openssl || { fail "Не установлен openssl" apt "$PKG_LOG"; steps_done; return 1; }
  for k in 80 443; do
    port_busy "$k" && { yel "⚠ Порт $k занят: $(port_owner "$k") — для сертификата и nginx он нужен свободным"; ok=0; }
  done
  (( ok )) || { ask "Продолжить всё равно? [y/N]"; read -r k; [[ "$k" =~ ^[Yy]$ ]] || { echo "  Отменено."; steps_done; return $RP_CANCEL; }; }

  step "Скачиваю Remnawave и создаю секреты"
  mkdir -p "$dir/$web" "$dir/backups" && chmod 700 "$dir"
  out=$( { curl -fsSL -o "$dir/docker-compose.yml" "$RW_SRC/docker-compose-prod.yml" \
           && curl -fsSL -o "$dir/.env" "$RW_SRC/.env.sample"; } 2>&1 ) \
    || { fail "Файлы Remnawave не скачались" net "$out"; rm -f "$dir/.env"; steps_done; return 1; }
  chmod 600 "$dir/.env"
  for k in APP_SECRET JWT_AUTH_SECRET JWT_API_TOKENS_SECRET METRICS_PASS WEBHOOK_SECRET_HEADER; do
    grep -q "^$k=" "$dir/.env" && env_set "$k" "$(openssl rand -hex 64)"
  done
  pw=$(openssl rand -hex 24)
  env_set POSTGRES_PASSWORD "$pw"
  PW="$pw" perl -pi -e 's|^(DATABASE_URL="?postgresql://[^:]+:)[^@]*(@)|$1$ENV{PW}$2|' "$dir/.env"
  env_set FRONT_END_DOMAIN "$panel"
  grep -q '^PANEL_DOMAIN=' "$dir/.env" && env_set PANEL_DOMAIN "$panel"
  sub_env="${sub:-$panel/api/sub}"; env_set SUB_PUBLIC_DOMAIN "$sub_env"
  green "✔ Секреты и пароль базы созданы случайно (они в $dir/.env, файл доступен только root)"

  step "Запускаю панель и базу"
  out=$(cd "$dir" && docker compose pull 2>&1 && docker compose up -d 2>&1) \
    || { fail "Панель не запустилась" docker "$out"; steps_done; return 1; }
  wait_healthy remnawave 180 || { fail "Панель не запустилась" container "$(docker logs --tail 60 remnawave 2>&1)"; steps_done; return 1; }
  green "✔ Панель и база работают"

  local le=1
  if [[ "$web" == caddy ]]; then
    step "Запускаю Caddy"
    pi_caddyfile "$panel" "$sub" > "$dir/caddy/Caddyfile"
    pi_caddy_compose > "$dir/caddy/docker-compose.yml"
    fw_allow_perm 80; fw_allow_perm 443                       # Caddy продлевает сертификат сам, через 80/443
    out=$(cd "$dir/caddy" && docker compose up -d 2>&1) || { fail "Caddy не запустился" docker "$out"; steps_done; return 1; }
    wait_healthy caddy 30 || { fail "Caddy не запустился" container "$(docker logs --tail 30 caddy 2>&1)"; steps_done; return 1; }

    step "Жду, пока Caddy выпустит сертификат"
    for k in $(seq 1 30); do
      curl -s -o /dev/null --max-time 5 --resolve "$panel:443:127.0.0.1" "https://$panel/" && break
      sleep 2
    done
    if curl -s -o /dev/null --max-time 5 --resolve "$panel:443:127.0.0.1" "https://$panel/"; then green "✔ Сертификат выпущен"
    else
      le=0
      yel "⚠ Caddy пока не выпустил сертификат — обычно домен не указывает на сервер или закрыт порт 80/443."
      todo "проверь A-запись домена и порты у хостера" "логи Caddy: docker logs --tail 30 caddy" "Caddy будет пробовать сам — перезапускать ничего не нужно"
    fi
  else
    step "Запускаю nginx (пока с временным сертификатом)"
    pi_nginx_conf "$panel" "$sub" > "$dir/nginx/nginx.conf"
    pi_nginx_compose > "$dir/nginx/docker-compose.yml"
    # временный самоподписанный сертификат: nginx нужен запущенным, чтобы acme.sh мог его перезагрузить
    out=$(openssl req -x509 -nodes -newkey rsa:2048 -days 7 -subj "/CN=$panel" \
            -keyout "$dir/nginx/privkey.key" -out "$dir/nginx/fullchain.pem" 2>&1) \
      || { fail "Временный сертификат не создался" "" ""; log_tail "$out"; steps_done; return 1; }
    chmod 600 "$dir/nginx/privkey.key"
    out=$(cd "$dir/nginx" && docker compose up -d 2>&1) || { fail "nginx не запустился" docker "$out"; steps_done; return 1; }
    wait_healthy remnawave-nginx 30 || { fail "nginx не запустился" container "$(docker logs --tail 30 remnawave-nginx 2>&1)"; steps_done; return 1; }
    fw_allow_perm 443                                         # порт 80 для продления откроется сам, на время

    step "Выпускаю сертификат Let's Encrypt"
    if ! CERT_EXTRA="$sub" issue_cert "$panel"; then
      le=0
      yel "⚠ Сертификат Let's Encrypt не выпущен — панель открывается, но браузер предупредит о небезопасном сертификате."
      todo "выпусти его позже: Панель → Сертификаты → 2"
    fi

  fi

  step "Проверяю, что панель открывается"
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$panel:443:127.0.0.1" "https://$panel/")
  if [[ "$code" =~ ^[23] ]]; then green "✔ https://$panel отвечает (HTTP $code)"
  else yel "⚠ https://$panel ответил HTTP ${code:-нет ответа} — проверь логи: Панель → Логи"; fi
  steps_done "Установка панели"
  echo
  green "Панель:   https://$panel"
  green "Подписка: https://$sub_env/…"
  echo "  Открой панель в браузере и создай администратора — первый вход регистрирует его."
  echo "  Дальше: Установка → Установка и обновление нод — поставить ноду; Защита → Firewall — закрыть лишние порты."
  (( le )) || return 1
}

# ---------- удаление панели ----------
confirm_delete() { # подсказка → 0, если человек ввёл УДАЛИТЬ (или DELETE)
  local a; ask "$1 — введи УДАЛИТЬ"; read -r a
  [[ "$a" == "УДАЛИТЬ" || "$a" == "удалить" || "$a" == "DELETE" || "$a" == "delete" ]]
}

panel_uninstall() {
  local dir="$RW_DIR" c cs=() doms=() d acme bk tmp out
  case "${dir%/}" in ""|/|/root|/opt|/home|/etc|/var|/usr) fail "Каталог панели «$dir» удалять опасно"; todo "Прочее → Сменить каталог панели"; return 1 ;; esac
  [[ -f "$dir/.env" || -n "$(find_composes 2>/dev/null)" ]] || { fail "Панель не найдена в $dir"; todo "если она в другом месте: Прочее → Сменить каталог панели"; return 1; }
  mapfile -t cs < <(find_composes | awk -v r="$dir/docker-compose.yml" '$0 != r' ; [[ -f "$dir/docker-compose.yml" ]] && echo "$dir/docker-compose.yml")
  mapfile -t doms < <({ detect_old; all_proxy_domains 2>/dev/null; sub_host; } | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | sort -u)
  local names; names=$(for c in "${cs[@]}"; do (cd "$(dirname "$c")" && docker compose -f "$c" ps -a --format '{{.Name}}' 2>/dev/null); done | sort -u | tr '\n' ' ')
  red "Будет удалено навсегда:"
  echo "  • контейнеры панели, базы, Redis и веб-сервера: ${names:-—}"
  echo "  • база данных: пользователи, ноды, хосты, настройки панели"
  echo "  • каталог $dir"
  (( ${#doms[@]} )) && echo "  • сертификаты: ${doms[*]}"
  green "Останется: ноды на других серверах, RemnaPilot, firewall и SSH."
  echo "  Перед удалением сделаю последний бэкап — его можно будет развернуть на новой панели."
  echo
  confirm_delete "Удалить панель" || { echo "  Отменено."; return $RP_CANCEL; }

  steps 4
  step "Последний бэкап базы и настроек"
  bk="${RP_REMOVED_DIR:-/root}/remnawave-removed-$(date +%Y%m%d-%H%M%S).tar.gz"; tmp=$(mktemp -d)
  if backup_db removed >/dev/null 2>&1; then cp -a "$(ls -1t "$dir"/backups/db-*-removed.sql.gz | head -1)" "$tmp/"
  else
    local why; why=$(why_short db "$BK_ERR"); yel "⚠ Бэкап базы не получился${why:+: $why}."
    confirm_delete "Удалить без бэкапа базы? Данные пропадут" || { rm -rf "$tmp"; echo "  Отменено."; steps_done; return $RP_CANCEL; }
  fi
  for c in .env docker-compose.yml nginx/nginx.conf caddy/Caddyfile; do [[ -f "$dir/$c" ]] && cp -a "$dir/$c" "$tmp/${c//\//-}"; done
  [[ -s "$NODES_FILE" ]] && cp -a "$NODES_FILE" "$tmp/"
  tar -C "$tmp" -czf "$bk" . && chmod 600 "$bk" && green "✔ Бэкап: $bk ($(du -h "$bk" | cut -f1))"
  rm -rf "$tmp"

  step "Останавливаю и удаляю контейнеры и данные"
  for c in "${cs[@]}"; do
    out=$(cd "$(dirname "$c")" && docker compose -f "$c" down -v --rmi all --remove-orphans 2>&1) || log_tail "$out" 3
  done

  step "Удаляю сертификаты и их автопродление"
  acme=$(acme_bin 2>/dev/null)
  for d in "${doms[@]}"; do
    [[ -n "$acme" ]] && "$acme" --remove -d "$d" >/dev/null 2>&1
    rm -rf "$HOME/.acme.sh/$d" "$HOME/.acme.sh/${d}_ecc"
    rm -f "$HOOK_DIR/$d"-*.sh "$HOOK_DIR/$d.state" "$HOOK_DIR/$d.fw"
  done

  step "Удаляю каталог панели"
  rm -rf "${dir:?}"
  if [[ "$(bk_get SCHED off)" != off ]]; then bk_set SCHED off; bk_install_cron; info "Автобэкап выключен — бэкапить больше нечего"; fi
  steps_done "Удаление панели"
  green "✔ Панель удалена."
  echo "  Бэкап: $bk"
  echo "  Вернуть на этом или другом сервере: Установка → Установить панель,"
  echo "  затем распакуй архив в $dir/backups и выбери дамп: Панель → Восстановить из дампа."
}
