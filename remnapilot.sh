#!/usr/bin/env bash
#  ╦═╗┌─┐┌┬┐┌┐┌┌─┐╔═╗┬┬  ┌─┐┌┬┐
#  ╠╦╝├┤ │││││││├─┤╠═╝││  │ │ │
#  ╩╚═└─┘┴ ┴┘└┘┴ ┴╩  ┴┴─┘└─┘ ┴   — пульт управления Remnawave
#
# Репозиторий:    https://github.com/Dubstep2004/RemnaPilot
# Установка:      bash <(curl -sSL https://raw.githubusercontent.com/Dubstep2004/RemnaPilot/main/remnapilot.sh)
#                 или скопируй файл на сервер и запусти  sudo bash remnapilot.sh
# Запуск с меню:  rw   (или sudo bash remnapilot.sh)
# Без меню:       sudo bash remnapilot.sh new.domain.com [--old old.domain.com] [--dir /opt/remnawave] [--dry-run] [--skip-cert]
#                 --cert-method http|alpn|dns|manual  (dns = Cloudflare, токен в CF_Token; manual = TXT вручную)
#                 --sub sub.domain.com [--dry-run] сменить домен подписки
#                 --update                       обновить панель    --update-all   панель + ноды
#                 --self-update [файл]           обновить RemnaPilot с GitHub (репозиторий — в меню) или из файла
#                 --lang en|ru                   язык интерфейса (меню: «Language / Язык»)
#                 --cert-status                  статус сертификатов

RP_DEFAULT_SOURCE="Dubstep2004/RemnaPilot"   # откуда обновляться по умолчанию (меняется в меню 6 → 5 → 3)

# Запуск через «curl … | bash»: stdin занят текстом скрипта, меню не сможет читать ввод.
# Скачиваем себя в /usr/local/bin/rw и перезапускаемся уже с клавиатурой.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == bash || "${BASH_SOURCE[0]}" == /dev/stdin ]] && [[ ! -t 0 ]]; then
  [[ $EUID -eq 0 ]] || { echo "Запусти от root (sudo -i)"; exit 1; }
  _t=$(mktemp)
  if curl -fsSL "https://raw.githubusercontent.com/$RP_DEFAULT_SOURCE/main/remnapilot.sh" -o "$_t" && bash -n "$_t" \
     && grep -q 'RP_NAME="RemnaPilot"' "$_t" && install -m 755 "$_t" /usr/local/bin/rw; then
    rm -f "$_t"; echo "RemnaPilot установлен. Дальше запускай командой:  rw"
    if (exec </dev/tty) 2>/dev/null; then exec /usr/local/bin/rw "$@" </dev/tty; fi
    exit 0
  fi
  rm -f "$_t"; echo "Не удалось скачать RemnaPilot. Сохрани скрипт в файл и запусти:  sudo bash remnapilot.sh"; exit 1
fi

set -o pipefail
RP_NAME="RemnaPilot"
RP_VERSION="1.8.1"
CERT_METHOD="${CERT_METHOD:-}"
STOPPED_CT=(); STOPPED_SVC=(); FW_OPENED=()

RW_DIR="/opt/remnawave"
NEW=""; OLD=""; DRY=0; SKIP_CERT=0

# ---------- оформление ----------
# UTF-8 нужен для рамок и правильного выравнивания
if [[ "${LANG:-}${LC_ALL:-}" != *[Uu][Tt][Ff]* ]]; then
  for l in C.UTF-8 C.utf8 en_US.UTF-8; do locale -a 2>/dev/null | grep -qix "${l/UTF-8/utf8}\|$l" && { export LC_ALL="$l"; break; }; done
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]] && (( $(tput colors 2>/dev/null || echo 0) >= 256 )); then
  C0=$'\e[0m'; CB=$'\e[1m'; CD=$'\e[2m'
  C_ACC=$'\e[38;5;45m'   # бирюзовый — акцент
  C_ACC2=$'\e[38;5;141m' # сиреневый
  C_OK=$'\e[38;5;114m'; C_WARN=$'\e[38;5;221m'; C_ERR=$'\e[38;5;203m'
  C_MUT=$'\e[38;5;245m'; C_LINE=$'\e[38;5;239m'
  GRAD=($'\e[38;5;51m' $'\e[38;5;45m' $'\e[38;5;39m' $'\e[38;5;63m' $'\e[38;5;99m' $'\e[38;5;141m')
elif [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C0=$'\e[0m'; CB=$'\e[1m'; CD=$'\e[2m'
  C_ACC=$'\e[36m'; C_ACC2=$'\e[35m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
  C_MUT=$'\e[90m'; C_LINE=$'\e[90m'; GRAD=($'\e[36m' $'\e[36m' $'\e[34m' $'\e[34m' $'\e[35m' $'\e[35m')
else
  C0=""; CB=""; CD=""; C_ACC=""; C_ACC2=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUT=""; C_LINE=""; GRAD=("" "" "" "" "" "")
fi
W=54   # ширина интерфейса

# ---------- язык ----------
RP_SELF=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
RP_LANG="${RP_LANG:-$(cat /etc/rw/lang 2>/dev/null)}"; [[ "$RP_LANG" == en ]] || RP_LANG=ru

rp_translate() { # фильтр вывода RU→EN по словарю в конце этого файла (без буферизации — подсказки видны сразу)
  perl -e '
    my %d; my $on = 0;
    open(my $f, "<", $ARGV[0]) or die;
    while (<$f>) { chomp; if ($_ eq "__RP_EN__") { $on = 1; next } next unless $on;
      last if $_ eq "__RP_EN_END__";
      my ($r, $e) = split /\t/, $_, 2; $d{$r} = $e if defined $e && length $r }
    my $alt = join "|", map { quotemeta } sort { length($b) <=> length($a) } keys %d;
    my $re = qr/(?<![\xD0\xD1][\x80-\xBF])($alt)(?![\xD0\xD1][\x80-\xBF])/;
    $| = 1; my $buf;
    while (sysread(STDIN, $buf, 65536)) {
      # не резать UTF-8 символ на границе чтения
      while ($buf =~ /[\xC0-\xFF]$/ || $buf =~ /[\xE0-\xFF][\x80-\xBF]$/) { my $more; last unless sysread(STDIN, $more, 1); $buf .= $more }
      $buf =~ s/$re/$d{$1}/g; syswrite(STDOUT, $buf);
    }' "$RP_SELF"
}

# перевод строки целиком внутри скрипта — нужен там, где важна ширина (рамки, заголовки)
declare -A RP_D=(); RP_KEYS=()
rp_load_dict() {
  local r e
  while IFS=$'\t' read -r r e; do
    [[ -n "$e" && ${#r} -ge 3 ]] || continue
    RP_D["$r"]="$e"; RP_KEYS+=("$r")
  done < <(awk '/^__RP_EN__$/{on=1;next} /^__RP_EN_END__$/{exit} on' "$RP_SELF" \
           | awk -F'\t' '{print length($1) "\t" $0}' | sort -t$'\t' -k1,1nr | cut -f2-)
}
T() {
  local s="$1" k
  if [[ "$RP_LANG" == en && ${#RP_KEYS[@]} -gt 0 && "$s" == *[А-Яа-яЁё]* ]]; then
    for k in "${RP_KEYS[@]}"; do [[ "$s" == *"$k"* ]] && s="${s//"$k"/"${RP_D[$k]}"}"; [[ "$s" == *[А-Яа-яЁё]* ]] || break; done
  fi
  printf '%s' "$s"
}

rp_reexec() { # перезапустить скрипт с чистым stdout/stderr
  [[ -n "${RP_TR_PID:-}" ]] && { exec 1>&3 2>&4; trap - EXIT; }
  exec "$@"
}

lang_toggle() {
  local n; [[ "$RP_LANG" == en ]] && n=ru || n=en
  mkdir -p /etc/rw && echo "$n" > /etc/rw/lang
  jlog INFO "Язык: $n"
  rp_reexec env RP_LANG="$n" bash "$RP_SELF"
}

red()   { printf '%s%s%s\n' "$C_ERR"  "$*" "$C0"; }
green() { printf '%s%s%s\n' "$C_OK"   "$*" "$C0"; }
yel()   { printf '%s%s%s\n' "$C_WARN" "$*" "$C0"; }
bold()  { printf '%s%s%s\n' "$CB"     "$*" "$C0"; }
info()  { printf '%s›%s %s\n' "$C_ACC" "$C0" "$*"; }
err()   { red "✖ $*"; return 1; }
pause() { echo; read -rp "  ${C_MUT}↵ Enter — назад${C0} " _; }
ask()   { printf '\n  %s❯%s %s' "$C_ACC" "$C0" "${1:-Выбор}: "; }   # usage: ask "Текст"; read -r var

repeat() { local s="" i; for ((i=0; i<$2; i++)); do s+="$1"; done; printf '%s' "$s"; }
vislen() { local s; s=$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'); echo "${#s}"; }

hr() { printf '  %s%s%s\n' "$C_LINE" "$(repeat ─ $((W-2)))" "$C0"; }

section() { # заголовок группы в меню:  ДОМЕН ─────────
  local t=" $(T "$1") " n; n=$(( W - 2 - $(vislen "$t") ))
  printf '\n  %s%s%s%s%s%s\n' "$C_ACC2$CB" "$t" "$C0" "$C_LINE" "$(repeat ─ $n)" "$C0"
}

item() { # пункт меню: номер, текст, [подсказка]
  printf '   %s%3s%s  %s' "$C_ACC$CB" "$1" "$C0" "$2"
  [[ -n "${3:-}" ]] && printf '  %s%s%s' "$C_MUT" "$3" "$C0"
  echo
}

box_top()    { printf '  %s╭%s╮%s\n' "$C_LINE" "$(repeat ─ $((W-4)))" "$C0"; }
box_bottom() { printf '  %s╰%s╯%s\n' "$C_LINE" "$(repeat ─ $((W-4)))" "$C0"; }
box_line()   { # строка внутри рамки с выравниванием по видимой ширине
  local s; s=$(T "$1"); local pad; pad=$(( W - 6 - $(vislen "$s") )); (( pad < 0 )) && pad=0
  printf '  %s│%s %s%s %s│%s\n' "$C_LINE" "$C0" "$s" "$(repeat ' ' $pad)" "$C_LINE" "$C0"
}

banner() {
  local rows=(
    "╦═╗┌─┐┌┬┐┌┐┌┌─┐╔═╗┬┬  ┌─┐┌┬┐"
    "╠╦╝├┤ │││││││├─┤╠═╝││  │ │ │ "
    "╩╚═└─┘┴ ┴┘└┘┴ ┴╩  ┴┴─┘└─┘ ┴ "
  )
  local r i ch out col n=${#GRAD[@]} u="─"
  echo
  if (( ${#u} != 1 )); then for r in "${rows[@]}"; do printf '   %s%s%s\n' "$C_ACC" "$r" "$C0"; done
  else for r in "${rows[@]}"; do
    out="   "
    for ((i=0; i<${#r}; i++)); do
      ch="${r:i:1}"; col=$(( i * n / ${#r} ))
      out+="${GRAD[$col]}$ch"
    done
    printf '%s%s\n' "$out" "$C0"
  done; fi
  printf '   %sпульт управления Remnawave%s  %sv%s%s\n' "$C_MUT" "$C0" "$C_LINE" "$RP_VERSION" "$C0"
}

screen() { # экран подменю: заголовок-плашка
  clear
  local t; t=$(T "$1"); local n; n=$(( W - 6 - $(vislen "$t") ))
  echo
  printf '  %s◆%s %s%s%s %s%s%s\n' "$C_ACC" "$C0" "$CB" "$t" "$C0" "$C_LINE" "$(repeat ─ $n)" "$C0"
  printf '  %s%s%s\n' "$C_MUT" "$RP_NAME" "$C0"
}

dot() { # цветная точка статуса: ok|warn|err|off
  case "$1" in ok) printf '%s●%s' "$C_OK" "$C0" ;; warn) printf '%s●%s' "$C_WARN" "$C0" ;;
               err) printf '%s●%s' "$C_ERR" "$C0" ;; *) printf '%s○%s' "$C_MUT" "$C0" ;; esac
}

status_box() {
  local panel_st panel_ver dom days ssl nodes db_st lbl
  lbl() { local l; l=$(T "$1"); local w=9; [[ "$RP_LANG" == en ]] && w=13; local pad=$(( w - ${#l} )); (( pad < 1 )) && pad=1; printf '%s%s%s%s' "$C_MUT" "$l" "$C0" "$(repeat ' ' $pad)"; }

  if [[ -f "$RW_DIR/.env" ]]; then
    local ps; ps=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null)
    local app; app=$(echo "$ps" | awk -F'|' '$3 ~ /remnawave\/backend|remnawave\/panel/ {print; exit}')
    [[ -z "$app" ]] && app=$(echo "$ps" | grep -E '^remnawave\|' | head -1)
    if   [[ "$app" == *"|Up"*"unhealthy"* || "$app" == *Restarting* ]]; then panel_st="$(dot warn) ${C_WARN}проблемы${C0}"
    elif [[ "$app" == *"|Up"* ]]; then panel_st="$(dot ok) ${C_OK}работает${C0}"
    elif [[ -n "$app" ]];        then panel_st="$(dot err) ${C_ERR}остановлена${C0}"
    else                              panel_st="$(dot off) ${C_MUT}не найдена${C0}"; fi
    panel_ver=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${app%%|*}" 2>/dev/null || true)
    [[ -n "$panel_ver" ]] && panel_st+="  ${C_MUT}v${panel_ver}${C0}"

    if echo "$ps" | grep -E 'remnawave-db\||postgres' | grep -q '|Up'; then db_st="$(dot ok) ${C_OK}ok${C0}"
    else db_st="$(dot err) ${C_ERR}недоступна${C0}"; fi

    dom=$(detect_old); dom="${dom:-—}"

    local f cp; cp=$(cert_paths_for "$dom" 2>/dev/null); f="${cp%%$'\t'*}"; f="${f:-$RW_DIR/nginx/fullchain.pem}"
    local endd; endd=$(openssl x509 -noout -enddate -in "$f" 2>/dev/null | cut -d= -f2)
    if [[ -f "$f" && -n "$endd" ]]; then
      days=$(( ( $(date -d "$endd" +%s) - $(date +%s) ) / 86400 ))
      if   (( days < 0 ));  then ssl="$(dot err) ${C_ERR}истёк${C0}"
      elif (( days < 15 )); then ssl="$(dot warn) ${C_WARN}${days} дн.${C0}"
      else                       ssl="$(dot ok) ${C_OK}${days} дн.${C0}"; fi
    else ssl="$(dot off) ${C_MUT}через Caddy/Traefik${C0}"; fi

    box_top
    box_line "$(lbl Панель)$panel_st"
    box_line "$(lbl Домен)${CB}${dom}${C0}"
    local sd; sd=$(env_get SUB_PUBLIC_DOMAIN)
    [[ -n "$sd" ]] && box_line "$(lbl Подписка)${sd}"
    box_line "$(lbl SSL)$ssl"
    box_line "$(lbl База)$db_st"
  else
    box_top
    box_line "$(lbl Панель)$(dot off) ${C_MUT}на этом сервере нет${C0}"
  fi
  if [[ -s "${NODES_FILE:-/etc/rw/nodes.list}" ]]; then
    nodes="$(wc -l < "${NODES_FILE:-/etc/rw/nodes.list}") в списке"
  else nodes="список пуст"; fi
  local local_node=""
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && local_node="  $(dot ok) ${C_MUT}+ нода здесь${C0}"
  box_line "$(lbl Ноды)${nodes}${local_node}"
  local lv; lv=$(cat /etc/rw/.latest_version 2>/dev/null)
  if [[ -n "$lv" && "$lv" != "$RP_VERSION" && "$(printf '%s\n%s\n' "$RP_VERSION" "$lv" | sort -V | tail -1)" == "$lv" ]]; then
    box_line "$(dot warn) ${C_WARN}Доступен RemnaPilot v$lv — пункт 6 → 5${C0}"
  fi
  box_bottom
}

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
    read -rp "Порт $p занят контейнером $ct. Остановить на время выпуска? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 1
    docker stop "$ct" >/dev/null && STOPPED_CT+=("$ct")
  elif [[ -n "$pid" ]]; then
    unit=$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ "$unit" == *.service ]]; then
      read -rp "Порт $p занят сервисом $unit. Остановить на время выпуска? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || return 1
      systemctl stop "$unit" && STOPPED_SVC+=("$unit")
    else
      red "Порт $p занят процессом $(ps -o comm= -p "$pid") (pid $pid), автоматически не остановить."
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
    if ! ufw status | grep -qE "^($p|$p/tcp)[[:space:]]+ALLOW"; then
      ufw allow "$p/tcp" >/dev/null && FW_OPENED+=("ufw:$p") && yel "Временно открыл $p/tcp в ufw"
    fi
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --query-port="$p/tcp" >/dev/null 2>&1; then
      firewall-cmd --add-port="$p/tcp" >/dev/null && FW_OPENED+=("fwd:$p") && yel "Временно открыл $p/tcp в firewalld"
    fi
  elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
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

# ---------- действия ----------
show_current() {
  section "НАСТРОЙКИ  $RW_DIR/.env"
  for k in FRONT_END_DOMAIN PANEL_DOMAIN SUB_PUBLIC_DOMAIN; do
    printf '  %-18s %s\n' "$k" "$(env_get "$k")"
  done
  section "КОНТЕЙНЕРЫ"
  docker ps --format '  {{.Names}}\t{{.Status}}' | grep -iE 'remna|nginx|caddy|traefik|angie' || echo "  (не найдены)"
}

backup_files() { # $1 суффикс, остальное — файлы; в пакетном режиме всё в один BK_DIR
  local sfx="$1" f rel; shift
  [[ -n "${BK_DIR:-}" ]] || BK_DIR="$RW_DIR/backup-domain-$(date +%Y%m%d-%H%M%S)$sfx"
  mkdir -p "$BK_DIR"
  for f in "$@" "$RW_DIR/.env"; do
    rel="${f#"$RW_DIR"/}"; [[ -e "$BK_DIR/$rel" ]] && continue
    mkdir -p "$BK_DIR/$(dirname "$rel")"; cp -a "$f" "$BK_DIR/$rel"
  done
}

change_domain() { # $1 new, $2 old (может быть пустым), $3 dry
  local new old dry="$3" files f bk rel sub ans
  new=$(clean_domain "$1"); old="${2:-$(detect_old)}"
  valid_domain "$new" || { err "некорректный домен: $new"; return 1; }
  [[ -n "$old" ]] || { err "не удалось определить старый домен, укажи его"; return 1; }
  [[ "$old" != "$new" ]] || { err "старый и новый домены совпадают"; return 1; }

  echo "Старый домен: $old"; echo "Новый домен:  $new"
  check_dns "$new"

  mapfile -t files < <(find_files "$old")
  if [[ ${#files[@]} -eq 0 ]]; then yel "Старый домен в конфигах не найден."
  else echo "Файлы:"; printf '  %s\n' "${files[@]}"; fi

  if (( dry )); then
    echo; yel "Предпросмотр — изменятся строки:"
    for f in "${files[@]}"; do grep -nF -- "$old" "$f" | sed "s|^|  $f:|"; done
    return 0
  fi

  if [[ -z "${DOM_BATCH:-}" ]]; then
    ask "Применить? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "  Отменено."; return 0; }
    BK_DIR=""
  fi
  backup_files "" "${files[@]}"
  [[ -z "${DOM_BATCH:-}" ]] && green "✔ Бэкап: $BK_DIR"

  for f in "${files[@]}"; do
    OLD="$old" NEW="$new" perl -pi -e 's/(?<![A-Za-z0-9.-])\Q$ENV{OLD}\E(?![A-Za-z0-9-])/$ENV{NEW}/g' "$f"
  done
  env_set FRONT_END_DOMAIN "$new"
  env_set PANEL_DOMAIN "$new"
  sub=$(env_get SUB_PUBLIC_DOMAIN)
  [[ -z "$sub" ]] && env_set SUB_PUBLIC_DOMAIN "$new/api/sub"
  green "✔ Домен панели: $old → $new"
  [[ -n "${DOM_BATCH:-}" ]] && return 0

  echo "Останавливаю контейнеры..."; stack_down
  (( SKIP_CERT )) || issue_cert "$new"
  echo "Запускаю контейнеры..."; stack_up

  echo; green "Готово: https://$new"
  sub=$(env_get SUB_PUBLIC_DOMAIN); sub="${sub#http*://}"
  if [[ "${sub%%/*}" == "$new" ]]; then
    yel "Подписка отдаётся с домена панели — старые ссылки на $old перестанут работать, при необходимости оставь редирект."
  else
    info "Подписка на отдельном домене (${sub%%/*}) — ссылки клиентов не изменились."
  fi
}

# ---------- домен подписки ----------
proxy_confs() { # конфиги reverse proxy
  find "$RW_DIR" -maxdepth 3 \( -path '*/backup-*' -prune \) -o -type f \
    \( -name '*.conf' -o -name 'Caddyfile' -o -name '*.yml' -o -name '*.yaml' -o -name '*.toml' \) -print 2>/dev/null \
    | grep -vE '/docker-compose\.ya?ml$|/compose\.ya?ml$'
}

nginx_blocks() { # печатает: ssl_certificate<TAB>ssl_certificate_key<TAB>server_names — для каждого server {}
  local f
  find "$RW_DIR" -maxdepth 3 \( -path '*/backup-*' -prune \) -o -type f -name '*.conf' -print 2>/dev/null | while read -r f; do
    perl -0777 -ne '
      while (/server\s*(\{(?:[^{}]++|(?1))*\})/g) {
        my $b = $1; my ($c) = $b =~ /(?:^|[;{])\s*ssl_certificate\s+([^;\s]+)\s*;/m; my ($k) = $b =~ /(?:^|[;{])\s*ssl_certificate_key\s+([^;\s]+)\s*;/m;
        my @n; while ($b =~ /(?:^|[;{])\s*server_name\s+([^;]+);/mg) { push @n, split(/\s+/, $1) }
        @n = grep { $_ ne "_" && $_ ne "" } @n; s/["\x27]//g for grep defined, $c, $k;
        print join("\t", $c // "", $k // "", join(" ", @n)), "\n" if @n;
      }' "$f"
  done
}

host_path() { # путь внутри контейнера nginx -> путь на хосте (по volumes в compose)
  local p="$1" c line hp
  while read -r c; do
    line=$(grep -E "^[[:space:]]*-[[:space:]]*[\"']?[^:\"' ]+:$p(:ro|:rw)?[\"']?[[:space:]]*$" "$c" | head -1)
    [[ -n "$line" ]] || continue
    hp=$(echo "$line" | sed -E "s/^[[:space:]]*-[[:space:]]*[\"']?//; s/:.*//")
    [[ "$hp" != /* ]] && hp="$(dirname "$c")/${hp#./}"
    echo "$hp"; return 0
  done < <(find_composes)
  [[ -f "$p" ]] && { echo "$p"; return 0; }
  [[ -f "$RW_DIR/nginx/$(basename "$p")" ]] && { echo "$RW_DIR/nginx/$(basename "$p")"; return 0; }
  return 1
}

sub_current() { env_get SUB_PUBLIC_DOMAIN; }

names_sharing_cert() { # все server_name, у которых тот же сертификат, что у домена $1
  local c; c=$(nginx_blocks | awk -F'\t' -v d="$1" '{n=" "$3" "; if (index(n," "d" ")) {print $1; exit}}')
  [[ -n "$c" ]] && nginx_blocks | awk -F'\t' -v c="$c" '$1==c {print $3}' | tr ' ' '\n' | grep -v '^\*' | awk 'NF && !s[$0]++' | tr '\n' ' '
}

nginx_has_ssl() { nginx_blocks | awk -F'\t' '$1!=""{f=1} END{exit !f}'; }

cert_paths_for() { # $1 домен -> "host_fullchain<TAB>host_key" из конфига nginx
  local line c k hc hk
  line=$(nginx_blocks | awk -F'\t' -v d="$1" '{n=" "$3" "; if (index(n," "d" ")) {print; exit}}')
  c=$(echo "$line" | cut -f1); k=$(echo "$line" | cut -f2)
  [[ -n "$c" && -n "$k" ]] && hc=$(host_path "$c") && hk=$(host_path "$k") && printf '%s\t%s\n' "$hc" "$hk"
}

change_sub_domain() { # $1 new, $2 dry
  local cur old_host path panel new dry="${2:-0}" files=() proxy=() f ans keep=0 bk rel
  cur=$(sub_current); cur="${cur#http://}"; cur="${cur#https://}"; old_host="${cur%%/*}"; path=""
  [[ "$cur" == */* ]] && path="/${cur#*/}"
  panel=$(detect_old)
  [[ -n "$old_host" ]] || { err "SUB_PUBLIC_DOMAIN не задан в .env"; return 1; }

  if [[ "$old_host" == "$panel" ]]; then
    yel "⚠ Подписка сейчас отдаётся самой панелью: $cur"
    echo "  Отдельного домена подписки нет — он меняется вместе с доменом панели."
    echo "  Чтобы вынести подписку на свой домен, нужна страница подписки (remnawave/subscription-page)."
    return 0
  fi

  new=$(clean_domain "$1")
  valid_domain "$new" || { err "некорректный домен: $new"; return 1; }
  [[ "$new" != "$old_host" ]] || { err "домен не изменился"; return 1; }
  [[ "$new" != "$panel" ]] || { err "это домен панели — для подписки на домене панели укажи $panel/api/sub через смену в .env"; return 1; }

  info "Текущая подписка: ${CB}https://$cur${C0}"
  info "Новая подписка:   ${CB}https://$new$path${C0}"
  check_dns "$new"

  mapfile -t files < <(find_files "$old_host")
  for f in "${files[@]}"; do [[ "$f" != *.env ]] && proxy+=("$f"); done

  section "ФАЙЛЫ"
  printf '   %s\n' "${files[@]:-$RW_DIR/.env}"
  if (( ${#proxy[@]} == 0 )); then
    yel "⚠ Домен подписки не найден в конфигах прокси на этом сервере —"
    yel "  похоже, страница подписки стоит на другом сервере. Здесь поменяется только .env панели,"
    yel "  а домен и сертификат на сервере подписки нужно сменить там (этим же скриптом, пункт 1)."
  fi

  if (( dry )); then
    section "ИЗМЕНЯТСЯ СТРОКИ"
    for f in "${files[@]}"; do grep -nF -- "$old_host" "$f" | sed "s|^|   $f:|"; done
    return 0
  fi

  if [[ -n "${DOM_BATCH:-}" ]]; then
    keep="${SUB_KEEP:-0}"
  else
    if (( ${#proxy[@]} )); then
      echo
      echo "  У клиентов в приложениях сохранены ссылки со старым доменом."
      ask "Оставить старый домен рабочим, чтобы подписки не отвалились? [Y/n]"; read -r ans
      [[ "$ans" =~ ^[Nn]$ ]] || keep=1
    fi
    ask "Применить? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "  Отменено."; return 0; }
    BK_DIR=""
  fi
  backup_files "-sub" "${files[@]}"
  [[ -z "${DOM_BATCH:-}" ]] && green "✔ Бэкап: $BK_DIR"

  for f in "${files[@]}"; do
    OLD="$old_host" NEW="$new" perl -pi -e 's/(?<![A-Za-z0-9.-])\Q$ENV{OLD}\E(?![A-Za-z0-9-])/$ENV{NEW}/g' "$f"
  done
  env_set SUB_PUBLIC_DOMAIN "$new$path"

  if (( keep )); then
    for f in "${proxy[@]}"; do
      OLD="$old_host" NEW="$new" perl -pi -e '
        s/((?:^|[;{])\s*server_name\s+[^;]*(?<![A-Za-z0-9.-])\Q$ENV{NEW}\E(?![A-Za-z0-9-])[^;]*);/$1 $ENV{OLD};/;
        s/^(\s*(?:https?:\/\/)?\Q$ENV{NEW}\E(?::\d+)?)(\s*\{)/$1, $ENV{OLD}$2/;
        s/Host\(`\Q$ENV{NEW}\E`\)/(Host(`$ENV{NEW}`) || Host(`$ENV{OLD}`))/g;
      ' "$f"
    done
    green "✔ Старый домен $old_host оставлен как алиас"
  fi
  green "✔ Домен подписки: $old_host → $new"
  [[ -n "${DOM_BATCH:-}" ]] && return 0

  info "Останавливаю контейнеры..."; stack_down

  # сертификат для Nginx: все домены, которые используют тот же файл сертификата
  if (( ${#proxy[@]} )) && nginx_has_ssl; then
    local line c k names hc hk doms="" first
    line=$(nginx_blocks | awk -F'\t' -v d="$new" '{n=" "$3" "; if (index(n," "d" ")) {print; exit}}')
    c=$(echo "$line" | cut -f1); k=$(echo "$line" | cut -f2)
    if [[ -n "$c" && -n "$k" ]] && hc=$(host_path "$c") && hk=$(host_path "$k"); then
      doms=$(nginx_blocks | awk -F'\t' -v c="$c" '$1==c {print $3}' | tr ' ' '\n' | grep -v '^\*' | awk 'NF && !s[$0]++' | tr '\n' ' ')
      first=$(echo "$doms" | awk '{print $1}')
      [[ "$doms" == *"$new"* ]] && first="$new"
      CERT_FULL="$hc" CERT_KEY="$hk" CERT_EXTRA="$doms" issue_cert "$first"
    else
      yel "⚠ Не нашёл файлы сертификата для $new в конфиге Nginx — выпусти его в разделе «Сертификаты»."
    fi
  fi

  info "Запускаю контейнеры..."; stack_up
  echo
  green "✔ Готово. Подписка: https://$new$path/<shortUuid>"
  (( keep )) && echo "  Старые ссылки https://$old_host$path/… продолжат работать." \
             || yel "  Старые ссылки на $old_host перестанут работать — пользователям нужно обновить подписку."
}

sub_host() { local c; c=$(sub_current); c="${c#http://}"; c="${c#https://}"; echo "${c%%/*}"; }

change_domains() { # $1 = 1 — только предпросмотр
  local dry="${1:-0}" op os np ns sep=0 ans keep=0 any_proxy f
  op=$(detect_old); os=$(sub_host)
  [[ -n "$os" && "$os" != "$op" ]] && sep=1

  box_top
  box_line "${C_MUT}$(padr "Панель" 10)${C0}${CB}${op:-—}${C0}"
  if (( sep )); then box_line "${C_MUT}$(padr "Подписка" 10)${C0}${CB}${os}${C0}"
  else box_line "${C_MUT}$(padr "Подписка" 10)${C0}${C_MUT}на домене панели — сменится вместе с ним${C0}"; fi
  box_bottom
  echo "  Enter — оставить домен как есть."

  ask "Новый домен панели"; read -r np; np=$(clean_domain "$np")
  if (( sep )); then ask "Новый домен подписки"; read -r ns; ns=$(clean_domain "$ns"); fi
  [[ "$np" == "$op" ]] && np=""; [[ "$ns" == "$os" ]] && ns=""
  [[ -n "$np" || -n "$ns" ]] || { echo "  Ничего не меняем."; return 0; }
  [[ -n "$np" ]] && { valid_domain "$np" || { err "некорректный домен панели: $np"; return 1; }; }
  [[ -n "$ns" ]] && { valid_domain "$ns" || { err "некорректный домен подписки: $ns"; return 1; }; }
  if [[ -n "$ns" && ( "$ns" == "$np" || ( -z "$np" && "$ns" == "$op" ) ) ]]; then
    err "домен подписки совпадает с доменом панели"; return 1
  fi

  # предпросмотр обеих частей
  [[ -n "$np" ]] && { section "ПАНЕЛЬ  $op → $np"; change_domain "$np" "$op" 1; }
  [[ -n "$ns" ]] && { section "ПОДПИСКА  $os → $ns"; change_sub_domain "$ns" 1; }
  (( dry )) && return 0

  if [[ -n "$ns" ]]; then
    for f in $(find_files "$os"); do [[ "$f" != *.env ]] && any_proxy=1; done
    if [[ -n "$any_proxy" ]]; then
      echo; echo "  У клиентов в приложениях сохранены ссылки на $os."
      ask "Оставить старый домен подписки рабочим? [Y/n]"; read -r ans
      [[ "$ans" =~ ^[Nn]$ ]] || keep=1
    fi
  fi

  section "ИТОГ"
  [[ -n "$np" ]] && echo "   Панель:   $op → $np"
  [[ -n "$ns" ]] && echo "   Подписка: $os → $ns$( (( keep )) && echo "  (+ старый как алиас)")"
  ask "Применить? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "  Отменено."; return 0; }

  BK_DIR=""; export DOM_BATCH=1 SUB_KEEP="$keep"
  [[ -n "$np" ]] && { change_domain "$np" "$op" 0 >/dev/null || { unset DOM_BATCH; return 1; }; green "✔ Панель: $op → $np"; }
  [[ -n "$ns" ]] && { change_sub_domain "$ns" 0 >/dev/null || { unset DOM_BATCH; return 1; }; green "✔ Подписка: $os → $ns"; }
  unset DOM_BATCH SUB_KEEP
  green "✔ Бэкап: $BK_DIR"

  info "Останавливаю контейнеры..."; stack_down
  if (( ! SKIP_CERT )); then
    local done_certs=" " d cf
    for d in $np $ns; do
      cf=$(cert_file_for "$d")
      [[ "$done_certs" == *" $cf "* ]] && continue      # общий сертификат уже выпущен
      issue_cert "$d"; done_certs+="$cf "
    done
  fi
  info "Запускаю контейнеры..."; stack_up

  echo
  [[ -n "$np" ]] && green "✔ Панель: https://$np"
  if [[ -n "$ns" ]]; then
    local pth; pth=$(sub_current); pth="${pth#*://}"; [[ "$pth" == */* ]] && pth="/${pth#*/}" || pth=""
    green "✔ Подписка: https://$ns$pth/<shortUuid>"
    (( keep )) && echo "  Старые ссылки на $os продолжат работать." || yel "  Старые ссылки на $os перестанут работать."
  elif (( ! sep )); then
    yel "  Подписка была на домене панели — старые ссылки на $op перестанут работать."
  else
    info "Подписка не менялась — ссылки клиентов прежние."
  fi
}

# ---------- удаление старых доменов ----------
acme_forget_others() { # $1 = путь fullchain, $2 = основной домен, который оставить
  # Старые заказы acme.sh, которые пишут сертификат в тот же файл, при продлении затёрли бы новый
  local acme conf dom path dir
  acme=$(acme_bin) || return 0
  for conf in "$HOME"/.acme.sh/*/*.conf; do
    [[ -f "$conf" && "$(basename "$conf")" != account.conf ]] || continue
    dom=$(sed -n "s/^Le_Domain='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$conf" | head -1)
    path=$(sed -n "s/^Le_RealFullChainPath='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$conf" | head -1)
    [[ -n "$dom" && "$path" == "$1" && "$dom" != "$2" ]] || continue
    dir=$(dirname "$conf")
    if [[ "$dir" == *_ecc ]]; then "$acme" --remove -d "$dom" --ecc >/dev/null 2>&1; else "$acme" --remove -d "$dom" >/dev/null 2>&1; fi
    rm -f "$HOOK_DIR/$dom"-*.sh
    info "Старое автопродление для $dom отключено"
  done
}

all_proxy_domains() { # все домены из конфигов прокси (nginx, Caddy, Traefik)
  {
    nginx_blocks | cut -f3 | tr ' ' '\n'
    find "$RW_DIR" -maxdepth 3 \( -path '*/backup-*' -prune \) -o -type f -name 'Caddyfile' -print 2>/dev/null \
      | xargs -r grep -hE '^[[:space:]]*[^#[:space:]][^{]*\{[[:space:]]*$' 2>/dev/null \
      | sed -E 's/\{.*//; s#https?://##g; s/:[0-9]+//g' | tr ',' '\n'
    find "$RW_DIR" -maxdepth 3 \( -path '*/backup-*' -prune \) -o -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.toml' \) -print 2>/dev/null \
      | xargs -r grep -hoE 'Host\(`[^`]+`\)' 2>/dev/null | sed -E 's/Host\(`([^`]+)`\)/\1/'
  } | tr -d ' \t' | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$|^[A-Za-z0-9.-]+\.xn--' | grep -v '^\*' | sort -u
}

remove_domain_from_files() { # $1 = домен; правит конфиги прокси, возвращает 0 если что-то изменилось
  local d="$1" f changed=1 before
  while read -r f; do
    [[ -f "$f" ]] || continue
    grep -qF -- "$d" "$f" || continue
    before=$(md5sum < "$f")
    DOM="$d" perl -0777 -pi -e '
      my $d = $ENV{DOM};
      # nginx: блок server, где это единственное имя, — удалить целиком
      s{[ \t]*server\s*(\{(?:[^{}]++|(?1))*\})[ \t]*\n?}{
        my $all = $&; my $b = $1; my @n;
        while ($b =~ /(?:^|[;\x7b])\s*server_name\s+([^;]+);/mg) { push @n, split /\s+/, $1 }
        @n = grep { length } @n;
        (@n == 1 && $n[0] eq $d) ? "" : $all
      }ge;
      # nginx: убрать имя из списка server_name
      s~((?:^|[;\x7b])\s*server_name\b[^;]*?)\s+\Q$d\E(?=[\s;])~$1~g;
      # Caddy: «a, b {» → убрать имя из адресов сайта
      s~^([ \t]*(?:https?://)?\S[^\n{]*?),\s*(?:https?://)?\Q$d\E(?::\d+)?(\s*[,{])~$1$2~mg;
      s~^([ \t]*)(?:https?://)?\Q$d\E(?::\d+)?\s*,\s*~$1~mg;
      # Caddy: сайт только с этим доменом — удалить блок целиком
      s~^[ \t]*(?:https?://)?\Q$d\E(?::\d+)?\s*(\{(?:[^{}]++|(?1))*\})[ \t]*\n?~~mg;
      # Traefik: убрать Host(`домен`) из правил
      s~\s*\|\|\s*Host\(`\Q$d\E`\)~~g;
      s~Host\(`\Q$d\E`\)\s*\|\|\s*~~g;
      s~\((Host\(`[^`]+`\))\)~$1~g;
    ' "$f"
    [[ "$(md5sum < "$f")" != "$before" ]] && changed=0
  done < <(proxy_confs)
  return $changed
}

remove_domains() {
  local panel sub all=() cand=() i c sel=() d ans f certs=() cf names first left
  panel=$(detect_old); sub=$(sub_host)
  mapfile -t all < <(all_proxy_domains)
  for d in "${all[@]}"; do [[ "$d" == "$panel" || "$d" == "$sub" ]] || cand+=("$d"); done

  box_top
  box_line "${C_MUT}$(padr "Панель" 10)${C0}${CB}${panel:-—}${C0}  ${C_MUT}(не удаляется)${C0}"
  [[ -n "$sub" && "$sub" != "$panel" ]] && box_line "${C_MUT}$(padr "Подписка" 10)${C0}${CB}${sub}${C0}  ${C_MUT}(не удаляется)${C0}"
  box_bottom

  if (( ${#cand[@]} == 0 )); then
    echo; green "Лишних доменов нет — в конфигах только домены панели и подписки."
    return 0
  fi
  section "СТАРЫЕ ДОМЕНЫ И АЛИАСЫ"
  for i in "${!cand[@]}"; do item $((i+1)) "${cand[$i]}"; done
  item a "Все сразу"
  hr; item 0 "Отмена"
  ask "Что удалить (номера через пробел)"; read -r c
  [[ -z "$c" || "$c" == 0 ]] && return 0
  if [[ "$c" == a || "$c" == а ]]; then sel=("${cand[@]}")
  else for i in $c; do [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#cand[@]} )) && sel+=("${cand[$((i-1))]}"); done; fi
  (( ${#sel[@]} )) || { err "ничего не выбрано"; return 1; }

  section "БУДЕТ УДАЛЕНО"
  printf '   ✖ %s\n' "${sel[@]}"
  yel "Ссылки подписки и адреса на этих доменах перестанут открываться."
  ask "Удалить? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "  Отменено."; return 0; }

  # какие сертификаты затронуты (запомнить до правки)
  for d in "${sel[@]}"; do cf=$(cert_paths_for "$d" 2>/dev/null); [[ -n "$cf" ]] && certs+=("$cf"); done

  BK_DIR=""; local files=(); mapfile -t files < <(proxy_confs); backup_files "-remove" "${files[@]}"
  for d in "${sel[@]}"; do
    if remove_domain_from_files "$d"; then green "✔ $d удалён из конфигов"; else yel "⚠ $d не найден в конфигах"; fi
  done
  green "✔ Бэкап: $BK_DIR"

  info "Останавливаю контейнеры..."; stack_down
  # перевыпустить сертификаты, в которых были удалённые домены, — уже без них
  local done_c=" "
  for cf in "${certs[@]}"; do
    f="${cf%%$'\t'*}"; [[ "$done_c" == *" $f "* ]] && continue; done_c+="$f "
    names=$(nginx_blocks | while IFS=$'\t' read -r c k n; do [[ -n "$c" ]] && [[ "$(host_path "$c")" == "$f" ]] && echo "$n"; done \
            | tr ' ' '\n' | grep -v '^\*' | awk 'NF && !s[$0]++' | tr '\n' ' ')
    first=""; for d in $names; do [[ "$d" == "$panel" || "$d" == "$sub" ]] && { first="$d"; break; }; done
    first="${first:-${names%% *}}"
    if [[ -n "$first" ]]; then
      CERT_FULL="$f" CERT_KEY="${cf#*$'\t'}" CERT_EXTRA="$names" issue_cert "$first"
    else
      info "Сертификат $(basename "$f") больше не используется"
    fi
  done
  # отключить продление удалённых доменов
  local acme; acme=$(acme_bin)
  for d in "${sel[@]}"; do
    [[ -n "$acme" ]] && { "$acme" --remove -d "$d" --ecc >/dev/null 2>&1; "$acme" --remove -d "$d" >/dev/null 2>&1; }
    rm -f "$HOOK_DIR/$d"-*.sh
  done
  info "Запускаю контейнеры..."; stack_up

  echo; green "✔ Готово. Удалено доменов: ${#sel[@]}"
  echo "  A-записи этих доменов у регистратора теперь можно удалить (или не продлевать домен)."
  jlog INFO "Удалены домены: ${sel[*]}"
}

rollback() {
  local bks i n
  mapfile -t bks < <(ls -1dt "$RW_DIR"/backup-domain-* 2>/dev/null)
  [[ ${#bks[@]} -gt 0 ]] || { yel "Бэкапов нет."; return 0; }
  section "БЭКАПЫ"
  for i in "${!bks[@]}"; do item $((i+1)) "$(basename "${bks[$i]}")" "$(date -r "${bks[$i]}" '+%d.%m %H:%M')"; done
  hr; item 0 "Отмена"
  ask "Номер"; read -r n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#bks[@]} )) || { echo "Отменено."; return 0; }
  cp -a "${bks[$((n-1))]}/." "$RW_DIR/"
  green "✓ Файлы восстановлены из $(basename "${bks[$((n-1))]}")"
  echo "Пересоздаю контейнеры..."; stack_down; stack_up
  green "Готово. Сертификат для старого домена, если он в Nginx, перевыпусти в разделе «Сертификаты» (пункт 9)."
}

restart_all() { echo "Пересоздаю контейнеры..."; stack_down; stack_up; green "✓ Готово"; }

rw_versions() {
  docker ps --format '{{.Names}}\t{{.Image}}' | grep -iE 'remna' | while IFS=$'\t' read -r n img; do
    local v
    v=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$n" 2>/dev/null)
    printf '  %-28s %s %s\n' "$n" "$img" "${v:+($v)}"
  done
}

# ---------- база данных ----------
DB_USER=""; DB_PASS=""; DB_HOST=""; DB_NAME=""; DB_CT=""

db_info() { # разбирает DATABASE_URL и находит контейнер БД
  local url; url=$(grep -E '^DATABASE_URL=' "$RW_DIR/.env" | head -1 | cut -d= -f2- | sed -E 's/^["'"'"']|["'"'"']$//g')
  if [[ "$url" =~ ^postgres(ql)?://([^:]+):([^@]*)@([^:/]+)(:([0-9]+))?/([^?]+) ]]; then
    DB_USER="${BASH_REMATCH[2]}"; DB_PASS="${BASH_REMATCH[3]}"
    DB_HOST="${BASH_REMATCH[4]}"; DB_NAME="${BASH_REMATCH[7]}"
  else
    DB_USER=$(env_get POSTGRES_USER); DB_USER="${DB_USER:-postgres}"
    DB_PASS=$(env_get POSTGRES_PASSWORD); DB_HOST="remnawave-db"; DB_NAME=$(env_get POSTGRES_DB); DB_NAME="${DB_NAME:-postgres}"
  fi
  DB_CT=$(docker ps --format '{{.Names}}' | grep -xF "$DB_HOST" | head -1)
  [[ -z "$DB_CT" ]] && DB_CT=$(docker ps --format '{{.Names}}' | grep -x 'remnawave-db' | head -1)
  [[ -z "$DB_CT" ]] && DB_CT=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '/postgres/ && /remna/ {print $1; exit}')
  [[ -n "$DB_CT" ]]
}

app_containers() { # контейнеры, которые пишут в БД
  local l; l=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /remnawave\/backend|remnawave\/panel/ {print $1}')
  echo "${l:-remnawave}"
}

backup_db() { # $1 — необязательная метка
  db_info || { yel "⚠ Контейнер БД не найден, дамп пропущен."; return 1; }
  mkdir -p "$RW_DIR/backups"
  local f="$RW_DIR/backups/db-$(date +%Y%m%d-%H%M%S)${1:+-$1}.sql.gz"
  echo "Дамп базы $DB_NAME ($DB_CT)..."
  if docker exec "$DB_CT" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists | gzip > "$f" \
     && [[ $(gzip -cd "$f" | head -c 100000 | wc -l) -gt 10 ]]; then
    cp -a "$RW_DIR/.env" "${f%.sql.gz}.env"
    green "✓ Бэкап БД: $f ($(du -h "$f" | cut -f1))"
  else
    rm -f "$f"; red "Дамп не удался."; return 1
  fi
}

restore_db() {
  local files=() i n f ans kind cts c env_bk
  if [[ -n "${RESTORE_FILE:-}" ]]; then f="$RESTORE_FILE"; else
  mapfile -t files < <(ls -1t "$RW_DIR"/backups/*.sql.gz "$RW_DIR"/backups/*.sql 2>/dev/null)
  bold "Дампы в $RW_DIR/backups (новые сверху):"
  for i in "${!files[@]}"; do
    printf '  %2d) %-45s %6s  %s\n' $((i+1)) "$(basename "${files[$i]}")" \
      "$(du -h "${files[$i]}" | cut -f1)" "$(date -r "${files[$i]}" '+%d.%m %H:%M')"
  done
  (( ${#files[@]} )) || echo "  (пусто)"
  echo "   п) указать путь к файлу вручную"
  read -rp "Выбор (0 — отмена): " n
  if [[ "$n" == "п" || "$n" == "p" ]]; then
    read -rep "Путь к дампу (.sql или .sql.gz): " f
  elif [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#files[@]} )); then
    f="${files[$((n-1))]}"
  else echo "Отменено."; return 0; fi
  fi
  [[ -f "$f" ]] || { err "файл не найден: $f"; return 1; }

  local cat=(cat); [[ "$f" == *.gz ]] && cat=(gzip -cd)
  "${cat[@]}" "$f" | head -c 300 >/dev/null 2>&1 || { err "файл повреждён"; return 1; }
  if "${cat[@]}" "$f" | head -c 4000 | grep -q 'database cluster dump'; then kind=cluster; else kind=db; fi

  db_info || { err "контейнер БД не запущен"; return 1; }
  red "ВНИМАНИЕ: текущие данные базы $DB_NAME будут заменены содержимым $(basename "$f")."
  read -rp "Для подтверждения введи YES: " ans
  [[ "$ans" == "YES" ]] || { echo "Отменено."; return 0; }

  echo "Страховочный бэкап текущей базы..."
  backup_db before-restore || { read -rp "Бэкап не удался. Всё равно продолжить? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0; }

  mapfile -t cts < <(app_containers)
  echo "Останавливаю панель: ${cts[*]}"
  for c in "${cts[@]}"; do docker stop "$c" >/dev/null 2>&1; done

  echo "Восстанавливаю ($kind)..."
  local rc=0
  if [[ "$kind" == db ]]; then
    "${cat[@]}" "$f" | docker exec -i "$DB_CT" psql -q -U "$DB_USER" -d "$DB_NAME" \
      -v ON_ERROR_STOP=1 --single-transaction >/dev/null || rc=$?
  else
    # старый формат (pg_dumpall): очищаем схему и заливаем, ошибки «уже существует» не критичны
    docker exec "$DB_CT" psql -q -U "$DB_USER" -d "$DB_NAME" \
      -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;' >/dev/null || rc=$?
    (( rc )) || "${cat[@]}" "$f" | docker exec -i "$DB_CT" psql -q -U "$DB_USER" -d "$DB_NAME" 2>&1 \
      | grep -vE 'already exists|does not exist|^$' | head -20
  fi

  env_bk="${f%.sql.gz}"; env_bk="${env_bk%.sql}.env"
  if (( rc == 0 )) && [[ -f "$env_bk" ]] && ! cmp -s "$env_bk" "$RW_DIR/.env"; then
    read -rp "Рядом есть .env из того же бэкапа. Восстановить и его? (нужно, если менялись JWT-секреты) [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      cp -a "$RW_DIR/.env" "$RW_DIR/.env.before-restore"; cp -a "$env_bk" "$RW_DIR/.env"
      green "✓ .env восстановлен (старый — .env.before-restore)"
      echo "Пересоздаю контейнеры..."; stack_down; stack_up; cts=()
    fi
  fi

  for c in "${cts[@]}"; do docker start "$c" >/dev/null 2>&1; done
  if (( rc )); then
    red "Восстановление не удалось — изменения откачены (одна транзакция). Панель запущена со старыми данными."
    return 1
  fi
  sleep 5
  green "✓ База восстановлена из $(basename "$f")"
  docker ps --format '  {{.Names}}\t{{.Status}}' | grep -E "$(IFS='|'; echo "${cts[*]:-remnawave}")" || true
}

# ---------- безопасность ----------
weak() { local v="$1" min="${2:-32}"; [[ -z "$v" || "$v" == change_me || "$v" == changeme || "$v" == postgres || "$v" == password || ${#v} -lt $min ]]; }
rnd()  { openssl rand -hex "${1:-32}"; }

security_check() {
  local issues=0 changed=0 ans v ports p
  section "ПРОВЕРКА"
  cp -a "$RW_DIR/.env" "$RW_DIR/.env.bak-$(date +%Y%m%d-%H%M%S)"

  # JWT_AUTH_SECRET
  if weak "$(env_get JWT_AUTH_SECRET)" 32; then
    issues=1; red "  ✗ JWT_AUTH_SECRET слабый или дефолтный"
    read -rp "    Сгенерировать новый? Все админы будут разлогинены. [Y/n] " ans
    [[ "$ans" =~ ^[Nn]$ ]] || { env_set JWT_AUTH_SECRET "$(rnd 64)"; changed=1; green "    ✓ заменён"; }
  else green "  ✓ JWT_AUTH_SECRET"; fi

  # JWT_API_TOKENS_SECRET
  if weak "$(env_get JWT_API_TOKENS_SECRET)" 32; then
    issues=1; red "  ✗ JWT_API_TOKENS_SECRET слабый или дефолтный"
    yel "    После замены ВСЕ API-токены перестанут работать: страница подписки, боты, интеграции."
    yel "    Их нужно будет создать заново в панели и прописать (REMNAWAVE_API_TOKEN и т.п.)."
    read -rp "    Сгенерировать новый? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && { env_set JWT_API_TOKENS_SECRET "$(rnd 64)"; changed=1; green "    ✓ заменён"; }
  else green "  ✓ JWT_API_TOKENS_SECRET"; fi

  # METRICS_PASS
  v=$(env_get METRICS_PASS)
  if [[ -n "$v" ]] && weak "$v" 16; then
    issues=1; red "  ✗ METRICS_PASS дефолтный"
    read -rp "    Сгенерировать новый? (обнови его в Prometheus, если используешь) [Y/n] " ans
    [[ "$ans" =~ ^[Nn]$ ]] || { env_set METRICS_PASS "$(rnd 16)"; changed=1; green "    ✓ заменён"; }
  elif [[ -n "$v" ]]; then green "  ✓ METRICS_PASS"; fi

  # WEBHOOK_SECRET_HEADER
  if [[ "$(env_get WEBHOOK_ENABLED)" == true ]] && weak "$(env_get WEBHOOK_SECRET_HEADER)" 32; then
    issues=1; red "  ✗ WEBHOOK_SECRET_HEADER слабый"
    read -rp "    Сгенерировать новый? (обнови его у получателя вебхуков) [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && { env_set WEBHOOK_SECRET_HEADER "$(rnd 32)"; changed=1; green "    ✓ заменён"; }
  fi

  # Пароль Postgres
  if db_info; then
    if weak "$DB_PASS" 16; then
      issues=1; red "  ✗ Пароль Postgres дефолтный/слабый ($DB_USER)"
      read -rp "    Сменить? [Y/n] " ans
      if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        local np; np=$(rnd 24)
        if docker exec "$DB_CT" psql -q -U "$DB_USER" -d "$DB_NAME" \
             -c "ALTER USER \"$DB_USER\" WITH PASSWORD '$np';" >/dev/null; then
          OLDP="$DB_PASS" NEWP="$np" USR="$DB_USER" perl -pi -e \
            's/^(DATABASE_URL=["\x27]?postgres(?:ql)?:\/\/\Q$ENV{USR}\E:)\Q$ENV{OLDP}\E@/${1}$ENV{NEWP}@/' "$RW_DIR/.env"
          grep -qE '^POSTGRES_PASSWORD=' "$RW_DIR/.env" && env_set POSTGRES_PASSWORD "$np"
          changed=1; green "    ✓ пароль изменён в БД и в .env"
        else red "    не удалось изменить пароль в БД"; fi
      fi
    else green "  ✓ Пароль Postgres"; fi
  else yel "  ? БД не запущена — пароль Postgres не проверен"; fi

  # Открытые наружу порты (кроме 80/443)
  ports=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -iE 'remna' | tr ',' '\n' \
          | grep -oE '(0\.0\.0\.0|\[::\]|:::):[0-9]+' | grep -oE '[0-9]+$' | sort -u | grep -vxE '80|443' || true)
  if [[ -n "$ports" ]]; then
    issues=1; red "  ✗ Наружу открыты порты: $(echo $ports | tr ' ' ',') (БД/панель доступны из интернета)"
    read -rp "    Привязать их к 127.0.0.1 в docker-compose? [Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      local c before fixed=""
      while read -r c; do
        for p in $ports; do
          before=$(md5sum < "$c")
          P="$p" perl -pi -e 's/^(\s*-\s*["\x27]?)(\Q$ENV{P}\E:\d+)/${1}127.0.0.1:$2/' "$c"
          [[ "$(md5sum < "$c")" != "$before" ]] && fixed+=" $p"
        done
      done < <(find_composes)
      for p in $ports; do [[ " $fixed " == *" $p "* ]] || yel "    ⚠ порт $p не нашёл в docker-compose — поправь вручную"; done
      [[ -n "$fixed" ]] && { changed=1; green "    ✓ привязаны к 127.0.0.1:$fixed"; }
    fi
  else green "  ✓ Наружу открыты только 80/443"; fi

  echo
  if (( changed )); then
    read -rp "Пересоздать контейнеры, чтобы применить изменения? [Y/n] " ans
    [[ "$ans" =~ ^[Nn]$ ]] || { stack_down; stack_up; green "✓ Применено"; }
  elif (( ! issues )); then green "Всё в порядке."; fi
  echo "Бэкап старого .env лежит рядом: .env.bak-*"
}

reset_admin() {
  local ct; ct=$(app_containers | head -1)
  yel "Откроется Rescue CLI панели. «Reset superadmin» удалит текущего суперадмина —"
  yel "после этого открой панель в браузере и зарегистрируй нового."
  read -rp "Запустить? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || return 0
  docker exec -it "$ct" cli
}

security_menu() {
  while true; do
    screen "Безопасность"
    item 1 "Проверить и исправить секреты, пароль БД, открытые порты"
    item 2 "Сбросить суперадмина / включить вход по паролю" "Rescue CLI"
    hr; item 0 "Назад"
    ask; read -r c
    case "$c" in 1) run_action "Безопасность: проверка" security_check; pause ;; 2) run_action "Сброс суперадмина" reset_admin; pause ;; 0|q) return ;; esac
  done
}

# ---------- логи ----------
ERR_RE='error|fatal|exception|panic|fail(ed)?|refused|denied|timeout|unhealthy|warn|critical|crash'

show_paged() {
  local tr=(cat); [[ "$RP_LANG" == en ]] && tr=(rp_translate)
  if command -v less >/dev/null && [[ -w /dev/tty ]]; then "${tr[@]}" | less -R +G >/dev/tty; else "${tr[@]}"; fi
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

# ---------- ноды ----------
NODES_FILE="/etc/rw/nodes.list"   # формат строки: имя user@host порт_ssh

node_script() { # $1 порт ноды, $2 SECRET_KEY, $3 IP панели (может быть пустым)
  cat <<EOF
set -e
echo "== Установка Remnawave Node =="
if ! command -v docker >/dev/null 2>&1; then
  echo "Устанавливаю Docker..."; curl -fsSL https://get.docker.com | sh
fi
mkdir -p /opt/remnanode && cd /opt/remnanode
[ -f docker-compose.yml ] && cp docker-compose.yml "docker-compose.yml.bak-\$(date +%s)"
cat > docker-compose.yml <<'YML'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$1
      - SECRET_KEY="$2"
YML
docker compose pull -q
docker compose up -d
EOF
  if [[ -n "${3:-}" ]]; then cat <<EOF
if command -v ufw >/dev/null 2>&1; then
  ufw allow from $3 to any port $1 proto tcp >/dev/null && echo "ufw: порт $1 разрешён только с $3"
  ufw status | grep -q '^Status: active' || echo "ВНИМАНИЕ: ufw выключен — порт $1 открыт для всех. Включи ufw, предварительно разрешив SSH."
else
  echo "ufw не найден — ограничь доступ к порту $1 (только с $3) в firewall хостера."
fi
EOF
  fi
  cat <<'EOF'
sleep 5
docker ps --filter name=remnanode --format 'remnanode: {{.Status}}'
docker logs --tail 15 remnanode 2>&1
echo "== Готово. В панели нажми Next / проверь, что нода стала онлайн. =="
EOF
}

ask_node_params() { # заполняет NP_PORT NP_SECRET NP_PANEL
  local def_ip
  echo "SECRET_KEY берётся в панели: Ноды → Management → + → Copy docker-compose.yml"
  echo "(или на сервере панели: docker exec -it remnawave cli → Get SECRET_KEY)."
  read -rp "Порт ноды (NODE_PORT) [2222]: " NP_PORT; NP_PORT="${NP_PORT:-2222}"
  [[ "$NP_PORT" =~ ^[0-9]+$ ]] && (( NP_PORT > 0 && NP_PORT < 65536 )) || { err "некорректный порт"; return 1; }
  read -rp "SECRET_KEY: " NP_SECRET
  NP_SECRET=$(echo "$NP_SECRET" | sed -E 's/^[[:space:]]*(SECRET_KEY=)?["'"'"']?//; s/["'"'"']?[[:space:]]*$//')
  [[ "$NP_SECRET" =~ ^[A-Za-z0-9+/=_.-]{20,}$ ]] || { err "SECRET_KEY выглядит некорректно"; return 1; }
  [[ -f "$RW_DIR/.env" ]] && def_ip=$(curl -4 -s --max-time 5 https://ifconfig.me || true)
  read -rp "IP панели (порт ноды откроется только для него; пусто — пропустить) [${def_ip:-}]: " NP_PANEL
  NP_PANEL="${NP_PANEL:-$def_ip}"
  [[ -z "$NP_PANEL" || "$NP_PANEL" =~ ^[0-9.]+$ || "$NP_PANEL" =~ : ]] || { err "некорректный IP"; return 1; }
}

ssh_target() { # $1 user@host, $2 port → печатает sudo-префикс
  [[ "${1%%@*}" == root ]] && echo "bash -s" || echo "sudo -n bash -s"
}

node_install_local() {
  ask_node_params || return 1
  node_script "$NP_PORT" "$NP_SECRET" "$NP_PANEL" | bash
}

node_install_remote() {
  local host port name ans
  read -rp "Сервер (user@IP, по умолчанию root@): " host
  [[ -n "$host" ]] || return 0; [[ "$host" == *@* ]] || host="root@$host"
  read -rp "SSH-порт [22]: " port; port="${port:-22}"
  ask_node_params || return 1
  echo "Подключаюсь к $host..."
  if node_script "$NP_PORT" "$NP_SECRET" "$NP_PANEL" | \
       ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$port" "$host" "$(ssh_target "$host")"; then
    green "✓ Нода установлена на $host"
    read -rp "Добавить в список для массового обновления? Имя [${host#*@}]: " name
    node_list_add "${name:-${host#*@}}" "$host" "$port"
  else
    red "Установка не удалась (если пользователь не root — нужен sudo без пароля)."
  fi
}

node_oneliner() {
  ask_node_params || return 1
  echo; bold "Скопируй целиком и вставь на новом сервере (под root):"; echo
  echo "bash <<'RWNODE'"; node_script "$NP_PORT" "$NP_SECRET" "$NP_PANEL"; echo "RWNODE"
}

node_list_add() { # имя host port
  mkdir -p "$(dirname "$NODES_FILE")"; touch "$NODES_FILE"; chmod 600 "$NODES_FILE"
  grep -qE "^[^ ]+ $2 $3$" "$NODES_FILE" && { yel "Уже в списке."; return; }
  echo "$1 $2 $3" >> "$NODES_FILE"; green "✓ Добавлена: $1 ($2:$3)"
}

node_list_show() {
  [[ -s "$NODES_FILE" ]] || { echo "  Список пуст ($NODES_FILE)."; return 1; }
  awk '{printf "  %2d) %-20s %s:%s\n", NR, $1, $2, $3}' "$NODES_FILE"
}

node_add_menu() {
  local name host port
  read -rp "Имя ноды: " name; [[ -n "$name" ]] || return
  read -rp "Сервер (user@IP, по умолчанию root@): " host; [[ -n "$host" ]] || return
  [[ "$host" == *@* ]] || host="root@$host"
  read -rp "SSH-порт [22]: " port
  node_list_add "${name// /_}" "$host" "${port:-22}"
}

node_remove_menu() {
  local n; node_list_show || return
  read -rp "Номер для удаления: " n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $(wc -l < "$NODES_FILE") )) || { echo "  Отменено."; return; }
  sed -i "${n}d" "$NODES_FILE" && green "✓ Удалена"
}

node_ssh_key() {
  local key="$HOME/.ssh/id_ed25519" n lines=() i
  [[ -f "$key" ]] || { ssh-keygen -t ed25519 -N "" -f "$key" -q; green "✓ Создан ключ $key"; }
  node_list_show || return
  read -rp "Номер ноды (Enter — все): " n
  mapfile -t lines < "$NODES_FILE"
  for i in "${!lines[@]}"; do
    [[ -z "$n" || "$n" == $((i+1)) ]] || continue
    read -r nm h p <<< "${lines[$i]}"
    echo "→ $nm ($h) — введи пароль SSH один раз:"
    ssh-copy-id -i "$key.pub" -p "$p" -o StrictHostKeyChecking=accept-new "$h"
  done
}

nodes_update() {
  local lines=() i n sel ok=() fail=() out
  node_list_show || return
  if [[ -n "${NODES_ALL:-}" ]]; then sel=""; else ask "Какие обновить? (Enter — все, или номера через запятую)"; read -r sel; fi
  mapfile -t lines < "$NODES_FILE"
  for i in "${!lines[@]}"; do
    [[ -z "$sel" || ",$sel," == *",$((i+1)),"* ]] || continue
    read -r nm h p <<< "${lines[$i]}"
    echo; bold "→ $nm ($h)"
    out=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$p" "$h" "$(ssh_target "$h")" <<'EOS' 2>&1
d=""; for x in /opt/remnanode /opt/remnawave-node; do [ -d "$x" ] && d="$x" && break; done
[ -n "$d" ] || { echo "NO_NODE_DIR"; exit 3; }
cd "$d" && docker compose pull -q && docker compose up -d && docker image prune -f >/dev/null
sleep 3
st=$(docker ps --filter name=remnanode --format '{{.Status}}')
v=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' remnanode 2>/dev/null)
echo "RESULT ${v:-?} | $st"
EOS
    )
    if echo "$out" | grep -q '^RESULT'; then
      ok+=("$nm: $(echo "$out" | grep '^RESULT' | cut -d' ' -f2-)"); green "  ✓ $(echo "$out" | grep '^RESULT' | cut -d' ' -f2-)"
    else
      fail+=("$nm"); red "  ✗ ошибка"; echo "$out" | tail -5 | sed 's/^/    /'
    fi
  done
  section "ИТОГ"; printf '  ✓ %s\n' "${ok[@]:-}" | grep -v '✓ $'; printf '  ✗ %s\n' "${fail[@]:-}" | grep -v '✗ $'
  return 0
}

node_menu() {
  while true; do
    screen "Ноды"
    item 1 "Установить ноду на этот сервер"
    item 2 "Установить ноду на другой сервер по SSH"
    item 3 "Показать команду установки" "скопировать и вставить на сервере"
    item 4 "Список нод"
    item 5 "Добавить ноду в список"
    item 6 "Удалить ноду из списка"
    item 7 "Настроить вход по SSH-ключу" "без паролей"
    item 8 "Обновить ноды по SSH"
    hr; item 0 "Назад"
    ask; read -r c
    case "$c" in
      1) run_action "Установка ноды здесь" node_install_local; pause ;;  2) run_action "Установка ноды по SSH" node_install_remote; pause ;;
      3) node_oneliner; pause ;;       4) node_list_show; pause ;;
      5) node_add_menu; pause ;;       6) node_remove_menu; pause ;;
      7) node_ssh_key; pause ;;        8) run_action "Обновление нод по SSH" nodes_update; pause ;;
      0|q) return ;;
    esac
  done
}

# ---------- журнал ----------
JOURNAL="/var/log/remnapilot.log"

jlog() { # уровень (OK|FAIL|INFO|START), текст
  printf '%s | %-5s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$JOURNAL" 2>/dev/null
}

run_action() { # название, команда… — пишет в журнал начало и результат
  local name="$1" rc; shift
  jlog START "$name"
  "$@"; rc=$?
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

# ---------- общие для сервера ----------
pkg_install() { # пакеты… — тихая установка через apt/dnf/yum
  if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 \
       || { apt-get update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1; }
  elif command -v dnf >/dev/null; then dnf install -y "$@" >/dev/null 2>&1
  elif command -v yum >/dev/null; then yum install -y "$@" >/dev/null 2>&1
  else return 1; fi
}

ssh_ports() { # порты, на которых сейчас слушает sshd
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')
  [[ -z "$p" ]] && p=$(ss -ltnpH 2>/dev/null | grep -E '"sshd"|"systemd".*ssh' | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')
  echo "${p:-22}"
}

local_node_port() { # NODE_PORT ноды на этом сервере
  local d c; d=$(node_dir) || return 1; c=$(compose_of "$d") || return 1
  grep -oE '(NODE_PORT|APP_PORT)[=:][[:space:]]*"?[0-9]+' "$c" | grep -oE '[0-9]+$' | head -1
}

public_listeners() { # «порт/протокол процесс» для всего, что слушает не на localhost
  ss -ltnupH 2>/dev/null | awk '{
      proto=$1; addr=$5; proc=$7
      if (addr ~ /^127\.|^\[::1\]|^::1:/) next
      n=split(addr,a,":"); port=a[n]
      match(proc, /\("[^"]+"/); p=substr(proc, RSTART+2, RLENGTH-3)
      print port "/" proto, (p==""?"?":p)
    }' | sort -V -u
}

# ---------- firewall ----------
fw_status_box() {
  local st rules
  if ! command -v ufw >/dev/null; then st="$(dot off) ${C_MUT}ufw не установлен${C0}"
  elif ufw status 2>/dev/null | grep -q '^Status: active'; then st="$(dot ok) ${C_OK}включён${C0}"
  else st="$(dot warn) ${C_WARN}выключен${C0}"; fi
  box_top
  box_line "${C_MUT}$(padr "ufw" 11)${C0}$st"
  box_line "${C_MUT}$(padr "SSH" 11)${C0}$(ssh_ports)"
  local np; np=$(local_node_port 2>/dev/null) && box_line "${C_MUT}$(padr "Нода" 11)${C0}порт $np"
  box_bottom
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    section "ПРАВИЛА"
    ufw status numbered 2>/dev/null | grep -E '^\[' | sed 's/^/  /'
  fi
}

fw_setup() {
  local sshp np panel_ip ans l port proto proc keep=() extra x
  sshp=$(ssh_ports); np=$(local_node_port 2>/dev/null)

  section "СЕЙЧАС СЛУШАЮТ СНАРУЖИ"
  while read -r port proc; do
    [[ -z "$port" ]] && continue
    printf '   %-12s %s\n' "$port" "$proc"
  done < <(public_listeners)

  # что оставим открытым
  for x in $sshp; do keep+=("$x/tcp|SSH"); done
  keep+=("80/tcp|HTTP" "443/tcp|HTTPS")
  # порты Xray на ноде (кроме порта управления ноды) — без них клиенты не подключатся
  while read -r port proc; do
    [[ "$proc" =~ ^(xray|rw-core|remnanode|node)$ ]] || continue
    [[ "${port%/*}" == "$np" ]] && continue
    [[ " ${keep[*]} " == *" ${port}|"* ]] || keep+=("$port|Xray")
  done < <(public_listeners)

  section "ПЛАН"
  echo "   Входящие по умолчанию: ${C_ERR}запрещены${C0}, исходящие: разрешены"
  for x in "${keep[@]}"; do printf '   %s✔%s %-12s %s\n' "$C_OK" "$C0" "${x%%|*}" "${x#*|}"; done

  if [[ -n "$np" ]]; then
    echo
    info "На этом сервере нода, порт управления ${CB}$np${C0}."
    [[ -f "$RW_DIR/.env" ]] && echo "   Панель на этом же сервере — разрешу порт $np для Docker-сетей." \
                            || { ask "IP панели, с которого разрешить порт $np (Enter — для всех)"; read -r panel_ip
                                 [[ -z "$panel_ip" ]] && panel_ip=any; }
  fi
  echo
  ask "Дополнительные порты через пробел (например 8443/tcp 2053/udp) или Enter"; read -r extra

  echo; yel "SSH-порт(ы) $sshp останутся открытыми — доступ к серверу не потеряешь."
  ask "Включить firewall? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "  Отменено."; return 0; }

  command -v ufw >/dev/null || { info "Устанавливаю ufw..."; pkg_install ufw || { red "✖ Не удалось установить ufw"; return 1; }; }
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null

  # сначала SSH — на случай, если что-то пойдёт не так
  for x in $sshp; do ufw allow "$x/tcp" comment 'SSH' >/dev/null; done
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  for x in "${keep[@]}"; do ufw allow "${x%%|*}" comment "${x#*|}" >/dev/null; done
  for x in $extra; do [[ "$x" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] && ufw allow "$x" comment 'RemnaPilot' >/dev/null; done
  if [[ -n "$np" ]]; then
    if [[ "$panel_ip" == any ]]; then ufw allow "$np/tcp" comment 'Remnawave node' >/dev/null
    elif [[ -n "$panel_ip" ]]; then ufw allow from "$panel_ip" to any port "$np" proto tcp comment 'Remnawave panel' >/dev/null
    elif [[ -f "$RW_DIR/.env" ]]; then
      ufw allow from 172.16.0.0/12 to any port "$np" proto tcp comment 'Remnawave panel (docker)' >/dev/null
      ufw allow from 127.0.0.1 to any port "$np" proto tcp >/dev/null
    fi
  fi
  ufw --force enable >/dev/null && green "✔ Firewall включён"
  jlog INFO "Firewall: открыто ${keep[*]%%|*} $extra; нода ${np:-—} ${panel_ip:+только с $panel_ip}"

  if docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE '0\.0\.0\.0:[0-9]+'; then
    yel "⚠ Порты, опубликованные Docker (ports: в compose), ufw НЕ закрывает — Docker обходит его."
    yel "  Проверь их в «Безопасность» → там же можно привязать их к 127.0.0.1."
  fi
}

fw_port() { # allow|deny
  local p from
  ask "Порт (например 8443 или 2053/udp)"; read -r p
  [[ "$p" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || { err "некорректный порт"; return 1; }
  if [[ "$1" == allow ]]; then
    ask "Только с IP (Enter — для всех)"; read -r from
    local pt="${p%/*}" pr=""; [[ "$p" == */* ]] && pr="${p#*/}"
    if [[ -n "$from" ]]; then ufw allow from "$from" to any port "$pt" ${pr:+proto "$pr"} >/dev/null
    else ufw allow "$p" >/dev/null; fi
    green "✔ Открыт $p${from:+ для $from}"; jlog INFO "Firewall: открыт $p${from:+ для $from}"
  else
    if [[ " $(ssh_ports) " == *" ${p%/*} "* ]]; then yel "Это порт SSH — не закрываю, иначе потеряешь доступ."; return 1; fi
    ufw delete allow "$p" >/dev/null 2>&1 || ufw delete allow "${p%/*}" >/dev/null 2>&1
    green "✔ Закрыт $p"; jlog INFO "Firewall: закрыт $p"
  fi
}

firewall_menu() {
  local c a
  while true; do
    screen "Firewall"; echo
    fw_status_box
    section "ДЕЙСТВИЯ"
    item 1 "Настроить одной кнопкой" "SSH · 80 · 443 · нода"
    item 2 "Открыть порт"
    item 3 "Закрыть порт"
    item 4 "Выключить firewall"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Firewall: настройка" fw_setup; pause ;;
      2) command -v ufw >/dev/null && run_action "Firewall: открыть порт" fw_port allow; pause ;;
      3) command -v ufw >/dev/null && run_action "Firewall: закрыть порт" fw_port deny; pause ;;
      4) ask "Выключить firewall? [y/N]"; read -r a
         [[ "$a" =~ ^[Yy]$ ]] && ufw disable >/dev/null && { yel "Firewall выключен"; jlog INFO "Firewall выключен"; }; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- защита SSH ----------
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-remnapilot.conf"

sshd_set() { # ключ значение — в свой drop-in (или в основной конфиг, если Include нет)
  local k="$1" v="$2" f="$SSHD_DROPIN"
  if ! grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then f=/etc/ssh/sshd_config; fi
  mkdir -p "$(dirname "$f")"; touch "$f"
  if grep -qiE "^\s*$k\s" "$f"; then K="$k" V="$v" perl -pi -e 's/^\s*\Q$ENV{K}\E\s.*/$ENV{K} $ENV{V}/i' "$f"
  elif [[ "$f" == /etc/ssh/sshd_config ]]; then
    K="$k" perl -pi -e 's/^(\s*\Q$ENV{K}\E\s)/#$1/i' "$f"; printf '%s %s\n' "$k" "$v" >> "$f"
  else printf '%s %s\n' "$k" "$v" >> "$f"; fi
}

sshd_reload() {
  sshd -t 2>/tmp/rp-sshd.err || { red "✖ Ошибка в конфиге SSH:"; sed 's/^/    /' /tmp/rp-sshd.err; return 1; }
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

ssh_has_keys() { # есть ли ключи у root и у пользователя sudo
  local f
  for f in /root/.ssh/authorized_keys ${SUDO_USER:+/home/$SUDO_USER/.ssh/authorized_keys}; do
    [[ -s "$f" ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" && return 0
  done
  return 1
}

ssh_status_box() {
  local pa rl f2b
  pa=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')
  rl=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}')
  if systemctl is-active fail2ban >/dev/null 2>&1; then
    f2b="$(dot ok) ${C_OK}работает${C0}  ${C_MUT}забанено: $(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')${C0}"
  else f2b="$(dot off) ${C_MUT}не установлен${C0}"; fi
  box_top
  box_line "${C_MUT}$(padr "Порт" 11)${C0}$(ssh_ports)"
  box_line "${C_MUT}$(padr "Пароль" 11)${C0}$( [[ "$pa" == no ]] && echo "$(dot ok) ${C_OK}вход по паролю выключен${C0}" || echo "$(dot warn) ${C_WARN}вход по паролю включён${C0}")"
  box_line "${C_MUT}$(padr "root" 11)${C0}${rl:-?}"
  box_line "${C_MUT}$(padr "Ключи" 11)${C0}$(ssh_has_keys && echo "$(dot ok) есть" || echo "$(dot warn) ${C_WARN}нет authorized_keys${C0}")"
  box_line "${C_MUT}$(padr "fail2ban" 11)${C0}$f2b"
  box_bottom
}

ssh_change_port() {
  local old new ans
  old=$(ssh_ports); old="${old%% *}"
  new=$(( (RANDOM % 40000) + 20000 ))
  ask "Новый порт SSH [$new]"; read -r ans; new="${ans:-$new}"
  [[ "$new" =~ ^[0-9]+$ ]] && (( new >= 1024 && new <= 65535 )) || { err "порт должен быть 1024–65535"; return 1; }
  port_busy "$new" && { err "порт $new уже занят"; return 1; }

  # firewall: открыть новый порт ДО перезапуска SSH
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow "$new/tcp" comment 'SSH' >/dev/null; fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$new/tcp" >/dev/null; firewall-cmd --reload >/dev/null; fi
  command -v semanage >/dev/null && semanage port -a -t ssh_port_t -p tcp "$new" 2>/dev/null

  sshd_set Port "$new"
  # Ubuntu 22.10+: SSH запускается через ssh.socket, порт задаётся там
  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    printf '[Socket]\nListenStream=\nListenStream=0.0.0.0:%s\nListenStream=[::]:%s\n' "$new" "$new" > /etc/systemd/system/ssh.socket.d/00-remnapilot.conf
    systemctl daemon-reload; sshd -t || { red "✖ Ошибка конфига SSH"; return 1; }
    systemctl restart ssh.socket
  else
    sshd_reload || return 1
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
  fi
  sleep 1
  if ! port_busy "$new"; then
    red "✖ SSH не слушает порт $new — возвращаю $old"; ssh_revert_port "$old"
    command -v ufw >/dev/null && ufw delete allow "$new/tcp" >/dev/null 2>&1
    return 1
  fi

  green "✔ SSH теперь на порту $new (старый $old пока тоже открыт в firewall)"
  yel "Не закрывай это окно! Открой НОВОЕ подключение:  ssh -p $new root@$(curl -4 -s --max-time 5 https://ifconfig.me)"
  ask "Получилось подключиться на новом порту? [y/N]"; read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    command -v ufw >/dev/null && ufw delete allow "$old/tcp" >/dev/null 2>&1
    green "✔ Готово. Старый порт $old закрыт."; jlog INFO "SSH: порт $old → $new"
  else
    ssh_revert_port "$old"
    command -v ufw >/dev/null && ufw delete allow "$new/tcp" >/dev/null 2>&1
    yel "Вернул порт $old."
  fi
}

ssh_revert_port() {
  sshd_set Port "$1"
  rm -f /etc/systemd/system/ssh.socket.d/00-remnapilot.conf
  if systemctl is-active ssh.socket >/dev/null 2>&1; then systemctl daemon-reload; systemctl restart ssh.socket
  else sshd_reload; systemctl restart ssh 2>/dev/null || systemctl restart sshd; fi
}

ssh_fail2ban() {
  local ports; ports=$(ssh_ports | tr ' ' ',' | sed 's/,$//')
  command -v fail2ban-client >/dev/null || { info "Устанавливаю fail2ban..."; pkg_install fail2ban || { red "✖ Не удалось установить fail2ban"; return 1; }; }
  local backend=auto; command -v journalctl >/dev/null && [[ ! -f /var/log/auth.log ]] && backend=systemd
  cat > /etc/fail2ban/jail.d/remnapilot.local <<EOF
# RemnaPilot
[sshd]
enabled  = true
port     = $ports
backend  = $backend
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.maxtime   = 1w
ignoreip = 127.0.0.1/8 ::1
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  sleep 2
  if fail2ban-client status sshd >/dev/null 2>&1; then
    green "✔ fail2ban защищает SSH (порт $ports): 5 ошибок за 10 минут → бан на 1 час, повторно — дольше."
    jlog INFO "fail2ban включён для SSH ($ports)"
  else red "✖ fail2ban не запустился:"; journalctl -u fail2ban -n 10 --no-pager 2>/dev/null | sed 's/^/    /'; return 1; fi
}

ssh_disable_password() {
  local ans
  if ! ssh_has_keys; then
    red "✖ На сервере нет ни одного SSH-ключа (authorized_keys)."
    echo "  Если выключить пароль сейчас — ты потеряешь доступ. Сначала добавь свой ключ:"
    echo "  на своём компьютере:  ssh-copy-id -p $(ssh_ports | awk '{print $1}') root@$(curl -4 -s --max-time 5 https://ifconfig.me)"
    return 1
  fi
  yel "Убедись, что ТЫ СЕЙЧАС вошёл по ключу, а не по паролю."
  ask "Выключить вход по паролю? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0
  sshd_set PasswordAuthentication no
  sshd_set KbdInteractiveAuthentication no
  sshd_set PermitRootLogin prohibit-password
  sshd_reload || return 1
  green "✔ Вход по паролю выключен, root — только по ключу."
  yel "Проверь в новом окне, что вход по ключу работает, прежде чем закрывать это."
  jlog INFO "SSH: вход по паролю выключен"
}

ssh_enable_password() {
  sshd_set PasswordAuthentication yes; sshd_set KbdInteractiveAuthentication yes
  sshd_reload && { yel "Вход по паролю снова включён."; jlog INFO "SSH: вход по паролю включён"; }
}

ssh_menu() {
  local c
  while true; do
    screen "Защита SSH"; echo
    ssh_status_box
    section "ДЕЙСТВИЯ"
    item 1 "Сменить порт SSH" "с проверкой, без риска потерять доступ"
    item 2 "Установить fail2ban" "бан за перебор паролей"
    item 3 "Выключить вход по паролю" "только по ключу"
    item 4 "Включить вход по паролю обратно"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "SSH: смена порта" ssh_change_port; pause ;;
      2) run_action "SSH: fail2ban" ssh_fail2ban; pause ;;
      3) run_action "SSH: выключить пароль" ssh_disable_password; pause ;;
      4) run_action "SSH: включить пароль" ssh_enable_password; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- BBR и тюнинг сети ----------
SYSCTL_FILE="/etc/sysctl.d/99-remnapilot.conf"

net_status_box() {
  local cc qd kv
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  kv=$(uname -r)
  box_top
  box_line "${C_MUT}$(padr "Алгоритм" 11)${C0}$( [[ "$cc" == bbr* ]] && echo "$(dot ok) ${C_OK}$cc${C0}" || echo "$(dot warn) ${C_WARN}$cc${C0}  ${C_MUT}(BBR выключен)${C0}")"
  box_line "${C_MUT}$(padr "Очередь" 11)${C0}$qd"
  box_line "${C_MUT}$(padr "Ядро" 11)${C0}$kv"
  box_line "${C_MUT}$(padr "Тюнинг" 11)${C0}$( [[ -f "$SYSCTL_FILE" ]] && echo "$(dot ok) применён" || echo "$(dot off) ${C_MUT}нет${C0}")"
  box_bottom
}

net_enable() {
  local major minor ans
  IFS=. read -r major minor _ <<< "$(uname -r)"
  if (( major < 4 || (major == 4 && minor < 9) )); then red "✖ BBR нужен Linux 4.9+, а здесь $(uname -r)"; return 1; fi
  modprobe tcp_bbr 2>/dev/null
  section "ЧТО ВКЛЮЧУ"
  cat <<'EOF'
   • BBR + fq — быстрее на каналах с потерями и большим пингом
   • большие TCP-буферы — скорость на дальних маршрутах
   • TCP Fast Open, MTU probing, без «медленного старта» после простоя
   • больше соединений и открытых файлов — для множества клиентов
EOF
  ask "Применить? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0
  cat > "$SYSCTL_FILE" <<'EOF'
# RemnaPilot — тюнинг сети для VPN
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.ip_local_port_range = 10240 65535
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
fs.file-max = 2097152
EOF
  echo tcp_bbr > /etc/modules-load.d/remnapilot-bbr.conf 2>/dev/null
  if ! grep -q 'RemnaPilot' /etc/security/limits.conf 2>/dev/null; then
    printf '# RemnaPilot\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' >> /etc/security/limits.conf
  fi
  sysctl --system >/dev/null 2>&1
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    green "✔ BBR включён, тюнинг применён. Перезагрузка не нужна."; jlog INFO "Сеть: BBR и тюнинг включены"
  else
    red "✖ BBR не включился (ядро без модуля tcp_bbr?)"; return 1
  fi
}

net_disable() {
  rm -f "$SYSCTL_FILE" /etc/modules-load.d/remnapilot-bbr.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
  sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
  sysctl --system >/dev/null 2>&1
  yel "Тюнинг убран, алгоритм — cubic. Остальные параметры вернутся к умолчаниям после перезагрузки."
  jlog INFO "Сеть: тюнинг выключен"
}

net_menu() {
  local c
  while true; do
    screen "Ускорение сети"; echo
    net_status_box
    section "ДЕЙСТВИЯ"
    item 1 "Включить BBR и тюнинг"
    item 2 "Вернуть как было"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Сеть: BBR" net_enable; pause ;;
      2) run_action "Сеть: откат тюнинга" net_disable; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- очистка ----------
disk_free_mb() { df -Pm / | awk 'NR==2{print $4}'; }

cleanup_status() {
  local used total pct
  read -r total used pct < <(df -Ph / | awk 'NR==2{print $2, $3, $5}')
  box_top
  box_line "${C_MUT}$(padr "Диск /" 11)${C0}занято $used из $total ($pct)"
  if command -v docker >/dev/null; then
    box_line "${C_MUT}$(padr "Образы" 11)${C0}$(docker system df --format '{{.Type}} {{.Size}} {{.Reclaimable}}' 2>/dev/null | awk '$1=="Images"{print $2", можно освободить "$3}')"
    local lg="" ids lps; ids=$(docker ps -aq 2>/dev/null)
    [[ -n "$ids" ]] && lps=$(docker inspect --format '{{.LogPath}}' $ids 2>/dev/null | grep -v '^$')
    [[ -n "$lps" ]] && lg=$(du -ch $lps 2>/dev/null | tail -1 | cut -f1)
    box_line "${C_MUT}$(padr "Логи Docker" 11)${C0}${lg:-0}"
  fi
  box_line "${C_MUT}$(padr "Журнал ОС" 11)${C0}$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | tail -1)"
  [[ -d /var/log/remnanode ]] && box_line "${C_MUT}$(padr "Логи ноды" 11)${C0}$(du -sh /var/log/remnanode 2>/dev/null | cut -f1)"
  [[ -d "$RW_DIR/backups" ]] && box_line "${C_MUT}$(padr "Бэкапы" 11)${C0}$(du -sh "$RW_DIR/backups" 2>/dev/null | cut -f1)  ${C_MUT}($(ls "$RW_DIR"/backups/*.sql.gz 2>/dev/null | wc -l) дампов)${C0}"
  box_bottom
}

cleanup_run() {
  local before after ans keep=10 f c lp
  before=$(disk_free_mb)
  section "ЧТО ОЧИЩУ"
  cat <<'EOF'
   • неиспользуемые Docker-образы без тега и кэш сборки
     (образы для отката обновления сохраняются)
   • логи контейнеров больше 50 МБ — обрежу
   • журнал ОС (journald) — до 200 МБ
   • кэш пакетов apt
   • логи ноды старше 7 дней
   • старые бэкапы — оставлю последние N
EOF
  ask "Сколько последних бэкапов базы оставить? [$keep]"; read -r ans; [[ "$ans" =~ ^[0-9]+$ ]] && keep="$ans"
  ask "Начать? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0

  if command -v docker >/dev/null; then
    docker image prune -f >/dev/null 2>&1; docker builder prune -f >/dev/null 2>&1
    for c in $(docker ps -aq 2>/dev/null); do
      lp=$(docker inspect --format '{{.LogPath}}' "$c" 2>/dev/null)
      [[ -f "$lp" ]] && (( $(stat -c %s "$lp") > 52428800 )) && truncate -s 0 "$lp"
    done
    green "✔ Docker почищен"
  fi
  command -v journalctl >/dev/null && journalctl --vacuum-size=200M >/dev/null 2>&1 && green "✔ Журнал ОС ужат до 200 МБ"
  command -v apt-get >/dev/null && apt-get clean >/dev/null 2>&1 && green "✔ Кэш apt очищен"
  if [[ -d /var/log/remnanode ]]; then
    find /var/log/remnanode -type f -mtime +7 -delete 2>/dev/null
    for f in /var/log/remnanode/*.log; do [[ -f "$f" ]] && (( $(stat -c %s "$f") > 104857600 )) && truncate -s 0 "$f"; done
    green "✔ Логи ноды почищены"
  fi
  if [[ -d "$RW_DIR/backups" ]]; then
    ls -1t "$RW_DIR"/backups/db-*.sql.gz 2>/dev/null | tail -n +$((keep + 1)) | while read -r f; do rm -f "$f" "${f%.sql.gz}.env"; done
    ls -1t "$RW_DIR"/backups/update-*.log 2>/dev/null | tail -n +21 | xargs -r rm -f
    ls -1dt "$RW_DIR"/backup-domain-* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -rf
    green "✔ Оставлено последних бэкапов: $keep"
  fi
  after=$(disk_free_mb)
  green "✔ Освобождено: $(( after - before )) МБ"
  jlog INFO "Очистка: освобождено $(( after - before )) МБ"
}

cleanup_autolimits() { # ограничить рост логов навсегда
  local ans
  section "ЧТО НАСТРОЮ"
  echo "   • Docker: логи каждого контейнера не больше 3 × 50 МБ"
  echo "   • logrotate для /var/log/remnanode: каждый день, хранить 7 дней, сжимать"
  echo "   • journald: не больше 300 МБ"
  yel "Для лимита логов Docker нужен перезапуск Docker — VPN прервётся на ~10 секунд."
  ask "Применить? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0

  cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    daily
    rotate 7
    maxsize 100M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=300M\n' > /etc/systemd/journald.conf.d/remnapilot.conf
  systemctl restart systemd-journald 2>/dev/null

  if command -v docker >/dev/null; then
    local dj=/etc/docker/daemon.json
    mkdir -p /etc/docker; [[ -s "$dj" ]] && cp -a "$dj" "$dj.bak-$(date +%s)" || echo '{}' > "$dj"
    if command -v python3 >/dev/null; then
      python3 - "$dj" <<'PY'
import json,sys
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: d={}
d["log-driver"]="json-file"; d.setdefault("log-opts",{}).update({"max-size":"50m","max-file":"3"})
json.dump(d,open(p,"w"),indent=2)
PY
    elif [[ "$(tr -d ' \n\t' < "$dj")" == "{}" ]]; then
      printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "50m", "max-file": "3" }\n}\n' > "$dj"
    elif ! grep -q '"log-opts"' "$dj"; then
      yel "⚠ В $dj уже есть настройки, а python3 нет — добавь вручную: \"log-opts\": {\"max-size\": \"50m\", \"max-file\": \"3\"}"
    fi
    systemctl restart docker && green "✔ Лимит логов Docker применён (для контейнеров, созданных заново — «Пересоздать контейнеры»)"
  fi
  green "✔ logrotate и лимит journald настроены"
  jlog INFO "Очистка: лимиты логов настроены"
}

cleanup_menu() {
  local c
  while true; do
    screen "Очистка диска"; echo
    cleanup_status
    section "ДЕЙСТВИЯ"
    item 1 "Очистить сейчас"
    item 2 "Ограничить рост логов навсегда" "logrotate · Docker · journald"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Очистка диска" cleanup_run; pause ;;
      2) run_action "Лимиты логов" cleanup_autolimits; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- перенос панели ----------
migrate_panel() {
  local host port ans dump newip oldip stop_old=1 sshc
  need_panel || return 1
  section "КАК ЭТО РАБОТАЕТ"
  cat <<'EOF'
   1. Проверю новый сервер, при необходимости поставлю Docker
   2. Остановлю панель здесь и сделаю свежий бэкап базы
   3. Скопирую /opt/remnawave (конфиги, сертификаты, .env) и дамп
   4. На новом сервере: подниму базу, восстановлю дамп, запущу панель
   5. Разрешу IP новой панели на нодах (если они в списке)
   6. Подскажу, какие DNS-записи поменять
   Старая панель останется (остановленной) — можно вернуться.
EOF
  ask "Новый сервер (user@IP, по умолчанию root@)"; read -r host
  [[ -n "$host" ]] || return 0; [[ "$host" == *@* ]] || host="root@$host"
  ask "SSH-порт [22]"; read -r port; port="${port:-22}"
  sshc=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$port" "$host")

  info "Проверяю подключение..."
  "${sshc[@]}" 'echo ok' >/dev/null 2>&1 || {
    yel "Не удалось войти без пароля. Сейчас попрошу пароль один раз и добавлю ключ."
    [[ -f "$HOME/.ssh/id_ed25519" ]] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -q
    ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" -p "$port" -o StrictHostKeyChecking=accept-new "$host" || { red "✖ Нет доступа к $host"; return 1; }
  }
  [[ "${host%%@*}" == root ]] || { red "✖ Нужен вход под root на новом сервере"; return 1; }
  if "${sshc[@]}" "test -f /opt/remnawave/.env"; then
    yel "⚠ На новом сервере уже есть /opt/remnawave — он будет перезаписан."
  fi
  newip=$("${sshc[@]}" 'curl -4 -s --max-time 5 https://ifconfig.me' 2>/dev/null); newip="${newip:-${host#*@}}"
  oldip=$(curl -4 -s --max-time 5 https://ifconfig.me)

  section "ИТОГ"
  echo "   Откуда: $oldip ($RW_DIR)"
  echo "   Куда:   $newip ($host)"
  yel "   Панель здесь будет остановлена на время переноса (подписки и ноды продолжат работать)."
  ask "Начать перенос? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0
  jlog INFO "Перенос панели: $oldip → $newip"

  info "1/5 Готовлю новый сервер (Docker)..."
  "${sshc[@]}" 'command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; docker compose version >/dev/null' \
    || { red "✖ Не удалось поставить Docker на новом сервере"; return 1; }

  info "2/5 Останавливаю панель и делаю бэкап..."
  local cts=(); mapfile -t cts < <(app_containers)
  for c in "${cts[@]}"; do docker stop "$c" >/dev/null 2>&1; done
  backup_db migrate || { for c in "${cts[@]}"; do docker start "$c" >/dev/null; done; red "✖ Бэкап не удался — перенос отменён"; return 1; }
  dump=$(ls -1t "$RW_DIR"/backups/db-*-migrate.sql.gz | head -1)

  info "3/5 Копирую файлы ($(du -sh --exclude='backup-domain-*' --exclude='backups' "$RW_DIR" 2>/dev/null | cut -f1))..."
  tar -C "$RW_DIR" --exclude='./backup-domain-*' --exclude='./backups' --exclude='./data' --exclude='./db' \
      --exclude='./db-data' --exclude='./pgdata' --exclude='./postgres*' -czf - . \
    | "${sshc[@]}" "mkdir -p /opt/remnawave/backups && tar -xzf - -C /opt/remnawave" || { red "✖ Ошибка копирования"; return 1; }
  scp -q -P "$port" -o StrictHostKeyChecking=accept-new "$dump" "$host:/opt/remnawave/backups/" || { red "✖ Не скопировался дамп"; return 1; }
  [[ -s "$NODES_FILE" ]] && "${sshc[@]}" "mkdir -p /etc/rw" && scp -q -P "$port" "$NODES_FILE" "$host:$NODES_FILE"
  local me; me=$(readlink -f "$0"); [[ -f "$me" ]] && scp -q -P "$port" "$me" "$host:/usr/local/bin/rw"

  info "4/5 Запускаю базу и восстанавливаю данные на новом сервере..."
  db_info >/dev/null 2>&1
  "${sshc[@]}" "DUMP='/opt/remnawave/backups/$(basename "$dump")' DBU='$DB_USER' DBN='$DB_NAME' DBH='$DB_HOST' bash -s" <<'EOS' || { red "✖ Ошибка на новом сервере"; return 1; }
set -e
cd /opt/remnawave
svc=$(docker compose config --services | grep -iE 'db|postgres' | head -1)
docker compose up -d "$svc" >/dev/null 2>&1
ct=$(docker compose ps -q "$svc")
for i in $(seq 1 30); do docker exec "$ct" pg_isready -U "$DBU" >/dev/null 2>&1 && break; sleep 2; done
gzip -cd "$DUMP" | docker exec -i "$ct" psql -q -U "$DBU" -d "$DBN" -v ON_ERROR_STOP=1 --single-transaction >/dev/null
docker compose up -d >/dev/null 2>&1
for f in $(find /opt/remnawave -mindepth 2 -maxdepth 2 \( -name docker-compose.yml -o -name compose.yml \)); do (cd "$(dirname "$f")" && docker compose up -d >/dev/null 2>&1); done
sleep 10
docker ps --format '  {{.Names}}\t{{.Status}}' | grep -i remna
EOS
  green "✔ Панель запущена на $newip"
  # старая панель не должна сама подняться после перезагрузки и спорить с новой за ноды
  for c in "${cts[@]}"; do docker update --restart=no "$c" >/dev/null 2>&1; done

  info "5/5 Ноды..."
  if [[ -s "$NODES_FILE" ]]; then
    local lines=() nm h p np
    mapfile -t lines < "$NODES_FILE"
    for l in "${lines[@]}"; do
      read -r nm h p <<< "$l"
      if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$p" "$h" \
          "command -v ufw >/dev/null || exit 0; np=\$(grep -oE 'NODE_PORT[=:][[:space:]]*\"?[0-9]+' /opt/remnanode/docker-compose.yml 2>/dev/null | grep -oE '[0-9]+\$'); [ -n \"\$np\" ] && ufw allow from $newip to any port \$np proto tcp comment 'Remnawave panel' >/dev/null" </dev/null 2>/dev/null
      then green "  ✔ $nm: доступ для $newip открыт"; else yel "  ⚠ $nm: не удалось — разреши $newip к порту ноды вручную"; fi
    done
  else
    echo "  Список нод пуст. Если на нодах firewall пускает только старый IP панели — разреши $newip к порту ноды."
  fi

  section "ОСТАЛОСЬ СДЕЛАТЬ ТЕБЕ"
  echo "   1. У регистратора домена поменяй A-записи на $newip:"
  printf '      %s\n' "$(detect_old)" $( s=$(sub_host); [[ -n "$s" && "$s" != "$(detect_old)" ]] && echo "$s" )
  echo "   2. Подожди обновления DNS и открой панель — данные должны быть на месте."
  echo "   3. На новом сервере запусти  rw  → «Сертификаты» → перевыпусти, чтобы заработало автопродление."
  echo "   4. Если всё хорошо — старую панель можно удалить. Если нет — запусти её здесь: пункт 7 «Пересоздать контейнеры»."
  jlog OK "Перенос панели на $newip завершён"
}

# ---------- выполнение на нодах: этот сервер / одна нода / все ----------
TARGETS=()

pick_targets() { # $1 = заголовок; заполняет TARGETS: "local" или "имя|user@host|порт"
  local lines=() i n c have_local=0
  node_dir >/dev/null 2>&1 && have_local=1
  [[ -s "$NODES_FILE" ]] && mapfile -t lines < "$NODES_FILE"
  TARGETS=()
  if (( ! have_local && ${#lines[@]} == 0 )); then
    yel "Нод нет: ни на этом сервере, ни в списке (пункт 13 → «Добавить ноду в список»)."; return 1
  fi
  section "${1:-ГДЕ}"
  n=0
  (( have_local )) && { n=$((n+1)); item $n "Этот сервер" "$(hostname)"; }
  for i in "${!lines[@]}"; do n=$((n+1)); read -r nm h p <<< "${lines[$i]}"; item $n "$nm" "$h"; done
  (( ${#lines[@]} )) && item a "Все ноды из списка"
  hr; item 0 "Отмена"
  ask; read -r c
  [[ "$c" == 0 || -z "$c" ]] && return 1
  if [[ "$c" == a || "$c" == а ]]; then
    for i in "${lines[@]}"; do read -r nm h p <<< "$i"; TARGETS+=("$nm|$h|$p"); done
  elif [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )); then
    if (( have_local )) && (( c == 1 )); then TARGETS=(local)
    else i=$(( c - 1 - have_local )); read -r nm h p <<< "${lines[$i]}"; TARGETS=("$nm|$h|$p"); fi
  else return 1; fi
}

run_on() { # цель, скрипт (текст) — выполнить локально или по SSH под root
  local t="$1" script="$2" nm h p
  if [[ "$t" == local ]]; then bash -s <<< "$script"; return; fi
  IFS='|' read -r nm h p <<< "$t"
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 -p "$p" "$h" "$(ssh_target "$h")" <<< "$script"
}

target_name() { [[ "$1" == local ]] && echo "этот сервер" || echo "${1%%|*}"; }

# ---------- geoip / geosite ----------
geo_script() { # $1 = источник (loyal|runet)
  local base
  case "$1" in
    runet) base="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download" ;;
    *)     base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download" ;;
  esac
  cat <<EOF
set -e
d=""; for x in /opt/remnanode /opt/remnawave-node; do [ -d "\$x" ] && d="\$x" && break; done
[ -n "\$d" ] || { echo "RESULT FAIL нет ноды"; exit 1; }
mkdir -p "\$d/geo" && cd "\$d/geo"
for f in geoip.dat geosite.dat; do
  curl -fsSL --max-time 120 -o "\$f.new" "$base/\$f" || { echo "RESULT FAIL не скачался \$f"; exit 1; }
  if curl -fsSL --max-time 20 -o "\$f.sha" "$base/\$f.sha256sum" 2>/dev/null; then
    [ "\$(sha256sum "\$f.new" | cut -d' ' -f1)" = "\$(cut -d' ' -f1 "\$f.sha")" ] || { echo "RESULT FAIL контрольная сумма \$f"; exit 1; }
  fi
  [ "\$(stat -c %s "\$f.new")" -gt 100000 ] || { echo "RESULT FAIL слишком маленький \$f"; exit 1; }
  mv -f "\$f.new" "\$f"; rm -f "\$f.sha"
done
c=\$(ls "\$d"/docker-compose.yml "\$d"/docker-compose.yaml "\$d"/compose.yml "\$d"/compose.yaml 2>/dev/null | head -1)
[ -n "\$c" ] || { echo "RESULT FAIL нет docker-compose ноды"; exit 1; }
if ! grep -q '/usr/local/share/xray/geoip.dat' "\$c"; then
  cp -a "\$c" "\$c.bak-\$(date +%s)"
  # добавить volumes к сервису remnanode
  if grep -qE '^[[:space:]]+volumes:' "\$c"; then
    sed -i -E '0,/^([[:space:]]+)volumes:[[:space:]]*\$/s##&\n\1  - ./geo/geoip.dat:/usr/local/share/xray/geoip.dat:ro\n\1  - ./geo/geosite.dat:/usr/local/share/xray/geosite.dat:ro#' "\$c"
  else
    ind=\$(grep -m1 -E '^[[:space:]]+image:' "\$c" | sed -E 's/image:.*//')
    sed -i -E "0,/^[[:space:]]+image:.*\$/s##&\n\${ind}volumes:\n\${ind}  - ./geo/geoip.dat:/usr/local/share/xray/geoip.dat:ro\n\${ind}  - ./geo/geosite.dat:/usr/local/share/xray/geosite.dat:ro#" "\$c"
  fi
  (cd "\$d" && docker compose up -d >/dev/null 2>&1) || true
else
  docker restart remnanode >/dev/null 2>&1 || true
fi
sleep 3
st=\$(docker ps --filter name=remnanode --format '{{.Status}}')
echo "RESULT OK \$(du -h geoip.dat | cut -f1) / \$(du -h geosite.dat | cut -f1) · \$st"
EOF
}

geo_cron_line() { echo "17 4 * * 1 root bash $RP_SELF --geo-update-local $1 >/var/log/remnapilot-geo.log 2>&1"; }

geo_update() {
  local src c t out
  section "ИСТОЧНИК"
  item 1 "Loyalsoldier" "v2ray-rules-dat — мировой, самый популярный"
  item 2 "runetfreedom" "russia-v2ray-rules-dat — с ru-blocked для РФ"
  hr; item 0 "Отмена"
  ask; read -r c
  case "$c" in 1) src=loyal ;; 2) src=runet ;; *) return 0 ;; esac
  pick_targets "КУДА" || return 0
  echo
  for t in "${TARGETS[@]}"; do
    info "$(target_name "$t")..."
    out=$(run_on "$t" "$(geo_script "$src")" 2>&1)
    if grep -q '^RESULT OK' <<< "$out"; then green "  ✔ $(grep '^RESULT OK' <<< "$out" | cut -d' ' -f3-)"
    else red "  ✖ $(grep '^RESULT' <<< "$out" | cut -d' ' -f3- || true)"; tail -3 <<< "$out" | sed 's/^/    /'; fi
  done
  jlog INFO "geo ($src): ${TARGETS[*]%%|*}"
  echo
  if [[ " ${TARGETS[*]} " == *" local "* ]]; then
    ask "Обновлять автоматически раз в неделю на этом сервере? [y/N]"; read -r c
    if [[ "$c" =~ ^[Yy]$ ]]; then
      geo_cron_line "$src" > /etc/cron.d/remnapilot-geo; green "✔ Каждый понедельник в 04:17"
    fi
  fi
  echo "  Новые теги (например geosite:ru-blocked) используй в правилах маршрутизации профиля в панели."
}

# ---------- swap ----------
swap_status_box() {
  local mt mu st su
  read -r mt mu < <(free -m | awk '/^Mem:/{print $2, $3}')
  read -r st su < <(free -m | awk '/^Swap:/{print $2, $3}')
  box_top
  box_line "${C_MUT}$(padr "RAM" 11)${C0}${mu} / ${mt} МБ"
  if (( st > 0 )); then box_line "${C_MUT}$(padr "Swap" 11)${C0}$(dot ok) ${su} / ${st} МБ"
  else box_line "${C_MUT}$(padr "Swap" 11)${C0}$( (( mt < 2048 )) && echo "$(dot warn) ${C_WARN}нет — при 1–2 ГБ RAM рекомендуется${C0}" || echo "$(dot off) нет")"; fi
  box_line "${C_MUT}$(padr "swappiness" 11)${C0}$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  box_bottom
}

swap_create() {
  local mt sz free_mb ans virt
  virt=$(systemd-detect-virt 2>/dev/null)
  if [[ "$virt" =~ ^(openvz|lxc|lxc-libvirt)$ ]]; then red "✖ Это контейнер ($virt) — своп здесь создать нельзя, его выдаёт хостер."; return 1; fi
  mt=$(free -m | awk '/^Mem:/{print $2}')
  if   (( mt <= 1024 )); then sz=2048
  elif (( mt <= 2048 )); then sz=2048
  elif (( mt <= 4096 )); then sz=1024
  else sz=1024; fi
  ask "Размер swap в МБ [$sz]"; read -r ans; [[ "$ans" =~ ^[0-9]+$ ]] && sz="$ans"
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  (( free_mb > sz + 1024 )) || { red "✖ Мало места на диске: свободно ${free_mb} МБ"; return 1; }
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx /swapfile; then
    swapoff /swapfile && rm -f /swapfile
  fi
  info "Создаю /swapfile на $sz МБ..."
  fallocate -l "${sz}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$sz" status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null
  if ! swapon /swapfile 2>/dev/null; then
    rm -f /swapfile; dd if=/dev/zero of=/swapfile bs=1M count="$sz" status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile || { red "✖ Не удалось включить swap"; rm -f /swapfile; return 1; }
  fi
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  printf 'vm.swappiness = 10\nvm.vfs_cache_pressure = 50\n' > /etc/sysctl.d/98-remnapilot-swap.conf
  sysctl -p /etc/sysctl.d/98-remnapilot-swap.conf >/dev/null 2>&1
  green "✔ Swap $sz МБ включён и переживёт перезагрузку (swappiness 10 — используется только при нехватке RAM)"
  jlog INFO "Swap: $sz МБ"
}

swap_remove() {
  swapoff /swapfile 2>/dev/null; rm -f /swapfile /etc/sysctl.d/98-remnapilot-swap.conf
  sed -i '\#^/swapfile #d' /etc/fstab
  yel "Swap удалён."; jlog INFO "Swap удалён"
}

swap_menu() {
  local c
  while true; do
    screen "Swap"; echo
    swap_status_box
    section "ДЕЙСТВИЯ"
    item 1 "Создать / изменить swap"
    item 2 "Удалить swap"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Swap: создание" swap_create; pause ;;
      2) run_action "Swap: удаление" swap_remove; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- статус всех нод ----------
NODE_STAT_SCRIPT='
st=$(docker ps -a --filter name=^remnanode$ --format "{{.Status}}" 2>/dev/null)
v=$(docker inspect --format "{{index .Config.Labels \"org.opencontainers.image.version\"}}" remnanode 2>/dev/null)
echo "ST=$st"; echo "VER=$v"
echo "LOAD=$(cut -d" " -f1 /proc/loadavg)"; echo "CPUS=$(nproc)"
free -m | awk "/^Mem:/{print \"MEM=\" \$3 \"/\" \$2}"
df -P / | awk "NR==2{print \"DISK=\" \$5}"
echo "UP=$(awk "{d=int(\$1/86400); h=int(\$1%86400/3600); print (d? d \"d \" : \"\") h \"h\"}" /proc/uptime)"
'

nodes_status() {
  local lines=() tmp i nm h p f st ver load cpus mem disk up d col
  [[ -s "$NODES_FILE" ]] && mapfile -t lines < "$NODES_FILE"
  node_dir >/dev/null 2>&1 && lines=("$(hostname)|local|-" "${lines[@]}")
  (( ${#lines[@]} )) || { yel "Нод нет (пункт 13 → «Добавить ноду в список»)."; return 0; }
  tmp=$(mktemp -d)
  info "Опрашиваю ${#lines[@]} нод..."
  local pids=()
  for i in "${!lines[@]}"; do
    if [[ "${lines[$i]}" == *"|local|"* ]]; then bash -c "$NODE_STAT_SCRIPT" > "$tmp/$i" 2>/dev/null </dev/null &
    else
      read -r nm h p <<< "${lines[$i]}"
      timeout 25 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -p "$p" "$h" "$NODE_STAT_SCRIPT" > "$tmp/$i" 2>"$tmp/$i.err" </dev/null &
    fi
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
  printf '\e[1A\e[2K'
  for i in "${!lines[@]}"; do
    if [[ "${lines[$i]}" == *"|local|"* ]]; then nm="${lines[$i]%%|*} (здесь)"; h=""
    else read -r nm h p <<< "${lines[$i]}"; fi
    f="$tmp/$i"; st=""; ver=""; load=""; cpus=""; mem=""; disk=""; up=""
    if [[ -s "$f" ]]; then
      local k v
      while IFS='=' read -r k v; do
        case "$k" in ST) st="$v" ;; VER) ver="$v" ;; LOAD) load="$v" ;; CPUS) cpus="$v" ;; MEM) mem="$v" ;; DISK) disk="$v" ;; UP) up="$v" ;; esac
      done < "$f"
      [[ "$disk" =~ ^[0-9]+%$ ]] || disk=""
      ver="${ver//[^0-9A-Za-z.-]/}"; load="${load//[^0-9.]/}"; cpus="${cpus//[^0-9]/}"; mem="${mem//[^0-9\/]/}"
      st="${st//[^[:print:]]/}"; up="${up//[^0-9dh ]/}"
    fi
    echo
    if [[ ! -s "$f" ]]; then
      if grep -qiE 'denied|permission' "$tmp/$i.err" 2>/dev/null; then printf '  %s %s%s%s  %sнет SSH-ключа — пункт 13 → 7%s\n' "$(dot err)" "$CB" "$nm" "$C0" "$C_ERR" "$C0"
      else printf '  %s %s%s%s  %sнедоступна%s\n' "$(dot err)" "$CB" "$nm" "$C0" "$C_ERR" "$C0"; fi
      continue
    fi
    case "$st" in Up*unhealthy*|Restarting*) d=warn ;; Up*) d=ok ;; "") d=err; st="нода не установлена" ;; *) d=err ;; esac
    printf '  %s %s%s%s  %sv%s%s  %s%s%s\n' "$(dot $d)" "$CB" "$nm" "$C0" "$C_ACC" "${ver:-?}" "$C0" "$C_MUT" "$st" "$C0"
    col="$C0"; [[ -n "$disk" ]] && (( ${disk%\%} >= 85 )) && col="$C_WARN"
    printf '     %sCPU%s %s/%s  %sRAM%s %s МБ  %sДиск%s %s%s%s  %sаптайм%s %s\n' \
      "$C_MUT" "$C0" "$load" "$cpus" "$C_MUT" "$C0" "$mem" "$C_MUT" "$C0" "$col" "$disk" "$C0" "$C_MUT" "$C0" "$up"
  done
  rm -rf "$tmp"
}

# ---------- проверка IP ----------
ch_api() { curl -fsS --max-time 15 -H 'Accept: application/json' "https://check-host.net/$1" 2>/dev/null; }

ip_check() {
  local ip port info rid res nodes=() n json
  ip=$(curl -4 -s --max-time 6 https://ifconfig.me)
  [[ -n "$ip" ]] || { red "✖ Не удалось узнать внешний IP"; return 1; }
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

# ---------- WARP ----------
warp_script_install() {
  cat <<'EOF'
set -e
. /etc/os-release
command -v apt-get >/dev/null || { echo "RESULT FAIL нужен Debian/Ubuntu"; exit 1; }
if ! command -v warp-cli >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y gnupg curl >/dev/null 2>&1 || true
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update >/dev/null 2>&1 && apt-get install -y cloudflare-warp >/dev/null 2>&1 || { echo "RESULT FAIL не установился cloudflare-warp (нет пакета для ${VERSION_CODENAME}?)"; exit 1; }
fi
systemctl enable --now warp-svc >/dev/null 2>&1 || true; sleep 2
w() { warp-cli --accept-tos "$@" >/dev/null 2>&1; }
w registration new || w register || true
w mode proxy || w set-mode proxy || true
w proxy port 40000 || w set-proxy-port 40000 || true
w connect || true
sleep 5
r=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^warp=' | cut -d= -f2)
[ "$r" = on ] || [ "$r" = plus ] && echo "RESULT OK warp=$r, SOCKS5 127.0.0.1:40000" || echo "RESULT FAIL WARP не подключился (warp=$r)"
EOF
}

warp_script_status() {
  cat <<'EOF'
if ! command -v warp-cli >/dev/null; then echo "RESULT OFF не установлен"; exit 0; fi
r=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(warp|ip|colo)=' | tr '\n' ' ')
case "$r" in *warp=on*|*warp=plus*) echo "RESULT OK $r" ;; *) echo "RESULT FAIL установлен, но не работает" ;; esac
EOF
}

warp_script_remove() {
  cat <<'EOF'
warp-cli --accept-tos disconnect >/dev/null 2>&1
apt-get remove -y cloudflare-warp >/dev/null 2>&1
rm -f /etc/apt/sources.list.d/cloudflare-client.list
echo "RESULT OK удалён"
EOF
}

warp_snippet() {
  section "ДОБАВЬ В ПРОФИЛЬ КОНФИГА В ПАНЕЛИ"
  echo "  Панель → Config Profiles → профиль ноды → в \"outbounds\":"
  printf '%s\n' '    { "tag": "WARP", "protocol": "socks",' \
                '      "settings": { "servers": [ { "address": "127.0.0.1", "port": 40000 } ] } }'
  echo "  и в \"routing\" → \"rules\" (выше остальных):"
  printf '%s\n' '    { "type": "field", "outboundTag": "WARP",' \
                '      "domain": [ "geosite:openai", "geosite:google-gemini", "geosite:netflix",' \
                '                  "geosite:spotify", "domain:chatgpt.com", "domain:claude.ai" ] }'
  echo "  Список доменов меняй под себя. Остальной трафик пойдёт как раньше — напрямую."
}

warp_run() { # install|status|remove
  local t out
  pick_targets "НА КАКОЙ НОДЕ" || return 0
  echo
  for t in "${TARGETS[@]}"; do
    info "$(target_name "$t")..."
    out=$(run_on "$t" "$("warp_script_$1")" 2>&1)
    case "$(grep -m1 '^RESULT' <<< "$out" | cut -d' ' -f2)" in
      OK)  green "  ✔ $(grep -m1 '^RESULT' <<< "$out" | cut -d' ' -f3-)" ;;
      OFF) echo "  ○ $(grep -m1 '^RESULT' <<< "$out" | cut -d' ' -f3-)" ;;
      *)   red "  ✖ $(grep -m1 '^RESULT' <<< "$out" | cut -d' ' -f3-)"; grep -v '^RESULT' <<< "$out" | tail -3 | sed 's/^/    /' ;;
    esac
  done
  jlog INFO "WARP $1: ${TARGETS[*]%%|*}"
  [[ "$1" == install ]] && { echo; warp_snippet; }
}

warp_menu() {
  local c
  while true; do
    screen "WARP на ноде"; echo
    echo "  WARP — выход в интернет через Cloudflare. Сайты, которые блокируют IP"
    echo "  хостеров (ChatGPT, Gemini, Netflix…), откроются. Ставится как SOCKS5-прокси"
    echo "  127.0.0.1:40000, трафик туда направляют правила маршрутизации в панели."
    section "ДЕЙСТВИЯ"
    item 1 "Установить WARP"
    item 2 "Проверить WARP"
    item 3 "Показать настройки для панели"
    item 4 "Удалить WARP"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "WARP: установка" warp_run install; pause ;;
      2) warp_run status; pause ;;
      3) warp_snippet; pause ;;
      4) run_action "WARP: удаление" warp_run remove; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- время и часовой пояс ----------
time_offset() { # расхождение часов сервера с эталоном (сек)
  local hd
  hd=$(curl -sI --max-time 6 https://www.cloudflare.com | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
  [[ -n "$hd" ]] && echo $(( $(date +%s) - $(date -d "$hd" +%s) ))
}

time_status_box() {
  local tz sync off
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  off=$(time_offset)
  box_top
  box_line "${C_MUT}$(padr "Время" 11)${C0}$(date '+%d.%m.%Y %H:%M:%S')"
  box_line "${C_MUT}$(padr "Пояс" 11)${C0}${tz:-?}"
  box_line "${C_MUT}$(padr "NTP" 11)${C0}$( [[ "$sync" == yes ]] && echo "$(dot ok) синхронизировано" || echo "$(dot warn) ${C_WARN}не синхронизировано${C0}")"
  if [[ -n "$off" ]]; then
    local a=${off#-}
    box_line "${C_MUT}$(padr "Расхождение" 11)${C0}$( (( a <= 2 )) && echo "$(dot ok) ${off} с" || echo "$(dot err) ${C_ERR}${off} с — Xray/Reality может не работать${C0}")"
  fi
  box_bottom
}

time_sync_script() {
  cat <<'EOF'
if command -v timedatectl >/dev/null; then
  timedatectl set-ntp true 2>/dev/null
  if ! systemctl is-active systemd-timesyncd >/dev/null 2>&1 && ! systemctl is-active chronyd >/dev/null 2>&1 && ! systemctl is-active chrony >/dev/null 2>&1; then
    (apt-get install -y systemd-timesyncd || apt-get install -y chrony || dnf install -y chrony) >/dev/null 2>&1
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || systemctl enable --now chrony >/dev/null 2>&1
    timedatectl set-ntp true 2>/dev/null
  fi
fi
[ -n "$TZ_SET" ] && timedatectl set-timezone "$TZ_SET" 2>/dev/null
sleep 3
echo "RESULT OK $(timedatectl show -p Timezone --value 2>/dev/null), NTP: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
EOF
}

time_set_tz() {
  local c tz
  section "ЧАСОВОЙ ПОЯС"
  item 1 "UTC" "рекомендуется для серверов"
  item 2 "Europe/Moscow"
  item 3 "Asia/Yekaterinburg"
  item 4 "Europe/Berlin"
  item 5 "Ввести вручную" "например Asia/Novosibirsk"
  hr; item 0 "Отмена"
  ask; read -r c
  case "$c" in 1) tz=UTC ;; 2) tz=Europe/Moscow ;; 3) tz=Asia/Yekaterinburg ;; 4) tz=Europe/Berlin ;;
    5) ask "Часовой пояс"; read -r tz ;; *) return 0 ;; esac
  timedatectl list-timezones 2>/dev/null | grep -qx "$tz" || [[ "$tz" == UTC ]] || { err "нет такого пояса: $tz"; return 1; }
  timedatectl set-timezone "$tz" && green "✔ Часовой пояс: $tz" && jlog INFO "Часовой пояс: $tz"
}

time_sync_local() {
  local out; out=$(TZ_SET="" bash -c "$(time_sync_script)" 2>&1)
  green "✔ ${out#RESULT OK }"
  jlog INFO "Синхронизация времени включена"
}

time_sync_nodes() {
  local lines=() l nm h p out
  [[ -s "$NODES_FILE" ]] || { yel "Список нод пуст."; return 0; }
  mapfile -t lines < "$NODES_FILE"
  for l in "${lines[@]}"; do
    read -r nm h p <<< "$l"
    out=$(run_on "$nm|$h|$p" "$(time_sync_script)" 2>&1 </dev/null)
    grep -q '^RESULT OK' <<< "$out" && green "  ✔ $nm: $(grep '^RESULT OK' <<< "$out" | cut -d' ' -f3-)" || red "  ✖ $nm: недоступна"
  done
}

time_menu() {
  local c
  while true; do
    screen "Время и часовой пояс"; echo
    time_status_box
    section "ДЕЙСТВИЯ"
    item 1 "Включить синхронизацию времени" "NTP"
    item 2 "Сменить часовой пояс"
    item 3 "Синхронизировать время на всех нодах"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Время: NTP" time_sync_local; pause ;;
      2) run_action "Время: часовой пояс" time_set_tz; pause ;;
      3) run_action "Время: ноды" time_sync_nodes; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- версия ----------
RP_CHANGELOG=(
  "1.8.1|Официальный репозиторий github.com/Dubstep2004/RemnaPilot — установка одной командой и обновления из коробки"
  "1.8|Обновление RemnaPilot с GitHub: репозиторий указывается в меню, в файл не вшит"
  "1.8|Подсказка в главном меню, когда вышла новая версия RemnaPilot"
  "1.7.1|Без привязки к ссылке: запуск из файла, обновление RemnaPilot из загруженного файла"
  "1.7|Удаление старых доменов и алиасов: из конфигов, сертификатов и автопродления"
  "1.7|Исправлено: старый заказ acme.sh после смены домена мог при продлении затереть новый сертификат"
  "1.6.1|Английский режим: «Статус всех нод» больше не зависает навсегда"
  "1.6.1|Смена языка и самообновление больше не теряют цвета и не переводят вывод дважды"
  "1.6.1|Флаги без значения (--dir, --old…) больше не вешают скрипт"
  "1.6.1|Статус нод: данные с ноды не выполняются как код (безопасность)"
  "1.6.1|Firewall: пустой IP панели больше не закрывает порт ноды для всех"
  "1.6.1|SSH: при отмене смены порта новый порт закрывается в firewall"
  "1.6.1|Перенос: живые файлы БД не копируются, старая панель не оживает после перезагрузки"
  "1.6.1|Swap на xfs/btrfs, geo при compose.yaml, WARP без обрыва установки, cron geo без команды rw"
  "1.6.1|Очистка: верный размер логов Docker, daemon.json не перезаписывается"
  "1.6.1|Английский: «О программе» переводится полностью, исправлен символ & в переводах"
  "1.6|Статус всех нод на одном экране: CPU, RAM, диск, версия, аптайм"
  "1.6|Обновление geoip/geosite на нодах (Loyalsoldier или runetfreedom), автообновление раз в неделю"
  "1.6|WARP на ноде: SOCKS5 через Cloudflare + готовые настройки для профиля в панели"
  "1.6|Swap для VPS с маленькой памятью"
  "1.6|Время: синхронизация NTP, часовой пояс, проверка расхождения часов"
  "1.6|Проверка IP: доступность из РФ (check-host.net), пинг, скорость"
  "1.6|Подбор SNI для Reality: проверка TLS 1.3, H2, X25519, пинга и поиск соседей в подсети"
  "1.5|Firewall одной кнопкой: SSH, 80, 443, порты Xray, порт ноды только с IP панели"
  "1.5|Защита SSH: смена порта с проверкой, fail2ban, вход только по ключу"
  "1.5|Ускорение сети: BBR и тюнинг TCP"
  "1.5|Очистка диска и ограничение роста логов (Docker, journald, logrotate для ноды)"
  "1.5|Перенос панели на другой сервер одним сценарием"
  "1.5|Журнал действий: что, когда и с каким результатом"
  "1.5|Английский язык интерфейса"
  "1.4|Смена доменов панели и подписки в одном пункте: один бэкап, один перезапуск, сертификаты сразу на оба"
  "1.3|Сертификаты: если способ не сработал — сразу предлагает другой (порт 80, 443, DNS Cloudflare, DNS вручную)"
  "1.3|Сертификаты: понятная причина ошибки — порт закрыт у хостера, прокси Cloudflare, DNS, лимит Let's Encrypt"
  "1.3|Сертификаты: выпуск через DNS вручную (TXT-запись у любого регистратора) с проверкой записи"
  "1.2.1|Смена домена панели не пугает «старые ссылки подписки перестанут работать», если подписка на своём домене"
  "1.2|Установка одной командой: curl -sSL …/remnapilot.sh | bash"
  "1.2|Раздел «Обновления»: панель, страница подписки, нода здесь и ноды по SSH — с версиями «было → стало»"
  "1.2|«Обновить всё» одной кнопкой: бэкап базы → панель → ноды"
  "1.2|Откат последнего обновления: старые образы + база из бэкапа"
  "1.2|Закрепление версии панели (или возврат на latest)"
  "1.2|Самообновление RemnaPilot с GitHub"
  "1.1|Исправлен вылет на необъявленных переменных (set -u)"
  "1.1|Скрипт запускается на чистом сервере без docker — для установки ноды"
  "1.1|Сертификаты: Let's Encrypt по умолчанию (ZeroSSL просил e-mail и не работал с .ru/.рф)"
  "1.1|Сертификаты: автоустановка acme.sh и socat"
  "1.1|Сертификаты: хуки продления свои для каждого домена — второй сертификат больше не ломает первый"
  "1.1|Смена домена панели больше не сбрасывает свой путь подписки на /api/sub"
  "1.1|Смена домена не трогает копии .env в папке backups"
  "1.1|Traefik: алиас старого домена подписки с правильными скобками"
  "1.1|Поддержка доменов в зоне .рф (punycode) и доменов с заглавными буквами"
  "1.1|Остановка контейнеров в правильном порядке: сначала прокси, потом панель"
  "1.1|Проверка открытых портов сообщает, если строку в compose не удалось исправить"
  "1.1|Мелочи: --help, проверка номера при удалении ноды, статус SSL без ложного «истёк»"
  "1.1|Новый раздел «О программе и версии»"
  "1.0|Меню, смена домена панели и подписки, сертификаты, бэкап/восстановление БД"
  "1.0|Безопасность, логи, установка и массовое обновление нод, команда rw"
)

gh_latest() { # $1 = docker-образ (remnawave/backend) -> последняя версия: GitHub, затем Docker Hub
  local v r
  case "$1" in remnawave/backend) r="remnawave/panel remnawave/backend" ;; *) r="$1" ;; esac
  for x in $r; do
    v=$(curl -fsS --max-time 6 "https://api.github.com/repos/$x/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[^"]*"v?([^"]+)".*/\1/')
    [[ -n "$v" ]] && { echo "$v"; return; }
  done
  curl -fsS --max-time 6 "https://hub.docker.com/v2/repositories/$1/tags?page_size=50&ordering=last_updated" 2>/dev/null \
    | grep -oE '"name": ?"v?[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1
}

ver_line() { # метка, установленная, последняя
  local cur="${2:-}" last="${3:-}" st
  if   [[ -z "$cur" ]];  then st="$(dot off) ${C_MUT}не установлено${C0}"
  elif [[ -z "$last" ]]; then st="$(dot off) ${C_MUT}v$cur · нет связи с GitHub${C0}"
  elif [[ "$cur" == "$last" ]]; then st="$(dot ok) v$cur ${C_OK}актуальная${C0}"
  elif [[ "$(printf '%s\n%s\n' "$cur" "$last" | sort -V | tail -1)" == "$last" ]]; then
       st="$(dot warn) v$cur ${C_WARN}→ доступна v$last${C0}"
  else st="$(dot ok) v$cur ${C_MUT}(новее релиза v$last)${C0}"; fi
  box_line "${C_MUT}$(padr "$1" 11)${C0}$st"
}

about_screen() {
  local pv nv dv cv app last_v
  info "Проверяю версии..."
  app=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$2 ~ /remnawave\/backend|remnawave\/panel/ {print $1; exit}')
  [[ -n "$app" ]] && pv=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$app" 2>/dev/null)
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && \
    nv=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' remnanode 2>/dev/null)
  dv=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  cv=$(docker compose version --short 2>/dev/null)

  screen "О программе и версии"; echo
  box_top
  box_line "${CB}${RP_NAME}${C0} ${C_ACC}v${RP_VERSION}${C0}  ${C_MUT}пульт управления Remnawave${C0}"
  box_line ""
  ver_line "Панель" "${pv#v}" "$( [[ -n "$app" ]] && gh_latest remnawave/backend )"
  ver_line "Нода"   "${nv#v}" "$( [[ -n "$nv" ]] && gh_latest remnawave/node )"
  box_line "${C_MUT}$(padr "Docker" 11)${C0}${dv:-—}${cv:+  ${C_MUT}compose $cv${C0}}"
  box_line "${C_MUT}$(padr "Bash" 11)${C0}${BASH_VERSION%%(*}"
  local fp; fp=$(readlink -f "$0" 2>/dev/null); (( ${#fp} > W - 17 )) && fp="…${fp: -$((W-18))}"
  box_line "${C_MUT}$(padr "Файл" 11)${C0}$fp"
  box_bottom

  local v="" line
  for line in "${RP_CHANGELOG[@]}"; do
    if [[ "${line%%|*}" != "$v" ]]; then v="${line%%|*}"; section "ЧТО НОВОГО В v$v"; fi
    wrap "$(T "${line#*|}")" $((W - 7)) | {
      read -r l1; printf '   %s•%s %s\n' "$C_ACC" "$C0" "$l1"
      while read -r l; do printf '     %s\n' "$l"; done; }
  done
  echo
  echo "  Обновить панель, ноды и сам RemnaPilot — пункт 6 «Обновления»."
}

# ---------- команда rw ----------
install_cmd() {
  local src; src=$(readlink -f "$0")
  if [[ ! -f "$src" || "$src" == /proc/* || "$src" == /dev/* ]]; then
    local t; t=$(mktemp)
    if rp_fetch_latest "$t" && install -m 755 "$t" /usr/local/bin/rw; then rm -f "$t"; green "✔ Готово: теперь можно просто набрать  rw"; return 0; fi
    rm -f "$t"; red "Не удалось скачать RemnaPilot — сохрани скрипт в файл и запусти его оттуда."; return 1
  fi
  [[ "$src" == /usr/local/bin/rw ]] && { green "Команда rw уже установлена."; return 0; }
  install -m 755 "$src" /usr/local/bin/rw && green "✓ Готово: теперь можно просто набрать  rw"
}

offer_cmd() {
  local src; src=$(readlink -f "$0")
  [[ "$src" == /usr/local/bin/rw || -f "$HOME/.rw-nocmd" ]] && return
  if [[ ! -f /usr/local/bin/rw ]]; then
    read -rp "Установить короткую команду  rw  для запуска скрипта? [Y/n] " a
    [[ "$a" =~ ^[Nn]$ ]] && touch "$HOME/.rw-nocmd" || install_cmd
  elif ! cmp -s "$src" /usr/local/bin/rw; then
    read -rp "Команда rw установлена из другой версии скрипта. Обновить её этой? [Y/n] " a
    [[ "$a" =~ ^[Nn]$ ]] || install_cmd
  fi
}

need_panel() {
  [[ -f "$RW_DIR/.env" ]] || { red "✖ Панель не найдена ($RW_DIR/.env). Пункт 29 — указать другой каталог."; return 1; }
  command -v docker >/dev/null || { red "✖ Не установлен docker"; return 1; }
  command -v perl   >/dev/null || { red "✖ Не установлен perl (apt install perl)"; return 1; }
}

UPD_LOG="" # файл с записью последнего обновления (для отката)

local_ver() { # контейнер -> версия из метки образа
  docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null | sed 's/^v//'
}

compose_of() { # каталог -> путь к compose-файлу
  local c; for c in "$1"/docker-compose.yml "$1"/docker-compose.yaml "$1"/compose.yml "$1"/compose.yaml; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }; done; return 1
}

node_dir() { local d; for d in /opt/remnanode /opt/remnawave-node; do [[ -d "$d" ]] && compose_of "$d" >/dev/null && { echo "$d"; return 0; }; done; return 1; }

snapshot_images() { # каталог: запомнить текущие образы как <repo>:rp-prev, чтобы можно было откатиться
  local c id ref img repo; c=$(compose_of "$1") || return 0
  for id in $(cd "$1" && docker compose -f "$c" ps -q 2>/dev/null); do
    ref=$(docker inspect -f '{{.Config.Image}}' "$id"); img=$(docker inspect -f '{{.Image}}' "$id")
    [[ "$ref" == *remnawave* ]] || continue          # откатываем только образы Remnawave
    repo="${ref%:*}"; [[ "$ref" == *:* && "${ref##*:}" != */* ]] || repo="$ref"
    docker tag "$img" "$repo:rp-prev" && echo "IMG $1|$ref|$repo:rp-prev|$(local_ver "$id")" >> "$UPD_LOG"
  done
}

pull_up() { # каталог: скачать образы и пересоздать
  local c; c=$(compose_of "$1") || return 1
  info "Обновляю $1"
  (cd "$1" && docker compose -f "$c" pull && docker compose -f "$c" up -d --remove-orphans)
}

wait_healthy() { # контейнер, секунд -> 0 если запущен и не unhealthy
  local i st
  for ((i=0; i<$2; i+=3)); do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null)
    case "$st" in "running healthy") return 0 ;; "running ") (( i >= 6 )) && return 0 ;; *unhealthy*|exited*|dead*) return 1 ;; esac
    sleep 3
  done
  [[ "$st" == running* ]]
}

new_upd_log() {
  local d="/opt/remnanode/backups"; [[ -f "$RW_DIR/.env" ]] && d="$RW_DIR/backups"
  mkdir -p "$d"; UPD_LOG="$d/update-$(date +%Y%m%d-%H%M%S).log"; : > "$UPD_LOG"
}

update_panel() { # $1=1 — не задавать вопросов (для «обновить всё»)
  local quiet="${1:-0}" ans c d dirs=() app before after
  need_panel || return 1
  app=$(app_containers | head -1); before=$(local_ver "$app")
  [[ -n "$UPD_LOG" ]] || new_upd_log

  if (( quiet )); then backup_db pre-update && echo "DUMP $(ls -1t "$RW_DIR"/backups/db-*-pre-update.sql.gz | head -1)" >> "$UPD_LOG"
  else
    ask "Сделать бэкап базы перед обновлением? [Y/n]"; read -r ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      if backup_db pre-update; then echo "DUMP $(ls -1t "$RW_DIR"/backups/db-*-pre-update.sql.gz | head -1)" >> "$UPD_LOG"
      else ask "Бэкап не удался. Продолжить без него? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0; fi
    fi
  fi

  dirs+=("$RW_DIR")
  while read -r c; do d=$(dirname "$c"); [[ "$d" != "$RW_DIR" ]] && dirs+=("$d"); done < <(find_composes)
  for d in "${dirs[@]}"; do snapshot_images "$d"; done
  for d in "${dirs[@]}"; do pull_up "$d" || { red "✖ Ошибка при обновлении $d"; yel "Откат: раздел «Обновления» → «Откатить последнее обновление»"; return 1; }; done
  docker image prune -f >/dev/null

  info "Жду запуска панели..."
  if wait_healthy "$app" 90; then
    after=$(local_ver "$app")
    if [[ "$before" == "$after" ]]; then green "✔ Панель уже на последней версии v${after:-?}"
    else green "✔ Панель обновлена: v${before:-?} → v${after:-?}"; fi
  else
    red "✖ Панель не поднялась после обновления. Последние логи:"
    docker logs --tail 25 "$app" 2>&1 | sed 's/^/    /'
    yel "Откатить: «Обновления» → «Откатить последнее обновление» (вернёт образы и при желании базу)."
    return 1
  fi
}

update_local_node() {
  local d before after
  d=$(node_dir) || { echo "  Ноды на этом сервере нет."; return 0; }
  command -v docker >/dev/null || { red "✖ docker не установлен"; return 1; }
  [[ -n "$UPD_LOG" ]] || new_upd_log
  before=$(local_ver remnanode)
  snapshot_images "$d"
  pull_up "$d" || { red "✖ Ошибка обновления ноды"; return 1; }
  docker image prune -f >/dev/null
  if wait_healthy remnanode 45; then
    after=$(local_ver remnanode)
    [[ "$before" == "$after" ]] && green "✔ Нода уже на последней версии v${after:-?}" || green "✔ Нода обновлена: v${before:-?} → v${after:-?}"
  else
    red "✖ Нода не запустилась:"; docker logs --tail 20 remnanode 2>&1 | sed 's/^/    /'; return 1
  fi
}

update_all() {
  local ans
  section "ПЛАН"
  [[ -f "$RW_DIR/.env" ]] && echo "   • панель (+ бэкап базы перед обновлением)"
  node_dir >/dev/null && echo "   • нода на этом сервере"
  [[ -s "$NODES_FILE" ]] && echo "   • ноды по SSH: $(wc -l < "$NODES_FILE")"
  ask "Начать? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0
  new_upd_log
  [[ -f "$RW_DIR/.env" ]] && { section "ПАНЕЛЬ"; update_panel 1 || { yel "Панель не обновилась — ноды не трогаю."; return 1; }; }
  node_dir >/dev/null && { section "НОДА ЗДЕСЬ"; update_local_node; }
  [[ -s "$NODES_FILE" ]] && { section "НОДЫ ПО SSH"; NODES_ALL=1 nodes_update; }
  echo; green "✔ Готово"
}

rollback_update() {
  local logs=() i n f line dump ans d dirs=""
  mapfile -t logs < <(ls -1t "$RW_DIR"/backups/update-*.log /opt/remnanode/backups/update-*.log 2>/dev/null)
  (( ${#logs[@]} )) || { yel "Записей об обновлениях нет — откатывать нечего."; return 0; }
  f="${logs[0]}"
  section "ПОСЛЕДНЕЕ ОБНОВЛЕНИЕ  $(date -r "$f" '+%d.%m %H:%M')"
  while IFS='|' read -r d ref prev ver; do
    printf '   %s → вернуть %s%s%s\n' "$ref" "$C_ACC" "${ver:+v$ver}" "$C0"
  done < <(sed -n 's/^IMG //p' "$f")
  dump=$(sed -n 's/^DUMP //p' "$f" | head -1)
  [[ -n "$dump" ]] && echo "   база: $(basename "$dump")"
  ask "Откатить образы? [y/N]"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || return 0

  while IFS='|' read -r d ref prev ver; do
    docker image inspect "$prev" >/dev/null 2>&1 || { yel "  ⚠ нет образа $prev — пропускаю"; continue; }
    docker tag "$prev" "$ref" && [[ " $dirs " != *" $d "* ]] && dirs+=" $d"
  done < <(sed -n 's/^IMG //p' "$f")
  for d in $dirs; do (cd "$d" && docker compose -f "$(compose_of "$d")" up -d); done
  green "✔ Образы возвращены"

  if [[ -n "$dump" && -f "$dump" ]]; then
    yel "Если новая версия успела изменить базу, старая панель может не запуститься без отката базы."
    ask "Восстановить и базу из $(basename "$dump")? [y/N]"; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] && RESTORE_FILE="$dump" restore_db
  fi
}

pin_panel_version() {
  local c last v cur ans
  need_panel || return 1
  c=$(compose_of "$RW_DIR") || { red "✖ docker-compose не найден"; return 1; }
  cur=$(grep -oE 'image:[[:space:]]*["'"'"']?remnawave/backend:[^"'"'"'[:space:]]+' "$c" | head -1 | sed -E 's/.*://')
  last=$(gh_latest remnawave/backend)
  info "Сейчас в compose: remnawave/backend:${cur:-?}   последняя: ${last:-?}"
  echo "   Введи версию (например ${last:-2.2.4}), «latest» — всегда последняя, «2» — последняя 2.x"
  ask "Версия"; read -r v; v="${v#v}"
  [[ "$v" =~ ^(latest|dev|[0-9]+(\.[0-9]+){0,2})$ ]] || { err "некорректная версия"; return 1; }
  cp -a "$c" "$c.bak-$(date +%Y%m%d-%H%M%S)"
  V="$v" perl -pi -e 's/(image:\s*["\x27]?remnawave\/backend:)[^"\x27\s]+/${1}$ENV{V}/' "$c"
  green "✔ В compose: remnawave/backend:$v"
  ask "Скачать и перезапустить панель сейчас? [Y/n]"; read -r ans
  [[ "$ans" =~ ^[Nn]$ ]] || update_panel
}

# ----- обновление с GitHub (репозиторий задаётся в меню, в файл не вшит) -----
RP_SRC_FILE="/etc/rw/update_source"

rp_source() { local v; v=$(head -1 "$RP_SRC_FILE" 2>/dev/null | tr -d ' \r'); echo "${v:-$RP_DEFAULT_SOURCE}"; }

rp_source_urls() { # owner/repo → ссылки на последний релиз и на ветку main; полная ссылка → как есть
  local v; v=$(rp_source)
  [[ -n "$v" ]] || return 1
  if [[ "$v" == https://* ]]; then echo "$v"; return 0; fi
  v="${v#github.com/}"; v="${v%.git}"; v="${v%/}"
  echo "https://github.com/$v/releases/latest/download/remnapilot.sh"
  echo "https://raw.githubusercontent.com/$v/main/remnapilot.sh"
}

rp_fetch_latest() { # $1 = куда сохранить → 0, если скачан настоящий RemnaPilot
  local u
  while read -r u; do
    curl -fsSL --max-time 20 -o "$1" "$u" 2>/dev/null || continue
    bash -n "$1" 2>/dev/null && grep -q 'RP_NAME="RemnaPilot"' "$1" && return 0
  done < <(rp_source_urls)
  return 1
}

rp_remote_version() { # версия на GitHub (кэш на 6 часов, чтобы меню не тормозило)
  local cache=/etc/rw/.latest_version t
  [[ -n "$(rp_source)" ]] || return 1
  if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache") < 21600 )); then cat "$cache"; return 0; fi
  t=$(mktemp); rp_fetch_latest "$t" && grep -m1 '^RP_VERSION=' "$t" | cut -d'"' -f2 | tee "$cache" 2>/dev/null; rm -f "$t"
}

rp_set_source() {
  local v cur; cur=$(rp_source)
  echo "  Укажи репозиторий на GitHub, где лежит remnapilot.sh:"
  echo "   • owner/repo — например  user/remnapilot"
  echo "     (берётся файл из последнего релиза, иначе из ветки main)"
  echo "   • или прямая ссылка https://… на файл"
  ask "Репозиторий${cur:+ [$cur]}"; read -r v; v="${v:-$cur}"
  [[ -z "$v" ]] && return 0
  [[ "$v" =~ ^https:// || "$v" =~ ^(github\.com/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { err "непохоже на owner/repo или ссылку"; return 1; }
  mkdir -p /etc/rw; echo "$v" > "$RP_SRC_FILE"; rm -f /etc/rw/.latest_version
  info "Проверяю..."
  local t; t=$(mktemp)
  if rp_fetch_latest "$t"; then green "✔ Найден RemnaPilot v$(grep -m1 '^RP_VERSION=' "$t" | cut -d'"' -f2)"
  else yel "⚠ Файл remnapilot.sh по этому адресу не найден (репозиторий закрыт или файла нет). Источник сохранён."; fi
  rm -f "$t"; jlog INFO "Источник обновлений: $v"
}

self_update_online() {
  local t nv
  [[ -n "$(rp_source)" ]] || { yel "Источник обновлений не задан."; rp_set_source || return 1; [[ -n "$(rp_source)" ]] || return 0; }
  info "Скачиваю с GitHub..."
  t=$(mktemp); rm -f /etc/rw/.latest_version
  rp_fetch_latest "$t" || { rm -f "$t"; red "✖ Не удалось скачать remnapilot.sh ($(rp_source))"; return 1; }
  nv=$(grep -m1 '^RP_VERSION=' "$t" | cut -d'"' -f2)
  if [[ "$nv" == "$RP_VERSION" ]]; then green "✔ У тебя последняя версия (v$RP_VERSION)"; rm -f "$t"; return 0; fi
  self_update "$t"; local rc=$?; rm -f "$t"; return $rc
}

self_update_menu() {
  local c rv src; src=$(rp_source)
  section "RemnaPilot"
  if [[ -n "$src" ]]; then
    rv=$(rp_remote_version)
    echo "   Источник: $src"
    echo "   Сейчас v$RP_VERSION, на GitHub ${rv:+v$rv}${rv:-—}"
  fi
  item 1 "Обновить с GitHub" "${src:-источник не задан}"
  item 2 "Обновить из файла" "загруженного на сервер"
  item 3 "Указать репозиторий GitHub"
  item 0 "Назад"
  ask; read -r c; echo
  case "$c" in
    1) run_action "Обновление RemnaPilot (GitHub)" self_update_online ;;
    2) run_action "Обновление RemnaPilot (файл)" self_update ;;
    3) rp_set_source ;;
  esac
}

# ----- самообновление из файла -----
self_update() { # $1 = путь к новому файлу (необязательно — спросит)
  local f="${1:-}" nv src
  if [[ -z "$f" ]]; then
    echo "  Загрузи новую версию на сервер (scp или SFTP) и укажи путь к файлу."
    ask "Путь к новому remnapilot.sh"; read -re f
  fi
  [[ -f "$f" ]] || { err "файл не найден: $f"; return 1; }
  bash -n "$f" 2>/dev/null && grep -q 'RP_NAME="RemnaPilot"' "$f" || { red "✖ Это не RemnaPilot или файл повреждён"; return 1; }
  nv=$(grep -m1 '^RP_VERSION=' "$f" | cut -d'"' -f2)
  if [[ "$nv" == "$RP_VERSION" ]]; then green "✔ Это та же версия (v$RP_VERSION)"; return 0; fi
  if [[ "$(printf '%s\n%s\n' "$RP_VERSION" "$nv" | sort -V | tail -1)" != "$nv" ]]; then
    yel "В файле версия v$nv — она старее текущей v$RP_VERSION."; ask "Всё равно заменить? [y/N]"; read -r a; [[ "$a" =~ ^[Yy]$ ]] || return 0
  fi
  install -m 755 "$f" /usr/local/bin/rw || return 1
  src=$(readlink -f "$0" 2>/dev/null)
  [[ -f "$src" && "$src" != /usr/local/bin/rw && "$src" != "$(readlink -f "$f")" ]] && cp -f /usr/local/bin/rw "$src"
  green "✔ RemnaPilot v$RP_VERSION → v$nv — перезапускаю"; jlog INFO "RemnaPilot обновлён до v$nv"; sleep 1
  rp_reexec /usr/local/bin/rw
}

update_menu() {
  local c pv pl nv nl sv sl app sub_ct
  while true; do
    screen "Обновления"; echo
    info "Проверяю версии..."
    app=""; pv=""; nv=""; sv=""
    if [[ -f "$RW_DIR/.env" ]] && command -v docker >/dev/null; then
      app=$(app_containers | head -1); pv=$(local_ver "$app"); pl=$(gh_latest remnawave/backend)
      sub_ct=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /subscription-page/ {print $1; exit}')
      [[ -n "$sub_ct" ]] && { sv=$(local_ver "$sub_ct"); sl=$(gh_latest remnawave/subscription-page); }
    fi
    if node_dir >/dev/null && command -v docker >/dev/null; then nv=$(local_ver remnanode); nl=$(gh_latest remnawave/node); fi
    printf '\e[1A\e[2K'   # убрать «Проверяю версии...»
    box_top
    [[ -n "$app" ]]    && ver_line "Панель"   "$pv" "$pl"
    [[ -n "$sub_ct" ]] && ver_line "Подписка" "$sv" "$sl"
    node_dir >/dev/null && ver_line "Нода"    "$nv" "$nl"
    [[ -s "$NODES_FILE" ]] && box_line "${C_MUT}$(padr "Ноды SSH" 11)${C0}$(wc -l < "$NODES_FILE") в списке"
    if [[ -n "$(rp_source)" ]]; then ver_line "RemnaPilot" "$RP_VERSION" "$(rp_remote_version)"
    else box_line "${C_MUT}$(padr "RemnaPilot" 11)${C0}v$RP_VERSION  ${C_MUT}(источник обновлений не задан)${C0}"; fi
    box_bottom

    section "ОБНОВИТЬ"
    item 1 "Всё сразу" "панель + ноды"
    item 2 "Панель" "с бэкапом базы"
    item 3 "Ноду на этом сервере"
    item 4 "Ноды по SSH"
    item 5 "RemnaPilot" "GitHub или файл"
    section "ВЕРСИИ"
    item 6 "Откатить последнее обновление"
    item 7 "Закрепить версию панели" "или вернуть latest"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Обновление: всё" update_all; pause ;;
      2) UPD_LOG=""; run_action "Обновление панели" update_panel; pause ;;
      3) UPD_LOG=""; run_action "Обновление ноды" update_local_node; pause ;;
      4) run_action "Обновление нод по SSH" nodes_update; pause ;;
      5) self_update_menu; pause ;;
      6) run_action "Откат обновления" rollback_update; pause ;;
      7) run_action "Закрепление версии панели" pin_panel_version; pause ;;
      0|q) return ;;
    esac
  done
}

change_dir() {
  read -rp "Путь к Remnawave [$RW_DIR]: " in
  in="${in:-$RW_DIR}"
  [[ -f "$in/.env" ]] && { RW_DIR="$in"; green "✓ Каталог: $RW_DIR"; } || red "Там нет .env"
}

menu() {
  while true; do
    clear
    banner
    echo
    status_box

    section "ДОМЕН"
    item 1 "Сменить домены" "панель и/или подписка"
    item 2 "Удалить старые домены" "алиасы и ненужные"
    item 3 "Предпросмотр смены" "без изменений"
    item 4 "Откатить смену домена"
    section "ПАНЕЛЬ"
    item 5 "Настройки и контейнеры"
    item 6 "Обновления" "панель · ноды · RemnaPilot"
    item 7 "Пересоздать контейнеры"
    item 8 "Логи"
    item 9 "Сертификаты"
    item 10 "Безопасность" "секреты · БД · админ"
    section "БАЗА"
    item 11 "Сделать бэкап"
    item 12 "Восстановить из дампа"
    section "НОДЫ"
    item 13 "Установка и обновление нод"
    item 14 "Статус всех нод" "CPU · RAM · диск · версия"
    item 15 "Обновить geoip / geosite"
    item 16 "WARP на ноде" "Cloudflare для ChatGPT и др."
    section "СЕРВЕР"
    item 17 "Firewall" "ufw"
    item 18 "Защита SSH" "порт · fail2ban · ключи"
    item 19 "Ускорение сети" "BBR"
    item 20 "Swap" "если мало RAM"
    item 21 "Время и часовой пояс"
    item 22 "Очистка диска"
    item 23 "Перенос панели на другой сервер"
    section "ПРОВЕРКИ"
    item 24 "Проверка IP сервера" "РФ · пинг · скорость"
    item 25 "Подбор SNI для Reality"
    section "ПРОЧЕЕ"
    item 26 "Журнал действий"
    item 27 "Language / Язык" "$( [[ "$RP_LANG" == en ]] && echo English || echo Русский )"
    item 28 "Установить команду rw"
    item 29 "Сменить каталог панели" "$RW_DIR"
    item 30 "О программе и версии" "v$RP_VERSION"
    item 0 "Выход"
    hr
    ask; read -r ch
    case "$ch" in
      1|2|3|4|5|7|9|10|11|12|23) need_panel || { pause; continue; } ;;
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
      28) install_cmd; pause ;;
      29) change_dir; pause ;;
      30) about_screen; pause ;;
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

# ---------- старт ----------
need_val() { [[ -n "${2:-}" && "$2" != -* ]] || { echo "Флаг $1 требует значение (см. --help)"; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --old|--dir|--cert-method|--sub|--lang) need_val "$1" "${2:-}" ;;
  esac
  case "$1" in
    --old)       OLD="$2"; shift 2 ;;
    --dir)       RW_DIR="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    --skip-cert) SKIP_CERT=1; shift ;;
    --cert-method) CERT_METHOD="$2"; [[ "$CERT_METHOD" =~ ^(http|alpn|dns|manual)$ ]] || { echo "--cert-method: http|alpn|dns|manual"; exit 1; }; shift 2 ;;
    --update)    DO_UPDATE=1; shift ;;
    --update-all) DO_UPDATE_ALL=1; shift ;;
    --geo-update-local) DO_GEO="${2:-loyal}"; [[ "$DO_GEO" == -* ]] && DO_GEO=loyal || shift; shift ;;
    --self-update) [[ $EUID -eq 0 ]] || { echo "Нужен root"; exit 1; }
                   if [[ -n "${2:-}" && "$2" != -* ]]; then self_update "$2"; else self_update_online; fi; exit $? ;;
    --sub)       SUB_NEW="$2"; shift 2 ;;
    --cert-status) DO_CERT_STATUS=1; shift ;;
    -h|--help)   awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$RP_SELF"; exit 0 ;;
    -v|--version) echo "$RP_NAME $RP_VERSION"; exit 0 ;;
    --lang)      RP_LANG="$2"; [[ "$RP_LANG" == en ]] || RP_LANG=ru; shift 2 ;;
    -*)          red "Неизвестный флаг $1"; exit 1 ;;
    *)           NEW="$1"; shift ;;
  esac
done

[[ $EUID -eq 0 ]] || { red "Запусти от root (sudo)"; exit 1; }
if [[ "$RP_LANG" == en && -f "$RP_SELF" ]] && command -v perl >/dev/null; then
  rp_load_dict
  exec 3>&1 4>&2
  exec > >(rp_translate) 2>&1
  RP_TR_PID=$!
  trap 'exec >&- 2>&-; wait "$RP_TR_PID" 2>/dev/null' EXIT
fi
if [[ -n "$NEW" || -n "${SUB_NEW:-}" || ${DO_UPDATE:-0} == 1 || ${DO_CERT_STATUS:-0} == 1 ]]; then
  need_panel || exit 1
fi

if [[ -n "${DO_GEO:-}" ]]; then
  bash -s <<< "$(geo_script "$DO_GEO")"
elif (( ${DO_CERT_STATUS:-0} )); then
  cert_status
elif [[ -n "${SUB_NEW:-}" ]]; then
  change_sub_domain "$SUB_NEW" "$DRY"
elif (( ${DO_UPDATE_ALL:-0} )); then
  update_all
elif (( ${DO_UPDATE:-0} )); then
  update_panel
elif [[ -n "$NEW" ]]; then
  change_domain "$NEW" "$OLD" "$DRY"
else
  offer_cmd
  if [[ -n "$(rp_source)" ]] && { [[ ! -f /etc/rw/.latest_version ]] || (( $(date +%s) - $(stat -c %Y /etc/rw/.latest_version) > 86400 )); }; then
    ( rp_remote_version >/dev/null 2>&1 & ) 2>/dev/null
  fi
  menu
fi
exit 0

# Словарь интерфейса RU → EN (используется при RP_LANG=en)
: <<'__RP_EN_END__'
__RP_EN__
Если всё хорошо — старую панель можно удалить. Если нет — запусти её здесь: пункт 7 «Пересоздать контейнеры».	If all is fine, you can delete the old panel. If not, start it here: item 6 "Recreate containers".
Сертификаты: если способ не сработал — сразу предлагает другой (порт 80, 443, DNS Cloudflare, DNS вручную)	Certificates: if a method fails, another one is offered right away (port 80, 443, DNS Cloudflare, manual DNS)
Смена домена панели не пугает «старые ссылки подписки перестанут работать», если подписка на своём домене	Panel domain change no longer warns "old subscription links will stop working" when the subscription has its own domain
Готово. Сертификат для старого домена, если он в Nginx, перевыпусти в разделе «Сертификаты» (пункт 9).	Done. If the old domain's certificate is in Nginx, reissue it in "Certificates" (item 8).
Восстановление не удалось — изменения откачены (одна транзакция). Панель запущена со старыми данными.	Restore failed — changes were rolled back (single transaction). The panel is running with the old data.
Смена доменов панели и подписки в одном пункте: один бэкап, один перезапуск, сертификаты сразу на оба	Panel and subscription domain change in one item: one backup, one restart, certificates for both at once
Причина: проверку получил не этот сервер — домен смотрит на другой IP или включён прокси Cloudflare.	Reason: the challenge reached another server — the domain points to another IP or the Cloudflare proxy is on.
Раздел «Обновления»: панель, страница подписки, нода здесь и ноды по SSH — с версиями «было → стало»	"Updates" section: panel, subscription page, local node and SSH nodes — with "was → now" versions
Сертификаты: понятная причина ошибки — порт закрыт у хостера, прокси Cloudflare, DNS, лимит Let	Certificates: clear error reasons — port closed at the hoster, Cloudflare proxy, DNS, Let
Сертификаты: хуки продления свои для каждого домена — второй сертификат больше не ломает первый	Certificates: separate renewal hooks per domain — a second certificate no longer breaks the first
минимальный. Если у домена несколько имён, записей будет несколько с одним именем — добавь все.	minimal. If the domain has several names, there will be several records with the same name — add them all.
Тюнинг убран, алгоритм — cubic. Остальные параметры вернутся к умолчаниям после перезагрузки.	Tuning removed, algorithm is cubic. Other parameters return to defaults after a reboot.
На новом сервере запусти  rw  → «Сертификаты» → перевыпусти, чтобы заработало автопродление.	On the new server run  rw  → "Certificates" → reissue so auto-renewal works.
Нужен API-токен Cloudflare: dash.cloudflare.com → My Profile → API Tokens → «Edit zone DNS».	A Cloudflare API token is needed: dash.cloudflare.com → My Profile → API Tokens → "Edit zone DNS".
Откатить: «Обновления» → «Откатить последнее обновление» (вернёт образы и при желании базу).	Roll back: "Updates" → "Roll back last update" (restores images and, optionally, the database).
Чтобы вынести подписку на свой домен, нужна страница подписки (remnawave/subscription-page).	To move the subscription to its own domain you need the subscription page (remnawave/subscription-page).
смотрит не на этот сервер (похоже на прокси Cloudflare) — TLS-ALPN через прокси не работает.	does not point to this server (looks like the Cloudflare proxy) — TLS-ALPN does not work through a proxy.
Если новая версия успела изменить базу, старая панель может не запуститься без отката базы.	If the new version already changed the database, the old panel may not start without a database rollback.
Сертификаты: выпуск через DNS вручную (TXT-запись у любого регистратора) с проверкой записи	Certificates: manual DNS issuance (TXT record at any registrar) with record check
Лимит логов Docker применён (для контейнеров, созданных заново — «Пересоздать контейнеры»)	Docker log limit applied (for newly created containers — "Recreate containers")
Рядом есть .env из того же бэкапа. Восстановить и его? (нужно, если менялись JWT-секреты)	There is a .env from the same backup. Restore it too? (needed if JWT secrets changed)
Открой его в панели хостера (firewall / security group) или выбери DNS — порты не нужны.	Open it in your hoster's panel (firewall / security group) or choose DNS — no ports needed.
Порты, опубликованные Docker (ports: в compose), ufw НЕ закрывает — Docker обходит его.	Ports published by Docker (ports: in compose) are NOT blocked by ufw — Docker bypasses it.
а домен и сертификат на сервере подписки нужно сменить там (этим же скриптом, пункт 1).	and the domain and certificate on the subscription server must be changed there (with this script, item 1).
Панель здесь будет остановлена на время переноса (подписки и ноды продолжат работать).	The panel here will be stopped during the move (subscriptions and nodes keep working).
похоже, страница подписки стоит на другом сервере. Здесь поменяется только .env панели	looks like the subscription page is on another server. Only the panel .env will change here
хуков нет — при standalone-выпуске продление упрётся в занятый порт (исправит пункт 2)	no hooks — with standalone issuance renewal will hit a busy port (item 2 fixes it)
Пока не видно — DNS обновляется от минуты до получаса. Подожди и нажми Enter ещё раз.	Not visible yet — DNS updates take from a minute to half an hour. Wait and press Enter again.
После замены ВСЕ API-токены перестанут работать: страница подписки, боты, интеграции.	After replacing it ALL API tokens stop working: subscription page, bots, integrations.
Мелочи: --help, проверка номера при удалении ноды, статус SSL без ложного «истёк»	Minor: --help, number check when removing a node, SSL status without false "expired"
Список нод пуст. Если на нодах firewall пускает только старый IP панели — разреши	Node list is empty. If the node firewall only allows the old panel IP — allow
Проверка открытых портов сообщает, если строку в compose не удалось исправить	Open ports check reports when a compose line could not be fixed
Если выключить пароль сейчас — ты потеряешь доступ. Сначала добавь свой ключ	If you disable the password now you will lose access. Add your key first
Причина: домен не найден в DNS или не указывает на сервер. Проверь A-запись.	Reason: the domain is not in DNS or does not point to the server. Check the A record.
Не удалось войти без пароля. Сейчас попрошу пароль один раз и добавлю ключ.	Could not log in without a password. I will ask for the password once and add a key.
Откроется Rescue CLI панели. «Reset superadmin» удалит текущего суперадмина	The panel Rescue CLI will open. "Reset superadmin" deletes the current superadmin
Проверь в новом окне, что вход по ключу работает, прежде чем закрывать это.	Check in a new window that key login works before closing this one.
Меню, смена домена панели и подписки, сертификаты, бэкап/восстановление БД	Menu, panel and subscription domain change, certificates, DB backup/restore
Причина: неверный токен Cloudflare или у него нет прав Zone → DNS → Edit.	Reason: wrong Cloudflare token or it lacks Zone → DNS → Edit permission.
Установка не удалась (если пользователь не root — нужен sudo без пароля).	Installation failed (if the user is not root, passwordless sudo is required).
слишком много попыток). Подожди час (или неделю при лимите сертификатов).	too many attempts). Wait an hour (or a week for the certificate limit).
Дополнительные порты через пробел (например 8443/tcp 2053/udp) или Enter	Extra ports separated by spaces (e.g. 8443/tcp 2053/udp) or Enter
Остановка контейнеров в правильном порядке: сначала прокси, потом панель	Containers stop in the right order: proxy first, then panel
Смена домена панели больше не сбрасывает свой путь подписки на /api/sub	Panel domain change no longer resets a custom subscription path to /api/sub
Поддержка доменов в зоне .рф (punycode) и доменов с заглавными буквами	Support for IDN domains (punycode) and domains with capital letters
Отдельного домена подписки нет — он меняется вместе с доменом панели.	There is no separate subscription domain — it changes together with the panel domain.
Подожди обновления DNS и открой панель — данные должны быть на месте.	Wait for DNS to update and open the panel — the data should be there.
Проверь их в «Безопасность» → там же можно привязать их к 127.0.0.1.	Check them in "Security" → you can bind them to 127.0.0.1 there.
Скрипт запускается на чистом сервере без docker — для установки ноды	The script runs on a clean server without docker — for node installation
Безопасность, логи, установка и массовое обновление нод, команда rw	Security, logs, node installation and bulk update, rw command
Для лимита логов Docker нужен перезапуск Docker — VPN прервётся на	The Docker log limit needs a Docker restart — VPN will drop for
Команда rw установлена из другой версии скрипта. Обновить её этой?	The rw command is from another script version. Replace it with this one?
Сертификат не выпущен — сделай это позже в разделе «Сертификаты».	Certificate not issued — do it later in "Certificates".
берётся в панели: Ноды → Management → + → Copy docker-compose.yml	is taken from the panel: Nodes → Management → + → Copy docker-compose.yml
или на сервере панели: docker exec -it remnawave cli → Get SECRET	or on the panel server: docker exec -it remnawave cli → Get SECRET
На новом сервере уже есть /opt/remnawave — он будет перезаписан.	The new server already has /opt/remnawave — it will be overwritten.
Сгенерировать новый? (обнови его в Prometheus, если используешь)	Generate a new one? (update it in Prometheus if you use it)
Сертификатов Nginx не найдено (Caddy/Traefik обновляют их сами).	No Nginx certificates found (Caddy/Traefik renew them themselves).
панели (порт ноды откроется только для него; пусто — пропустить)	panel IP (the node port will be opened only for it; empty — skip)
На новом сервере: подниму базу, восстановлю дамп, запущу панель	On the new server: start the database, restore the dump, start the panel
Обновить панель, ноды и сам RemnaPilot — пункт 6 «Обновления».	Update the panel, nodes and RemnaPilot itself — item 5 "Updates".
Готово. В панели нажми Next / проверь, что нода стала онлайн.	Done. Press Next in the panel / check that the node is online.
Оставить старый домен рабочим, чтобы подписки не отвалились?	Keep the old domain working so subscriptions don't break?
Откат: раздел «Обновления» → «Откатить последнее обновление»	Rollback: "Updates" → "Roll back last update"
У клиентов в приложениях сохранены ссылки со старым доменом.	Clients' apps have links with the old domain saved.
больше соединений и открытых файлов — для множества клиентов	more connections and open files — for many clients
для /var/log/remnanode: каждый день, хранить 7 дней, сжимать	for /var/log/remnanode: daily, keep 7 days, compress
перестанут работать — пользователям нужно обновить подписку.	will stop working — users need to update their subscription.
после этого открой панель в браузере и зарегистрируй нового.	then open the panel in a browser and register a new one.
Откат последнего обновления: старые образы + база из бэкапа	Roll back the last update: old images + database from backup
Скопирую /opt/remnawave (конфиги, сертификаты, .env) и дамп	Copy /opt/remnawave (configs, certificates, .env) and the dump
по умолчанию (ZeroSSL просил e-mail и не работал с .ru/.рф)	by default (ZeroSSL required e-mail and did not work with .ru/.рф)
Домен подписки не найден в конфигах прокси на этом сервере	Subscription domain not found in proxy configs on this server
Старая панель останется (остановленной) — можно вернуться.	The old panel stays (stopped) — you can go back.
Запускаю базу и восстанавливаю данные на новом сервере...	Starting the database and restoring data on the new server...
открыт для всех. Включи ufw, предварительно разрешив SSH.	is open to everyone. Enable ufw after allowing SSH.
Проверить и исправить секреты, пароль БД, открытые порты	Check and fix secrets, DB password, open ports
Через прокси Cloudflare работает только порт 80 или DNS.	Only port 80 or DNS works through the Cloudflare proxy.
Какие обновить? (Enter — все, или номера через запятую)	Which to update? (Enter — all, or numbers separated by commas)
Не закрывай это окно! Открой НОВОЕ подключение:  ssh -p	Do not close this window! Open a NEW connection:  ssh -p
Обновить всё» одной кнопкой: бэкап базы → панель → ноды	Update all" with one button: DB backup → panel → nodes
Проверю новый сервер, при необходимости поставлю Docker	Check the new server, install Docker if needed
Сгенерировать новый? (обнови его у получателя вебхуков)	Generate a new one? (update it at the webhook receiver)
перестанут работать, при необходимости оставь редирект.	will stop working, keep a redirect if needed.
Убедись, что ТЫ СЕЙЧАС вошёл по ключу, а не по паролю.	Make sure YOU ARE NOW logged in with a key, not a password.
в конфиге Nginx — выпусти его в разделе «Сертификаты».	in the Nginx config — issue it in "Certificates".
это домен панели — для подписки на домене панели укажи	this is the panel domain — for a subscription on the panel domain set
Скопируй целиком и вставь на новом сервере (под root)	Copy it all and paste on the new server (as root)
Установить короткую команду  rw  для запуска скрипта?	Install the short command  rw  to launch the script?
ошибок за 10 минут → бан на 1 час, повторно — дольше.	failures in 10 minutes → 1 hour ban, longer on repeat.
Исправлен вылет на необъявленных переменных (set -u)	Fixed crash on undeclared variables (set -u)
Панель не поднялась после обновления. Последние логи	The panel did not start after the update. Last logs
Подписка отдаётся с домена панели — старые ссылки на	The subscription is served from the panel domain — old links to
Разрешу IP новой панели на нодах (если они в списке)	Allow the new panel IP on nodes (if they are in the list)
алиас старого домена подписки с правильными скобками	old subscription domain alias with correct brackets
останутся открытыми — доступ к серверу не потеряешь.	will stay open — you won't lose access to the server.
с ssl не найден — сертификат выпустит Caddy/Traefik.	with ssl not found — Caddy/Traefik will issue the certificate.
Это порт SSH — не закрываю, иначе потеряешь доступ.	This is the SSH port — not closing it, or you'd lose access.
Их нужно будет создать заново в панели и прописать	You will need to create them again in the panel and set
Пересоздать контейнеры, чтобы применить изменения?	Recreate containers to apply the changes?
Сгенерировать новый? Все админы будут разлогинены.	Generate a new one? All admins will be logged out.
Смена домена не трогает копии .env в папке backups	Domain change no longer touches .env copies in the backups folder
большие TCP-буферы — скорость на дальних маршрутах	large TCP buffers — speed on long routes
неиспользуемые Docker-образы без тега и кэш сборки	unused untagged Docker images and build cache
Закрепление версии панели (или возврат на latest)	Pin the panel version (or return to latest)
Остановлю панель здесь и сделаю свежий бэкап базы	Stop the panel here and make a fresh DB backup
Подписка была на домене панели — старые ссылки на	The subscription was on the panel domain — old links to
Вход по паролю выключен, root — только по ключу.	Password login disabled, root — key only.
включён, тюнинг применён. Перезагрузка не нужна.	enabled, tuning applied. No reboot needed.
не резолвится — сертификат может не выпуститься.	does not resolve — the certificate may fail to issue.
Добавить в список для массового обновления? Имя	Add to the list for bulk updates? Name
Записей об обновлениях нет — откатывать нечего.	No update records — nothing to roll back.
Подписка не менялась — ссылки клиентов прежние.	Subscription not changed — client links stay the same.
Сбросить суперадмина / включить вход по паролю	Reset superadmin / enable password login
быстрее на каналах с потерями и большим пингом	faster on lossy, high-latency links
не удалось определить старый домен, укажи его	could not detect the old domain, specify it
БД не запущена — пароль Postgres не проверен	DB is not running — Postgres password not checked
Не удалось поставить Docker на новом сервере	Could not install Docker on the new server
У клиентов в приложениях сохранены ссылки на	Clients' apps have links saved to
восстановлен (старый — .env.before-restore)	restored (old one — .env.before-restore)
дней повтори выпуск (раздел «Сертификаты»).	days repeat the issuance ("Certificates").
логи каждого контейнера не больше 3 × 50 МБ	each container's logs no more than 3 × 50 MB
не нашёл в docker-compose — поправь вручную	not found in docker-compose — fix it manually
Привязать их к 127.0.0.1 в docker-compose?	Bind them to 127.0.0.1 in docker-compose?
Сертификаты: автоустановка acme.sh и socat	Certificates: auto-install acme.sh and socat
Пробное продление на тестовом сервере Let	Test renewal on the staging server of Let
У регистратора домена поменяй A-записи на	At your domain registrar change the A records to
домен подписки совпадает с доменом панели	subscription domain equals the panel domain
образы для отката обновления сохраняются)	images for update rollback are kept)
установлен. Дальше запускай командой:  rw	installed. From now on run:  rw
Бэкап старого .env лежит рядом: .env.bak	Backup of the old .env is next to it: .env.bak
Панель на этом же сервере — разрешу порт	The panel is on this server — I will allow port
Продление не проходит — проверь порт/DNS	Renewal fails — check port/DNS
Сколько последних бэкапов базы оставить?	How many recent DB backups to keep?
на домене панели — сменится вместе с ним	on the panel domain — will change with it
Готово: теперь можно просто набрать  rw	Done: now you can just type  rw
Оставить старый домен подписки рабочим?	Keep the old subscription domain working?
Получилось подключиться на новом порту?	Were you able to connect on the new port?
Установить ноду на другой сервер по SSH	Install a node on another server via SSH
панель (+ бэкап базы перед обновлением)	panel (+ DB backup before updating)
Бэкап не удался. Всё равно продолжить?	Backup failed. Continue anyway?
Добавил? Enter — проверить, q — отмена	Added? Enter — check, q — cancel
Контейнер БД не найден, дамп пропущен.	DB container not found, dump skipped.
Панель не обновилась — ноды не трогаю.	Panel was not updated — leaving nodes alone.
Подписка сейчас отдаётся самой панелью	The subscription is currently served by the panel itself
Причина: порт занят другой программой.	Reason: the port is used by another program.
Проверить, что автопродление сработает	Check that auto-renewal will work
Ручной DNS не продлевается сам — через	Manual DNS does not auto-renew — in about
Скачать и перезапустить панель сейчас?	Pull and restart the panel now?
логи контейнеров больше 50 МБ — обрежу	container logs over 50 MB — truncate
любой DNS-провайдер, без автопродления	any DNS provider, no auto-renewal
с проверкой, без риска потерять доступ	with a check, no risk of losing access
Бэкап не удался. Продолжить без него?	Backup failed. Continue without it?
На этом сервере нода, порт управления	This server has a node, control port
Не установлен perl (apt install perl)	perl is not installed (apt install perl)
Сделать бэкап базы перед обновлением?	Back up the database before updating?
без «медленного старта» после простоя	no "slow start" after idle
всегда последняя, «2» — последняя 2.x	always the latest, "2" — latest 2.x
Нужен вход под root на новом сервере	Root login on the new server is required
Останавливаю панель и делаю бэкап...	Stopping the panel and making a backup...
на своём компьютере:  ssh-copy-id -p	on your computer:  ssh-copy-id -p
Новый раздел «О программе и версии»	New "About & version" section
Подскажу, какие DNS-записи поменять	Tell you which DNS records to change
Сейчас в compose: remnawave/backend	Currently in compose: remnawave/backend
Установка одной командой: curl -sSL	One-command install: curl -sSL
не найден — ограничь доступ к порту	not found — restrict access to port
старые бэкапы — оставлю последние N	old backups — keep the last N
На сервере нет ни одного SSH-ключа	There are no SSH keys on the server
Пункт 29 — указать другой каталог.	Item 21 — set another directory.
Самообновление RemnaPilot с GitHub	RemnaPilot self-update from GitHub
Старый домен в конфигах не найден.	Old domain not found in configs.
Страховочный бэкап текущей базы...	Safety backup of the current database...
боевой сертификат не трогается)...	the production certificate is not touched)...
добавишь TXT-запись у регистратора	you add a TXT record at your registrar
Бэкап не удался — перенос отменён	Backup failed — move cancelled
Порт (например 8443 или 2053/udp)	Port (e.g. 8443 or 2053/udp)
панели, с которого разрешить порт	panel IP to allow the port from
скопировать и вставить на сервере	copy and paste on the server
БД/панель доступны из интернета)	DB/panel reachable from the internet)
Готовлю новый сервер (Docker)...	Preparing the new server (Docker)...
ДОБАВЬ TXT-ЗАПИСИ У РЕГИСТРАТОРА	ADD TXT RECORDS AT YOUR REGISTRAR
Панель уже на последней версии v	The panel is already on the latest version v
Пароль Postgres дефолтный/слабый	Postgres password is default/weak
журнал ОС (journald) — до 200 МБ	OS journal (journald) — down to 200 MB
Включить вход по паролю обратно	Re-enable password login
Обновить / перевыпустить сейчас	Renew / reissue now
Очистка: лимиты логов настроены	Cleanup: log limits configured
Перенос панели на другой сервер	Move the panel to another server
Предпросмотр — изменятся строки	Preview — these lines will change
Путь к дампу (.sql или .sql.gz)	Path to the dump (.sql or .sql.gz)
не достучался до сервера — порт	could not reach the server — port
не удалось изменить пароль в БД	could not change the password in the DB
п) указать путь к файлу вручную	p) enter the file path manually
порты не нужны, нужен API-токен	no ports needed, API token required
старый и новый домены совпадают	old and new domains are the same
Не нашёл файлы сертификата для	Certificate files not found for
Не удалось установить fail2ban	Could not install fail2ban
Нода уже на последней версии v	The node is already on the latest version v
Нужен socat: apt install socat	socat is required: apt install socat
Ограничить рост логов навсегда	Limit log growth permanently
Только с IP (Enter — для всех)	Only from IP (Enter — for everyone)
Установить ноду на этот сервер	Install a node on this server
ок, если домен за Cloudflare).	OK if the domain is behind Cloudflare).
ссылки клиентов не изменились.	client links did not change.
ВНИМАНИЕ: ufw выключен — порт	WARNING: ufw is disabled — port
ВНИМАНИЕ: текущие данные базы	WARNING: the current data of database
Вход по паролю снова включён.	Password login enabled again.
Откатить последнее обновление	Roll back last update
В compose: remnawave/backend	In compose: remnawave/backend
Наружу открыты только 80/443	Only 80/443 are open to the outside
Не удалось получить версию с	Could not get the version from
Нет acme.sh или сертификата.	No acme.sh or certificate.
Остановить на время выпуска?	Stop it during issuance?
Подписка на отдельном домене	Subscription is on a separate domain
автоматически не остановить.	cannot be stopped automatically.
пароль изменён в БД и в .env	password changed in the DB and in .env
пока тоже открыт в firewall)	is still open in the firewall too)
Для подтверждения введи YES	Type YES to confirm
Запусти от root:  curl -sSL	Run as root:  curl -sSL
Команда rw уже установлена.	The rw command is already installed.
Настроить вход по SSH-ключу	Set up SSH key login
Оставлено последних бэкапов	Recent backups kept
Сеть: BBR и тюнинг включены	Network: BBR and tuning enabled
некорректный домен подписки	invalid subscription domain
порт должен быть 1024–65535	port must be 1024–65535
Готово. Подписка: https://	Done. Subscription: https://
Запустил обратно контейнер	Started container back
Останавливаю контейнеры...	Stopping containers...
Показать команду установки	Show the install command
Попробовать другой способ?	Try another method?
Предпросмотр смены доменов	Domain change preview
Сертификат: тест продления	Certificate: renewal test
Установка и обновление нод	Node install and update
и лимит journald настроены	and journald limit configured
и настроить автообновление	and set up auto-renewal
не установлен. Установить?	is not installed. Install?
панель · ноды · RemnaPilot	panel · nodes · RemnaPilot
пульт управления Remnawave	Remnawave control panel
Выключить вход по паролю?	Disable password login?
Закрепление версии панели	Pin panel version
Не удалось установить ufw	Could not install ufw
Ноды на этом сервере нет.	There is no node on this server.
Продление пройдёт успешно	Renewal will succeed
будут заменены содержимым	will be replaced with the contents of
введи пароль SSH один раз	enter the SSH password once
некорректный домен панели	invalid panel domain
нужен Linux 4.9+, а здесь	requires Linux 4.9+, but here
Выключить вход по паролю	Disable password login
Журнал ОС ужат до 200 МБ	OS journal shrunk to 200 MB
Номер ноды (Enter — все)	Node number (Enter — all)
Пересоздание контейнеров	Recreating containers
Пересоздаю контейнеры...	Recreating containers...
Скачанный файл повреждён	Downloaded file is corrupted
Устанавливаю fail2ban...	Installing fail2ban...
Установка Remnawave Node	Installing Remnawave Node
оставить домен как есть.	keep the domain as is.
хуки продления настроены	renewal hooks configured
Автопродление настроено	Auto-renewal configured
Выпускаю сертификат для	Issuing certificate for
Закрепить версию панели	Pin panel version
Запустил обратно сервис	Started service back
Настроить одной кнопкой	One-click setup
Ошибка на новом сервере	Error on the new server
Проверяю подключение...	Checking connection...
вход по паролю выключен	password login disabled
контейнер БД не запущен	DB container is not running
логи ноды старше 7 дней	node logs older than 7 days
порт · fail2ban · ключи	port · fail2ban · keys
Безопасность: проверка	Security: check
Восстановить и базу из	Restore the database too from
Добавить ноду в список	Add a node to the list
Запускаю контейнеры...	Starting containers...
Запусти от root (sudo)	Run as root (sudo)
Контейнеры не найдены.	No containers found.
Настройки и контейнеры	Settings and containers
Ошибка обновления ноды	Node update error
Пересоздать контейнеры	Recreate containers
СЕЙЧАС СЛУШАЮТ СНАРУЖИ	LISTENING EXTERNALLY NOW
Сменить каталог панели	Change panel directory
Старые ссылки https://	Old links https://
Удалить ноду из списка	Remove a node from the list
Устанавливаю Docker...	Installing Docker...
Файлы восстановлены из	Files restored from
бан за перебор паролей	ban for password brute-force
вход по паролю включён	password login enabled
База восстановлена из	Database restored from
Включить BBR и тюнинг	Enable BBR and tuning
Восстановить из дампа	Restore from dump
Входящие по умолчанию	Incoming by default
Жду запуска панели...	Waiting for the panel to start...
ОСТАЛОСЬ СДЕЛАТЬ ТЕБЕ	LEFT FOR YOU TO DO
Обновление RemnaPilot	RemnaPilot update
Обновление нод по SSH	Node update via SSH
Обновляю RemnaPilot v	Updating RemnaPilot v
Откатить смену домена	Roll back domain change
Ошибка при обновлении	Update error
Последние строки лога	Last log lines
Сеть: тюнинг выключен	Network: tuning disabled
Устанавливаю socat...	Installing socat...
Установить команду rw	Install the rw command
Установка ноды по SSH	Node install via SSH
без socat не работает	does not work without socat
панель и/или подписка	panel and/or subscription
привязаны к 127.0.0.1	bound to 127.0.0.1
Заняты оба порта: 80	Both ports are busy: 80
Наружу открыты порты	Ports open to the outside
Не скопировался дамп	Dump was not copied
Не установлен docker	docker is not installed
Новый домен подписки	New subscription domain
Ноду на этом сервере	Node on this server
О программе и версии	About & version
Обновить ноды по SSH	Update nodes via SSH
Очистка: освобождено	Cleanup: freed
Ошибка в конфиге SSH	Error in SSH config
ПОСЛЕДНЕЕ ОБНОВЛЕНИЕ	LAST UPDATE
Сгенерировать новый?	Generate a new one?
Установка ноды здесь	Local node install
выглядит некорректно	looks invalid
исходящие: разрешены	outgoing: allowed
к порту ноды вручную	to the node port manually
не удалось — разреши	failed — allow
нода на этом сервере	node on this server
ноды на этом сервере	nodes on this server
перестанут работать.	will stop working.
секреты · БД · админ	secrets · DB · admin
слабый или дефолтный	weak or default
Восстановление базы	Database restore
Всё равно заменить?	Replace anyway?
Выключить firewall?	Disable the firewall?
Готово. Старый порт	Done. Old port
Нода не запустилась	The node did not start
Нода установлена на	Node installed on
Останавливаю панель	Stopping the panel
Ошибки за всё время	Errors for all time
Панель обновлена: v	Panel updated: v
Порт 443 (TLS-ALPN)	Port 443 (TLS-ALPN)
Последние 300 строк	Last 300 lines
Сеть: откат тюнинга	Network: tuning rollback
Удалить все записи?	Delete all records?
Устанавливаю ufw...	Installing ufw...
Установить fail2ban	Install fail2ban
в firewall хостера.	in the hoster's firewall.
на этом сервере нет	not on this server
некорректная версия	invalid version
продолжат работать.	will keep working.
через Caddy/Traefik	via Caddy/Traefik
В реальном времени	Live
Включить firewall?	Enable the firewall?
Выбор (0 — отмена)	Choice (0 — cancel)
Выключить firewall	Disable firewall
Логи ноды почищены	Node logs cleaned
Локальная версия v	Local version v
Не удалось скачать	Could not download
Новый домен панели	New panel domain
Номер для удаления	Number to remove
Откат смены домена	Domain change rollback
Ошибка конфига SSH	SSH config error
Ошибка копирования	Copy error
Ошибок не найдено.	No errors found.
Панель запущена на	Panel started on
Подписка: https://	Subscription: https://
Предпросмотр смены	Change preview
Причина: лимит Let	Reason: rate limit of Let
Проверяю версии...	Checking versions...
Сертификат: выпуск	Certificate: issue
временно остановлю	will stop temporarily
домен не изменился	the domain did not change
или вернуть latest	or return to latest
некорректный домен	invalid domain
нет связи с GitHub	no connection to GitHub
оставлен как алиас	kept as an alias
остановлю на время	will stop for a while
через смену в .env	via a change in .env
Ничего не меняем.	Nothing to change.
Нода обновлена: v	Node updated: v
Обновление панели	Panel update
Образы возвращены	Images restored
Ошибки за 24 часа	Errors in 24 hours
Панель не найдена	Panel not found
Перенос панели на	Moving the panel to
Сброс суперадмина	Superadmin reset
для Docker-сетей.	for Docker networks.
занят контейнером	is used by container
некорректный порт	invalid port
по умолчанию root	default root
разрешён только с	allowed only from
старый как алиас)	old one as alias)
Вернуть как было	Revert
Готово: https://	Done: https://
ИЗМЕНЯТСЯ СТРОКИ	LINES TO CHANGE
КАК ЭТО РАБОТАЕТ	HOW IT WORKS
Неизвестный флаг	Unknown flag
Откат обновления	Update rollback
Откатить образы?	Roll back images?
Панель: https://	Panel: https://
Путь к Remnawave	Path to Remnawave
Сертификаты: Let	Certificates: Let
Сменить порт SSH	Change SSH port
Старые ссылки на	Old links to
Текущая подписка	Current subscription
выключить пароль	disable password
можно освободить	can be freed
на время выпуска	during issuance
не больше 300 МБ	no more than 300 MB
Временно открыл	Temporarily opened
Дамп не удался.	Dump failed.
Журнал действий	Action log
Начать перенос?	Start the move?
Обновить статус	Refresh status
Обновление ноды	Node update
Обновление: всё	Update: all
Очистить журнал	Clear the log
Очистить сейчас	Clean up now
Ошибки за 1 час	Errors in 1 hour
Пароль Postgres	Postgres password
Слово или regex	Word or regex
включить пароль	enable password
включён для SSH	enabled for SSH
закрыт снаружи.	closed from the outside.
занят процессом	is used by process
и верну обратно	and bring it back
кэш пакетов apt	apt package cache
не задан в .env	is not set in .env
не слушает порт	is not listening on port
некорректный IP	invalid IP
теперь на порту	now on port
только по ключу	key only
АВТООБНОВЛЕНИЕ	AUTO-RENEWAL
Восстанавливаю	Restoring
Всё в порядке.	All good.
Домен подписки	Subscription domain
Каталог панели	Panel directory
Кэш apt очищен	apt cache cleared
Новая подписка	New subscription
Новый порт SSH	New SSH port
Обновлено до v	Updated to v
Перенос панели	Panel move
Поиск по слову	Search by word
Порт 80 (HTTP)	Port 80 (HTTP)
Сертификат для	Certificate for
Сменить домены	Change domains
Ускорение сети	Network boost
ЧТО НОВОГО В v	WHAT'S NEW IN v
вернуть %s%s%s	restore %s%s%s
всё ещё занят.	is still busy.
занят сервисом	is used by service
не установился	failed to install
не установлено	not installed
нет authorized	no authorized
новее релиза v	newer than release v
порты не нужны	no ports needed
с бэкапом базы	with DB backup
у регистратора	at the registrar
файл не найден	file not found
файл повреждён	file is corrupted
Журнал очищен	Log cleared
Копирую файлы	Copying files
Не получилось	Failed
Нет доступа к	No access to
Очистка диска	Disk cleanup
Подключаюсь к	Connecting to
Сделать бэкап	Make a backup
Смена доменов	Domain change
Только ошибки	Errors only
Уже в списке.	Already in the list.
без изменений	no changes
к порту ноды.	to the node port.
не запустился	did not start
не установлен	not installed
новые сверху)	newest first)
панель + ноды	panel + nodes
Безопасность	Security
Бэкапов нет.	No backups.
Введи версию	Enter a version
Домен панели	Panel domain
Журнал пуст.	Log is empty.
Закрыть порт	Close a port
Лимиты логов	Log limits
Новый сервер	New server
Открыть порт	Open a port
Причина: Let	Reason: Let
Старый домен	Old domain
Там нет .env	No .env there
закрыть порт	close port
записи видны	records are visible
защищает SSH	protects SSH
не включился	was not enabled
открыть порт	open port
перезапускаю	restarting
сертификаты)	certificates)
Вернул порт	Restored port
Весь журнал	Full log
Логи Docker	Docker logs
НОДЫ ПО SSH	NODES VIA SSH
Новый домен	New domain
Ноды по SSH	Nodes via SSH
Освобождено	Freed
СЕРТИФИКАТЫ	CERTIFICATES
Сертификаты	Certificates
Создан ключ	Key created
Список пуст	The list is empty
ЧТО НАСТРОЮ	WHAT WILL BE SET UP
без паролей	no passwords
в firewalld	in firewalld
не выпущен.	not issued.
не найдены)	not found)
ноды по SSH	nodes via SSH
остановлена	stopped
смена порта	port change
список пуст	list is empty
Бэкап базы	Database backup
Запустить?	Launch?
Защита SSH	SSH protection
КОНТЕЙНЕРЫ	CONTAINERS
Команда rw	rw command
НОДА ЗДЕСЬ	LOCAL NODE
Нужен root	Root required
Обновления	Updates
Применить?	Apply?
Сертификат	Certificate
Список нод	Node list
ЧТО ВКЛЮЧУ	WHAT WILL BE ENABLED
актуальная	up to date
в iptables	in iptables
доступ для	access for
доступна v	available v
не найдена	not found
недоступна	unavailable
неизвестно	unknown
нет образа	no image
нода здесь	node here
установлен	installed
Всё сразу	Everything
Дамп базы	Database dump
Добавлена	Added
Журнал ОС	OS journal
Логи ноды	Node logs
НАСТРОЙКИ	SETTINGS
Остановил	Stopped
Отменено.	Cancelled.
Порт ноды	Node port
Применено	Applied
Сеть: BBR	Network: BBR
ЧТО ОЧИЩУ	WHAT WILL BE CLEANED
возвращаю	reverting
выключен)	disabled)
дефолтный	default
дн. назад	days ago
запрещены	denied
контейнер	container
настройка	setup
не найден	not found
порт ноды	node port
последняя	latest
пропускаю	skipping
уже занят	is already in use
Алгоритм	Algorithm
Бэкап БД	DB backup
ДЕЙСТВИЯ	ACTIONS
Запустил	Started
ИСТОЧНИК	SOURCE
Имя ноды	Node name
Источник	Source
Ноды SSH	SSH nodes
ОБНОВИТЬ	UPDATE
Обновляю	Updating
ПОДПИСКА	SUBSCRIPTION
ПРОВЕРКА	CHECK
Подписка	Subscription
Порт 443	Port 443
Сменить?	Change?
актуален	up to date
в списке	in the list
выключен	disabled
забанено	banned
завершён	completed
и т.п.).	etc.).
осталось	left
применён	applied
проблемы	problems
работает	running
свободен	free
только с	only from
Дампы в	Dumps in
Каталог	Directory
Начать?	Start?
Ноды...	Nodes...
Очередь	Queue
ПРАВИЛА	RULES
Порт 80	Port 80
Удалена	Removed
включён	enabled
вручную	manually
дампов)	dumps)
закрыт.	closed.
заменён	replaced
каталог	directory
открыто	opened
порт(ы)	port(s)
почищен	cleaned
секунд.	seconds.
сервера	server
БЭКАПЫ	BACKUPS
Бэкапы	Backups
ВЕРСИИ	VERSIONS
Версия	Version
Готово	Done
Диск /	Disk /
Закрыт	Closed
Образы	Images
Открыт	Opened
Откуда	From
Отмена	Cancel
ПАНЕЛЬ	PANEL
ПРОЧЕЕ	OTHER
Панель	Panel
Пароль	Password
СЕРВЕР	SERVER
СПОСОБ	METHOD
Сервер	Server
Способ	Method
Тюнинг	Tuning
закрыт	closed
занято	used
открыт	open
ошибка	error
пусто)	empty)
слабый	weak
старый	old
Бэкап	Backup
Выбор	Choice
Выход	Exit
ДОМЕН	DOMAIN
Домен	Domain
ИСТЁК	EXPIRED
Ключи	Keys
Назад	Back
Номер	Number
РЕЖИМ	MODE
Режим	Mode
ФАЙЛЫ	FILES
Файлы	Files
в ufw	in ufw
выход	exit
домен	domain
занят	busy
истёк	expired
назад	ago
Авто	Auto
БАЗА	DATABASE
ИТОГ	SUMMARY
Куда	To
Логи	Logs
НОДЫ	NODES
Нода	Node
Ноды	Nodes
ПЛАН	PLAN
Порт	Port
Файл	File
Ядро	Kernel
база	database
есть	present
нода	node
порт	port
тест	test
для	for
дн.	days
код	code
нет	no
МБ	MB
из	of
п	p
Firewall включён	Firewall enabled
Firewall выключен	Firewall disabled
Firewall: открыто	Firewall: opened
Firewall: открыт	Firewall: opened
Firewall: закрыт	Firewall: closed
Firewall: настройка	Firewall: setup
Firewall: открыть порт	Firewall: open port
Firewall: закрыть порт	Firewall: close port
SSH-порт(ы)	SSH port(s)
SSH: смена порта	SSH: port change
SSH: fail2ban	SSH: fail2ban
SSH: выключить пароль	SSH: disable password
SSH: включить пароль	SSH: enable password
SSH теперь на порту	SSH is now on port
fail2ban защищает SSH	fail2ban protects SSH
fail2ban не запустился	fail2ban did not start
fail2ban включён для SSH	fail2ban enabled for SSH
BBR нужен Linux 4.9+, а здесь	BBR requires Linux 4.9+, but here
BBR не включился (ядро без модуля tcp_bbr?)	BBR was not enabled (kernel without tcp_bbr module?)
BBR включён, тюнинг применён. Перезагрузка не нужна.	BBR enabled, tuning applied. No reboot needed.
BBR + fq — быстрее на каналах с потерями и большим пингом	BBR + fq — faster on lossy, high-latency links
TCP Fast Open, MTU probing, без «медленного старта» после простоя	TCP Fast Open, MTU probing, no "slow start" after idle
Docker почищен	Docker cleaned
Docker: логи каждого контейнера не больше 3 × 50 МБ	Docker: each container's logs no more than 3 × 50 MB
logrotate для /var/log/remnanode: каждый день, хранить 7 дней, сжимать	logrotate for /var/log/remnanode: daily, keep 7 days, compress
logrotate и лимит journald настроены	logrotate and journald limit configured
journald: не больше 300 МБ	journald: no more than 300 MB
Language / Язык	Language / Язык
Русский	Russian
Firewall	Firewall
TXT-записи видны	TXT records are visible
DNS вручную	Manual DNS
DNS Cloudflare	DNS Cloudflare
Значение:	Value:
Имя:	Name:
новее, чем на GitHub	is newer than on GitHub
Локальная версия v	Local version v
База	DB
Очистка диска и ограничение роста логов (Docker, journald, logrotate для ноды)	Disk cleanup and log growth limits (Docker, journald, logrotate for the node)
одной кнопкой: SSH, 80, 443, порты Xray, порт ноды только с IP панели	in one click: SSH, 80, 443, Xray ports, node port only from the panel IP
Защита SSH: смена порта с проверкой, fail2ban, вход только по ключу	SSH protection: port change with a check, fail2ban, key-only login
Журнал действий: что, когда и с каким результатом	Action log: what, when and with what result
Перенос панели на другой сервер одним сценарием	Moving the panel to another server in one scenario
Ускорение сети: BBR и тюнинг TCP	Network boost: BBR and TCP tuning
Английский язык интерфейса	English interface language
Firewall одной кнопкой	One-click firewall
Язык:	Language:
проверка видит блокировку IP. Блокировку по SNI/DPI она не покажет — это проверяется реальным подключением.	check detects IP blocking. It won't show SNI/DPI blocking — that needs a real connection test.
Обновление geoip/geosite на нодах (Loyalsoldier или runetfreedom), автообновление раз в неделю	geoip/geosite update on nodes (Loyalsoldier or runetfreedom), weekly auto-update
Новые теги (например geosite:ru-blocked) используй в правилах маршрутизации профиля в панели.	Use new tags (e.g. geosite:ru-blocked) in the routing rules of the profile in the panel.
МБ включён и переживёт перезагрузку (swappiness 10 — используется только при нехватке RAM)	MB enabled and survives reboots (swappiness 10 — used only when RAM runs out)
Подбор SNI для Reality: проверка TLS 1.3, H2, X25519, пинга и поиск соседей в подсети	Reality SNI picker: TLS 1.3, H2, X25519, ping check and neighbor search in the subnet
Нод нет: ни на этом сервере, ни в списке (пункт 13 → «Добавить ноду в список»).	No nodes: neither on this server nor in the list (item 12 → "Add a node to the list").
Соседей с TLS 1.3 + H2 не нашлось. Попробуй проверить известные домены вручную.	No neighbors with TLS 1.3 + H2 found. Try checking known domains manually.
Список доменов меняй под себя. Остальной трафик пойдёт как раньше — напрямую.	Adjust the domain list as you like. All other traffic goes directly, as before.
на ноде: SOCKS5 через Cloudflare + готовые настройки для профиля в панели	on a node: SOCKS5 via Cloudflare + ready settings for the panel profile
недоступен ни с одного узла — похоже на блокировку IP (или порт закрыт).	is unreachable from every node — looks like an IP block (or the port is closed).
близко к серверу (в идеале — тот же дата-центр) и не за Cloudflare.	close to the server (ideally the same data center) and not behind Cloudflare.
Время: синхронизация NTP, часовой пояс, проверка расхождения часов	Time: NTP sync, time zone, clock drift check
Статус всех нод на одном экране: CPU, RAM, диск, версия, аптайм	All nodes status on one screen: CPU, RAM, disk, version, uptime
Хороший SNI: TLS 1.3, H2, X25519, без редиректа на другой домен	A good SNI: TLS 1.3, H2, X25519, no redirect to another domain
Проверка IP: доступность из РФ (check-host.net), пинг, скорость	IP check: reachability from Russia (check-host.net), ping, speed
выход в интернет через Cloudflare. Сайты, которые блокируют IP	internet access via Cloudflare. Sites that block hosting IPs
трафик туда направляют правила маршрутизации в панели.	traffic is sent there by routing rules in the panel.
Обновлять автоматически раз в неделю на этом сервере?	Auto-update weekly on this server?
Нод нет (пункт 13 → «Добавить ноду в список»).	No nodes (item 12 → "Add a node to the list").
своп здесь создать нельзя, его выдаёт хостер.	swap cannot be created here, the hoster provides it.
Панель → Config Profiles → профиль ноды → в	Panel → Config Profiles → node profile → in
Сейчас у check-host.net нет узлов в РФ.	check-host.net currently has no nodes in Russia.
недоступен — проверка из РФ невозможна	unreachable — check from Russia is not possible
откроются. Ставится как SOCKS5-прокси	will open. Installed as a SOCKS5 proxy
Синхронизировать время на всех нодах	Sync time on all nodes
нет — при 1–2 ГБ RAM рекомендуется	none — recommended with 1–2 GB RAM
с — Xray/Reality может не работать	s — Xray/Reality may not work
ДОБАВЬ В ПРОФИЛЬ КОНФИГА В ПАНЕЛИ	ADD TO THE CONFIG PROFILE IN THE PANEL
блокировка в РФ · пинг · скорость	RU block · ping · speed
возможна частичная блокировка.	partial blocking is possible.
Включить синхронизацию времени	Enable time synchronization
не установился cloudflare-warp	cloudflare-warp failed to install
Синхронизация времени включена	Time synchronization enabled
нет SSH-ключа — пункт 13 → 7	no SSH key — item 12 → 7
сертификат не прошёл проверку	certificate failed verification
Мало места на диске: свободно	Low disk space: free
Показать настройки для панели	Show settings for the panel
за Cloudflare — нежелательно	behind Cloudflare — not recommended
Не удалось узнать внешний IP	Could not get the public IP
Жду ответы узлов (10 сек)...	Waiting for node responses (10 s)...
Доступен не со всех узлов РФ	Not reachable from all RU nodes
для VPS с маленькой памятью	for VPS with little memory
Каждый понедельник в 04:17	Every Monday at 04:17
рекомендуется для серверов	recommended for servers
установлен, но не работает	installed but not working
мировой, самый популярный	global, most popular
например Asia/Novosibirsk	e.g. Asia/Novosibirsk
Обновить geoip / geosite	Update geoip / geosite
Не удалось включить swap	Could not enable swap
Создать / изменить swap	Create / resize swap
ИЗ РОССИИ → ЭТОТ СЕРВЕР	FROM RUSSIA → THIS SERVER
сайты в той же подсети	sites in the same subnet
Подбор SNI для Reality	Reality SNI picker
Найти соседей сервера	Find server neighbors
СКОРОСТЬ (Cloudflare)	SPEED (Cloudflare)
доступен из РФ по TCP	reachable from Russia via TCP
Загрузка:	Download:
Отдача:	Upload:
Мбит/с	Mbit/s
Время и часовой пояс	Time and time zone
Сменить часовой пояс	Change time zone
Создаю /swapfile на	Creating /swapfile of
Проверка IP сервера	Server IP check
Проверяю каждого...	Checking each...
нода не установлена	node not installed
нужен Debian/Ubuntu	Debian/Ubuntu required
Яндекс DNS (Москва)	Yandex DNS (Moscow)
с ru-blocked для РФ	with ru-blocked for Russia
Время: часовой пояс	Time: time zone
не синхронизировано	not synchronized
Найдено кандидатов	Candidates found
Все ноды из списка	All nodes from the list
Скачиваю 50 МБ...	Downloading 50 MB...
для ChatGPT и др.	for ChatGPT etc.
Порт для проверки	Port to check
слишком маленький	too small
контрольная сумма	checksum
Размер swap в МБ	Swap size in MB
Проверить домены	Check domains
синхронизировано	synchronized
Страна:	Country:
Хостинг:	Hosting:
Список нод пуст.	Node list is empty.
нет такого пояса	no such time zone
Статус всех нод	All nodes status
выше остальных)	above the others)
Установить WARP	Install WARP
ПИНГ С СЕРВЕРА	PING FROM THE SERVER
Проверить WARP	Check WARP
не подключился	did not connect
Отдаю 20 МБ...	Uploading 20 MB...
Ввести вручную	Enter manually
НА КАКОЙ НОДЕ	ON WHICH NODE
Это контейнер	This is a container
диск · версия	disk · version
если мало RAM	if RAM is low
через пробел	space-separated
ЧАСОВОЙ ПОЯС	TIME ZONE
Часовой пояс	Time zone
Удалить swap	Remove swap
Удалить WARP	Remove WARP
этот сервер	this server
всё отлично	all good
Расхождение	Drift
Проверка IP	IP check
редирект на	redirect to
нет TLS 1.3	no TLS 1.3
Время: ноды	Time: nodes
не скачался	was not downloaded
Этот сервер	This server
Финляндия	Finland
Из РФ порт	From Russia port
Время: NTP	Time: NTP
минута)...	minute)...
нет X25519	no X25519
Опрашиваю	Polling
замечания	notes
установка	installation
Сканирую	Scanning
ПРОВЕРКИ	CHECKS
нет ноды	no node
хостеров	hosters
создание	creation
удаление	removal
удалён.	removed.
на ноде	on a node
потери	loss
адреса	addresses
нет H2	no H2
удалён	removed
не РФ	not RU
далеко	far
здесь	here
Домены	Domains
Время	Time
узел	node
пинг	ping
КУДА	WHERE
Пояс	Zone
ГДЕ	WHERE
мс	ms
WARP на ноде	WARP on node
Swap удалён.	Swap removed.
Swap: создание	Swap: creation
Swap: удаление	Swap: removal
WARP: установка	WARP: installation
WARP: удаление	WARP: removal
Cloudflare для ChatGPT и др.	Cloudflare for ChatGPT etc.
Английский режим: «Статус всех нод» больше не зависает навсегда	English mode: "All nodes status" no longer hangs forever
Смена языка и самообновление больше не теряют цвета и не переводят вывод дважды	Language switch and self-update no longer lose colors or translate output twice
Флаги без значения (--dir, --old…) больше не вешают скрипт	Flags without a value (--dir, --old…) no longer hang the script
Статус нод: данные с ноды не выполняются как код (безопасность)	Node status: data from a node is no longer executed as code (security)
Firewall: пустой IP панели больше не закрывает порт ноды для всех	Firewall: an empty panel IP no longer closes the node port for everyone
SSH: при отмене смены порта новый порт закрывается в firewall	SSH: cancelling a port change closes the new port in the firewall
Перенос: живые файлы БД не копируются, старая панель не оживает после перезагрузки	Move: live DB files are not copied, the old panel won't come back after a reboot
Swap на xfs/btrfs, geo при compose.yaml, WARP без обрыва установки, cron geo без команды rw	Swap on xfs/btrfs, geo with compose.yaml, WARP install no longer aborts, geo cron without the rw command
Очистка: верный размер логов Docker, daemon.json не перезаписывается	Cleanup: correct Docker log size, daemon.json is not overwritten
Английский: «О программе» переводится полностью, исправлен символ & в переводах	English: "About" is fully translated, & in translations fixed
Удаление старых доменов и алиасов: из конфигов, сертификатов и автопродления	Removing old domains and aliases: from configs, certificates and auto-renewal
Исправлено: старый заказ acme.sh после смены домена мог при продлении затереть новый сертификат	Fixed: after a domain change the old acme.sh order could overwrite the new certificate on renewal
Удалить старые домены	Remove old domains
алиасы и ненужные	aliases and unused
Удаление доменов	Domain removal
Удалены домены	Removed domains
СТАРЫЕ ДОМЕНЫ И АЛИАСЫ	OLD DOMAINS AND ALIASES
БУДЕТ УДАЛЕНО	WILL BE REMOVED
Что удалить (номера через пробел)	What to remove (space-separated numbers)
Все сразу	All at once
Лишних доменов нет — в конфигах только домены панели и подписки.	No extra domains — configs contain only the panel and subscription domains.
Ссылки подписки и адреса на этих доменах перестанут открываться.	Subscription links and addresses on these domains will stop opening.
Удалить?	Delete?
удалён из конфигов	removed from configs
не найден в конфигах	not found in configs
больше не используется	is no longer used
Готово. Удалено доменов	Done. Domains removed
A-записи этих доменов у регистратора теперь можно удалить (или не продлевать домен).	The A records of these domains can now be deleted at the registrar (or let the domain expire).
Старое автопродление для	Old auto-renewal for
отключено	disabled
не удаляется	not removable
ничего не выбрано	nothing selected
Без привязки к ссылке: запуск из файла, обновление RemnaPilot из загруженного файла	No link dependency: run from a file, update RemnaPilot from an uploaded file
Сохрани скрипт в файл и запусти его:  sudo bash remnapilot.sh	Save the script to a file and run it:  sudo bash remnapilot.sh
Сохрани скрипт в файл и запусти его оттуда — тогда команда rw установится.	Save the script to a file and run it from there — then the rw command will be installed.
Загрузи новую версию на сервер (scp или SFTP) и укажи путь к файлу.	Upload the new version to the server (scp or SFTP) and enter the file path.
Путь к новому remnapilot.sh	Path to the new remnapilot.sh
Это не RemnaPilot или файл повреждён	This is not RemnaPilot or the file is corrupted
Это та же версия	This is the same version
В файле версия v	The file has version v
она старее текущей v	it is older than the current v
перезапускаю	restarting
RemnaPilot обновлён до v	RemnaPilot updated to v
из загруженного файла	from an uploaded file
Укажи файл:	Specify the file:
Обновление RemnaPilot с GitHub: репозиторий указывается в меню, в файл не вшит	RemnaPilot update from GitHub: the repository is set in the menu, not hardcoded
Подсказка в главном меню, когда вышла новая версия RemnaPilot	Main menu hint when a new RemnaPilot version is out
Укажи репозиторий на GitHub, где лежит remnapilot.sh:	Enter the GitHub repository with remnapilot.sh:
owner/repo — например  user/remnapilot	owner/repo — e.g.  user/remnapilot
берётся файл из последнего релиза, иначе из ветки main	the file from the latest release, otherwise from the main branch
или прямая ссылка https://… на файл	or a direct https://… link to the file
Репозиторий	Repository
непохоже на owner/repo или ссылку	does not look like owner/repo or a link
Найден RemnaPilot v	Found RemnaPilot v
Файл remnapilot.sh по этому адресу не найден (репозиторий закрыт или файла нет). Источник сохранён.	remnapilot.sh not found at this address (private repo or no file). Source saved.
Источник обновлений	Update source
Источник обновлений не задан.	Update source is not set.
источник обновлений не задан	update source not set
Скачиваю с GitHub...	Downloading from GitHub...
Не удалось скачать remnapilot.sh	Could not download remnapilot.sh
У тебя последняя версия	You have the latest version
Источник:	Source:
на GitHub	on GitHub
Обновить с GitHub	Update from GitHub
источник не задан	source not set
Обновить из файла	Update from a file
загруженного на сервер	uploaded to the server
Указать репозиторий GitHub	Set the GitHub repository
GitHub или файл	GitHub or file
Доступен RemnaPilot v	RemnaPilot available v
пункт 6 → 5	item 6 → 5
Обновление RemnaPilot (GitHub)	RemnaPilot update (GitHub)
Обновление RemnaPilot (файл)	RemnaPilot update (file)
Проверяю...	Checking...
Официальный репозиторий github.com/Dubstep2004/RemnaPilot — установка одной командой и обновления из коробки	Official repository github.com/Dubstep2004/RemnaPilot — one-command install and updates out of the box
Запусти от root (sudo -i)	Run as root (sudo -i)
Не удалось скачать RemnaPilot. Сохрани скрипт в файл и запусти:	Could not download RemnaPilot. Save the script to a file and run:
Не удалось скачать RemnaPilot — сохрани скрипт в файл и запусти его оттуда.	Could not download RemnaPilot — save the script to a file and run it from there.
РФ · пинг · скорость	RU · ping · speed
__RP_EN_END__
