# geoip/geosite: файлы подключаются к ноде, compose правится корректно (3 варианта)
source "$(dirname "$0")/lib.sh"
F=$(funcs)
fake='curl(){ local o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done; case "$o" in *.sha) return 1;; esac; head -c 200000 /dev/urandom > "$o"; }; docker(){ :; }'
run_geo() { { echo "$fake"; bash -c 'source "'"$F"'"; geo_script '"$1"; } | bash 2>&1; }
backup=""; [ -d /opt/remnanode ] && { backup="$T/remnanode.bak"; cp -a /opt/remnanode "$backup"; }
rm -rf /opt/remnanode; mkdir -p /opt/remnanode

printf 'services:\n  remnanode:\n    container_name: remnanode\n    image: remnawave/node:latest\n    network_mode: host\n    environment:\n      - NODE_PORT=2222\n' > /opt/remnanode/docker-compose.yml
out=$(run_geo runet)
out_has "обновление прошло" "RESULT OK" "$out"
has "volumes добавлены (не было)" "./geo/geoip.dat:/usr/local/share/xray/geoip.dat:ro" /opt/remnanode/docker-compose.yml
check "compose остаётся валидным YAML-отступом" 'grep -qE "^    volumes:$" /opt/remnanode/docker-compose.yml'
run_geo runet >/dev/null
check "повторный запуск не дублирует" '[ "$(grep -c geoip.dat /opt/remnanode/docker-compose.yml)" = 1 ]'

printf 'services:\n  remnanode:\n    image: remnawave/node:latest\n    volumes:\n      - /var/log/remnanode:/var/log/remnanode\n' > /opt/remnanode/docker-compose.yml
run_geo loyal >/dev/null
check "добавлено к существующим volumes" '[ "$(grep -c "^    volumes:" /opt/remnanode/docker-compose.yml)" = 1 ] && grep -q geosite.dat /opt/remnanode/docker-compose.yml && grep -q /var/log/remnanode /opt/remnanode/docker-compose.yml'

rm -f /opt/remnanode/docker-compose.yml
printf 'services:\n  remnanode:\n    image: remnawave/node:latest\n' > /opt/remnanode/compose.yaml
out=$(run_geo loyal); out_has "compose.yaml тоже находится" "RESULT OK" "$out"

rm -rf /opt/remnanode; [ -n "$backup" ] && cp -a "$backup" /opt/remnanode
finish
