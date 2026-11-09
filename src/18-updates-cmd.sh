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

need_compose() { # все действия используют «docker compose» (v2)
  docker compose version >/dev/null 2>&1 && return 0
  red "✖ Нужен Docker Compose v2 — команда «docker compose»."
  command -v docker-compose >/dev/null && echo "  Сейчас стоит старый docker-compose v1, RemnaPilot с ним не работает."
  echo "  Установить:  apt install docker-compose-plugin   (или: curl -fsSL https://get.docker.com | sh)"
  return 1
}

need_panel() {
  [[ -f "$RW_DIR/.env" ]] || { red "✖ Панель не найдена ($RW_DIR/.env). Прочее → Сменить каталог панели."; return 1; }
  command -v docker >/dev/null || { red "✖ Не установлен docker"; return 1; }
  need_compose || return 1
  command -v perl   >/dev/null || { red "✖ Не установлен perl (apt install perl)"; return 1; }
}

UPD_LOG="" # файл с записью последнего обновления (для отката)

# Функция для sh: версия приложения в контейнере. Выполняется и здесь, и на нодах по SSH.
RP_VER_FN=$(cat <<'VERFN'
rp_ver() {
  c="$1"; v=""
  for k in org.opencontainers.image.version version org.label-schema.version; do
    v=$(docker inspect -f "{{index .Config.Labels \"$k\"}}" "$c" 2>/dev/null)
    case "$v" in ""|"<no value>") v="" ;; *) break ;; esac
  done
  if [ -z "$v" ]; then
    t=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null); t="${t##*/}"; t="${t#*:}"
    case "$t" in [0-9]*.*|v[0-9]*.*) v="$t" ;; esac
  fi
  if [ -z "$v" ]; then
    v=$(docker exec "$c" sh -c 'for f in /opt/app/package.json /app/package.json /usr/src/app/package.json ./package.json; do [ -f "$f" ] && { sed -n "s/.*\"version\"[^\"]*\"\([^\"]*\)\".*/\1/p" "$f" | head -1; exit 0; }; done' 2>/dev/null)
  fi
  if [ -z "$v" ]; then
    v=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | sed -n 's/^[A-Z_]*VERSION=v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1)
  fi
  v="${v#v}"; case "$v" in [0-9]*) echo "$v" ;; esac
}
VERFN
)

local_ver() { # контейнер -> версия (кэш по ID контейнера: после пересоздания — заново)
  local id f v
  [[ -n "$DPS" ]] && id=$(dps_id "$1")
  [[ -n "$id" ]] || id=$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null) || return 0
  [[ -n "$id" ]] || return 0
  f="/run/remnapilot/ver-${id:0:16}"
  [[ -s "$f" ]] && { cat "$f"; return 0; }
  v=$(sh -c "$RP_VER_FN"'
rp_ver "$1"' _ "$1" 2>/dev/null)
  [[ -n "$v" ]] && { mkdir -p /run/remnapilot 2>/dev/null; echo "$v" > "$f" 2>/dev/null; }
  echo "$v"
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
  local img_before img_after
  app=$(app_containers | head -1); before=$(local_ver "$app"); img_before=$(docker inspect -f '{{.Image}}' "$app" 2>/dev/null)
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
    after=$(local_ver "$app"); img_after=$(docker inspect -f '{{.Image}}' "$app" 2>/dev/null)
    if [[ "$img_before" == "$img_after" ]]; then green "✔ Панель уже на последней версии${after:+ v$after}"
    else green "✔ Панель обновлена${before:+: v$before}${after:+ → v$after}"; fi
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
  need_compose || return 1
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

RP_FETCH_VERIFIED=0; RP_FETCH_BAD=0
rp_is_script() { bash -n "$1" 2>/dev/null && grep -q 'RP_NAME="RemnaPilot"' "$1"; }
rp_repo() { local v; v=$(rp_source); v="${v#github.com/}"; v="${v%.git}"; echo "${v%/}"; }

rp_fetch_latest() { # $1 = куда сохранить → 0, если скачан настоящий RemnaPilot
  # RP_FETCH_VERIFIED=1 — файл сверен с контрольной суммой релиза; RP_FETCH_BAD=1 — сумма НЕ совпала (подмена)
  local repo base sum got
  RP_FETCH_VERIFIED=0; RP_FETCH_BAD=0; repo=$(rp_repo)
  if [[ "$repo" == https://* ]]; then
    curl -fsSL --max-time 30 -o "$1" "$repo" 2>/dev/null && rp_is_script "$1"; return
  fi
  base="https://github.com/$repo/releases/latest/download"
  if curl -fsSL --max-time 30 -o "$1" "$base/remnapilot.sh" 2>/dev/null && rp_is_script "$1"; then
    sum=$(curl -fsSL --max-time 15 "$base/remnapilot.sh.sha256" 2>/dev/null | awk '{print $1}')
    if [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then
      got=$(sha256sum "$1" | awk '{print $1}')
      if [[ "$got" == "$sum" ]]; then RP_FETCH_VERIFIED=1; return 0; fi
      RP_FETCH_BAD=1; : > "$1"; return 1          # подменённый файл не используем вообще
    fi
    return 0                                        # старый релиз без контрольной суммы
  fi
  curl -fsSL --max-time 30 -o "$1" "https://raw.githubusercontent.com/$repo/main/remnapilot.sh" 2>/dev/null && rp_is_script "$1"
}

rp_verify_self() { # совпадает ли этот файл с официальным релизом → ok | modified | unknown
  local repo sum got t
  repo=$(rp_repo); [[ "$repo" == https://* ]] && { echo unknown; return; }
  [[ -f "$RP_SELF" ]] || { echo unknown; return; }
  got=$(sha256sum "$RP_SELF" | awk '{print $1}')
  sum=$(curl -fsSL --max-time 10 "https://github.com/$repo/releases/download/v$RP_VERSION/remnapilot.sh.sha256" 2>/dev/null | awk '{print $1}')
  if [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then [[ "$got" == "$sum" ]] && { echo ok; return; }
  else
    # у старых релизов нет .sha256 — сравниваем с самим файлом релиза
    t=$(mktemp)
    if curl -fsSL --max-time 15 -o "$t" "https://github.com/$repo/releases/download/v$RP_VERSION/remnapilot.sh" 2>/dev/null; then
      [[ "$(sha256sum "$t" | awk '{print $1}')" == "$got" ]] && { rm -f "$t"; echo ok; return; }
    else rm -f "$t"; echo unknown; return; fi
    rm -f "$t"
  fi
  echo modified
}

verify_line() {
  case "$(rp_verify_self)" in
    ok)       echo "$(dot ok) ${C_OK}официальный релиз${C0}" ;;
    modified) echo "$(dot warn) ${C_WARN}не совпадает с релизом v$RP_VERSION — изменён или не из релиза${C0}" ;;
    *)        echo "$(dot off) ${C_MUT}не проверить (нет связи или релиз без суммы)${C0}" ;;
  esac
}

rp_remote_version() { # версия на GitHub (кэш на 6 часов, чтобы меню не тормозило)
  local cache=/etc/rw/.latest_version t
  [[ -n "$(rp_source)" ]] || return 1
  if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache") < 21600 )); then cat "$cache"; return 0; fi
  mkdir -p /etc/rw 2>/dev/null
  t=$(mktemp); rp_fetch_latest "$t" && grep -m1 '^RP_VERSION=' "$t" | cut -d'"' -f2 | tee "$cache" 2>/dev/null; rm -f "$t"
}

self_update_online() {
  local t nv
  info "Скачиваю с GitHub..."
  t=$(mktemp); rm -f /etc/rw/.latest_version
  if ! rp_fetch_latest "$t"; then
    rm -f "$t"
    if (( RP_FETCH_BAD )); then
      red "✖ Контрольная сумма не совпала с релизом — файл подменён или повреждён. Обновление отменено."
      jlog FAIL "Обновление RemnaPilot отменено: контрольная сумма не совпала"
      tg_text "⚠️ $(hostname): RemnaPilot — контрольная сумма обновления не совпала, обновление отменено"
    else red "✖ Не удалось скачать remnapilot.sh ($(rp_source))"; fi
    return 1
  fi
  nv=$(grep -m1 '^RP_VERSION=' "$t" | cut -d'"' -f2)
  if [[ "$nv" == "$RP_VERSION" ]]; then green "✔ У тебя последняя версия (v$RP_VERSION)"; rm -f "$t"; return 0; fi
  if (( RP_FETCH_VERIFIED )); then
    green "✔ Подлинность подтверждена: контрольная сумма совпадает с релизом v$nv"
  else
    yel "⚠ У релиза нет контрольной суммы — подлинность не проверить."
    [[ -n "${RP_AUTO:-}" ]] && { rm -f "$t"; return 1; }
    ask "Всё равно установить? [y/N]"; read -r a; [[ "$a" =~ ^[Yy]$ ]] || { rm -f "$t"; return 0; }
  fi
  self_update "$t"; local rc=$?; rm -f "$t"; return $rc
}

self_update_menu() {
  local c rv
  rv=$(rp_remote_version)
  section "RemnaPilot"
  echo "   Сейчас v$RP_VERSION, на GitHub ${rv:+v$rv}${rv:-—}"
  item 1 "Обновить с GitHub"
  item 2 "Обновить из файла" "загруженного на сервер"
  item 0 "Назад"
  ask; read -r c; echo
  case "$c" in
    1) run_action "Обновление RemnaPilot (GitHub)" self_update_online ;;
    2) run_action "Обновление RemnaPilot (файл)" self_update ;;
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
    yel "В файле версия v$nv — она старее текущей v$RP_VERSION."
    [[ -n "${RP_AUTO:-}" ]] && return 0
    ask "Всё равно заменить? [y/N]"; read -r a; [[ "$a" =~ ^[Yy]$ ]] || return 0
  fi
  install -m 755 "$f" /usr/local/bin/rw || return 1
  src=$(readlink -f "$0" 2>/dev/null)
  [[ -f "$src" && "$src" != /usr/local/bin/rw && "$src" != "$(readlink -f "$f")" ]] && cp -f /usr/local/bin/rw "$src.new" && mv -f "$src.new" "$src"
  jlog INFO "RemnaPilot обновлён до v$nv"
  [[ -n "${RP_AUTO:-}" ]] && { green "✔ RemnaPilot v$RP_VERSION → v$nv"; return 0; }
  green "✔ RemnaPilot v$RP_VERSION → v$nv — перезапускаю"; sleep 1
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
    item 8 "Автообновление" "$(au_mode_name "$(au_mode)")"
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
      8) au_menu ;;
      0|q) return ;;
    esac
  done
}

change_dir() {
  read -rp "Путь к Remnawave [$RW_DIR]: " in
  in="${in:-$RW_DIR}"
  [[ -f "$in/.env" ]] && { RW_DIR="$in"; green "✓ Каталог: $RW_DIR"; } || red "Там нет .env"
}

