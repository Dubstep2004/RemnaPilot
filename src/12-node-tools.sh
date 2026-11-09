# ---------- выполнение на нодах: этот сервер / одна нода / все ----------
TARGETS=()

pick_targets() { # $1 = заголовок; заполняет TARGETS: "local" или "имя|user@host|порт"
  local lines=() i n c have_local=0
  node_dir >/dev/null 2>&1 && have_local=1
  [[ -s "$NODES_FILE" ]] && mapfile -t lines < "$NODES_FILE"
  TARGETS=()
  if (( ! have_local && ${#lines[@]} == 0 )); then
    yel "Нод нет: ни на этом сервере, ни в списке (Ноды → Установка и обновление нод → Добавить ноду в список)."; return 1
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
      ensure_cron; geo_cron_line "$src" > /etc/cron.d/remnapilot-geo; green "✔ Каждый понедельник в 04:17"
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
NODE_STAT_SCRIPT="$RP_VER_FN"'
st=$(docker ps -a --filter name=^remnanode$ --format "{{.Status}}" 2>/dev/null)
v=$(rp_ver remnanode)
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
  (( ${#lines[@]} )) || { yel "Нод нет (Ноды → Установка и обновление нод → Добавить ноду в список)."; return 0; }
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
      if grep -qiE 'denied|permission' "$tmp/$i.err" 2>/dev/null; then printf '  %s %s%s%s  %sнет SSH-ключа — Ноды → Установка → 7%s\n' "$(dot err)" "$CB" "$nm" "$C0" "$C_ERR" "$C0"
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

