# ---------- автообновление сертификата ----------
HOOK_DIR="/usr/local/lib/rw-cert"

nginx_ct() {
  local n
  n=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$2 ~ /nginx|angie/ && $1 ~ /remna/ {print $1; exit}')
  [[ -z "$n" ]] && n=$(find_composes | xargs -r grep -hoE 'container_name:[[:space:]]*["'"'"']?[A-Za-z0-9_.-]*(nginx|angie)[A-Za-z0-9_.-]*' 2>/dev/null \
                        | head -1 | sed -E 's/.*:[[:space:]]*["'"'"']?//')
  echo "${n:-remnawave-nginx}"
}

write_renew_hooks() { # $1 = домен, $2 = порт для standalone (пусто для dns)
  local d="$1" p="${2:-}" ng x
  ng=$(nginx_ct)
  mkdir -p "$HOOK_DIR"
  {
    echo '#!/bin/sh'
    echo "# остановка того, что мешает выпуску (сгенерировано RemnaPilot)"
    echo "docker stop $ng >/dev/null 2>&1"
    for x in "${STOPPED_CT[@]:-}";  do [[ -n "$x" ]] && echo "docker stop $x >/dev/null 2>&1"; done
    for x in "${STOPPED_SVC[@]:-}"; do [[ -n "$x" ]] && echo "systemctl stop $x"; done
    if [[ -n "$p" ]]; then cat <<EOF
rm -f $HOOK_DIR/$d.fw
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active' && ! ufw status | grep -qE '^($p|$p/tcp)[[:space:]]+ALLOW'; then
  ufw allow $p/tcp >/dev/null && echo ufw > $HOOK_DIR/$d.fw
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1 && ! firewall-cmd --query-port=$p/tcp >/dev/null 2>&1; then
  firewall-cmd --add-port=$p/tcp >/dev/null && echo fwd > $HOOK_DIR/$d.fw
fi
EOF
    fi
    echo "exit 0"
  } > "$HOOK_DIR/$d-pre.sh"

  {
    echo '#!/bin/sh'
    if [[ -n "$p" ]]; then cat <<EOF
case "\$(cat $HOOK_DIR/$d.fw 2>/dev/null)" in
  ufw) ufw delete allow $p/tcp >/dev/null ;;
  fwd) firewall-cmd --remove-port=$p/tcp >/dev/null ;;
esac
rm -f $HOOK_DIR/$d.fw
EOF
    fi
    for x in "${STOPPED_SVC[@]:-}"; do [[ -n "$x" ]] && echo "systemctl start $x"; done
    for x in "${STOPPED_CT[@]:-}";  do [[ -n "$x" ]] && echo "docker start $x >/dev/null 2>&1"; done
    echo "docker start $ng >/dev/null 2>&1"
    echo "exit 0"
  } > "$HOOK_DIR/$d-post.sh"

  printf '#!/bin/sh\ndocker restart %s >/dev/null 2>&1\nexit 0\n' "$ng" > "$HOOK_DIR/$d-reload.sh"
  chmod +x "$HOOK_DIR/$d"-*.sh
}

ensure_acme_cron() { # $1 = путь к acme.sh
  crontab -l 2>/dev/null | grep -q 'acme.sh.*--cron' || "$1" --install-cronjob >/dev/null 2>&1
}

acme_bin() {
  local a="${ACME:-$HOME/.acme.sh/acme.sh}"
  command -v acme.sh >/dev/null && a="$(command -v acme.sh)"
  [[ -x "$a" ]] && echo "$a"
}

cert_file_for() { # путь к fullchain сертификата домена (по конфигу nginx, иначе стандартный)
  local cp; cp=$(cert_paths_for "$1" 2>/dev/null)
  [[ -n "$cp" ]] && echo "${cp%%$'\t'*}" || echo "$RW_DIR/nginx/fullchain.pem"
}

cert_domain() { # CN из текущего сертификата панели
  local f; f=$(cert_file_for "$(detect_old)")
  [[ -f "$f" ]] && openssl x509 -noout -subject -in "$f" 2>/dev/null | sed -E 's/.*CN ?= ?//; s/[,/].*//'
}

cert_status() {
  local f days end cn a
  section "СЕРТИФИКАТЫ"
  local found=0
  local certs=() c
  while IFS=$'\t' read -r c _ _; do [[ -n "$c" ]] && c=$(host_path "$c") && certs+=("$c"); done < <(nginx_blocks)
  certs+=("$RW_DIR"/nginx/*.pem "$RW_DIR"/nginx/*.crt)
  local seen=" "
  for f in "${certs[@]}"; do
    [[ -f "$f" && "$seen" != *" $f "* ]] || continue; seen+="$f "
    openssl x509 -noout -in "$f" >/dev/null 2>&1 || continue
    found=1
    cn=$(openssl x509 -noout -subject -in "$f" | sed -E 's/.*CN ?= ?//; s/[,/].*//')
    end=$(openssl x509 -noout -enddate -in "$f" | cut -d= -f2)
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    if   (( days < 0 ));  then red   "  ✗ $cn — ИСТЁК $((-days)) дн. назад ($(basename "$f"))"
    elif (( days < 15 )); then yel   "  ⚠ $cn — осталось $days дн. ($(basename "$f"))"
    else                       green "  ✓ $cn — осталось $days дн. ($(basename "$f"))"; fi
  done
  (( found )) || echo "  Сертификатов Nginx не найдено (Caddy/Traefik обновляют их сами)."

  section "АВТООБНОВЛЕНИЕ"
  a=$(acme_bin)
  if [[ -z "$a" ]]; then red "  acme.sh не установлен"
  else
    crontab -l 2>/dev/null | grep -q 'acme.sh.*--cron' && green "  ✓ cron acme.sh есть" || red "  ✗ cron acme.sh не найден"
    local hk; hk=$(ls "$HOOK_DIR"/*-pre.sh 2>/dev/null | xargs -r -n1 basename | sed 's/-pre\.sh$//' | tr '\n' ' ')
    [[ -n "$hk" ]] && green "  ✓ хуки продления настроены: $hk" \
      || yel "  ⚠ хуков нет — при standalone-выпуске продление упрётся в занятый порт (исправит пункт 2)"
    "$a" --list 2>/dev/null | sed 's/^/  /'
  fi
}

renew_now() {
  local d ng m in
  d=$(cert_domain); [[ -z "$d" ]] && d=$(detect_old)
  local sd; sd=$(sub_current); sd="${sd%%/*}"
  [[ -n "$sd" && "$sd" != "$d" ]] && info "Домен подписки: $sd"
  ask "Домен [$d]"; read -r in; d=$(clean_domain "${in:-$d}")
  valid_domain "$d" || { err "некорректный домен"; return 1; }
  section "СПОСОБ"; item 1 "Авто"; item 2 "Порт 80" "$(method_hint http)"; item 3 "Порт 443" "$(method_hint alpn)"; item 4 "DNS Cloudflare" "порты не нужны"; item 5 "DNS вручную" "TXT у регистратора"
  ask "Выбор [1]"; read -r m
  case "$m" in 2) CERT_METHOD=http ;; 3) CERT_METHOD=alpn ;; 4) CERT_METHOD=dns ;; 5) CERT_METHOD=manual ;; *) CERT_METHOD="" ;; esac
  ng=$(nginx_ct)
  docker stop "$ng" >/dev/null 2>&1 && echo "Остановил $ng на время выпуска"
  issue_cert "$d"
  docker start "$ng" >/dev/null 2>&1 && echo "Запустил $ng"
  CERT_METHOD=""
}

test_renew() {
  local a d in; a=$(acme_bin); d=$(cert_domain); [[ -z "$d" ]] && d=$(detect_old)
  ask "Домен [$d]"; read -r in; d=$(clean_domain "${in:-$d}")
  [[ -n "$a" && -n "$d" ]] || { red "Нет acme.sh или сертификата."; return 1; }
  echo "Пробное продление на тестовом сервере Let's Encrypt (боевой сертификат не трогается)..."
  local tmp; tmp=$(mktemp -d)
  local conf wr mode=(--standalone)
  conf=$(ls "$HOME/.acme.sh/${d}_ecc/${d}.conf" "$HOME/.acme.sh/${d}/${d}.conf" 2>/dev/null | head -1)
  wr=$(grep -oP "^Le_Webroot='\K[^']*" "$conf" 2>/dev/null)
  case "$wr" in
    dns_*) mode=(--dns "$wr") ;;
    alpn)  mode=(--alpn) ;;
  esac
  echo "Способ: ${mode[*]}"
  [[ "${mode[0]}" != --dns ]] && sh "$HOOK_DIR/$d-pre.sh" 2>/dev/null
  "$a" --issue "${mode[@]}" -d "$d" --server letsencrypt_test \
       --cert-home "$tmp" --force >/dev/null 2>&1 \
    && green "✓ Продление пройдёт успешно" || red "✗ Продление не проходит — проверь порт/DNS"
  [[ "${mode[0]}" != --dns ]] && sh "$HOOK_DIR/$d-post.sh" 2>/dev/null
  rm -rf "$tmp"
}

cert_menu() {
  while true; do
    screen "Сертификаты"; echo
    cert_status
    echo
    item 1 "Обновить статус"
    item 2 "Обновить / перевыпустить сейчас" "и настроить автообновление"
    item 3 "Проверить, что автопродление сработает" "тест"
    hr; item 0 "Назад"
    ask; read -r c
    case "$c" in
      2) run_action "Сертификат: выпуск" renew_now; pause ;;
      3) run_action "Сертификат: тест продления" test_renew; pause ;;
      0|q) return ;;
    esac
  done
}

# ---------- порты и firewall ----------
port_busy()  { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
port_pid()   { ss -ltnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1; }
port_owner() {
  local ct pid
  ct=$(docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null | head -1)
  [[ -n "$ct" ]] && { echo "контейнер $ct"; return; }
  pid=$(port_pid "$1")
  [[ -n "$pid" ]] && echo "$(ps -o comm= -p "$pid") (pid $pid)" || echo "неизвестно"
}

free_port() { # временно освобождает порт
  local p="$1" ct pid unit ans
  ct=$(docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null | head -1)
  if [[ -z "$ct" ]]; then
    pid=$(port_pid "$p")
    # контейнер с network_mode: host
    [[ -n "$pid" ]] && ct=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.State.Pid}} {{.Name}}' 2>/dev/null |
      while read -r cpid name; do pstree -p "$cpid" 2>/dev/null | grep -q "($pid)" && { echo "${name#/}"; break; }; done)
  fi

  if [[ -n "$ct" ]]; then
    info "Порт $p занят контейнером $ct — останавливаю на время выпуска, потом запущу обратно"
    docker stop "$ct" >/dev/null && STOPPED_CT+=("$ct")
  elif [[ -n "$pid" ]]; then
    unit=$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ "$unit" == *.service ]]; then
      info "Порт $p занят сервисом $unit — останавливаю на время выпуска, потом запущу обратно"
      systemctl stop "$unit" && STOPPED_SVC+=("$unit")
    else
      fail "Порт $p занят: $(ps -o comm= -p "$pid") (pid $pid)"
      cause "это не контейнер и не сервис — остановить его сам я не могу"
      if [[ $p == 80 ]]; then todo "выбери порт 443 или DNS Cloudflare — порт 80 для них не нужен"
      else todo "выбери порт 80 или DNS Cloudflare — порт 443 для них не нужен"; fi
      todo "или останови программу сам: kill $pid"
      return 1
    fi
  fi
  sleep 1
  port_busy "$p" && { red "Порт $p всё ещё занят."; return 1; }
  green "✓ Порт $p свободен"
}

fw_open() { # открывает порт в ufw/firewalld, если закрыт
  local p="$1"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! grep -qE "^($p|$p/tcp)[[:space:]]+ALLOW" < <(ufw status); then
      ufw allow "$p/tcp" >/dev/null && FW_OPENED+=("ufw:$p") && yel "Временно открыл $p/tcp в ufw"
    fi
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --query-port="$p/tcp" >/dev/null 2>&1; then
      firewall-cmd --add-port="$p/tcp" >/dev/null && FW_OPENED+=("fwd:$p") && yel "Временно открыл $p/tcp в firewalld"
    fi
  elif command -v iptables >/dev/null && grep -qE '^-P INPUT (DROP|REJECT)' < <(iptables -S INPUT 2>/dev/null); then
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT && FW_OPENED+=("ipt:$p") && yel "Временно открыл $p/tcp в iptables"
  fi
}

restore_after_cert() {
  local x
  for x in "${FW_OPENED[@]:-}"; do
    case "$x" in
      ufw:*) ufw delete allow "${x#ufw:}/tcp" >/dev/null ;;
      fwd:*) firewall-cmd --remove-port="${x#fwd:}/tcp" >/dev/null ;;
      ipt:*) iptables -D INPUT -p tcp --dport "${x#ipt:}" -j ACCEPT ;;
    esac
  done
  for x in "${STOPPED_CT[@]:-}";  do [[ -n "$x" ]] && docker start "$x" >/dev/null && echo "Запустил обратно контейнер $x"; done
  for x in "${STOPPED_SVC[@]:-}"; do [[ -n "$x" ]] && systemctl start "$x" && echo "Запустил обратно сервис $x"; done
  FW_OPENED=(); STOPPED_CT=(); STOPPED_SVC=()
}

