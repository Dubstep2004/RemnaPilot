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

