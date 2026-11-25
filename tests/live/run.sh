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
noerr() { # название, вывод — нет ошибок самого bash
  local e; e=$(grep -E "line [0-9]+:|command not found|syntax error|unbound variable|bad substitution" <<< "$2")
  if [[ -z "$e" ]]; then ok "$1: без ошибок bash"; else bad "$1: ошибки bash"; printf '%s\n' "$e" | head -5 | sed 's/^/      │ /'; fi
}
rw()   { bash "$RP" "$@" 2>&1 | plain; }
F="$(mktemp)"; awk '/^# ---------- старт/{exit} {print}' "$RP" > "$F"
fn()   { bash -c 'source "'"$F"'"; RW_DIR='"$RW"'; JOURNAL=/var/log/remnapilot.log; '"$1" 2>&1 | plain; }
psql_q() { docker exec remnawave-db psql -U postgres -d postgres -tAc "$1" 2>&1; }
panel_up() { # ждёт, пока контейнер панели здоров (healthcheck образа), до 3 минут
  local i st; for i in $(seq 1 60); do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' remnawave 2>/dev/null)
    [[ "$st" == "running healthy" ]] && return 0
    sleep 3
  done; echo "      │ состояние панели: $st"; return 1
}
envv() { grep -m1 "^$1=" "$RW/.env" | cut -d= -f2- | tr -d '"'; }

# ─────────────────────────────────────────────────────────────
sec "Установка панели через RemnaPilot (Панель → Установить панель)"
mkdir -p /etc/rw; touch "$HOME/.rw-nocmd"
# домены не существуют → RemnaPilot предупредит и спросит (y); веб-сервер 1 = nginx;
# Let's Encrypt для .test не выпустит → на «другой способ?» отвечаем 0 — панель остаётся с временным сертификатом
out=$(printf 'panel.rp-live.test\nsub.rp-live.test\ny\n1\n0\n' | fn 'apply_ui; panel_install; echo "rc=$?"')
noerr "установка панели" "$out"
printf '%s\n' "$out" | grep -E '/6|✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "шаги установки 6/6" "6/6" "$out"
has "честно: сертификат не выпущен (домен .test)" "Сертификат Let's Encrypt не выпущен" "$out"
check "панель запустилась" panel_up
check "nginx запущен" '[[ "$(docker inspect -f "{{.State.Status}}" remnawave-nginx 2>/dev/null)" == running ]]'
check "конфиг nginx правильный (nginx -t)" 'docker exec remnawave-nginx nginx -t >/dev/null 2>&1'
check "секреты случайные" '[[ "$(envv APP_SECRET)" =~ ^[0-9a-f]{128}$ ]]'
check "домены в .env" '[[ "$(envv FRONT_END_DOMAIN)" == panel.rp-live.test && "$(envv SUB_PUBLIC_DOMAIN)" == sub.rp-live.test ]]'
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve panel.rp-live.test:443:127.0.0.1 https://panel.rp-live.test/)
check "панель открывается через nginx (HTTP $code)" '[[ "$code" =~ ^[23] ]]'
body=$(curl -sk --max-time 10 --resolve sub.rp-live.test:443:127.0.0.1 https://sub.rp-live.test/nonexistent-short-uuid)
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve sub.rp-live.test:443:127.0.0.1 https://sub.rp-live.test/nonexistent-short-uuid)
echo "      │ подписка: HTTP $code · $(head -c 160 <<< "$body")"
check "домен подписки доходит до панели (не 502 и не ошибка nginx)" '[[ "$code" =~ ^[0-9]+$ && "$code" != 502 && "$code" != 000 ]] && ! grep -qi "<center>nginx" <<< "$body"'
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve other.rp-live.test:443:127.0.0.1 https://other.rp-live.test/)
check "чужой домен отклоняется (ssl_reject_handshake)" '[[ "$code" == 000 ]]'
out=$(printf 'x\n\n1\n' | fn 'panel_install'); has "повторная установка — отказ" "Панель уже установлена" "$out"
docker ps --format '   {{.Names}}  {{.Image}}  {{.Status}}'
cd "$ROOT" || exit 1

# ─────────────────────────────────────────────────────────────
sec "Самопроверка и статус"
out=$(rw --selftest); noerr "selftest" "$out"; has "selftest видит Docker Compose" "docker compose" "$out"
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
check "отдельный домен подписки не тронут" '[[ "$(envv SUB_PUBLIC_DOMAIN)" == sub.rp-live.test ]]'
check "nginx: server_name сменился" 'grep -q "server_name new.rp-live.test;" "$RW/nginx/nginx.conf"'
check "nginx после смены домена работает" 'docker exec remnawave-nginx nginx -t >/dev/null 2>&1'
check "панель работает после смены домена" panel_up
check "в журнале — успех" 'grep -q "| OK    | Смена домена$" /var/log/remnapilot.log'
check "предпросмотр записан в журнал как предпросмотр" 'grep -q "Предпросмотр смены домена" /var/log/remnapilot.log'
out=$(printf '1\n' | fn 'rollback'); noerr "откат домена" "$out"
check "откат вернул старый домен" '[[ "$(envv FRONT_END_DOMAIN)" == panel.rp-live.test ]]'
check "панель работает после отката" panel_up

# ─────────────────────────────────────────────────────────────
sec "Бэкап и восстановление базы"
psql_q "CREATE TABLE rp_live_marker(v text); INSERT INTO rp_live_marker VALUES ('до бэкапа');" >/dev/null
out=$(fn 'backup_db live'); noerr "бэкап" "$out"
dump=$(ls -1t "$RW"/backups/db-*-live.sql.gz 2>/dev/null | head -1)
check "дамп создан и не пустой" '[[ -s "$dump" ]] && (( $(zcat "$dump" | wc -l) > 100 ))'
zcat "$dump" > /tmp/dump.sql
check "в дампе есть данные панели" 'grep -q "rp_live_marker" /tmp/dump.sql'
psql_q "DROP TABLE rp_live_marker;" >/dev/null
check "маркер удалён перед восстановлением" '! psql_q "SELECT v FROM rp_live_marker" | grep -q "до бэкапа"'
out=$(printf 'YES\n' | fn "RESTORE_FILE='$dump' restore_db"); noerr "восстановление" "$out"
has "восстановление прошло" "База восстановлена" "$out"
check "данные вернулись из дампа" 'psql_q "SELECT v FROM rp_live_marker" | grep -q "до бэкапа"'
check "панель работает после восстановления" panel_up

head -c 3000 "$dump" > /tmp/broken.sql.gz
out=$(printf 'YES\n' | fn "RESTORE_FILE=/tmp/broken.sql.gz restore_db")
has "обрезанный дамп — понятная ошибка" "Дамп повреждён" "$out"
check "…и база не тронута" 'psql_q "SELECT v FROM rp_live_marker" | grep -q "до бэкапа"'

out=$(rw --backup); noerr "автобэкап" "$out"
arc=$(ls -1t "$RW"/backups/remnawave-*.tar.gz 2>/dev/null | head -1)
check "архив автобэкапа создан" '[[ -s "$arc" ]]'
list=$(tar -tzf "$arc" 2>&1)
check "в архиве дамп базы и .env" 'grep -q "\.sql\.gz$" <<< "$list" && grep -q "remnawave.env" <<< "$list"'

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
sec "Смена домена ноды (на настоящей базе)"
psql_q "INSERT INTO nodes (name, address, port) VALUES ('rp-live-node', 'old-node.rp-live.test', 2222);
        INSERT INTO hosts (remark, address, port, sni) VALUES ('rp-live-host', 'old-node.rp-live.test', 443, 'old-node.rp-live.test');" >/dev/null
n=$(psql_q "SELECT count(*) FROM nodes WHERE view_position <= (SELECT view_position FROM nodes WHERE name = 'rp-live-node')")
out=$(printf '%s\nnew-node.rp-live.test\ny\n' "$n" | fn 'apply_ui; node_domain_change; echo "rc=$?"'); noerr "смена домена ноды" "$out"
printf '%s\n' "$out" | grep -E '/3|✔|✖|⚠|→|rc=' | sed 's/^/      │ /'
check "адрес ноды сменился" '[[ "$(psql_q "SELECT address FROM nodes WHERE name = '"'"'rp-live-node'"'"'")" == new-node.rp-live.test ]]'
check "адрес и SNI хоста сменились" '[[ "$(psql_q "SELECT address || '"'"' '"'"' || sni FROM hosts WHERE remark = '"'"'rp-live-host'"'"'")" == "new-node.rp-live.test new-node.rp-live.test" ]]'
check "бэкап перед сменой сделан" 'ls "$RW"/backups/db-*-node-domain.sql.gz >/dev/null 2>&1'
check "панель работает после смены домена ноды" panel_up

sec "Firewall: список правил"
out=$(fn 'apply_ui; fw_rules'); noerr "список правил" "$out"; printf '%s\n' "$out" | head -12 | sed 's/^/      │ /'
has "список показывает порт панели" "443" "$out"

sec "Журнал"
out=$(fn 'apply_ui; journal_fmt all "" 30'); printf '%s\n' "$out" | sed 's/^/      │ /'
has "журнал по дням" "Сегодня," "$out"

# ─────────────────────────────────────────────────────────────
sec "v2.8: доступ к API (логин админа → токен)"
API="http://127.0.0.1:3000"; H=(-H "X-Forwarded-For: 127.0.0.1" -H "X-Forwarded-Proto: https" -H "Content-Type: application/json")
APASS="RpLive-Passw0rd-$(openssl rand -hex 8)A1"
reg=$(curl -s "${H[@]}" -d "{\"username\":\"rpadmin\",\"password\":\"$APASS\"}" "$API/api/auth/register")
check "админ зарегистрирован через API" 'grep -q accessToken <<< "$reg"' || echo "      │ $reg" | head -c 300
out=$(printf '\nrpadmin\nwrong-password\n' | fn 'apply_ui; api_ready; echo "rc=$?"'); has "неверный пароль — понятно" "неверный логин или пароль" "$out"
out=$(printf '\nrpadmin\n%s\n' "$APASS" | fn 'apply_ui; api_ready; echo "rc=$?"'); noerr "api_ready" "$out"
has "токен создан и сохранён" "Доступ к API сохранён" "$out"
check "…файл токена только для root" '[[ "$(stat -c %a /etc/rw/api.token)" == 600 ]]'
out=$(fn 'api GET /api/keygen && echo "OK $API_CODE"'); has "API отвечает с сохранённым токеном" "OK 200" "$out"
out=$(fn 'api_ready; echo "rc=$?"'); has "повторно токен не спрашивает" "rc=0" "$out"
check "…и вопросов не было" '! grep -q "API-токен" <<< "$out"'

sec "v2.8: панель и нода на одном сервере"
out=$(printf '\n\n\n' | fn 'apply_ui; panel_node_local; echo "rc=$?"'); noerr "нода на сервере панели" "$out"
printf '%s\n' "$out" | grep -E '/4|✔|✖|⚠|rc=' | sed 's/^/      │ /'
check "контейнер remnanode запущен" '[[ "$(docker inspect -f "{{.State.Status}}" remnanode 2>/dev/null)" == running ]]'
check "в compose ноды есть NET_ADMIN" 'grep -q NET_ADMIN /opt/remnanode/docker-compose.yml'
gw=$(docker network inspect remnawave-network -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
check "нода добавлена в панель с адресом шлюза ($gw)" '[[ -n "$gw" ]] && psql_q "SELECT address FROM nodes WHERE port = 2222" | grep -qx "$gw"'
has "панель подключилась к ноде" "Нода онлайн" "$out"
out=$(printf '\n' | fn 'apply_ui; panel_node_local; echo "rc=$?"'); has "повторно — нода уже стоит" "Нода на этом сервере уже стоит" "$out"

sec "v2.8: блокировка торрентов и рекламы (правила Xray через API)"
prof() { fn 'api GET /api/config-profiles >/dev/null; echo "$API_OUT"'; }
out=$(fn 'apply_ui; xr_toggle on torrent; echo "rc=$?"'); noerr "торренты вкл" "$out"; has "профили обновлены" "Обновлено профилей" "$out"
check "в профиле правило bittorrent → blackhole" 'prof | python3 -c "import json,sys; c=json.load(sys.stdin)[\"response\"][\"configProfiles\"][0][\"config\"]; r=c[\"routing\"][\"rules\"][0]; assert r[\"protocol\"]==[\"bittorrent\"]; assert any(o.get(\"protocol\")==\"blackhole\" and o.get(\"tag\")==r[\"outboundTag\"] for o in c[\"outbounds\"])"'
out=$(fn 'apply_ui; xr_toggle on ads; echo "rc=$?"'); has "реклама вкл" "Обновлено профилей" "$out"
out=$(fn 'xr_status torrent; xr_status ads'); check "статус: обе блокировки включены" '[[ "$(tr "\n" " " <<< "$out")" =~ ^[1-9]/[0-9]+\ [1-9]/[0-9]+ ]]'
out=$(fn 'apply_ui; xr_toggle off ads; xr_toggle off torrent; echo "rc=$?"'); has "выключены" "rc=0" "$out"
check "правил RemnaPilot в профилях не осталось" '! prof | grep -q "rp-torrent\|rp-ads"'
out=$(fn 'apply_ui; tb_plugin on; echo "rc=$?"'); noerr "Torrent Blocker" "$out"
printf '%s\n' "$out" | grep -E '✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "Torrent Blocker включён" "Torrent Blocker включён" "$out"
has "…плагин подключён к ноде" "плагин подключён" "$out"
has "…NET_ADMIN у ноды уже есть" "NET_ADMIN уже есть" "$out"
check "плагин RemnaPilot в базе" 'psql_q "SELECT count(*) FROM node_plugin WHERE name = '"'"'RemnaPilot'"'"'" | grep -qx 1'
out=$(fn 'tb_state'); has "состояние: вкл" "вкл" "$out"
out=$(fn 'apply_ui; tb_plugin off; tb_state'); has "выключен" "выкл" "$out"

sec "v2.8: закрыть вход в панель (nginx)"
cp -a "$RW/nginx/nginx.conf" /tmp/nginx.before-access
pc() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve panel.rp-live.test:443:127.0.0.1 "$@"; }
out=$(printf '203.0.113.7\n' | fn 'apply_ui; acc_ips_ask; echo "rc=$?"'); noerr "только IP" "$out"; has "закрыто по IP" "Вход в панель закрыт" "$out"
check "nginx принял конфиг" 'docker exec remnawave-nginx nginx -t >/dev/null 2>&1'
code=$(pc https://panel.rp-live.test/); check "чужому IP — 404 (HTTP $code)" '[[ "$code" == 404 ]]'
out=$(fn 'apply_ui; acc_key_new; echo "rc=$?"'); has "секретная ссылка" "Секретная ссылка: https://panel.rp-live.test/" "$out"
key=$(grep -m1 '^KEY=' /etc/rw/access.conf | cut -d= -f2)
code=$(pc "https://panel.rp-live.test/$key"); check "ссылка ставит куку и перекидывает в панель (HTTP $code)" '[[ "$code" == 302 ]]'
hdr=$(curl -sk -D - -o /dev/null --max-time 10 --resolve panel.rp-live.test:443:127.0.0.1 "https://panel.rp-live.test/$key")
check "…кука Secure, HttpOnly" 'grep -qi "set-cookie: rp_key=$key; Path=/; Max-Age=31536000; Secure; HttpOnly" <<< "$hdr"'
code=$(pc -H "Cookie: rp_key=$key" https://panel.rp-live.test/); check "с кукой панель открывается (HTTP $code)" '[[ "$code" =~ ^[23] ]]'
code=$(pc -H "Cookie: rp_key=wrong" https://panel.rp-live.test/); check "с чужой кукой — 404" '[[ "$code" == 404 ]]'
code=$(pc https://panel.rp-live.test/api/sub/nonexistent); body=$(curl -sk --max-time 10 --resolve panel.rp-live.test:443:127.0.0.1 https://panel.rp-live.test/api/sub/nonexistent)
check "подписка на домене панели доходит до панели (не страница nginx)" '! grep -qi "<center>nginx" <<< "$body"'
out=$(fn 'apply_ui; acc_off; echo "rc=$?"'); has "открыт для всех" "открыт для всех" "$out"
check "конфиг nginx вернулся как был" 'cmp -s "$RW/nginx/nginx.conf" /tmp/nginx.before-access'
code=$(pc https://panel.rp-live.test/); check "панель снова открывается (HTTP $code)" '[[ "$code" =~ ^[23] ]]'

sec "v2.8: защита от перебора пароля (nginx + fail2ban)"
out=$(fn 'apply_ui; bf_enable; echo "rc=$?"'); noerr "перебор" "$out"
printf '%s\n' "$out" | grep -E '/3|✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "включено" "rc=0" "$out"
check "nginx принял конфиг" 'docker exec remnawave-nginx nginx -t >/dev/null 2>&1'
check "каталог логов подключён к nginx" 'docker inspect -f "{{range .Mounts}}{{.Destination}} {{end}}" remnawave-nginx | grep -qw /var/log/rp'
codes=""; for i in $(seq 1 16); do codes+="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve panel.rp-live.test:443:127.0.0.1 -H 'Content-Type: application/json' -d '{"username":"rpadmin","password":"wrong"}' https://panel.rp-live.test/api/auth/login) "; done
echo "      │ коды: $codes"
check "неверный пароль доходит до панели (4xx, не 502)" 'grep -qE "(^| )4(0[0-3]) " <<< " $codes"'
check "после 10 попыток — 429" 'grep -q "429" <<< "$codes"'
check "попытки входа пишутся в лог" '[[ -s /var/log/remnawave-panel/auth.log ]]'
m=$(fail2ban-regex /var/log/remnawave-panel/auth.log /etc/fail2ban/filter.d/remnawave-panel.conf 2>&1 | grep -m1 -oE "Failregex: [0-9]+ total" | grep -oE "[0-9]+")
check "фильтр fail2ban узнаёт неудачные входы ($m)" '(( ${m:-0} >= 10 ))'
check "jail fail2ban запущен" 'fail2ban-client status remnawave-panel >/dev/null 2>&1'
out=$(fn 'apply_ui; bf_disable; echo "rc=$?"'); has "выключено" "Защита от перебора выключена" "$out"
check "nginx после выключения работает" 'docker exec remnawave-nginx nginx -t >/dev/null 2>&1'
check "jail удалён" '! fail2ban-client status remnawave-panel >/dev/null 2>&1'

sec "v2.8: страница подписки"
out=$(printf '\n' | fn 'apply_ui; subpage_install; echo "rc=$?"'); noerr "страница подписки" "$out"
printf '%s\n' "$out" | grep -E '/4|✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "установлена" "rc=0" "$out"
check "контейнер страницы подписки запущен" '[[ "$(docker inspect -f "{{.State.Status}}" remnawave-subscription-page 2>/dev/null)" == running ]]'
check "nginx: домен подписки → страница подписки" 'grep -q "proxy_pass http://remnawave-subscription-page:3010;" "$RW/nginx/nginx.conf"'
check "nginx принял конфиг" 'docker exec remnawave-nginx nginx -t >/dev/null 2>&1'
for i in $(seq 1 15); do code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve sub.rp-live.test:443:127.0.0.1 https://sub.rp-live.test/nonexistent); [[ "$code" != 502 ]] && break; sleep 2; done
[[ "$code" == 502 ]] && docker logs --tail 30 remnawave-subscription-page 2>&1 | sed 's/^/      │ /'
check "домен подписки отвечает страницей (HTTP $code, не 502)" '[[ "$code" =~ ^[0-9]+$ && "$code" != 502 && "$code" != 000 ]]'
check "в .env страницы — токен API" 'grep -q "^REMNAWAVE_API_TOKEN=..*" "$RW/subscription/.env"'
out=$(printf 'y\n' | fn 'apply_ui; subpage_remove; echo "rc=$?"'); has "убрана" "Страница подписки убрана" "$out"
check "контейнер страницы удалён" '! docker ps -a --format "{{.Names}}" | grep -qx remnawave-subscription-page'
check "nginx снова отдаёт подписку из панели" 'grep -q "proxy_pass http://remnawave/api/sub/;" "$RW/nginx/nginx.conf" && docker exec remnawave-nginx nginx -t >/dev/null 2>&1'

sec "v2.8: переустановка панели с сохранением данных"
nodes_before=$(psql_q "SELECT count(*) FROM nodes")
out=$(printf 'y\n' | fn 'apply_ui; panel_reinstall; echo "rc=$?"'); noerr "переустановка" "$out"
printf '%s\n' "$out" | grep -E '/5|✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "переустановлена" "Панель переустановлена" "$out"
check "панель работает" panel_up
check "данные на месте (маркер)" 'psql_q "SELECT v FROM rp_live_marker" | grep -q "до бэкапа"'
check "ноды на месте ($nodes_before)" '[[ "$(psql_q "SELECT count(*) FROM nodes")" == "$nodes_before" ]]'
out=$(fn 'api GET /api/keygen && echo "OK $API_CODE"'); has "API-токен работает после переустановки" "OK 200" "$out"
check "nginx работает" '[[ "$(docker inspect -f "{{.State.Status}}" remnawave-nginx 2>/dev/null)" == running ]]'

sec "v2.8: selfsteal на этом сервере"
out=$(printf '1\nss.rp-live.test\n\n0\n' | fn 'apply_ui; selfsteal_install; echo "rc=$?"'); noerr "selfsteal" "$out"
printf '%s\n' "$out" | grep -E '/3|✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "Caddy работает" "Caddy работает" "$out"
check "контейнер selfsteal запущен" '[[ "$(docker inspect -f "{{.State.Status}}" selfsteal 2>/dev/null)" == running ]]'
check "сайт слушает только 127.0.0.1:9443" 'ss -ltnH "sport = :9443" | grep -q "127.0.0.1:9443" && ! ss -ltnH "sport = :9443" | grep -q "0.0.0.0:9443"'
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ -H 'Host: ss.rp-live.test'); check "порт 80 перекидывает на https (HTTP $code)" '[[ "$code" == 301 || "$code" == 308 ]]'
out=$(printf '1\n' | fn 'apply_ui; selfsteal_remove'); has "selfsteal удалён" "selfsteal удалён" "$out"
check "контейнер selfsteal удалён" '! docker ps -a --format "{{.Names}}" | grep -qx selfsteal'

sec "v2.8: IPv6"
v6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
out=$(printf '1\n' | fn 'apply_ui; ipv6_set off; echo "rc=$?"'); noerr "IPv6 выкл" "$out"; has "выключен" "IPv6 выключен" "$out"
check "IPv6 выключен в ядре" '[[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == 1 ]]'
check "настройка сохранится после перезагрузки" '[[ -f /etc/sysctl.d/99-remnapilot-ipv6.conf ]]'
out=$(printf '1\n' | fn 'apply_ui; ipv6_set on; echo "rc=$?"'); has "включён" "IPv6 включён" "$out"
check "IPv6 снова включён" '[[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == 0 && ! -f /etc/sysctl.d/99-remnapilot-ipv6.conf ]]'
check "панель работает" panel_up

sec "v2.8: меню на английском — новые экраны"
for n in 2 4 5 20 21 22 28 29 30 35; do
  o=$(printf '%s\n\n\n0\n\n0\n0\n0\n' "$n" | RP_LANG=en RP_NO_LIVE=1 TERM=xterm-256color timeout 60 script -qc "bash '$RP'" /dev/null 2>&1 | plain)
  left=$(perl -CSD -Mutf8 -ne 'print if /\p{Cyrillic}/ && !/Язык|Русский/' <<< "$o" | sort -u)
  check "пункт $n на английском" '[[ -z "$left" ]]'; [[ -n "$left" ]] && printf '%s\n' "$left" | head -5 | sed 's/^/      │ /'
done
docker rm -f remnanode >/dev/null 2>&1; rm -rf /opt/remnanode

# ─────────────────────────────────────────────────────────────
sec "Удаление ноды (на этом сервере)"
mkdir -p /opt/remnanode && printf 'services:\n  remnanode:\n    image: alpine:3.20\n    container_name: remnanode\n    command: sleep infinity\n' > /opt/remnanode/docker-compose.yml
(cd /opt/remnanode && docker compose up -d >/dev/null 2>&1)
check "тестовая нода запущена" '[[ "$(docker inspect -f "{{.State.Status}}" remnanode 2>/dev/null)" == running ]]'
out=$(printf '1\nнет\n' | fn 'apply_ui; node_uninstall; echo "rc=$?"'); has "без слова УДАЛИТЬ — отмена" "rc=10" "$out"
check "…нода на месте" '[[ -d /opt/remnanode ]]'
out=$(printf '1\nУДАЛИТЬ\n' | fn 'apply_ui; node_uninstall; echo "rc=$?"'); noerr "удаление ноды" "$out"
printf '%s\n' "$out" | grep -E '/2|✔|✖|rc=' | sed 's/^/      │ /'
check "контейнер ноды удалён" '! docker ps -a --format "{{.Names}}" | grep -qx remnanode'
check "каталог ноды удалён" '[[ ! -e /opt/remnanode ]]'

sec "Удаление панели"
out=$(printf 'УДАЛИТЬ\n' | fn 'apply_ui; panel_uninstall; echo "rc=$?"'); noerr "удаление панели" "$out"
printf '%s\n' "$out" | grep -E '/4|✔|✖|⚠|rc=' | sed 's/^/      │ /'
has "панель удалена" "Панель удалена" "$out"
check "контейнеры панели удалены" '! docker ps -a --format "{{.Names}}" | grep -qE "^(remnawave|remnawave-db|remnawave-redis|remnawave-nginx)$"'
check "данные базы удалены (том)" '! docker volume ls --format "{{.Name}}" | grep -q remnawave-db-data'
check "каталог панели удалён" '[[ ! -e /opt/remnawave ]]'
bk=$(ls -1t /root/remnawave-removed-*.tar.gz 2>/dev/null | head -1)
check "последний бэкап сохранён вне панели" '[[ -s "$bk" ]] && tar -tzf "$bk" | grep -q "\.sql\.gz$"'
zdump=$(tar -xzOf "$bk" --wildcards "*.sql.gz" 2>/dev/null | zcat 2>/dev/null)
check "…и в нём настоящие данные (маркер из теста бэкапа)" 'grep -q rp_live_marker <<< "$zdump"'

echo
if (( FAILS )); then printf '\e[31mНе прошло: %d из %d\e[0m\n' "$FAILS" $((FAILS + PASSES)); exit 1; fi
printf '\e[32mВсе проверки на настоящей панели прошли: %d\e[0m\n' "$PASSES"
