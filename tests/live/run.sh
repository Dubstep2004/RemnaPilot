#!/bin/bash
# Проверка на НАСТОЯЩЕЙ Remnawave: ставит панель по официальной инструкции (docs.rw) и гоняет RemnaPilot.
# Запускается в GitHub Actions (.github/workflows/live.yml) на чистой машине. На своём сервере НЕ запускать:
# тест ставит и ломает панель в /opt/remnawave.
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RP="$ROOT/remnapilot.sh"
RW=/opt/remnawave
FAILS=0; PASSES=0

[[ -n "${CI:-}${RP_LIVE_FORCE:-}" ]] || { echo "Только для CI (или RP_LIVE_FORCE=1 на одноразовой машине)"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Нужен root"; exit 1; }
[[ -e "$RW/.env" && -z "${RP_LIVE_FORCE:-}" ]] && { echo "Панель уже установлена — тест её сломает. Выход."; exit 1; }

ok()   { printf '  \e[32m✔\e[0m %s\n' "$1"; PASSES=$((PASSES + 1)); }
bad()  { printf '  \e[31m✖ %s\e[0m\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
has()  { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else bad "$1 — нет «$2»"; printf '%s\n' "$3" | tail -25 | sed 's/^/      │ /'; fi; }
sec()  { printf '\n\e[1m▸ %s\e[0m\n' "$1"; }
plain() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r'; }
noerr() { check "$1: без ошибок bash" '! grep -qE "line [0-9]+:|command not found|syntax error|unbound variable|bad substitution" <<< "$2"'; }
rw()   { bash "$RP" "$@" 2>&1 | plain; }
F="$(mktemp)"; awk '/^# ---------- старт/{exit} {print}' "$RP" > "$F"
fn()   { bash -c 'source "'"$F"'"; RW_DIR='"$RW"'; JOURNAL=/var/log/remnapilot.log; '"$1" 2>&1 | plain; }
psql_q() { docker exec remnawave-db psql -U postgres -d postgres -tAc "$1" 2>&1; }
panel_up() { # ждёт, пока приложение панели работает и отвечает на порту
  local i; for i in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Status}}' remnawave 2>/dev/null)" == running ]] \
      && curl -s -o /dev/null --max-time 3 http://127.0.0.1:3000/ && return 0
    sleep 3
  done; return 1
}
envv() { grep -m1 "^$1=" "$RW/.env" | cut -d= -f2- | tr -d '"'; }

# ─────────────────────────────────────────────────────────────
sec "Установка Remnawave по docs.rw"
mkdir -p "$RW" && cd "$RW" || exit 1
curl -fsSL -o docker-compose.yml https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
curl -fsSL -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
for k in APP_SECRET METRICS_PASS WEBHOOK_SECRET_HEADER JWT_AUTH_SECRET JWT_API_TOKENS_SECRET; do
  grep -q "^$k=" .env && sed -i "s/^$k=.*/$k=$(openssl rand -hex 64)/" .env
done
pw=$(openssl rand -hex 24)
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^\@]*\(@.*\)|\1$pw\2|" .env
sed -i "s/^FRONT_END_DOMAIN=.*/FRONT_END_DOMAIN=panel.rp-live.test/" .env
sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=panel.rp-live.test/api/sub|" .env
docker compose up -d 2>&1 | tail -5
check "панель запустилась" panel_up
docker ps --format '   {{.Names}}  {{.Image}}  {{.Status}}'
cd "$ROOT" || exit 1
mkdir -p /etc/rw; touch "$HOME/.rw-nocmd"

# ─────────────────────────────────────────────────────────────
sec "Самопроверка и статус"
out=$(rw --selftest); noerr "selftest" "$out"; has "selftest видит Docker Compose" "Compose" "$out"
printf '%s\n' "$out" | sed -n '1,40p' | sed 's/^/      │ /'
out=$(rw --check-updates); noerr "check-updates" "$out"
out=$(rw --cert-status); noerr "cert-status" "$out"
out=$(fn 'apply_ui; dps_refresh; status_box_full'); noerr "рамка статуса" "$out"
has "статус: панель работает" "работает" "$out"
printf '%s\n' "$out" | sed 's/^/      │ /'

# ─────────────────────────────────────────────────────────────
sec "Смена домена"
out=$(rw --dry-run --skip-cert new.rp-live.test); noerr "предпросмотр" "$out"
check "предпросмотр ничего не поменял" '[[ "$(envv FRONT_END_DOMAIN)" == panel.rp-live.test ]]'
# домена нет в DNS → RemnaPilot спросит «всё равно применить?» → отвечаем «y»
out=$(printf 'y\n' | rw --skip-cert new.rp-live.test); noerr "смена домена" "$out"
has "предупредил, что домена нет в DNS" "не найден в DNS" "$out"
check "FRONT_END_DOMAIN сменился" '[[ "$(envv FRONT_END_DOMAIN)" == new.rp-live.test ]]'
check "SUB_PUBLIC_DOMAIN сменился вместе с панелью" '[[ "$(envv SUB_PUBLIC_DOMAIN)" == new.rp-live.test/api/sub ]]'
check "панель работает после смены домена" panel_up
check "в журнале — успех" 'grep -q "| OK    | Смена домена" /var/log/remnapilot.log'
out=$(printf '1\n' | fn 'rollback'); noerr "откат домена" "$out"
check "откат вернул старый домен" '[[ "$(envv FRONT_END_DOMAIN)" == panel.rp-live.test ]]'
check "панель работает после отката" panel_up

# ─────────────────────────────────────────────────────────────
sec "Бэкап и восстановление базы"
psql_q "CREATE TABLE rp_live_marker(v text); INSERT INTO rp_live_marker VALUES ('до бэкапа');" >/dev/null
out=$(fn 'backup_db live'); noerr "бэкап" "$out"
dump=$(ls -1t "$RW"/backups/db-*-live.sql.gz 2>/dev/null | head -1)
check "дамп создан и не пустой" '[[ -s "$dump" ]] && (( $(gzip -cd "$dump" | wc -l) > 100 ))'
check "в дампе есть данные панели" 'gzip -cd "$dump" | grep -q "rp_live_marker"'
psql_q "DROP TABLE rp_live_marker;" >/dev/null
check "маркер удалён перед восстановлением" '! psql_q "SELECT v FROM rp_live_marker" | grep -q "до бэкапа"'
out=$(printf 'YES\n' | fn "RESTORE_FILE='$dump' restore_db"); noerr "восстановление" "$out"
has "восстановление прошло" "База восстановлена" "$out"
check "данные вернулись из дампа" 'psql_q "SELECT v FROM rp_live_marker" | grep -q "до бэкапа"'
check "панель работает после восстановления" panel_up

out=$(rw --backup); noerr "автобэкап" "$out"
arc=$(ls -1t "$RW"/backups/remnawave-*.tar.gz 2>/dev/null | head -1)
check "архив автобэкапа создан" '[[ -s "$arc" ]]'
check "в архиве база, .env и только они" 'tar -tzf "$arc" | grep -q "\.sql\.gz$" && tar -tzf "$arc" | grep -q "remnawave.env"'

# ─────────────────────────────────────────────────────────────
sec "Обновление панели"
out=$(rw --update); rc=$?; noerr "обновление" "$out"
check "обновление прошло (код 0)" '[[ $rc == 0 ]]'
has "шаги с прогрессом" "4/4" "$out"
has "бэкап перед обновлением" "Бэкап БД" "$out"
check "панель работает после обновления" panel_up
printf '%s\n' "$out" | grep -E '/4|✔|✖' | sed 's/^/      │ /'

# ─────────────────────────────────────────────────────────────
sec "Понятные ошибки на настоящих сообщениях Docker"
cp -a "$RW/docker-compose.yml" /tmp/compose.good
sed -i -E 's~(image:[[:space:]]*["'"'"']?remnawave/backend:)[^"'"'"'[:space:]]+~\19.99.99-нет-такой~' "$RW/docker-compose.yml"
sed -i 's/9.99.99-нет-такой/9.99.99-does-not-exist/' "$RW/docker-compose.yml"
out=$(rw --update); rc=$?
check "несуществующая версия → ошибка" '[[ $rc != 0 ]]'
has "причина: такой версии образа нет" "такой версии образа нет" "$out"
has "подсказка, что делать" "Что делать:" "$out"
printf '%s\n' "$out" | grep -A4 '✖' | head -12 | sed 's/^/      │ /'
cp -a /tmp/compose.good "$RW/docker-compose.yml"
(cd "$RW" && docker compose up -d >/dev/null 2>&1)
check "панель вернулась после правильной версии" panel_up

cp -a "$RW/.env" /tmp/env.good
sed -i -E 's|^(DATABASE_URL="postgresql://postgres:)[^@]*(@.*)|\1wrong-password\2|' "$RW/.env"
out=$(rw --update); rc=$?
check "неверный пароль базы → панель не запустилась (код ≠ 0)" '[[ $rc != 0 ]]'
has "причина: пароль базы не совпадает" "пароль базы в .env не совпадает" "$out"
printf '%s\n' "$out" | grep -A4 '✖' | head -12 | sed 's/^/      │ /'
cp -a /tmp/env.good "$RW/.env"
(cd "$RW" && docker compose up -d --force-recreate >/dev/null 2>&1)
check "панель вернулась с правильным паролем" panel_up

# ─────────────────────────────────────────────────────────────
sec "Английский режим на настоящей панели"
out=$(RP_LANG=en bash "$RP" --update 2>&1 | plain); noerr "EN обновление" "$out"
left=$(perl -CSD -Mutf8 -ne 'print if /\p{Cyrillic}/' <<< "$out" | grep -v 'rp_live_marker\|до бэкапа' | sort -u)
check "в EN-выводе обновления нет русского" '[[ -z "$left" ]]'; [[ -n "$left" ]] && printf '%s\n' "$left" | head -10 | sed 's/^/      │ /'

# ─────────────────────────────────────────────────────────────
sec "Журнал"
out=$(fn 'apply_ui; journal_fmt all "" 30'); printf '%s\n' "$out" | sed 's/^/      │ /'
has "журнал по дням" "Сегодня," "$out"

echo
if (( FAILS )); then printf '\e[31mНе прошло: %d из %d\e[0m\n' "$FAILS" $((FAILS + PASSES)); exit 1; fi
printf '\e[32mВсе проверки на настоящей панели прошли: %d\e[0m\n' "$PASSES"
