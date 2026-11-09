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
    ls -1t "$RW_DIR"/.env.bak-* 2>/dev/null | tail -n +6 | xargs -r rm -f
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
  echo "   4. Если всё хорошо — старую панель можно удалить. Если нет — запусти её здесь: Панель → Пересоздать контейнеры."
  jlog OK "Перенос панели на $newip завершён"
}

