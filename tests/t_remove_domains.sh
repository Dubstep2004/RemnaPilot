# Удаление старых доменов из Nginx, Caddy и Traefik
source "$(dirname "$0")/lib.sh"
mkdir -p "$T/rw/caddy" "$T/rw/traefik"
printf 'FRONT_END_DOMAIN=panel.new.com\nSUB_PUBLIC_DOMAIN=sub.new.com\n' > "$T/rw/.env"
cat > "$T/rw/docker-compose.yml" <<'Y'
services:
  nginx:
    volumes:
      - ./s.pem:/ssl/s.pem
      - ./s.key:/ssl/s.key
      - ./o.pem:/ssl/o.pem
      - ./o.key:/ssl/o.key
Y
cat > "$T/rw/nginx.conf" <<'N'
server {
    server_name sub.new.com sub.old.com;
    ssl_certificate /ssl/s.pem;
    ssl_certificate_key /ssl/s.key;
}
server {
    server_name panel.old.com;
    ssl_certificate /ssl/o.pem;
    ssl_certificate_key /ssl/o.key;
    location / { return 301 https://panel.new.com$request_uri; }
}
N
printf 'https://sub.new.com, sub.old.com {\n    reverse_proxy sub:3010\n}\nlegacy.old.com {\n    redir https://panel.new.com{uri}\n}\n' > "$T/rw/caddy/Caddyfile"
printf '      rule: "(Host(`sub.new.com`) || Host(`sub.old.com`)) && PathPrefix(`/api/sub/`)"\n' > "$T/rw/traefik/r.yml"
out=$(bash -c 'source "'"$(funcs)"'"; RW_DIR="'"$T"'/rw"; HOOK_DIR="'"$T"'/h"; JOURNAL=/dev/null
  docker(){ :; }; stack_down(){ :; }; stack_up(){ :; }; acme_bin(){ return 1; }
  issue_cert(){ echo "[cert $1 extra=$CERT_EXTRA]"; }
  printf "a\ny\n" | remove_domains' 2>&1 | nocolor)
has_not "nginx: алиас удалён" "sub.old.com" "$T/rw/nginx.conf"
has_not "nginx: блок старого домена удалён" "panel.old.com" "$T/rw/nginx.conf"
has "nginx: домен подписки на месте" "server_name sub.new.com;" "$T/rw/nginx.conf"
has_not "Caddy: алиас удалён" "sub.old.com" "$T/rw/caddy/Caddyfile"
has_not "Caddy: сайт старого домена удалён" "legacy.old.com" "$T/rw/caddy/Caddyfile"
has "Traefik: правило упрощено" 'rule: "Host(`sub.new.com`) && PathPrefix' "$T/rw/traefik/r.yml"
out_has "сертификат подписки перевыпущен без алиаса" "[cert sub.new.com extra=sub.new.com" "$out"
out_has "ненужный сертификат отмечен" "o.pem" "$out"
finish
