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
    yel "  а домен и сертификат на сервере подписки нужно сменить там (этим же скриптом: Домены → Сменить домены)."
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
  green "Готово. Сертификат для старого домена, если он в Nginx, перевыпусти: Панель → Сертификаты."
}

restart_all() { echo "Пересоздаю контейнеры..."; stack_down; stack_up; green "✓ Готово"; }

rw_versions() {
  docker ps --format '{{.Names}}\t{{.Image}}' | grep -iE 'remna' | while IFS=$'\t' read -r n img; do
    local v
    v=$(local_ver "$n")
    printf '  %-28s %s %s\n' "$n" "$img" "${v:+($v)}"
  done
}

