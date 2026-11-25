# v2.9: готовые профили Xray и подготовка ноды для Hysteria2
source "$(dirname "$0")/lib.sh"
F=$(funcs)
run() { bash -c 'source "'"$F"'"; C_WARN= C_ACC= C0= C_MUT= C_OK= C_ERR= CB= C_LINE=; '"$1" 2>&1 | nocolor; }
env_x='NAME=RP-Combo SNI=www.example.com PK=priv SID=abcd1234 XPATH=/p1 SSL=/var/lib/remnawave/configs/xray/ssl P_REALITY=443 P_XHTTP=8443 P_TROJAN=443 P_HY2=443'
cfg() { run "$env_x python3 -c \"\$XT_PY\" $1"; }

o=$(cfg combo)
check "всё в одном: три inbound — Reality, XHTTP, Hysteria2" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"config\"]; t=[i[\"tag\"] for i in c[\"inbounds\"]]
assert t==[\"RP_REALITY\",\"RP_XHTTP\",\"RP_HYSTERIA2\"], t" "$o"'
check "Reality: raw + reality, ключ, SNI, target, shortIds" 'python3 -c "
import json,sys; i=json.loads(sys.argv[1])[\"config\"][\"inbounds\"][0]; s=i[\"streamSettings\"]; r=s[\"realitySettings\"]
assert i[\"protocol\"]==\"vless\" and s[\"network\"]==\"raw\" and s[\"security\"]==\"reality\"
assert r[\"privateKey\"]==\"priv\" and r[\"serverNames\"]==[\"www.example.com\"] and r[\"target\"]==\"www.example.com:443\" and r[\"shortIds\"]==[\"\",\"abcd1234\"]
assert i[\"settings\"][\"decryption\"]==\"none\" and i[\"sniffing\"][\"enabled\"]" "$o"'
check "XHTTP: путь и порт 8443" 'python3 -c "
import json,sys; i=json.loads(sys.argv[1])[\"config\"][\"inbounds\"][1]; s=i[\"streamSettings\"]
assert i[\"port\"]==8443 and s[\"network\"]==\"xhttp\" and s[\"xhttpSettings\"][\"path\"]==\"/p1\"" "$o"'
check "Hysteria2: version 2, TLS h3, сертификат ноды" 'python3 -c "
import json,sys; i=json.loads(sys.argv[1])[\"config\"][\"inbounds\"][2]; s=i[\"streamSettings\"]
assert i[\"protocol\"]==\"hysteria\" and i[\"settings\"][\"version\"]==2 and s[\"network\"]==\"hysteria\" and s[\"hysteriaSettings\"][\"version\"]==2
assert s[\"tlsSettings\"][\"alpn\"]==[\"h3\"] and s[\"tlsSettings\"][\"certificates\"][0][\"certificateFile\"]==\"/var/lib/remnawave/configs/xray/ssl/cert.pem\"" "$o"'
check "есть DIRECT, BLOCK и блок приватных IP" 'grep -q "\"DIRECT\"" <<< "$o" && grep -q "geoip:private" <<< "$o"'
o=$(cfg trojan)
check "Trojan: TLS с сертификатом ноды" 'python3 -c "
import json,sys; c=json.loads(sys.argv[1])[\"config\"]; i=c[\"inbounds\"][0]
assert len(c[\"inbounds\"])==1 and i[\"protocol\"]==\"trojan\" and i[\"streamSettings\"][\"security\"]==\"tls\"
assert i[\"streamSettings\"][\"tlsSettings\"][\"certificates\"][0][\"keyFile\"].endswith(\"/cert.key\")" "$o"'
for k in reality xhttp hy2; do o=$(cfg $k); check "шаблон $k — один inbound" 'python3 -c "import json,sys; assert len(json.loads(sys.argv[1])[\"config\"][\"inbounds\"])==1" "$o"'; done

o=$(run 'api() { return 1; }; xt_keys && echo "PK=$XT_PK"')
check "ключ Reality через openssl, если панель не дала (base64url, 43 знака)" '[[ "$o" =~ PK=[A-Za-z0-9_-]{43}$ ]]'

# ── подготовка ноды: сертификат есть → compose правится, повторно — без дублей ──
mkdir -p "$T/bin" "$T/nd" "$T/le/live/n1.example.com"
openssl req -x509 -nodes -newkey rsa:2048 -days 30 -subj /CN=n1.example.com -keyout "$T/le/live/n1.example.com/privkey.pem" -out "$T/le/live/n1.example.com/fullchain.pem" >/dev/null 2>&1
printf '#!/bin/sh\necho "docker $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/docker"; chmod +x "$T/bin/docker"
printf 'services:\n  remnanode:\n    container_name: remnanode\n    hostname: remnanode\n    image: remnawave/node:latest\n    network_mode: host\n    restart: always\n' > "$T/nd/docker-compose.yml"
scr() { run 'hy2_node_script n1.example.com 443' | sed "s|/etc/letsencrypt|$T/le|g; s|/opt/remnanode |$T/nd |; s|for x in /opt/remnanode|for x in $T/nd|"; }
check "скрипт подготовки ноды без синтаксических ошибок" 'bash -n <<< "$(scr)"'
o=$(PATH="$T/bin:$PATH" bash <<< "$(scr)" 2>&1)
out_has "нода найдена" "RP:DIR $T/nd" "$o"
out_has "сертификат уже есть — не перевыпускается" "RP:CERT_HAVE" "$o"
out_has "сертификат виден в контейнере" "RP:MOUNT_OK" "$o"
C="$T/nd/docker-compose.yml"
check "NET_ADMIN добавлен" 'grep -q "  - NET_ADMIN" "$C"'
check "/dev/shm и сертификат в volumes" 'grep -q "/dev/shm:/dev/shm:rw" "$C" && grep -q "$T/le/live/n1.example.com/fullchain.pem:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro" "$C" && grep -q "privkey.pem:/var/lib/remnawave/configs/xray/ssl/cert.key:ro" "$C"'
check "compose остался правильным YAML" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(sys.argv[1]))[\"services\"][\"remnanode\"]; assert \"NET_ADMIN\" in s[\"cap_add\"] and len(s[\"volumes\"])==3" "$C" 2>/dev/null || ! python3 -c "import yaml" 2>/dev/null'
check "нода перезапущена (compose up)" 'grep -q "docker compose up -d" "$T/calls"'
cp "$C" "$T/c1"; PATH="$T/bin:$PATH" bash <<< "$(scr)" >/dev/null 2>&1
check "повторный запуск ничего не дублирует" 'cmp -s "$C" "$T/c1"'
printf 'services:\n  remnanode:\n    image: remnawave/node:2.7.0\n    network_mode: host\n    volumes:\n      - /var/log/remnanode:/var/log/remnanode\n' > "$C"
PATH="$T/bin:$PATH" bash <<< "$(scr)" >/dev/null 2>&1
check "свои volumes сохраняются, сертификат добавляется к ним" 'grep -q "/var/log/remnanode:/var/log/remnanode" "$C" && [ "$(grep -c "^    volumes:" "$C")" = 1 ] && grep -q "cert.pem:ro" "$C"'
printf 'services:\n  other:\n    image: nginx\n' > "$C"
o=$(PATH="$T/bin:$PATH" bash <<< "$(scr)" 2>&1)
out_has "нет ноды — понятная ошибка" "RP:NONODE" "$o"

o=$(run 'for n in 51 52; do i=$(item_info $n); echo "${i%%|*}"; done; all_items | grep -cx "5[12]"')
out_has "меню: готовые профили Xray" "Готовые профили Xray" "$o"
out_has "меню: Hysteria2 на ноде" "Hysteria2 на ноде" "$o"
finish
