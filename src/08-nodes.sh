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
    out=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$p" "$h" "$(ssh_target "$h")" <<EOS 2>&1
$RP_VER_FN
$(cat <<'EOS2'
d=""; for x in /opt/remnanode /opt/remnawave-node; do [ -d "$x" ] && d="$x" && break; done
[ -n "$d" ] || { echo "NO_NODE_DIR"; exit 3; }
cd "$d" && docker compose pull -q && docker compose up -d && docker image prune -f >/dev/null
sleep 3
st=$(docker ps --filter name=remnanode --format '{{.Status}}')
v=$(rp_ver remnanode)
echo "RESULT ${v:-?} | $st"
EOS2
)
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

