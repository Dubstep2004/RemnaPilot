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
    info "Пересоздаю контейнеры, чтобы применить изменения..."; stack_down; stack_up; green "✓ Применено"
  elif (( ! issues )); then green "Всё в порядке."; fi
  echo "Бэкап старого .env лежит рядом: .env.bak-*"
}

reset_admin() { # «забыл пароль от панели»: сброс суперадмина через официальный Rescue CLI
  local ct a dom; ct=$(app_containers | head -1)
  [[ -n "$ct" ]] || { fail "Панель не запущена"; todo "запусти: cd $RW_DIR && docker compose up -d"; return 1; }
  [[ -t 0 ]] || { fail "Нужен терминал"; cause "Rescue CLI панели работает только в интерактивном окне SSH"; return 1; }
  dom=$(detect_old)
  echo "Пароль администратора панель хранит только в виде хеша — узнать его нельзя, можно только сбросить."
  echo "Сброс удаляет учётную запись суперадмина. Пользователи, ноды, хосты и настройки остаются."
  echo
  bold "Что будет:"
  echo "  1. Откроется Rescue CLI панели — выбери в нём сброс суперадмина (Reset superadmin) и подтверди."
  echo "     Если вход по паролю был выключен (только Telegram или OAuth) — там же можно включить его снова."
  echo "  2. Закрой Rescue CLI."
  echo "  3. Сразу открой ${dom:+https://$dom}${dom:-панель} в браузере и зарегистрируй нового администратора."
  yel "  Первый, кто откроет панель после сброса, станет администратором — не откладывай шаг 3."
  echo
  ask "Сбросить суперадмина? Это нельзя отменить [y/N]"; read -r a; [[ "$a" =~ ^[Yy]$ ]] || { echo "  Отменено."; return $RP_CANCEL; }
  docker exec -it "$ct" cli
  echo
  green "Готово. Теперь открой ${dom:+https://$dom}${dom:-панель} и зарегистрируй администратора."
}

security_menu() {
  while true; do
    screen "Безопасность"
    item 1 "Проверить и исправить секреты, пароль БД, открытые порты"
    item 2 "Забыл пароль от панели" "сброс суперадмина · Rescue CLI"
    hr; item 0 "Назад"
    ask; read -r c
    case "$c" in 1) run_action "Безопасность: проверка" security_check; pause ;; 2) run_action "Сброс пароля панели" reset_admin; pause ;; 0|q) return ;; esac
  done
}

