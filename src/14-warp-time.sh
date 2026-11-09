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

