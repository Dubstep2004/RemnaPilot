# ---------- понятные ошибки ----------
# Вместо «не удалось» — причина и что делать. why ВИД ЛОГ разбирает вывод упавшей команды.
#   fail "Панель не обновилась" docker "$log"
#     ✖ Панель не обновилась
#        Причина:    Docker Hub не отвечает с этого сервера
#        Что делать: …
cause() { printf '   %s%s%s %s\n' "$C_WARN" "$(padr "Причина:" 12)" "$C0" "$1"; }
todo()  { local l first=1; for l in "$@"; do
            if (( first )); then printf '   %s%s%s %s\n' "$C_ACC" "$(padr "Что делать:" 12)" "$C0" "$l"; first=0
            else printf '   %12s %s\n' "" "$l"; fi; done; }
fail()  { red "✖ $1"; [[ -n "${2:-}" ]] && why "$2" "${3:-}"; return 1; }

log_tail() { # последние значимые строки, если причину не узнали
  [[ -n "$1" ]] || return 0
  printf '   %s%s%s\n' "$C_MUT" "Последние строки:" "$C0"
  grep -v '^[[:space:]]*$' <<< "$1" | tail -"${2:-5}" | cut -c1-160 | sed 's/^/     /'
}

why() { # вид (docker|container|apt|ssh|net|telegram|db), текст лога → 0 если причина узнана
  local k="$1" t="$2" p
  case "$k" in
    docker|container|db)
      if grep -qiE 'no space left on device' <<< "$t"; then
        cause "на диске кончилось место"; todo "освободи место: Сервер → Очистка диска, потом повтори"; return 0
      fi ;;
  esac
  case "$k" in
    docker)
      if grep -qiE 'toomanyrequests|rate limit' <<< "$t"; then
        cause "Docker Hub ограничил скачивание (лимит на число загрузок с одного IP)"
        todo "подожди 1–6 часов и повтори" "или войди в Docker Hub: docker login"
      elif grep -qiE 'manifest (for .* )?(unknown|not found)|not found: manifest|repository does not exist' <<< "$t"; then
        cause "такой версии образа нет"
        todo "проверь тег image: в docker-compose.yml" "или выбери версию: Панель → Обновления → Закрепить версию панели"
      elif grep -qiE 'registry-1\.docker\.io|docker\.io|production\.cloudflare\.docker\.com|auth\.docker\.io' <<< "$t" \
           && grep -qiE 'timeout|i/o timeout|connection (refused|reset)|no such host|EOF|handshake' <<< "$t"; then
        cause "Docker Hub не отвечает с этого сервера (блокировка или сбой сети)"
        todo "добавь зеркало в /etc/docker/daemon.json:" \
             '  { "registry-mirrors": ["https://mirror.gcr.io"] }' \
             "затем: systemctl restart docker — и повтори"
      elif p=$(grep -oiE '(0\.0\.0\.0|127\.0\.0\.1|\[::\]):[0-9]+' <<< "$t" | head -1) \
           && grep -qiE 'address already in use|port is already allocated' <<< "$t"; then
        p="${p##*:}"
        cause "порт $p уже занят: $(port_owner "$p")"
        todo "освободи порт или смени его в docker-compose.yml" "кто занял: ss -ltnp 'sport = :$p'"
      elif grep -qiE 'Cannot connect to the Docker daemon|docker\.sock.*(no such file|connection refused)' <<< "$t"; then
        cause "Docker не запущен"; todo "systemctl start docker"
      elif grep -qiE 'permission denied.*docker\.sock' <<< "$t"; then
        cause "нет прав на Docker"; todo "запусти RemnaPilot под root: sudo rw"
      elif grep -qiE 'yaml:|services\.[^ ]+ (must|additional)|Additional property|invalid compose' <<< "$t"; then
        cause "ошибка в docker-compose.yml"; todo "покажет строку с ошибкой: docker compose config" "бэкап конфига — файлы *.bak-* рядом"
      else log_tail "$t"; return 1; fi ;;
    container)
      if grep -qiE 'password authentication failed' <<< "$t"; then
        cause "пароль базы в .env не совпадает с паролем в Postgres"
        todo "Панель → Безопасность → 1 — сверит и предложит исправить"
      elif grep -qiE "ECONNREFUSED[^ ]*:5432|Can't reach database|connect ECONNREFUSED|getaddrinfo .*(db|postgres)" <<< "$t"; then
        cause "панель не достучалась до базы данных"
        todo "проверь контейнер базы: docker ps -a | grep db" "его логи: docker logs --tail 30 remnawave-db"
      elif grep -qiE 'EADDRINUSE|address already in use' <<< "$t"; then
        p=$(grep -oiE 'EADDRINUSE[^0-9]*[0-9.:]*:([0-9]+)' <<< "$t" | grep -oE '[0-9]+$' | head -1)
        if [[ -n "$p" ]]; then cause "порт $p занят: $(port_owner "$p")"; else cause "нужный порт занят другой программой"; fi
        todo "освободи порт или смени его в .env (APP_PORT, METRICS_PORT)"
      elif grep -qiE 'out of memory|OOMKilled|JavaScript heap|Killed' <<< "$t"; then
        cause "не хватило памяти"; todo "добавь swap: Сервер → Swap" "или возьми сервер с 2 ГБ памяти и больше"
      elif grep -qiE 'migrat' <<< "$t" && grep -qiE 'fail|error' <<< "$t"; then
        cause "не прошла миграция базы на новую версию"
        todo "верни прошлую версию: Панель → Обновления → Откатить последнее обновление" "(бэкап базы сделан перед обновлением)"
      elif grep -qiE 'invalid environment|environment variable|must be (a|an|defined)|is required|ZodError|validation' <<< "$t"; then
        cause "в .env не хватает настройки или она неверная — новая версия могла добавить переменные"
        todo "сравни .env с .env.sample из документации новой версии: docs.rw"
      else log_tail "$t" 8; return 1; fi ;;
    db)
      if grep -qiE 'password authentication failed|role .* does not exist' <<< "$t"; then
        cause "логин или пароль базы в .env не подходят"; todo "Панель → Безопасность → 1"
      elif grep -qiE 'database .* does not exist' <<< "$t"; then
        cause "в .env указана база, которой нет"; todo "проверь DATABASE_URL в $RW_DIR/.env"
      elif grep -qiE 'is not running|No such container|cannot exec' <<< "$t"; then
        cause "контейнер базы не запущен"; todo "запусти панель: cd $RW_DIR && docker compose up -d"
      else log_tail "$t"; return 1; fi ;;
    apt)
      if grep -qiE 'Could not get lock|Unable to acquire the dpkg|is held by process' <<< "$t"; then
        cause "установщик пакетов занят — обычно это автообновление системы"
        todo "подожди 2–5 минут и повтори"
      elif grep -qiE 'dpkg was interrupted' <<< "$t"; then
        cause "прошлая установка пакетов прервалась"; todo "dpkg --configure -a — и повтори"
      elif grep -qiE 'Temporary failure resolving|Could not resolve|Failed to fetch|Network is unreachable' <<< "$t"; then
        cause "нет связи с репозиторием пакетов"; todo "проверь интернет и DNS: ping -c1 deb.debian.org"
      elif grep -qiE 'Unable to locate package|has no installation candidate' <<< "$t"; then
        cause "пакета нет в списках системы"; todo "apt update — и повтори"
      elif grep -qiE 'no space left' <<< "$t"; then
        cause "на диске кончилось место"; todo "Сервер → Очистка диска"
      else log_tail "$t"; return 1; fi ;;
    ssh)
      if grep -qiE 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' <<< "$t"; then
        cause "сменился ключ сервера — его переустановили или это другой сервер с тем же адресом"
        todo "если сервер переустанавливал ты: ssh-keygen -R <адрес> — и повтори"
      elif grep -qiE 'ssh: Could not resolve hostname' <<< "$t"; then
        cause "адрес сервера не найден"; todo "проверь IP или домен"
      elif grep -qiE 'ssh: connect to host .*Connection refused' <<< "$t"; then
        cause "на этом порту не работает SSH"; todo "проверь порт SSH (по умолчанию 22)"
      elif grep -qiE 'ssh: connect to host .*(timed out|No route to host|Network is unreachable)|Connection timed out during banner' <<< "$t"; then
        cause "сервер не отвечает — выключен или порт SSH закрыт firewall"
        todo "проверь, что сервер включён и порт SSH открыт у хостера"
      elif grep -qiE 'Permission denied \((publickey|password|keyboard)|Too many authentication failures' <<< "$t"; then
        cause "сервер не принял ключ или пароль"
        todo "добавь ключ: ssh-copy-id -p <порт> root@<адрес>" "проверь, что вход под root разрешён"
      else log_tail "$t"; return 1; fi ;;
    net)
      if grep -qE 'curl: \(6\)|Could not resolve host' <<< "$t"; then
        cause "сервер не может найти адрес — не работает DNS"; todo "проверь /etc/resolv.conf или поставь DNS 1.1.1.1"
      elif grep -qE 'curl: \((7|28|35|56)\)' <<< "$t"; then
        cause "нет связи с GitHub (блокировка или сбой сети)"
        todo "скачай remnapilot.sh из релиза на компьютер:" "  github.com/Dubstep2004/RemnaPilot/releases/latest" "скопируй на сервер и запусти: sudo bash remnapilot.sh"
      elif grep -qE 'curl: \(22\)|404' <<< "$t"; then
        cause "файла нет по этому адресу"; todo "проверь адрес или попробуй позже"
      else log_tail "$t"; return 1; fi ;;
    telegram)
      if grep -qiE '"error_code":401|Unauthorized' <<< "$t"; then
        cause "неверный токен бота"; todo "возьми токен у @BotFather → /mybots → API Token"
      elif grep -qiE 'chat not found' <<< "$t"; then
        cause "бот не знает этот чат"; todo "открой бота в Telegram и нажми Start (/start)"
      elif grep -qiE 'bot was blocked|user is deactivated' <<< "$t"; then
        cause "бот заблокирован в Telegram"; todo "открой бота и разблокируй его"
      elif grep -qiE 'Too Many Requests|"error_code":429' <<< "$t"; then
        cause "Telegram ограничил частоту сообщений"; todo "подожди минуту"
      elif [[ -z "$t" ]] || grep -qE 'curl: \(' <<< "$t"; then
        cause "нет связи с api.telegram.org — в РФ он часто заблокирован"
        todo "отправка работает с серверов за границей" "или пропиши прокси: export https_proxy=… в /etc/environment"
      else log_tail "$t" 3; return 1; fi ;;
  esac
  return 0
}

why_short() { # вид, лог → одна строка причины без цвета (для журнала и Telegram); пусто, если не узнали
  ( RP_LANG=ru C_WARN="" C_ACC="" C0="" C_MUT=""; why "$1" "$2" 2>/dev/null ) | sed -n 's/^ *Причина: *//p' | head -1
}

why_first() { # лог, виды… — первая узнанная причина; иначе последние строки лога
  local t="$1" k o; shift
  for k; do o=$(why "$k" "$t") && { printf '%s\n' "$o"; return 0; }; done
  log_tail "$t"; return 1
}
