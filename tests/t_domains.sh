# Смена доменов панели и подписки за один раз, старый домен подписки остаётся алиасом
source "$(dirname "$0")/lib.sh"
mkdir -p "$T/rw"
printf 'FRONT_END_DOMAIN=panel.example.com\nPANEL_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > "$T/rw/.env"
cat > "$T/rw/docker-compose.yml" <<'Y'
services:
  nginx:
    volumes:
      - ./p.pem:/ssl/p.pem
      - ./p.key:/ssl/p.key
      - ./s.pem:/ssl/s.pem
      - ./s.key:/ssl/s.key
Y
printf 'server { server_name panel.example.com;\n  ssl_certificate /ssl/p.pem;\n  ssl_certificate_key /ssl/p.key; }\nserver {\n  server_name sub.example.com;\n  ssl_certificate /ssl/s.pem;\n  ssl_certificate_key /ssl/s.key;\n}\n' > "$T/rw/nginx.conf"
out=$(cd "$T" && bash -c 'source "'"$(funcs)"'"; RW_DIR="'"$T"'/rw"; JOURNAL=/dev/null
  docker(){ :; }; stack_down(){ echo "[down]"; }; stack_up(){ echo "[up]"; }; check_dns(){ :; }
  issue_cert(){ echo "[cert $1 -> $(cert_file_for $1 | xargs basename) names: $(names_sharing_cert $1)]"; }
  printf "new-panel.example.org\nnew-sub.example.org\ny\ny\n" | change_domains 0' 2>&1 | nocolor)
out_has "сертификат панели" "[cert new-panel.example.org -> p.pem" "$out"
out_has "сертификат подписки с алиасом" "[cert new-sub.example.org -> s.pem names: new-sub.example.org sub.example.com" "$out"
out_has "один перезапуск" "[down]" "$out"
has ".env: FRONT_END_DOMAIN" "FRONT_END_DOMAIN=new-panel.example.org" "$T/rw/.env"
has ".env: SUB_PUBLIC_DOMAIN" "SUB_PUBLIC_DOMAIN=new-sub.example.org" "$T/rw/.env"
has "nginx: новый домен панели" "server_name new-panel.example.org;" "$T/rw/nginx.conf"
has "nginx: старый домен подписки — алиас" "server_name new-sub.example.org sub.example.com;" "$T/rw/nginx.conf"
check "бэкап создан" 'ls -d "$T"/rw/backup-domain-* >/dev/null 2>&1'

# только подписка, без пути
printf 'FRONT_END_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > "$T/rw/.env"
printf 'server {\n  server_name sub.example.com;\n  ssl_certificate /ssl/s.pem;\n  ssl_certificate_key /ssl/s.key;\n}\n' > "$T/rw/nginx.conf"
out=$(bash -c 'source "'"$T"'/funcs.sh"; RW_DIR="'"$T"'/rw"; JOURNAL=/dev/null; docker(){ :; }; stack_down(){ :; }; stack_up(){ :; }; check_dns(){ :; }; issue_cert(){ :; }
  printf "\nonly-sub.example.org\nn\ny\n" | change_domains 0' 2>&1 | nocolor)
has "подписка без /api/sub" "SUB_PUBLIC_DOMAIN=only-sub.example.org" "$T/rw/.env"
has "панель не тронута" "FRONT_END_DOMAIN=panel.example.com" "$T/rw/.env"
has_not "без алиаса, если отказались" "sub.example.com;" "$T/rw/nginx.conf"
finish
