# v2.6: установка панели (nginx / Caddy), список правил firewall, домен ноды, автопродление с портом на время
source "$(dirname "$0")/lib.sh"
F=$(funcs)
run() { bash -c 'source "'"$F"'"; C_WARN= C_ACC= C0= C_MUT= C_OK= C_ERR= CB= C_LINE=; '"$1" 2>&1 | nocolor; }

# ───────── установка панели ─────────
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'D'
#!/bin/bash
echo "docker $*" >> "$CALLS"
case "$*" in
  "ps -a --format {{.Names}}") exit 0 ;;
  inspect*) echo "running healthy" ;;
esac; exit 0
D
cat > "$T/bin/curl" <<'C'
#!/bin/bash
out=""; url=""; code=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -w) code=1; shift ;; --resolve|--max-time) shift ;; -*) ;; *) url="$1" ;; esac; shift; done
case "$url" in
  *docker-compose-prod.yml) printf 'services:\n  remnawave:\n    image: remnawave/backend:2\n' > "$out" ;;
  *.env.sample) printf 'APP_PORT=3000\nAPP_SECRET=change_me\nJWT_AUTH_SECRET=change_me\nMETRICS_PASS=change_me\nPOSTGRES_PASSWORD=postgres\nDATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"\nFRONT_END_DOMAIN=example.com\nSUB_PUBLIC_DOMAIN=example.com/api/sub\n' > "$out" ;;
  *ifconfig.me*) echo 203.0.113.10 ;;
  https://*) [ -n "$code" ] && printf 200 ;;
esac; exit 0
C
chmod +x "$T/bin"/*
inst() { # каталог, ввод → вывод установки
  CALLS="$T/calls" PATH="$T/bin:$PATH" run 'RW_DIR="'"$1"'"; JOURNAL=/dev/null; need_compose(){ :; }; port_busy(){ return 1; }
    check_dns(){ :; }; issue_cert(){ echo "ISSUE $1 extra=$CERT_EXTRA"; [ -z "$FAIL_CERT" ]; }; sleep(){ :; }
    printf "'"$2"'" | panel_install; echo "rc=$?"'
}
o=$(inst "$T/rw1" 'panel.example.com\nsub.example.com\n1\n')
out_has "nginx: установка прошла" "rc=0" "$o"
out_has "nginx: шаги 6/6" "6/6" "$o"
out_has "nginx: сертификат на оба домена" "ISSUE panel.example.com extra=sub.example.com" "$o"
E="$T/rw1/.env"
check "секреты заменены случайными (128 hex)" 'grep -qE "^APP_SECRET=[0-9a-f]{128}$" "$E" && grep -qE "^JWT_AUTH_SECRET=[0-9a-f]{128}$" "$E" && ! grep -q change_me "$E"'
pw=$(grep -m1 '^POSTGRES_PASSWORD=' "$E" | cut -d= -f2)
check "пароль базы случайный и совпадает в DATABASE_URL" '[ ${#pw} = 48 ] && grep -q "postgres:$pw@remnawave-db" "$E"'
has "домен панели в .env" "FRONT_END_DOMAIN=panel.example.com" "$E"
has "отдельный домен подписки в .env" "SUB_PUBLIC_DOMAIN=sub.example.com" "$E"
check ".env доступен только root" '[ "$(stat -c %a "$E")" = 600 ]'
N="$T/rw1/nginx"
has "nginx.conf: панель → remnawave:3000" "server remnawave:3000;" "$N/nginx.conf"
check "nginx.conf: подписка → /api/sub/" 'grep -A12 "server_name sub.example.com;" "$N/nginx.conf" | grep -q "proxy_pass http://remnawave/api/sub/;"'
has "nginx.conf: чужие домены отклоняются" "ssl_reject_handshake on;" "$N/nginx.conf"
check "временный сертификат создан" 'openssl x509 -in "$N/fullchain.pem" -noout -subject | grep -q panel.example.com'
check "nginx запущен до выпуска (чтобы acme.sh мог его перезагрузить)" 'grep -n "compose up -d" "$T/calls" | tail -1 | grep -q .'
# RemnaPilot понимает установленную раскладку: смена домена и продление найдут сертификат
o=$(run 'RW_DIR="'"$T"'/rw1"; cert_paths_for panel.example.com; echo; names_sharing_cert panel.example.com')
out_has "раскладка понятна RemnaPilot: путь к сертификату" "$N/fullchain.pem" "$o"
out_has "раскладка понятна RemnaPilot: домены с общим сертификатом" "sub.example.com" "$o"

: > "$T/calls"
o=$(inst "$T/rw2" 'panel.example.com\n\n2\n')
out_has "Caddy: установка прошла" "rc=0" "$o"
check "Caddy: acme.sh не используется" '! grep -q "ISSUE" <<< "$o"'
has "Caddyfile: домен панели" "https://panel.example.com {" "$T/rw2/caddy/Caddyfile"
has "Caddyfile: прокси на панель" "reverse_proxy * http://remnawave:3000" "$T/rw2/caddy/Caddyfile"
has "Caddyfile: заглушка для чужих доменов" "tls internal" "$T/rw2/caddy/Caddyfile"
has "без отдельного домена подписка на домене панели" "SUB_PUBLIC_DOMAIN=panel.example.com/api/sub" "$T/rw2/.env"
has "Caddy: compose как в docs.rw" "image: caddy:2.9" "$T/rw2/caddy/docker-compose.yml"
check "Caddy: каталога nginx нет" '[ ! -d "$T/rw2/nginx" ]'
o=$(run 'pi_caddyfile p.example.com s.example.com')
check "Caddyfile: подписка переписывается на /api/sub" 'grep -A3 "https://s.example.com {" <<< "$o" | grep -q "rewrite \* /api/sub{uri}"'

o=$(inst "$T/rw1" 'x.example.com\n\n1\n')
out_has "уже установлена — отказ" "Панель уже установлена" "$o"
check "…и .env не тронут" 'grep -q "FRONT_END_DOMAIN=panel.example.com" "$T/rw1/.env"'
o=$(inst "$T/rw3" 'not a domain\npanel.example.com\n\n1\n')
out_has "не домен — переспрашивает" "не похоже на домен" "$o"
out_has "…и дальше ставит" "rc=0" "$o"
o=$(inst "$T/rw4" '\n')
out_has "пустой домен — отмена (код 10)" "rc=10" "$o"
check "…и ничего не создано" '[ ! -e "$T/rw4/.env" ]'
o=$(FAIL_CERT=1 inst "$T/rw5" 'panel.example.com\n\n1\n')
out_has "сертификат не выпущен — честно и с подсказкой" "Сертификат Let's Encrypt не выпущен" "$o"
out_has "…панель при этом установлена (код 1, а не молчаливый успех)" "rc=1" "$o"

# ───────── firewall: список правил ─────────
ufwout='Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
443                        ALLOW       Anywhere                   # panel
2222/tcp                   ALLOW       203.0.113.5
3000/tcp                   ALLOW       Anywhere
8080                       DENY        Anywhere
22/tcp (v6)                ALLOW       Anywhere (v6)'
o=$(run 'command(){ [[ $2 == ufw ]] && return 0; builtin command "$@"; }; ufw(){ printf "%s\n" "'"$ufwout"'"; }
  ssh_ports(){ echo 22; }; local_node_port(){ echo 2222; }; public_listeners(){ :; }; fw_rules')
out_has "правила: SSH" "SSH — вход на сервер" "$o"
out_has "правила: порт ноды только с IP панели" "203.0.113.5       нода — связь с панелью" "$o"
out_has "правила: открытый порт панели — предупреждение" "⚠ панель напрямую" "$o"
out_has "правила: запрещённый порт" "запрещено" "$o"
check "правила: IPv6-дубли не повторяются" '[ "$(grep -c "^   22/tcp" <<< "$o")" = 1 ]'
check "правила: комментарий ufw не ломает колонки" '! grep -q "# panel" <<< "$o"'
o=$(run 'command(){ [[ $2 == ufw ]] && return 0; builtin command "$@"; }; ufw(){ echo "Status: inactive"; }
  ssh_ports(){ echo 22; }; local_node_port(){ :; }; public_listeners(){ printf "22/tcp sshd\n5432/tcp docker-proxy\n"; }; fw_rules')
out_has "firewall выключен — что открыто" "Firewall выключен" "$o"
out_has "…и опасный открытый порт" "⚠ база данных" "$o"

# ───────── домен ноды ─────────
o=$(run 'getent(){ case "$2" in de.example.com) echo "198.51.100.7 STREAM x";; esac; }; node_domain_check de.example.com 198.51.100.7; node_domain_check de.example.com 198.51.100.8; node_domain_check nx.example.com 1.2.3.4')
out_has "домен ноды указывает на ноду" "✔ Домен ноды de.example.com указывает на ноду" "$o"
out_has "домен ноды на другом IP — предупреждение" "указывает на 198.51.100.7, а нода на 198.51.100.8" "$o"
out_has "домена ноды нет в DNS" "не найден в DNS" "$o"
o=$(run 'sql_s "it'"'"'s"'); out_has "SQL: кавычки экранируются" "'it''s'" "$o"

cat > "$T/bin/docker" <<'D'
#!/bin/bash
if [ "$1" = exec ]; then
  q="${@: -1}"; echo "$q" >> "$SQL"
  case "$q" in
    "SELECT name, address FROM nodes"*) printf 'de-1\told.example.com\nnl-1\t198.51.100.9\n' ;;
    "SELECT count(*) FROM hosts"*) echo 2 ;;
    "SELECT count(*) FROM nodes"*) case "$q" in *taken.example.com*) echo 1 ;; *) echo 0 ;; esac ;;
    BEGIN*) echo COMMIT ;;
  esac; exit 0
fi
[ "$1" = inspect ] && echo "running healthy"; exit 0
D
chmod +x "$T/bin/docker"
nd() { SQL="$T/sql" PATH="$T/bin:$PATH" run 'RW_DIR="'"$T"'/rw1"; JOURNAL=/dev/null; db_info(){ DB_CT=db; DB_USER=postgres; DB_NAME=postgres; }
  backup_db(){ echo BACKUP; }; getent(){ case "$2" in old.example.com|new.example.com) echo "198.51.100.7 S x";; esac; }; sleep(){ :; }
  printf "'"$1"'" | node_domain_change; echo "rc=$?"'; }
: > "$T/sql"; o=$(nd '1\nnew.example.com\n')
out_has "домен ноды: список нод из панели" "de-1" "$o"
out_has "домен ноды: сколько хостов затронет" "хостов с этим адресом: 2" "$o"
out_has "домен ноды: бэкап перед изменением" "BACKUP" "$o"
out_has "домен ноды: готово" "old.example.com → new.example.com" "$o"
check "SQL: нода и хосты в одной транзакции" 'grep -q "^BEGIN;" "$T/sql" && grep -q "UPDATE nodes SET address = '"'"'new.example.com'"'"'" "$T/sql" && grep -q "UPDATE hosts SET sni" "$T/sql" && grep -q "COMMIT;" "$T/sql"'
: > "$T/sql"; o=$(nd '1\ntaken.example.com\n')
out_has "занятый адрес — отказ" "уже занят другой нодой" "$o"
check "…и без UPDATE" '! grep -q UPDATE "$T/sql"'
: > "$T/sql"; o=$(nd '1\nnx.example.com\nn\n')
out_has "домен не указывает на ноду — спрашивает" "Всё равно сменить" "$o"
out_has "…«нет» — отмена (код 10)" "rc=10" "$o"
check "…и без UPDATE" '! grep -q UPDATE "$T/sql"'
o=$(nd '9\n'); out_has "неверный номер — отмена" "rc=10" "$o"

# ───────── автопродление: порт открыт только на время, nginx не трогаем зря ─────────
H="$T/hooks"; mkdir -p "$H"
run 'HOOK_DIR="'"$H"'"; nginx_ct(){ echo remnawave-nginx; }; write_renew_hooks p.example.com 80; write_renew_hooks d.example.com ""' >/dev/null
for f in "$H"/*.sh; do check "хук без ошибок sh: $(basename "$f")" 'sh -n "$f"'; done
mkdir -p "$T/hb"; FWLOG="$T/fw.log"; : > "$FWLOG"
cat > "$T/hb/ufw" <<U
#!/bin/sh
echo "ufw \$*" >> $FWLOG
[ "\$1" = status ] && { echo "Status: active"; echo "22/tcp ALLOW Anywhere"; }
exit 0
U
printf '#!/bin/sh\necho "docker $*" >> %s\nexit 0\n' "$FWLOG" > "$T/hb/docker"
printf '#!/bin/sh\n[ -f %s/busy ] && echo "LISTEN 0 0 *:80 *:*"\nexit 0\n' "$T" > "$T/hb/ss"
chmod +x "$T/hb"/*
PATH="$T/hb:$PATH" sh "$H/p.example.com-pre.sh"; PATH="$T/hb:$PATH" sh "$H/p.example.com-post.sh"
check "продление: порт 80 открыт на время" 'grep -q "ufw allow 80/tcp" "$FWLOG"'
check "продление: и закрыт после" 'grep -q "ufw delete allow 80/tcp" "$FWLOG"'
check "продление: порт свободен — nginx не останавливается (панель не падает)" '! grep -q "docker stop" "$FWLOG"'
: > "$FWLOG"; touch "$T/busy"
PATH="$T/hb:$PATH" sh "$H/p.example.com-pre.sh"; PATH="$T/hb:$PATH" sh "$H/p.example.com-post.sh"; rm -f "$T/busy"
check "продление: порт занят nginx — остановлен и запущен обратно" 'grep -q "docker stop remnawave-nginx" "$FWLOG" && grep -q "docker start remnawave-nginx" "$FWLOG"'
: > "$FWLOG"; PATH="$T/hb:$PATH" sh "$H/d.example.com-pre.sh"; PATH="$T/hb:$PATH" sh "$H/d.example.com-post.sh"
check "продление через DNS: ничего не останавливается и порты не трогаются" '[ ! -s "$FWLOG" ]'
check "состояние убрано после продления" '[ ! -e "$H/p.example.com.state" ]'
# старые хуки (до v2.6) обновляются сами
printf '#!/bin/sh\ndocker stop remnawave-nginx >/dev/null 2>&1\ndocker stop caddy >/dev/null 2>&1\nif true; then ufw allow 80/tcp; fi\nexit 0\n' > "$H/old.example.com-pre.sh"
run 'HOOK_DIR="'"$H"'"; nginx_ct(){ echo remnawave-nginx; }; upgrade_renew_hooks' >/dev/null
has "старый хук обновлён" "rp-hooks-v2" "$H/old.example.com-pre.sh"
has "…порт сохранён" "sport = :80" "$H/old.example.com-pre.sh"
has "…и мешающий контейнер тоже" "docker stop caddy" "$H/old.example.com-pre.sh"
check "…nginx — только если занимает порт" 'grep -q "busy && docker stop remnawave-nginx" "$H/old.example.com-pre.sh"'

# ───────── забыл пароль ─────────
o=$(run 'app_containers(){ echo remnawave; }; reset_admin </dev/null; echo "rc=$?"')
out_has "сброс пароля без терминала — понятный отказ" "Нужен терминал" "$o"
finish
