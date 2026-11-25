# ---------- Hysteria2 на ноде: сертификат, NET_ADMIN, /dev/shm, 443/udp ----------
# Как в ручной инструкции: сертификат Let's Encrypt (certbot) монтируется в контейнер ноды,
# после продления нода перезапускается сама, UDP-порт открывается в firewall.
NODE_SSL="/var/lib/remnawave/configs/xray/ssl"

hy2_node_script() { # домен, UDP-порт
  cat <<EOF
D="$1"; U="$2"; L="/etc/letsencrypt/live/\$D"
d=""; for x in /opt/remnanode /opt/remnawave-node /opt/remnawave; do
  for f in docker-compose.yml compose.yml; do [ -f "\$x/\$f" ] && grep -q 'remnawave/node' "\$x/\$f" && { d=\$x; cf=\$x/\$f; break 2; }; done
done
[ -n "\$d" ] || { echo "RP:NONODE"; exit 3; }
echo "RP:DIR \$d"
# 1. сертификат
if [ -s "\$L/fullchain.pem" ] && [ -s "\$L/privkey.pem" ] && openssl x509 -checkend 86400 -noout -in "\$L/fullchain.pem" >/dev/null 2>&1; then
  echo "RP:CERT_HAVE"
else
  if ! command -v certbot >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot >/tmp/rp-certbot.log 2>&1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q certbot >/tmp/rp-certbot.log 2>&1
    else yum install -y -q certbot >/tmp/rp-certbot.log 2>&1; fi
    command -v certbot >/dev/null 2>&1 || { echo "RP:NOCERTBOT"; tail -5 /tmp/rp-certbot.log; exit 4; }
  fi
  if ss -ltnH 'sport = :80' | grep -q .; then echo "RP:BUSY80 \$(ss -ltnpH 'sport = :80' | grep -o '"[^"]*"' | head -1)"; exit 5; fi
  hooks=""
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' && ! ufw status | grep -qE '^80(/tcp)?[[:space:]]+ALLOW'; then
    hooks="--pre-hook 'ufw allow 80/tcp' --post-hook 'ufw delete allow 80/tcp'"   # порт 80 открыт только на время выпуска и продления
  fi
  if eval certbot certonly --standalone -d "\$D" --non-interactive --agree-tos --register-unsafely-without-email \$hooks >/tmp/rp-certbot.log 2>&1; then echo "RP:CERT_NEW"
  else echo "RP:CERT_FAIL"; tail -8 /tmp/rp-certbot.log; exit 6; fi
fi
# 2. после продления — перезапуск ноды (новый сертификат подхватывается при запуске контейнера)
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/bash\n# RemnaPilot: после продления сертификата перезапустить ноду\ncd %s && docker compose restart remnanode\n' "\$d" > /etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh
# 3. docker-compose ноды: NET_ADMIN, /dev/shm, сертификат
cp "\$cf" "\$cf.bak-hy2"
L="\$L" S="$NODE_SSL" perl -0777 -i -pe '
  s/^[ \t]*- [^\n]*:\Q\$ENV{S}\E\/cert\.(pem|key)[^\n]*\n//mg;
  s/^[ \t]*- \/dev\/shm:\/dev\/shm[^\n]*\n//mg;
  s/^([ \t]*)volumes:[ \t]*\n(?=\1[^ \t-]|\s*\z)//mg;
  \$ok = /^([ \t]*)image:[ \t]*\S*remnawave\/node/m; my \$i = \$1;
  my \$items = "\$i  - /dev/shm:/dev/shm:rw\n\$i  - \$ENV{L}/fullchain.pem:\$ENV{S}/cert.pem:ro\n\$i  - \$ENV{L}/privkey.pem:\$ENV{S}/cert.key:ro\n";
  unless (/NET_ADMIN/) { s/^(\Q\$i\Eimage:[ \t]*\S*remnawave\/node[^\n]*\n)/\$1\$i\Ecap_add:\n\$i  - NET_ADMIN\n/m }
  if (/^\Q\$i\Evolumes:[ \t]*\n/m) { s/^(\Q\$i\Evolumes:[ \t]*\n)/\$1\$items/m }
  else { s/^(\Q\$i\Eimage:[ \t]*\S*remnawave\/node[^\n]*\n)/\$1\$i\Evolumes:\n\$items/m }
  END { exit !\$ok }' "\$cf" || { cp "\$cf.bak-hy2" "\$cf"; echo "RP:NOIMAGE"; exit 7; }
cd "\$d" && docker compose up -d >/tmp/rp-node-up.log 2>&1 || { cp "\$cf.bak-hy2" "\$cf"; docker compose up -d >/dev/null 2>&1; echo "RP:UPFAIL"; tail -5 /tmp/rp-node-up.log; exit 8; }
sleep 5
docker exec remnanode sh -c 'test -s $NODE_SSL/cert.pem && test -s $NODE_SSL/cert.key' && echo "RP:MOUNT_OK" || echo "RP:MOUNT_FAIL"
# 4. UDP-порт
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "\$U/udp" >/dev/null && echo "RP:FW ufw"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="\$U/udp" >/dev/null && firewall-cmd --reload >/dev/null && echo "RP:FW firewalld"
else echo "RP:FW none"; fi
EOF
}

hy2_node_setup() { # [домен] [порт] → HY_DOMAIN; 0 — нода готова
  local dom="${1:-}" port="${2:-443}" t out tn
  PT_LOCAL=1 pick_targets "КАКУЮ НОДУ ГОТОВИТЬ" || { echo "  Отменено."; return $RP_CANCEL; }
  (( ${#TARGETS[@]} == 1 )) || { fail "Ноду готовлю по одной"; return 1; }
  t="${TARGETS[0]}"; tn=$(target_name "$t")
  echo "Нужен домен ноды с A-записью на её IP и свободный порт 80 на время выпуска сертификата."
  [[ -n "$dom" ]] || { pi_ask_domain "Домен ноды (например node1.example.com)" dom || { echo "  Отменено."; return $RP_CANCEL; }; }
  if [[ "$t" == local ]]; then node_domain_check "$dom" "$(curl -4 -s --max-time 5 https://ifconfig.me)"
  else node_domain_check "$dom" "$(ip_of "$(cut -d'|' -f2 <<< "$t" | cut -d@ -f2)")"; fi

  steps 4
  step "Сертификат, NET_ADMIN и порт на $tn"
  out=$(run_on "$t" "$(hy2_node_script "$dom" "$port")" 2>&1 </dev/null)
  case "$out" in
    *RP:NONODE*)     fail "Нет ноды Remnawave: $tn"; todo "сначала поставь ноду: Установка → Установка и обновление нод"; steps_done; return 1 ;;
    *RP:NOCERTBOT*)  fail "certbot не установился" apt "$out"; steps_done; return 1 ;;
    *RP:BUSY80*)     fail "Порт 80 занят: ${out##*RP:BUSY80 }"; cause "certbot нужен порт 80, чтобы получить сертификат"; todo "освободи порт 80 на ноде на минуту и повтори"; steps_done; return 1 ;;
    *RP:CERT_FAIL*)  fail "Сертификат не выпущен"; explain_acme_error "${out#*RP:CERT_FAIL}" http; steps_done; return 1 ;;
    *RP:NOIMAGE*)    fail "Не нашёл образ remnawave/node в docker-compose"; todo "проверь файл: ${out#*RP:DIR }"; steps_done; return 1 ;;
    *RP:UPFAIL*)     fail "Нода не запустилась с новыми настройками — вернул как было" docker "${out#*RP:UPFAIL}"; steps_done; return 1 ;;
    *RP:MOUNT_OK*)   ;;
    *)               fail "Не получилось подготовить ноду"; why_first "$out" ssh docker; steps_done; return 1 ;;
  esac
  [[ "$out" == *RP:CERT_HAVE* ]] && green "✔ Сертификат для $dom уже есть" || green "✔ Сертификат Let's Encrypt выпущен: $dom"
  step "Продление сертификата"
  green "✔ После продления нода перезапустится сама (certbot, /etc/letsencrypt/renewal-hooks/deploy)"
  step "docker-compose ноды"
  green "✔ NET_ADMIN, /dev/shm и сертификат подключены: $NODE_SSL/cert.pem, cert.key"
  step "Firewall"
  case "$out" in
    *"RP:FW ufw"*|*"RP:FW firewalld"*) green "✔ Открыт $port/udp" ;;
    *) yel "⚠ Firewall на ноде выключен — $port/udp и так открыт. Проверь ещё firewall у хостера." ;;
  esac
  steps_done "Нода для Hysteria2"
  HY_DOMAIN="$dom"
}

hy2_menu() {
  hy2_node_setup || return $?
  [[ -f "$RW_DIR/.env" ]] || { echo; echo "  Дальше: в панели создай профиль с inbound Hysteria2 — путь к сертификату $NODE_SSL/cert.pem и cert.key."; return 0; }
  local a; ask "Создать в панели готовый профиль Hysteria2 для этой ноды? [Y/n]"; read -r a
  [[ "$a" =~ ^[NnНн]$ ]] && return 0
  XT_DOMAIN="$HY_DOMAIN" xt_create hy2
}

# ---------- готовые профили Xray ----------
XT_PY='
import json,sys,os
kind=sys.argv[1]; E=os.environ
sniff={"enabled":True,"destOverride":["http","tls","quic"]}
def reality(net,extra):
    s={"network":net,"security":"reality","realitySettings":{"show":False,"xver":0,"target":E["SNI"]+":443",
       "serverNames":[E["SNI"]],"privateKey":E["PK"],"shortIds":["",E["SID"]]}}
    s.update(extra); return s
certs=[{"certificateFile":E["SSL"]+"/cert.pem","keyFile":E["SSL"]+"/cert.key"}]
def ib(tag,port,proto,settings,stream,sn=True):
    d={"tag":tag,"listen":"0.0.0.0","port":int(port),"protocol":proto,"settings":settings,"streamSettings":stream}
    if sn: d["sniffing"]=sniff
    return d
I={
 "reality": lambda: ib("RP_REALITY",E["P_REALITY"],"vless",{"clients":[],"decryption":"none"},reality("raw",{})),
 "xhttp":   lambda: ib("RP_XHTTP",E["P_XHTTP"],"vless",{"clients":[],"decryption":"none"},reality("xhttp",{"xhttpSettings":{"path":E["XPATH"],"mode":"auto"}})),
 "trojan":  lambda: ib("RP_TROJAN",E["P_TROJAN"],"trojan",{"clients":[]},{"network":"raw","security":"tls","tlsSettings":{"alpn":["h2","http/1.1"],"certificates":certs}}),
 "hy2":     lambda: ib("RP_HYSTERIA2",E["P_HY2"],"hysteria",{"version":2,"clients":[]},{"network":"hysteria","security":"tls",
               "tlsSettings":{"alpn":["h3"],"certificates":certs},"hysteriaSettings":{"version":2,"udpIdleTimeout":60}},False),
}
parts={"reality":["reality"],"xhttp":["xhttp"],"trojan":["trojan"],"hy2":["hy2"],"combo":["reality","xhttp","hy2"]}[kind]
cfg={"log":{"loglevel":"warning"},"inbounds":[I[p]() for p in parts],
     "outbounds":[{"protocol":"freedom","tag":"DIRECT"},{"protocol":"blackhole","tag":"BLOCK"}],
     "routing":{"rules":[{"ip":["geoip:private"],"outboundTag":"BLOCK"}]}}
print(json.dumps({"name":E["NAME"],"config":cfg},ensure_ascii=False))
'

xt_title() { case "$1" in reality) echo "VLESS + Reality";; xhttp) echo "VLESS + XHTTP";; trojan) echo "Trojan";; hy2) echo "Hysteria2";; combo) echo "Всё в одном: Reality + XHTTP + Hysteria2";; esac; }
xt_needs_cert() { [[ "$1" == trojan || "$1" == hy2 || "$1" == combo ]]; }

xt_ask_port() { # подсказка, по умолчанию, переменная
  local -n _p="$3"; local v
  ask "$1 [$2]"; read -r v; v="${v:-$2}"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 && v < 65536 )) || { fail "Некорректный порт: $v"; return 1; }
  _p="$v"
}

xt_keys() { # → XT_PK (privateKey Reality)
  if api GET /api/system/tools/x25519/generate; then XT_PK=$(jget 'j["response"]["keypairs"][0]["privateKey"]' <<< "$API_OUT"); fi
  if [[ -z "${XT_PK:-}" ]]; then   # старая панель — ключ через openssl
    XT_PK=$(openssl genpkey -algorithm X25519 -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
  fi
  [[ ${#XT_PK} -ge 40 ]]
}

xt_pick_list() { # заголовок, строки «uuid<TAB>имя<TAB>подсказка» → XT_PICK (uuid через пробел); Enter — значение по умолчанию $2
  local title="$1" def="$2" lines="$3" i=0 c n name hint
  section "$title"
  while IFS=$'\t' read -r _ name hint; do i=$((i+1)); item "$i" "$name" "$hint"; done <<< "$lines"
  item a "Все"; item 0 "Ни одной"
  ask "Номера через пробел [$def]"; read -r c; c="${c:-$def}"
  XT_PICK=""
  [[ "$c" == 0 ]] && return 0
  if [[ "$c" == a || "$c" == а ]]; then
    XT_PICK=$(cut -f1 <<< "$lines" | tr '\n' ' '); return 0
  fi
  for n in $(tr ',' ' ' <<< "$c"); do
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= i )) && XT_PICK+="$(sed -n "${n}p" <<< "$lines" | cut -f1) "
  done
}

xt_create() { # вид: reality|xhttp|trojan|hy2|combo
  local kind="$1" title sni="" dom="${XT_DOMAIN:-}" pr=443 px=8443 pt=443 ph=443 name body puuid inb i n
  need_panel || return 1; api_ready || return $?
  title=$(xt_title "$kind")
  echo "Создам в панели профиль «$title» с правильными настройками: ключи, порты, sniffing, правила."
  case "$kind" in reality|xhttp|combo)
    echo "  SNI — чужой сайт, под который маскируется Reality (подобрать: Ноды → Подбор SNI для Reality),"
    echo "  или домен твоего selfsteal (Ноды → Selfsteal для Reality)."
    ask "SNI [www.google.com]"; read -r sni; sni=$(clean_domain "${sni:-www.google.com}")
    valid_domain "$sni" || { fail "«$sni» — не похоже на домен"; return 1; } ;;
  esac
  if xt_needs_cert "$kind"; then
    echo "  Нужен сертификат на ноде (Ноды → Hysteria2 на ноде — выпустит и подключит его)."
    [[ -n "$dom" ]] || { pi_ask_domain "Домен ноды, на который выпущен сертификат" dom || { echo "  Отменено."; return $RP_CANCEL; }; }
  fi
  case "$kind" in
    reality) xt_ask_port "Порт Reality (TCP)" 443 pr || return 1 ;;
    xhttp)   xt_ask_port "Порт XHTTP (TCP)" 443 px || return 1 ;;
    trojan)  xt_ask_port "Порт Trojan (TCP)" 443 pt || return 1 ;;
    hy2)     xt_ask_port "Порт Hysteria2 (UDP)" 443 ph || return 1 ;;
    combo)   xt_ask_port "Порт Reality (TCP)" 443 pr || return 1
             xt_ask_port "Порт XHTTP (TCP)" 8443 px || return 1
             xt_ask_port "Порт Hysteria2 (UDP)" 443 ph || return 1
             [[ "$pr" == "$px" ]] && { fail "Reality и XHTTP не могут быть на одном TCP-порту"; return 1; } ;;
  esac

  steps 4
  step "Ключи и профиль"
  XT_PK=""; case "$kind" in reality|xhttp|combo) xt_keys || { fail "Не получилось создать ключ Reality"; steps_done; return 1; } ;; esac
  name="RP-$(case $kind in reality) echo Reality;; xhttp) echo XHTTP;; trojan) echo Trojan;; hy2) echo Hysteria2;; combo) echo Combo;; esac)"
  api GET /api/config-profiles || { fail "Не получил профили конфигурации"; cause "$(api_msg)"; steps_done; return 1; }
  local taken; taken=$(jget '" ".join(p["name"] for p in j["response"]["configProfiles"])' <<< "$API_OUT")
  if [[ " $taken " == *" $name "* ]]; then for i in $(seq 2 99); do [[ " $taken " == *" $name-$i "* ]] || { name="$name-$i"; break; }; done; fi
  body=$(NAME="$name" SNI="$sni" PK="$XT_PK" SID="$(openssl rand -hex 8)" XPATH="/$(openssl rand -hex 6)" SSL="$NODE_SSL" \
         P_REALITY="$pr" P_XHTTP="$px" P_TROJAN="$pt" P_HY2="$ph" python3 -c "$XT_PY" "$kind") || { fail "Не собрал конфиг профиля"; steps_done; return 1; }
  api POST /api/config-profiles "$body" || { fail "Панель не приняла профиль"; cause "$(api_msg)"; steps_done; return 1; }
  puuid=$(jget 'j["response"]["uuid"]' <<< "$API_OUT")
  inb=$(jget '"\n".join(i["uuid"]+"\t"+i["tag"]+"\t"+i["type"]+" · порт "+str(i.get("port")) for i in j["response"]["inbounds"])' <<< "$API_OUT")
  local tags; tags=$(cut -f2 <<< "$inb" | tr '\n' ' ')
  green "✔ Профиль «$name» создан: $tags"

  step "Доступ пользователей (сквады)"
  api GET /api/internal-squads || { fail "Не получил сквады"; cause "$(api_msg)"; steps_done; return 1; }
  local sq; sq=$(jget '"\n".join(s["uuid"]+"\t"+s["name"]+"\t"+str(s.get("info",{}).get("membersCount","?")) for s in j["response"]["internalSquads"])' <<< "$API_OUT" | sed -E 's/\t([0-9?]+)$/\tпользователей: \1/')
  local squads_json="$API_OUT"
  if [[ -n "$sq" ]]; then
    if (( $(wc -l <<< "$sq") == 1 )); then XT_PICK=$(cut -f1 <<< "$sq")
    else echo "  Пользователи видят inbound, только если он есть в их скваде."; xt_pick_list "В КАКИЕ СКВАДЫ ДОБАВИТЬ" a "$sq"; fi
    local s add sname
    for s in $XT_PICK; do
      sname=$(awk -F'\t' -v u="$s" '$1==u{print $2}' <<< "$sq")
      add=$(S="$s" N="$(cut -f1 <<< "$inb" | tr '\n' ',')" python3 -c 'import json,sys,os
j=json.load(sys.stdin)["response"]["internalSquads"]; sq=next(x for x in j if x["uuid"]==os.environ["S"])
old=[i["uuid"] for i in sq.get("inbounds",[])]; new=[x for x in os.environ["N"].split(",") if x and x not in old]
print(json.dumps({"uuid":sq["uuid"],"inbounds":old+new}))' <<< "$squads_json")
      api PATCH /api/internal-squads "$add" && green "✔ Сквад «$sname»: inbound добавлены" \
        || yel "⚠ Сквад не обновился: $(api_msg)"
    done
  fi

  step "Ноды"
  api GET /api/nodes || { fail "Не получил список нод"; cause "$(api_msg)"; steps_done; return 1; }
  local nl; nl=$(jget '"\n".join(n["uuid"]+"\t"+n["name"]+"\t"+n["address"] for n in j["response"])' <<< "$API_OUT")
  local nodes=""
  if [[ -n "$nl" ]]; then
    yel "  Нода переключится на новый профиль — её прежние подключения перестанут работать."
    xt_pick_list "КАКИЕ НОДЫ ПЕРЕКЛЮЧИТЬ НА ПРОФИЛЬ" 0 "$nl"; nodes="$XT_PICK"
    local u nn ins; ins=$(cut -f1 <<< "$inb" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
    for u in $nodes; do
      nn=$(awk -F'\t' -v x="$u" '$1==x{print $2}' <<< "$nl")
      api PATCH /api/nodes "{\"uuid\":\"$u\",\"configProfile\":{\"activeConfigProfileUuid\":\"$puuid\",\"activeInbounds\":$ins}}" \
        && green "✔ Нода «$nn» на профиле «$name»" || yel "⚠ Нода не переключилась: $(api_msg)"
    done
  fi

  step "Хосты для клиентов"
  local addr def_addr; def_addr="$dom"
  [[ -z "$def_addr" && -n "$nodes" ]] && def_addr=$(awk -F'\t' -v x="${nodes%% *}" '$1==x{print $3}' <<< "$nl")
  echo "  Хост — адрес, который получат клиенты в подписке (домен или IP ноды)."
  ask "Адрес для клиентов${def_addr:+ [$def_addr]} (0 — не создавать хосты)"; read -r addr; addr="${addr:-$def_addr}"
  if [[ -n "$addr" && "$addr" != 0 ]]; then
    local iu itag ity hs hp nj; nj=$(printf '%s' "$nodes" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')
    while IFS=$'\t' read -r iu itag ity; do
      case "$itag" in RP_REALITY) hp=$pr; hs="$sni";; RP_XHTTP) hp=$px; hs="$sni";; RP_TROJAN) hp=$pt; hs="$dom";; RP_HYSTERIA2) hp=$ph; hs="$dom";; *) continue;; esac
      body=$(PU="$puuid" IU="$iu" R="$name ${itag#RP_}" A="$addr" P="$hp" S="$hs" NJ="$nj" python3 -c 'import json,os
b={"inbound":{"configProfileUuid":os.environ["PU"],"configProfileInboundUuid":os.environ["IU"]},"remark":os.environ["R"],
   "address":os.environ["A"],"port":int(os.environ["P"]),"sni":os.environ["S"] or None}
n=json.loads(os.environ["NJ"])
if n: b["nodes"]=n
print(json.dumps(b))')
      api POST /api/hosts "$body" && green "✔ Хост «$name ${itag#RP_}»: $addr:$hp" || yel "⚠ Хост ${itag#RP_} не создан: $(api_msg)"
    done <<< "$inb"
  fi
  steps_done "Профиль $title"
  echo
  section "ПОРТЫ НА НОДАХ"
  local need=""; case "$kind" in
    reality) need="$pr/tcp";; xhttp) need="$px/tcp";; trojan) need="$pt/tcp";; hy2) need="$ph/udp";; combo) need="$pr/tcp $px/tcp $ph/udp";; esac
  echo "  Должны быть открыты: $need (и в firewall у хостера)."
  local fa; ask "Открыть их в firewall нод по SSH? [y/N]"; read -r fa
  [[ "$fa" =~ ^[YyДд]$ ]] && xt_open_ports "$need"
  return 0
}

xt_open_ports() { # «443/tcp 8443/tcp 443/udp»
  PT_LOCAL=1 pick_targets "ГДЕ ОТКРЫТЬ ПОРТЫ" || return 0
  local t out p sc
  sc='for p in '"$1"'; do
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then ufw allow "$p" >/dev/null && echo "RP:OPEN $p"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$p" >/dev/null && echo "RP:OPEN $p"
  else echo "RP:NOFW"; break; fi
done; command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; true'
  for t in "${TARGETS[@]}"; do
    out=$(run_on "$t" "$sc" 2>&1 </dev/null)
    if [[ "$out" == *RP:OPEN* ]]; then green "✔ $(target_name "$t"): открыто $(grep -o 'RP:OPEN [^ ]*' <<< "$out" | cut -d' ' -f2 | tr '\n' ' ')"
    elif [[ "$out" == *RP:NOFW* ]]; then echo "  $(target_name "$t"): firewall выключен — порты и так открыты"
    else yel "⚠ $(target_name "$t"): не получилось"; why_first "$out" ssh; fi
  done
}

xt_menu() {
  local c
  need_panel || { pause; return; }
  while true; do
    screen "Готовые профили Xray"; echo
    echo "  Профиль создаётся в панели с правильными настройками: ключи Reality, порты, sniffing,"
    echo "  правила. Потом можно сразу переключить на него ноды и создать хосты для клиентов."
    section "ШАБЛОНЫ"
    item 1 "VLESS + Reality" "основной, самый быстрый"
    item 2 "VLESS + XHTTP" "запасной, если режут Reality"
    item 3 "Trojan" "TLS с сертификатом на домене ноды"
    item 4 "Hysteria2" "UDP, быстрый на плохих сетях"
    item 5 "Всё в одном" "Reality + XHTTP + Hysteria2"
    section "НОДА"
    item 6 "Подготовить ноду для Hysteria2 и Trojan" "сертификат · NET_ADMIN · порт UDP"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Профиль: VLESS + Reality" xt_create reality; pause ;;
      2) run_action "Профиль: VLESS + XHTTP" xt_create xhttp; pause ;;
      3) run_action "Профиль: Trojan" xt_create trojan; pause ;;
      4) run_action "Профиль: Hysteria2" xt_create hy2; pause ;;
      5) run_action "Профиль: всё в одном" xt_create combo; pause ;;
      6) run_action "Нода для Hysteria2" hy2_node_setup; pause ;;
      0|q|"") return ;;
    esac
  done
}
