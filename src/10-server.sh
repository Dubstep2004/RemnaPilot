# ---------- общие для сервера ----------
pkg_install() { # пакеты… — тихая установка через apt/dnf/yum; вывод при ошибке — в PKG_LOG
  local log rc; log=$(mktemp); PKG_LOG=""
  if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >"$log" 2>&1 \
       || { apt-get update >>"$log" 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >>"$log" 2>&1; }
  elif command -v dnf >/dev/null; then dnf install -y "$@" >"$log" 2>&1
  elif command -v yum >/dev/null; then yum install -y "$@" >"$log" 2>&1
  else echo "нет apt, dnf или yum" > "$log"; false; fi
  rc=$?; (( rc )) && PKG_LOG=$(tail -c 8000 "$log"); rm -f "$log"; return "$rc"
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

  command -v ufw >/dev/null || { info "Устанавливаю ufw..."; pkg_install ufw || { fail "ufw не установился" apt "$PKG_LOG"; return 1; }; }
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
      4) ufw disable >/dev/null && { yel "Firewall выключен. Включить снова: пункт 1"; jlog INFO "Firewall выключен"; }; pause ;;
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
  command -v fail2ban-client >/dev/null || { info "Устанавливаю fail2ban..."; pkg_install fail2ban || { fail "fail2ban не установился" apt "$PKG_LOG"; return 1; }; }
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

