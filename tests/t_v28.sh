# v2.8: вход в панель, перебор пароля, правила Xray, selfsteal, IPv6, API, страница подписки, новые разделы меню
source "$(dirname "$0")/lib.sh"
F=$(funcs)
run() { bash -c 'source "'"$F"'"; C_WARN= C_ACC= C0= C_MUT= C_OK= C_ERR= CB= C_LINE=; RW_DIR="'"$T"'/p"; JOURNAL=/dev/null
  ACCESS_CONF="'"$T"'/access.conf"; F2B_JAIL="'"$T"'/jail.local"; F2B_FILTER="'"$T"'/filter.conf"; API_CONF="'"$T"'/api.token"; BF_LOG_DIR="'"$T"'/logs"
  detect_old() { echo panel.example.com; }; '"$1" 2>&1 | nocolor; }
mkp() { # $1 = nginx|caddy
  rm -rf "$T/p"; mkdir -p "$T/p/backups"
  printf 'FRONT_END_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > "$T/p/.env"
  rm -f "$T/access.conf" "$T/jail.local" "$T/filter.conf"
  if [ "$1" = caddy ]; then mkdir -p "$T/p/caddy"; run 'pi_caddyfile panel.example.com sub.example.com' > "$T/p/caddy/Caddyfile"; CF="$T/p/caddy/Caddyfile"
  else mkdir -p "$T/p/nginx"; run 'pi_nginx_conf panel.example.com sub.example.com' > "$T/p/nginx/nginx.conf"; CF="$T/p/nginx/nginx.conf"; fi
  cp "$CF" "$T/orig"
}
MOCK='need_panel() { return 0; }; proxy_reload() { echo RELOAD; return 0; }; panel_code() { [ -n "$1" ] && echo 200 || echo 404; }; proxy_find; '
blk() { awk -v d="$2" 'BEGIN{RS="\n}\n"} index($0,d) {print; exit}' "$1"; }   # блок сервера/сайта с доменом

# ── вход в панель: nginx ──
mkp nginx; ino=$(stat -c %i "$CF")
o=$(run "$MOCK"'echo "PROXY=$PROXY_KIND $PROXY_FILE"; acc_set IPS "203.0.113.7 10.1.0.0/16"; acc_apply')
out_has "nginx: конфиг панели найден" "PROXY=nginx $CF" "$o"
out_has "вход по IP: закрыт" "Вход в панель закрыт: только IP: 203.0.113.7 10.1.0.0/16" "$o"
check "geo со списком IP на уровне http (вне server)" 'awk "/rp-access-http begin/{f=1} f&&/^server/{exit 1} /203.0.113.7 1;/{ok=1} END{exit !ok}" "$CF"'
check "проверка вставлена в блок панели" 'blk "$CF" "server_name panel.example.com" | grep -q "rp_pass !~"'
check "…но не в блок подписки" '! blk "$CF" "server_name sub.example.com" | grep -q rp_pass'
check "подписка на домене панели (/api/sub/) пропускается" 'grep -q "\^/api/sub/" "$CF"'
check "файл правится на месте (тот же inode — docker видит изменения)" '[ "$(stat -c %i "$CF")" = "$ino" ]'
check "копия конфига до изменения" 'ls "$T"/p/backups/nginx.conf.access-* >/dev/null 2>&1'
o=$(run "$MOCK"'acc_set KEY abc123; acc_apply')
out_has "секретная ссылка показана" "https://panel.example.com/abc123" "$o"
out_has "…и по ней пускает" "По секретной ссылке пускает (HTTP 200)" "$o"
check "куку ставит location = /ключ" 'grep -q "location = /abc123" "$CF" && grep -q "rp_key=abc123; Path=/" "$CF"'
check "повторное применение не дублирует вставку" '[ "$(grep -c "rp-access begin" "$CF")" = 1 ] && [ "$(grep -c "rp-access-http begin" "$CF")" = 1 ]'
o=$(run "$MOCK"'acc_off')
out_has "открыть для всех" "открыт для всех" "$o"
check "выключение возвращает конфиг байт в байт" 'cmp -s "$CF" "$T/orig"'

# ── вход в панель: Caddy ──
mkp caddy
o=$(run "$MOCK"'echo "PROXY=$PROXY_KIND"; acc_set IPS "203.0.113.7"; acc_set KEY k9; acc_apply')
out_has "Caddy: конфиг панели найден" "PROXY=caddy" "$o"
check "Caddy: @rp_deny в блоке панели" 'blk "$CF" "https://panel.example.com" | grep -q "not remote_ip 203.0.113.7"'
check "Caddy: кука и путь ключа" 'grep -q "@rp_key path /k9" "$CF" && grep -q "rp_key=k9(;|\$)" "$CF"'
check "Caddy: блок подписки не тронут" '! blk "$CF" "https://sub.example.com" | grep -q rp_'
run "$MOCK"'acc_off' >/dev/null
check "Caddy: выключение возвращает конфиг байт в байт" 'cmp -s "$CF" "$T/orig"'

# ── ошибка в конфиге → откат ──
mkp nginx
o=$(run 'proxy_reload() { PROXY_LOG="nginx: [emerg] unknown directive"; cat "$PROXY_FILE" >> "'"$T"'/seen"; return 1; }; proxy_find; acc_set IPS 1.2.3.4; acc_apply; echo "rc=$?"')
out_has "nginx не принял конфиг → понятная ошибка" "Веб-сервер не принял новый конфиг" "$o"
out_has "…причина из nginx -t" "unknown directive" "$o"
check "…и конфиг вернулся как был" 'cmp -s "$CF" "$T/orig" && grep -q rp-access "$T/seen"'

# ── перебор пароля: nginx ──
mkp nginx; mkdir -p "$T/bin"
for t in fail2ban-client systemctl docker; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$t" "$T" > "$T/bin/$t"; done; chmod +x "$T/bin"/*
o=$(PATH="$T/bin:$PATH" run "$MOCK"'bf_nginx_mount() { return 0; }; bf_enable; echo "rc=$?"')
out_has "перебор: включено" "rc=0" "$o"
out_has "…лимит nginx" "Не больше 10 попыток входа в минуту" "$o"
out_has "…бан fail2ban" "5 неверных паролей за 10 минут" "$o"
check "location /api/auth/login с limit_req в блоке панели" 'blk "$CF" "server_name panel.example.com" | grep -q "location = /api/auth/login" && grep -q "limit_req zone=rp_login" "$CF"'
check "…проксирует туда же, куда location / (upstream remnawave)" 'grep -A12 "location = /api/auth/login" "$CF" | grep -q "proxy_pass http://remnawave;"'
check "…с заголовками для Remnawave (X-Forwarded-Proto)" 'grep -A14 "location = /api/auth/login" "$CF" | grep -q "X-Forwarded-Proto"'
check "limit_req_zone и log_format — на уровне http" 'awk "/rp-bf-http begin/{f=1} f&&/^server/{exit 1} /limit_req_zone/{ok=1} END{exit !ok}" "$CF"'
check "jail: лог входов, бан в DOCKER-USER, docker-сети не банятся" 'grep -q "logpath  = $T/logs/auth.log" "$T/jail.local" && grep -q "chain=DOCKER-USER" "$T/jail.local" && grep -q "172.16.0.0/12" "$T/jail.local"'
check "фильтр ловит неверный пароль" 'python3 - "$T/filter.conf" <<PY
import re,sys
r=[l.split("=",1)[1].strip() for l in open(sys.argv[1]) if l.startswith("failregex")][0].replace("<HOST>",r"(?P<host>\S+)")
assert re.search(r,"198.51.100.4 [25/Nov/2026:10:00:00 +0000] \"POST /api/auth/login HTTP/2.0\" 403")
assert not re.search(r,"198.51.100.4 [25/Nov/2026:10:00:00 +0000] \"POST /api/auth/login HTTP/2.0\" 200")
PY'
o=$(PATH="$T/bin:$PATH" run "$MOCK"'bf_disable')
out_has "перебор: выключено" "Защита от перебора выключена" "$o"
check "…конфиг вернулся байт в байт, jail удалён" 'cmp -s "$CF" "$T/orig" && [ ! -e "$T/jail.local" ]'
mkp caddy
o=$(PATH="$T/bin:$PATH" run "$MOCK"'bf_logpath() { echo "'"$T"'/data/rp-access.log"; }; bf_enable; echo "rc=$?"')
check "Caddy: лог доступа панели в /data" 'blk "$CF" "https://panel.example.com" | grep -q "output file /data/rp-access.log"'
check "Caddy: фильтр по JSON-логу" 'grep -q "client_ip" "$T/filter.conf" && grep -q "{EPOCH}" "$T/filter.conf"'
check "Caddy: фильтр ловит неверный пароль" 'python3 - "$T/filter.conf" <<PY
import re,sys
r=[l.split("=",1)[1].strip() for l in open(sys.argv[1]) if l.startswith("failregex")][0].replace("<HOST>",r"(?P<host>\S+)")
assert re.search(r,"{\"level\":\"info\",\"ts\":1764000000.1,\"request\":{\"remote_ip\":\"172.18.0.1\",\"client_ip\":\"198.51.100.4\",\"method\":\"POST\",\"host\":\"p\",\"uri\":\"/api/auth/login\"},\"status\":403}")
PY'

# ── страница подписки: свой блок подписки направляется на страницу ──
mkp nginx
run 'block_edit "'"$CF"'" sub.example.com '"'"'s{proxy_pass\s+[^;]+;}{proxy_pass http://remnawave-subscription-page:3010;}g'"'"''
check "подписка → страница подписки, панель не тронута" 'blk "$CF" "server_name sub.example.com" | grep -q "proxy_pass http://remnawave-subscription-page:3010;" && blk "$CF" "server_name panel.example.com" | grep -q "proxy_pass http://remnawave;"'
o=$(run 'sp_compose')
out_has "compose страницы подписки по docs.rw" "127.0.0.1:3010:3010" "$o"
out_has "…в сети панели" "external: true" "$o"

# ── API: токен не виден в списке процессов ──
cat > "$T/bin/curl" <<EOF
#!/bin/bash
echo "ARGS \$*" >> "$T/curl.log"
for a in "\$@"; do case "\$a" in @/dev/fd/*|@/proc/*) cat "\${a#@}" >> "$T/curl.log" ;; esac; done
printf '{"response":{"secretKey":"KEY1"}}\n200'
EOF
chmod +x "$T/bin/curl"; echo "tok-SECRET-1" > "$T/api.token"; : > "$T/curl.log"
o=$(PATH="$T/bin:$PATH" run 'api GET /api/keygen && echo "code=$API_CODE"; jget "j[\"response\"][\"secretKey\"]" <<< "$API_OUT"')
out_has "api: ответ и код" "code=200" "$o"
out_has "jget достаёт поле" "KEY1" "$o"
check "токен передан заголовком" 'grep -q "Authorization: Bearer tok-SECRET-1" "$T/curl.log"'
check "…но не в аргументах curl" '! grep "^ARGS" "$T/curl.log" | grep -q "tok-SECRET-1"'
check "заголовки как от reverse proxy" 'grep "^ARGS" "$T/curl.log" | grep -q "X-Forwarded-Proto: https"'

# ── правила Xray во всех профилях ──
P='{"response":{"configProfiles":[{"uuid":"u1","name":"Default","config":{"inbounds":[{"tag":"vless","port":443}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"}],"routing":{"rules":[{"ip":["geoip:private"],"outboundTag":"BLOCK"}]}}}]}}'
o=$(run 'python3 -c "$XR_PY" on torrent <<< '"'$P'")
check "торренты: правило первым, blackhole добавлен, sniffing включён" 'python3 -c "
import json,sys
l=sys.argv[1].splitlines(); c=json.loads(l[0])[\"config\"]
r=c[\"routing\"][\"rules\"][0]; assert r[\"protocol\"]==[\"bittorrent\"] and r[\"ruleTag\"]==\"rp-torrent\", r
assert any(o[\"protocol\"]==\"blackhole\" and o[\"tag\"]==r[\"outboundTag\"] for o in c[\"outbounds\"])
assert c[\"inbounds\"][0][\"sniffing\"][\"enabled\"] and l[-1]==\"#sniff\t1\"
" "$o"'
P2=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["response"]["configProfiles"][0]["config"]=json.loads(sys.argv[2].splitlines()[0])["config"]; print(json.dumps(d))' "$P" "$o")
o2=$(run 'python3 -c "$XR_PY" on torrent <<< '"'$P2'")
check "торренты: повторно — правило не дублируется" '[ "$(grep -o rp-torrent <<< "$o2" | wc -l)" = 1 ]'
o3=$(run 'python3 -c "$XR_PY" status torrent <<< '"'$P2'"'; python3 -c "$XR_PY" status ads <<< '"'$P2'")
check "статус: торренты вкл, реклама выкл" '[ "$(echo "$o3" | cut -f1 | tr -d "\n")" = 10 ]'
o4=$(run 'python3 -c "$XR_PY" off torrent <<< '"'$P2'")
check "торренты выкл: правило убрано, своё правило пользователя осталось" 'grep -q geoip:private <<< "$o4" && ! grep -q rp-torrent <<< "$o4"'
o5=$(run 'python3 -c "$XR_PY" on ads <<< '"'$P'")
check "реклама: geosite:category-ads-all" 'grep -q "geosite:category-ads-all" <<< "$o5"'
o6=$(run 'python3 -c "$XR_PY" off ads <<< '"'$P'")
check "выключать нечего — профиль не трогаем" '[ "$(grep -vc "^#" <<< "$o6")" = 0 ]'

# ── Torrent Blocker, Reality ──
o=$(run 'python3 -c "$TB_PY" cfg p1 on <<< "{\"response\":{\"uuid\":\"p1\",\"pluginConfig\":null}}"')
out_has "Torrent Blocker: включён в конфиге плагина" '"torrentBlocker": {"blockDuration": 3600, "ignoreLists": {"ip": []}, "enabled": true}' "$o"
R='{"response":{"configProfiles":[{"uuid":"u1","name":"D","config":{"inbounds":[{"tag":"r1","port":443,"streamSettings":{"security":"reality","realitySettings":{"dest":"google.com:443","serverNames":["google.com"],"xver":1}}},{"tag":"ws","streamSettings":{"security":"none"}}]}}]}}'
o=$(run 'python3 -c "$RL_PY" list <<< '"'$R'")
out_has "Reality: найден только inbound с reality" $'u1\tr1\tD\t443' "$o"
check "…ровно один" '[ "$(wc -l <<< "$o")" = 1 ]'
o=$(run 'python3 -c "$RL_PY" set u1 r1 de.example.com 9443 <<< '"'$R'")
check "Reality: dest → 127.0.0.1:9443, serverNames, xver 0 (старое поле dest сохранено)" 'grep -q "\"dest\": \"127.0.0.1:9443\"" <<< "$o" && grep -q "\"serverNames\": \[\"de.example.com\"\]" <<< "$o" && grep -q "\"xver\": 0" <<< "$o" && ! grep -q "\"target\"" <<< "$o"'

# ── selfsteal, NET_ADMIN, IPv6 ──
o=$(run 'selfsteal_script de.example.com 9443')
check "selfsteal: скрипт без синтаксических ошибок" 'bash -n <<< "$o"'
out_has "selfsteal: сайт только на 127.0.0.1:9443" "https_port 9443" "$o"
out_has "…bind 127.0.0.1" "bind 127.0.0.1" "$o"
out_has "…порт 80 для сертификата" "http://de.example.com {" "$o"
o=$(run 'node_script 2222 KEY 172.18.0.0/16')
out_has "нода ставится с NET_ADMIN" "- NET_ADMIN" "$o"
out_has "…порт ноды только из docker-сети" "ufw allow from 172.18.0.0/16 to any port 2222" "$o"
mkdir -p "$T/nd"; printf 'services:\n  remnanode:\n    container_name: remnanode\n    image: remnawave/node:latest\n    network_mode: host\n' > "$T/nd/docker-compose.yml"
o=$(run 'node_cap_script' | sed "s|/opt/remnanode|$T/nd|")
o=$(PATH="$T/bin:$PATH" bash <<< "$o" 2>&1)
check "NET_ADMIN добавляется в compose старой ноды" 'grep -A2 "image: remnawave/node" "$T/nd/docker-compose.yml" | grep -q "NET_ADMIN"'
o=$(PATH="$T/bin:$PATH" bash <<< "$(run 'node_cap_script' | sed "s|/opt/remnanode|$T/nd|")" 2>&1)
out_has "…повторно — уже есть" "RP:CAP_OK" "$o"
o=$(run 'IPV6_CONF="'"$T"'/v6.conf"; ipv6_script off' | SSH_CONNECTION="2001:db8::5 50000 2001:db8::1 22" bash 2>&1)
out_has "IPv6: выключение по IPv6-SSH отклонено" "RP:SSH6 2001:db8::5" "$o"
check "…и ничего не записано" '[ ! -e "$T/v6.conf" ]'
check "IPv6: скрипт включения без ошибок" 'bash -n <<< "$(run "ipv6_script on")"'

# ── мультипанель ──
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ssh"; chmod +x "$T/bin/ssh"
o=$(printf 'admin@203.0.113.9\n2222\nde-panel\n' | PATH="$T/bin:$PATH" run 'PANELS_FILE="'"$T"'/panels.list"; mp_add')
out_has "мультипанель: сервер добавлен" "Добавлен: de-panel" "$o"
check "…в список" 'grep -qx "de-panel admin@203.0.113.9 2222" "$T/panels.list"'
o=$(printf '1\n' | PATH="$T/bin:$PATH" run 'PANELS_FILE="'"$T"'/panels.list"; mp_remove')
check "…и убран" '[ ! -s "$T/panels.list" ]'

# ── меню: новые разделы ──
o=$(run 'for x in "${MENU_SECTIONS[@]}"; do echo "${x%%|*}"; done | tr "\n" " "')
out_has "разделы по-новому" "Установка Домены Панель Защита Ноды Сервер Прочее" "$o"
o=$(run 'all_items | sort -n | uniq -d; echo "N=$(all_items | wc -l)"; for n in $(seq 41 52); do all_items | grep -qx $n || echo "MISS $n"; i=$(item_info $n); [ -n "${i%%|*}" ] || echo "NONAME $n"; done')
out_has "51 пункт в полном списке" "N=51" "$o"
check "без повторов, все новые пункты на месте и с названием" '! grep -qE "^[0-9]+$|MISS|NONAME" <<< "$o"'
finish
