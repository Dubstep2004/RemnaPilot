# ---------- панель и нода на одном сервере ----------
# Нода ставится рядом с панелью (network_mode: host), панель подключается к ней через шлюз
# docker-сети remnawave-network — порт ноды не нужно открывать наружу.
net_gw() { docker network inspect remnawave-network -f '{{range .IPAM.Config}}{{.'"$1"'}} {{end}}' 2>/dev/null | awk '{print $1}'; }

panel_node_local() {
  need_panel || return 1
  if node_dir >/dev/null 2>&1; then fail "Нода на этом сервере уже стоит ($(node_dir))"; todo "обновить: Панель → Обновления" "удалить: Установка → Установка и обновление нод → Удалить ноду"; return 1; fi
  local port gw sub key profs n pick puuid pname ports inb name body uuid i st web443 log
  gw=$(net_gw Gateway); sub=$(net_gw Subnet)
  [[ -n "$gw" ]] || { fail "Не нашёл docker-сеть remnawave-network"; cause "панель запущена не по инструкции docs.rw"; return 1; }
  api_ready || return $?
  echo "Поставлю ноду на этот сервер и сразу добавлю её в панель. Панель подключится к ней изнутри (через $gw)."
  ask "Порт ноды (NODE_PORT) [2222]"; read -r port; port="${port:-2222}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { fail "Некорректный порт: $port"; return 1; }
  port_busy "$port" && { fail "Порт $port занят: $(port_owner "$port")"; todo "выбери другой порт"; return 1; }

  api GET /api/config-profiles || { fail "Не получил профили конфигурации" ; cause "$(api_msg)"; return 1; }
  profs=$(jget '"\n".join(p["uuid"]+"\t"+p["name"]+"\t"+",".join(i["uuid"] for i in p.get("inbounds",[]))+"\t"+" ".join(str(i.get("port")) for i in p.get("inbounds",[])) for p in j["response"]["configProfiles"])' <<< "$API_OUT")
  [[ -n "$profs" ]] || { fail "В панели нет профиля конфигурации"; todo "создай его в панели: Конфиг-профили → +" "и запусти этот пункт ещё раз"; return 1; }
  n=$(wc -l <<< "$profs")
  if (( n > 1 )); then
    section "ПРОФИЛЬ КОНФИГУРАЦИИ"
    i=0; while IFS=$'\t' read -r _ name _ _; do i=$((i+1)); item $i "$name"; done <<< "$profs"
    ask "Профиль [1]"; read -r pick; pick="${pick:-1}"
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= n )) || { echo "  Отменено."; return $RP_CANCEL; }
  else pick=1; fi
  IFS=$'\t' read -r puuid pname inb ports <<< "$(sed -n "${pick}p" <<< "$profs")"
  web443=$(port_busy 443 && port_owner 443)
  [[ " $ports " == *" 443 "* && -n "$web443" ]] && yel "⚠ В профиле «$pname» есть inbound на порту 443, а его занимает веб-сервер панели ($web443) — этот inbound не запустится. Смени ему порт или используй Selfsteal (Ноды → Selfsteal для Reality)."

  steps 4
  step "Ставлю ноду"
  api GET /api/keygen; key=$(jget 'j["response"].get("secretKey") or j["response"].get("pubKey")' <<< "$API_OUT")
  [[ -n "$key" ]] || { fail "Панель не отдала SECRET_KEY"; cause "$(api_msg)"; steps_done; return 1; }
  log=$(node_script "$port" "$key" "$sub" | bash 2>&1) || { fail "Нода не установилась" docker "$log"; steps_done; return 1; }
  wait_healthy remnanode 30 || { fail "Нода не запустилась" container "$(docker logs --tail 40 remnanode 2>&1)"; steps_done; return 1; }
  green "✔ Нода работает (порт $port, доступ только из docker-сети $sub)"

  step "Добавляю ноду в панель"
  name="$(hostname -s | cut -c1-24)"; (( ${#name} >= 3 )) || name="local-node"; name="$name-local"; name="${name:0:30}"
  body=$(N="$name" A="$gw" P="$port" U="$puuid" I="$inb" python3 -c 'import json,os
print(json.dumps({"name":os.environ["N"],"address":os.environ["A"],"port":int(os.environ["P"]),"countryCode":"XX",
 "configProfile":{"activeConfigProfileUuid":os.environ["U"],"activeInbounds":[x for x in os.environ["I"].split(",") if x]}}))')
  api POST /api/nodes "$body" || { fail "Нода не добавилась в панель"; cause "$(api_msg)"; todo "добавь вручную: панель → Ноды → + , адрес $gw, порт $port"; steps_done; return 1; }
  uuid=$(jget 'j["response"]["uuid"]' <<< "$API_OUT")
  green "✔ В панели: «$name» ($gw:$port), профиль «$pname»"

  step "Жду, пока панель подключится к ноде"
  for i in $(seq 1 20); do
    api GET "/api/nodes/$uuid" && st=$(jget 'j["response"]["isConnected"]' <<< "$API_OUT")
    [[ "$st" == true ]] && break; sleep 3
  done
  if [[ "$st" == true ]]; then green "✔ Нода онлайн"
  else st=$(jget 'j["response"].get("lastStatusMessage") or ""' <<< "$API_OUT"); yel "⚠ Панель пока не подключилась к ноде: $st"; todo "логи ноды: docker logs --tail 30 remnanode"; fi
  steps_done "Нода на сервере панели"
  echo "  Хосты для клиентов укажи с публичным адресом сервера (домен или IP), не $gw."
}

# ---------- правила Xray во всех профилях: торренты, реклама ----------
XR_PY='
import json,sys
act,kind=sys.argv[1],sys.argv[2]
tag={"torrent":"rp-torrent","ads":"rp-ads"}[kind]
out=[]; sniff=0
for p in json.load(sys.stdin)["response"]["configProfiles"]:
    cfg=p.get("config") or {}
    if not isinstance(cfg,dict): continue
    rules=cfg.setdefault("routing",{}).setdefault("rules",[])
    had=any(r.get("ruleTag")==tag for r in rules)
    if act=="status":
        out.append(("1" if had else "0")+"\t"+p["name"]); continue
    rules[:]=[r for r in rules if r.get("ruleTag")!=tag]
    if act=="on":
        obs=cfg.setdefault("outbounds",[])
        bl=next((o["tag"] for o in obs if o.get("protocol")=="blackhole" and o.get("tag")),None)
        if not bl:
            bl="rp-block" if any(o.get("tag")=="BLOCK" for o in obs) else "BLOCK"
            obs.append({"tag":bl,"protocol":"blackhole"})
        r={"type":"field","ruleTag":tag,"outboundTag":bl}
        if kind=="torrent": r["protocol"]=["bittorrent"]
        else: r["domain"]=["geosite:category-ads-all"]
        rules.insert(0,r)
        for ib in cfg.get("inbounds",[]):
            s=ib.get("sniffing")
            if not isinstance(s,dict) or not s.get("enabled"):
                ib["sniffing"]={"enabled":True,"destOverride":["http","tls","quic"]}; sniff+=1
            else:
                d=s.setdefault("destOverride",[])
                for x in ("http","tls"):
                    if x not in d: d.append(x); sniff+=1
    elif not had: continue
    out.append(json.dumps({"uuid":p["uuid"],"config":cfg},ensure_ascii=False))
if act!="status": out.append("#sniff\t%d"%sniff)
print("\n".join(out))
'

xr_status() { # вид → «вкл в N из M профилей»
  api GET /api/config-profiles 2>/dev/null || { echo "?"; return; }
  python3 -c "$XR_PY" status "$1" <<< "$API_OUT" 2>/dev/null | awk -F'\t' '{n++; o+=$1} END{print o+0 "/" n+0}'
}

xr_toggle() { # on|off вид
  api_ready || return $?
  api GET /api/config-profiles || { fail "Не получил профили конфигурации"; cause "$(api_msg)"; return 1; }
  local lines l ok=0 bad=0 sn=0
  lines=$(python3 -c "$XR_PY" "$1" "$2" <<< "$API_OUT") || { fail "Не разобрал профили конфигурации"; return 1; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    [[ "$l" == "#sniff"* ]] && { sn="${l#*$'\t'}"; continue; }
    if api PATCH /api/config-profiles "$l"; then ok=$((ok+1)); else bad=$((bad+1)); fail "Профиль не обновился"; cause "$(api_msg)"; fi
  done <<< "$lines"
  (( ok + bad )) || { echo "  Менять нечего — в профилях этого правила нет."; return 0; }
  (( ok )) && green "✔ Обновлено профилей: $ok — панель сама перезапустит Xray на нодах"
  [[ "$1" == on ]] && (( sn )) && info "Включил распознавание трафика (sniffing) у inbound: без него Xray не видит торренты и домены"
  (( bad == 0 ))
}

# ---------- Torrent Blocker (плагин ноды, панель 2.7+) ----------
TB_PY='
import json,sys
mode,plug=sys.argv[1],sys.argv[2]
j=json.load(sys.stdin)["response"]
if mode=="find":
    print(next((p["uuid"] for p in j["nodePlugins"] if p["name"]=="RemnaPilot"),""))
elif mode=="cfg":
    c=j.get("pluginConfig") or {}
    on=sys.argv[3]=="on"
    tb=c.get("torrentBlocker") or {"blockDuration":3600,"ignoreLists":{"ip":[]}}
    tb["enabled"]=on; tb.setdefault("blockDuration",3600); tb.setdefault("ignoreLists",{"ip":[]})
    c["torrentBlocker"]=tb
    print(json.dumps({"uuid":plug,"pluginConfig":c}))
elif mode=="nodes":
    for n in j:
        a=n.get("activePluginUuid")
        print(n["uuid"]+"\t"+("free" if not a else ("ours" if a==plug else "other"))+"\t"+n["name"])
'

node_cap_script() {
  cat <<'EOF'
d=""; for x in /opt/remnanode /opt/remnawave-node; do [ -f "$x/docker-compose.yml" ] && { d=$x; break; }; done
[ -n "$d" ] || { echo "RP:NOCOMPOSE"; exit 3; }
cd "$d"
k=$(uname -r | awk -F. '{print $1*100+$2}'); [ "$k" -ge 507 ] || echo "RP:OLDKERNEL $(uname -r)"
grep -q NET_ADMIN docker-compose.yml && { echo "RP:CAP_OK"; exit 0; }
cp docker-compose.yml docker-compose.yml.bak-cap
perl -0777 -i -pe '$ok = s/^([ \t]*)(image:[ \t]*\S*remnawave\/node\S*[^\n]*\n)/$1$2$1cap_add:\n$1  - NET_ADMIN\n/m; END { exit !$ok }' docker-compose.yml || { cp docker-compose.yml.bak-cap docker-compose.yml; echo "RP:NOIMAGE"; exit 4; }
docker compose up -d >/dev/null 2>&1 && echo "RP:CAP_ADDED" || { cp docker-compose.yml.bak-cap docker-compose.yml; echo "RP:UPFAIL"; exit 5; }
EOF
}

tb_plugin() { # on|off
  api_ready || return $?
  api GET /api/node-plugins || { fail "Torrent Blocker недоступен"; cause "$( [[ "$API_CODE" == 404 ]] && echo "плагины нод появились в Remnawave 2.7 — обнови панель и ноды" || api_msg)"; return 1; }
  local plug cfg l nu st nm others=() t out
  plug=$(python3 -c "$TB_PY" find "" <<< "$API_OUT")
  if [[ -z "$plug" ]]; then
    [[ "$1" == off ]] && { echo "  Плагина RemnaPilot нет — выключать нечего."; return 0; }
    api POST /api/node-plugins '{"name":"RemnaPilot"}' || { fail "Плагин не создался"; cause "$(api_msg)"; return 1; }
    plug=$(jget 'j["response"]["uuid"]' <<< "$API_OUT")
  fi
  api GET "/api/node-plugins/$plug" || { fail "Плагин не читается"; cause "$(api_msg)"; return 1; }
  cfg=$(python3 -c "$TB_PY" cfg "$plug" "$1" <<< "$API_OUT")
  api PATCH /api/node-plugins "$cfg" || { fail "Плагин не обновился"; cause "$(api_msg)"; return 1; }
  if [[ "$1" == off ]]; then green "✔ Torrent Blocker выключен (плагин «RemnaPilot»)"; return 0; fi
  green "✔ Torrent Blocker включён в плагине «RemnaPilot»: IP с торрентом блокируется на 1 час"
  api GET /api/nodes || { fail "Не получил список нод"; cause "$(api_msg)"; return 1; }
  while IFS=$'\t' read -r nu st nm; do
    [[ -n "$nu" ]] || continue
    case "$st" in
      free) api PATCH /api/nodes "{\"uuid\":\"$nu\",\"activePluginUuid\":\"$plug\"}" && green "✔ Нода «$nm»: плагин подключён" || yel "⚠ Нода «$nm»: $(api_msg)" ;;
      other) others+=("$nm") ;;
    esac
  done < <(python3 -c "$TB_PY" nodes "$plug" <<< "$API_OUT")
  (( ${#others[@]} )) && yel "⚠ У нод ${others[*]} свой плагин — включи Torrent Blocker в нём (панель → Плагины нод)."
  section "NET_ADMIN ДЛЯ НОД"
  echo "  Нодам нужно право NET_ADMIN, чтобы блокировать IP (nftables). Добавлю его в docker-compose нод."
  local targets=(); node_dir >/dev/null 2>&1 && targets+=(local)
  [[ -s "$NODES_FILE" ]] && while read -r nm h p; do [[ -n "$nm" ]] && targets+=("$nm|$h|$p"); done < "$NODES_FILE"
  (( ${#targets[@]} )) || { echo "  Нод в RemnaPilot нет — добавь NET_ADMIN вручную: cap_add: [NET_ADMIN] в docker-compose ноды."; return 0; }
  for t in "${targets[@]}"; do
    out=$(run_on "$t" "$(node_cap_script)" 2>&1 </dev/null)
    case "$out" in
      *RP:CAP_ADDED*) green "✔ $(target_name "$t"): NET_ADMIN добавлен, нода перезапущена" ;;
      *RP:CAP_OK*)    green "✔ $(target_name "$t"): NET_ADMIN уже есть" ;;
      *RP:NOCOMPOSE*) yel "⚠ $(target_name "$t"): не нашёл docker-compose ноды" ;;
      *)              yel "⚠ $(target_name "$t"): не получилось"; why_first "$out" ssh docker ;;
    esac
    [[ "$out" == *RP:OLDKERNEL* ]] && yel "  ядро ${out##*RP:OLDKERNEL } — Torrent Blocker нужен Linux 5.7+"
  done
}

tb_state() { # вкл|выкл|нет — состояние Torrent Blocker в плагине RemnaPilot
  api GET /api/node-plugins 2>/dev/null || { echo "нет"; return; }
  local plug; plug=$(python3 -c "$TB_PY" find "" <<< "$API_OUT" 2>/dev/null)
  [[ -n "$plug" ]] && api GET "/api/node-plugins/$plug" && [[ "$(jget '(j["response"].get("pluginConfig") or {}).get("torrentBlocker",{}).get("enabled")' <<< "$API_OUT")" == true ]] && echo "вкл" || echo "выкл"
}

block_state_line() { # подпись, «N/M»
  local n="${2%/*}" m="${2#*/}"
  if [[ "$2" == "?" ]]; then box_line "$(dot warn) $(padr "$1" 16)${C0}нет доступа к API"
  elif (( n > 0 )); then box_line "$(dot ok) $(padr "$1" 16)${C0}включено ($n из $m профилей)"
  else box_line "$(dot warn) $(padr "$1" 16)${C0}выключено"; fi
}

torrent_menu() {
  local c
  need_panel || { pause; return; }
  [[ -s "$API_CONF" ]] || { api_ready || { pause; return; }; }
  while true; do
    screen "Блокировка торрентов"; echo
    box_top; block_state_line "Правило Xray" "$(xr_status torrent)"
    box_line "$(dot "$([[ "$(tb_state)" == вкл ]] && echo ok || echo warn)") $(padr "Torrent Blocker" 16)$(tb_state)"; box_bottom
    echo "  Правило Xray — торрент-трафик не уходит дальше ноды (работает в любой версии)."
    echo "  Torrent Blocker — плагин ноды: ещё и блокирует IP пользователя на час (Remnawave 2.7+)."
    section "ДЕЙСТВИЯ"
    item 1 "Включить правило Xray" "во всех профилях конфигурации"
    item 2 "Выключить правило Xray"
    item 3 "Включить Torrent Blocker" "плагин + NET_ADMIN нодам"
    item 4 "Выключить Torrent Blocker"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Торренты: правило Xray" xr_toggle on torrent; pause ;;
      2) run_action "Торренты: правило Xray выкл" xr_toggle off torrent; pause ;;
      3) run_action "Торренты: Torrent Blocker" tb_plugin on; pause ;;
      4) run_action "Торренты: Torrent Blocker выкл" tb_plugin off; pause ;;
      0|q|"") return ;;
    esac
  done
}

ads_menu() {
  local c
  need_panel || { pause; return; }
  [[ -s "$API_CONF" ]] || { api_ready || { pause; return; }; }
  while true; do
    screen "Блокировка рекламы и трекеров"; echo
    box_top; block_state_line "Реклама/трекеры" "$(xr_status ads)"; box_bottom
    echo "  Xray на нодах не пускает к рекламным и следящим доменам (список geosite:category-ads-all)."
    echo "  Для всех клиентов сразу, в приложениях ничего настраивать не нужно."
    section "ДЕЙСТВИЯ"
    item 1 "Включить" "во всех профилях конфигурации"
    item 2 "Выключить"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Реклама: блокировка" xr_toggle on ads; pause ;;
      2) run_action "Реклама: блокировка выкл" xr_toggle off ads; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- Selfsteal для Reality ----------
# На ноде Caddy отдаёт настоящий сайт с сертификатом на домен ноды (только на 127.0.0.1),
# а Reality маскируется под него: target 127.0.0.1:порт, serverNames — домен ноды.
SS_DIR="/opt/selfsteal"

selfsteal_script() { # домен, порт
  cat <<EOF
command -v docker >/dev/null 2>&1 || { echo "RP:NODOCKER"; exit 3; }
if [ ! -f $SS_DIR/Caddyfile ] && ss -ltnH 'sport = :80' | grep -q .; then echo "RP:BUSY80 \$(ss -ltnpH 'sport = :80' | grep -o '"[^"]*"' | head -1)"; exit 4; fi
if [ ! -f $SS_DIR/Caddyfile ] && ss -ltnH 'sport = :$2' | grep -q .; then echo "RP:BUSYPORT"; exit 4; fi
mkdir -p $SS_DIR/html && cd $SS_DIR
cat > Caddyfile <<'CF'
# Создано RemnaPilot: сайт для маскировки Reality (selfsteal). Слушает только 127.0.0.1:$2.
{
    https_port $2
    auto_https disable_redirects
}

http://$1 {
    bind 0.0.0.0
    redir https://{host}{uri} permanent
}

https://$1 {
    bind 127.0.0.1
    root * /srv
    file_server
    header -Server
}
CF
[ -f html/index.html ] || cat > html/index.html <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px/1.6 system-ui,sans-serif;background:#f6f6f4;color:#222}
main{max-width:34rem;padding:2rem;text-align:center}h1{font-weight:600;margin:0 0 .5rem}p{color:#666;margin:0}</style></head>
<body><main><h1>$1</h1><p>We are working on something new. Please check back soon.</p></main></body></html>
HTML
cat > docker-compose.yml <<'YML'
services:
  selfsteal:
    image: caddy:2.9
    container_name: selfsteal
    hostname: selfsteal
    restart: always
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/srv:ro
      - selfsteal-data:/data

volumes:
  selfsteal-data:
    name: selfsteal-data
YML
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow 80/tcp >/dev/null && echo "RP:UFW80"; fi
docker compose up -d 2>&1 | tail -3
sleep 3
docker exec selfsteal caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && echo "RP:VALID" || echo "RP:INVALID"
for i in \$(seq 1 20); do
  curl -s -o /dev/null --max-time 4 --resolve "$1:$2:127.0.0.1" "https://$1:$2/" && { echo "RP:CERT"; break; }
  sleep 3
done
docker ps --filter name=^selfsteal\$ --format 'RP:STATUS {{.Status}}'
EOF
}

selfsteal_rm_script() { echo "cd $SS_DIR 2>/dev/null && docker compose down -v --rmi all >/dev/null 2>&1; rm -rf $SS_DIR; echo RP:REMOVED"; }

reality_snippet() { # домен, порт
  cat <<EOF
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:$2",
    "serverNames": ["$1"],
    "privateKey": "…оставь свой…",
    "shortIds": ["…оставь свои…"]
  }
EOF
}

RL_PY='
import json,sys
mode=sys.argv[1]
j=json.load(sys.stdin)["response"]["configProfiles"]
if mode=="list":
    for p in j:
        for ib in (p.get("config") or {}).get("inbounds",[]):
            if (ib.get("streamSettings") or {}).get("security")=="reality":
                print(p["uuid"]+"\t"+ib.get("tag","")+"\t"+p["name"]+"\t"+str(ib.get("port","")))
else:
    pu,tag,dom,port=sys.argv[2:6]
    for p in j:
        if p["uuid"]!=pu: continue
        cfg=p["config"]
        for ib in cfg.get("inbounds",[]):
            if ib.get("tag")==tag:
                rs=ib["streamSettings"].setdefault("realitySettings",{})
                key="dest" if "dest" in rs and "target" not in rs else "target"
                rs[key]="127.0.0.1:"+port; rs["serverNames"]=[dom]; rs["xver"]=0
        print(json.dumps({"uuid":pu,"config":cfg},ensure_ascii=False))
'

reality_apply() { # домен, порт — прописать selfsteal в inbound Reality через API
  api_ready || return $?
  api GET /api/config-profiles || { fail "Не получил профили"; cause "$(api_msg)"; return 1; }
  local lines n pick pu tag pn pp body
  lines=$(python3 -c "$RL_PY" list <<< "$API_OUT")
  [[ -n "$lines" ]] || { yel "⚠ В профилях нет inbound с Reality — пропиши настройки вручную."; return 1; }
  n=$(wc -l <<< "$lines")
  section "INBOUND REALITY"
  local i=0; while IFS=$'\t' read -r _ tag pn pp; do i=$((i+1)); item $i "$tag" "профиль «$pn», порт $pp"; done <<< "$lines"
  hr; item 0 "Не менять"
  ask "Куда прописать selfsteal [1]"; read -r pick; pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= n )) || { echo "  Не меняю профиль."; return 0; }
  IFS=$'\t' read -r pu tag pn pp <<< "$(sed -n "${pick}p" <<< "$lines")"
  body=$(python3 -c "$RL_PY" set "$pu" "$tag" "$1" "$2" <<< "$API_OUT")
  api PATCH /api/config-profiles "$body" || { fail "Профиль не обновился"; cause "$(api_msg)"; return 1; }
  green "✔ Inbound «$tag»: target 127.0.0.1:$2, serverNames $1 — панель перезапустит Xray на нодах"
  echo "  В хостах для клиентов SNI тоже должен быть $1."
}

selfsteal_install() {
  local dom port out t
  PT_LOCAL=1 pick_targets "КУДА СТАВИТЬ SELFSTEAL (на сервер с нодой)" || { echo "  Отменено."; return $RP_CANCEL; }
  (( ${#TARGETS[@]} == 1 )) || { fail "Selfsteal ставится на одну ноду за раз"; return 1; }
  t="${TARGETS[0]}"
  echo "Нужен домен ноды с A-записью на её IP и свободный порт 80 (Caddy получает по нему сертификат)."
  pi_ask_domain "Домен ноды (например de.example.com)" dom || { echo "  Отменено."; return $RP_CANCEL; }
  ask "Внутренний порт сайта [9443]"; read -r port; port="${port:-9443}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 1024 && port < 65536 )) || { fail "Некорректный порт: $port"; return 1; }
  [[ "$t" == local ]] && node_domain_check "$dom" "$(curl -4 -s --max-time 5 https://ifconfig.me)" || node_domain_check "$dom" "$(ip_of "$(cut -d'|' -f2 <<< "$t" | cut -d@ -f2)")"

  steps 3
  local tn; tn=$(target_name "$t")
  step "Ставлю Caddy с сайтом на $tn"
  out=$(run_on "$t" "$(selfsteal_script "$dom" "$port")" 2>&1)
  case "$out" in
    *RP:NODOCKER*) fail "На сервере нет Docker"; todo "сначала поставь ноду: Установка → Установка и обновление нод"; steps_done; return 1 ;;
    *RP:BUSY80*)   fail "Порт 80 занят: ${out##*RP:BUSY80 }"; cause "Caddy нужен порт 80, чтобы получить сертификат"; todo "освободи порт 80 на ноде"; steps_done; return 1 ;;
    *RP:BUSYPORT*) fail "Порт $port занят"; todo "выбери другой внутренний порт"; steps_done; return 1 ;;
  esac
  [[ "$out" == *RP:VALID* ]] || { fail "Caddy не запустился" docker "$out"; steps_done; return 1; }
  [[ "$out" == *RP:UFW80* ]] && info "Открыл 80/tcp в ufw — нужен Caddy для продления сертификата"
  green "✔ Caddy работает: https://$dom → 127.0.0.1:$port"

  step "Проверяю сертификат"
  if [[ "$out" == *RP:CERT* ]]; then green "✔ Сертификат Let's Encrypt выпущен"
  else yel "⚠ Сертификат пока не выпущен — обычно A-запись не указывает на ноду или порт 80 закрыт у хостера."
       todo "Caddy будет пробовать сам; логи: docker logs --tail 30 selfsteal"; fi

  step "Настройки Reality"
  if [[ -f "$RW_DIR/.env" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave; then
    reality_apply "$dom" "$port" || { echo; bold "  Пропиши в inbound Reality (панель → Конфиг-профили):"; reality_snippet "$dom" "$port"; }
  else
    echo; bold "  Пропиши в inbound Reality (панель → Конфиг-профили):"; reality_snippet "$dom" "$port"
  fi
  steps_done "Selfsteal"
}

selfsteal_remove() {
  PT_LOCAL=1 pick_targets "ГДЕ УБРАТЬ SELFSTEAL" || { echo "  Отменено."; return $RP_CANCEL; }
  local t out
  for t in "${TARGETS[@]}"; do
    out=$(run_on "$t" "$(selfsteal_rm_script)" 2>&1)
    [[ "$out" == *RP:REMOVED* ]] && green "✔ $(target_name "$t"): selfsteal удалён" || { yel "⚠ $(target_name "$t"): не получилось"; why_first "$out" ssh; }
  done
  yel "  Не забудь вернуть в inbound Reality прежний target и serverNames."
}

selfsteal_menu() {
  local c st
  while true; do
    screen "Selfsteal для Reality"; echo
    st=$(docker ps -a --filter name=^selfsteal$ --format '{{.Status}}' 2>/dev/null)
    box_top
    if [[ -n "$st" ]]; then box_line "$(dot ok) $(padr "Этот сервер" 12)$(grep -m1 -oE '^https://[^ ]+' "$SS_DIR/Caddyfile" 2>/dev/null | sed 's|https://||') · $st"
    else box_line "$(dot warn) $(padr "Этот сервер" 12)${C0}не установлен"; fi
    box_bottom
    echo "  Reality маскируется под твой собственный сайт на домене ноды, а не под чужой."
    echo "  Сайт с настоящим сертификатом, его не заблокировать «за компанию» с чужим SNI."
    section "ДЕЙСТВИЯ"
    item 1 "Установить selfsteal" "здесь или на ноде по SSH"
    item 2 "Удалить selfsteal"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "Selfsteal: установка" selfsteal_install; pause ;;
      2) run_action "Selfsteal: удаление" selfsteal_remove; pause ;;
      0|q|"") return ;;
    esac
  done
}

# ---------- IPv6 ----------
IPV6_CONF="/etc/sysctl.d/99-remnapilot-ipv6.conf"

ipv6_script() { # off|on
  cat <<EOF
c="\${SSH_CONNECTION%% *}"
if [ "$1" = off ]; then
  case "\$c" in *:*) case "\$c" in ::ffff:*) ;; *) echo "RP:SSH6 \$c"; exit 3 ;; esac ;; esac
  printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 0\n' > $IPV6_CONF
  sysctl -q -p $IPV6_CONF >/dev/null 2>&1
else
  rm -f $IPV6_CONF
  sysctl -q -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
  for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo 0 > "\$i" 2>/dev/null; done
fi
echo "RP:STATE \$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) \$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)"
EOF
}

ipv6_line() { # 0/1 disable, число адресов
  if [[ "$1" == 1 ]]; then echo "${C_WARN}выключен${C0}"
  elif (( ${2:-0} > 0 )); then echo "${C_OK}включён${C0} · адресов: $2"
  else echo "включён · ${C_MUT}внешнего адреса IPv6 нет${C0}"; fi
}

ipv6_set() { # off|on
  local h="ГДЕ ВЫКЛЮЧИТЬ IPV6"; [[ "$1" == on ]] && h="ГДЕ ВКЛЮЧИТЬ IPV6"
  PT_LOCAL=1 pick_targets "$h" || { echo "  Отменено."; return $RP_CANCEL; }
  local t out bad=0 s
  for t in "${TARGETS[@]}"; do
    out=$(run_on "$t" "$(ipv6_script "$1")" 2>&1 </dev/null)
    case "$out" in
      *RP:SSH6*)  fail "$(target_name "$t"): ты подключён по IPv6 (${out##*RP:SSH6 }) — выключение оборвёт SSH"; todo "подключись по IPv4 и повтори"; bad=1 ;;
      *RP:STATE*) s=${out##*RP:STATE }; green "✔ $(target_name "$t"): IPv6 $(ipv6_line ${s% *} ${s#* })" ;;
      *)          fail "$(target_name "$t"): не получилось"; why_first "$out" ssh; bad=1 ;;
    esac
  done
  [[ "$1" == on ]] && echo "  Внешний адрес IPv6 вернётся сам через минуту-две (или после перезагрузки)."
  [[ "$1" == off ]] && echo "  Настройка сохраняется после перезагрузки ($IPV6_CONF)."
  return $bad
}

ipv6_menu() {
  local c d a
  while true; do
    screen "IPv6"; echo
    d=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null); a=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
    box_top; box_line "$(dot "$([[ "$d" == 1 ]] && echo warn || echo ok)") $(padr "Этот сервер" 12)$(ipv6_line "$d" "$a")"; box_bottom
    echo "  Выключи IPv6, если у хостера он кривой: клиенты зависают, сайты определяют не ту страну."
    section "ДЕЙСТВИЯ"
    item 1 "Выключить IPv6" "здесь или на нодах по SSH"
    item 2 "Включить IPv6"
    hr; item 0 "Назад"
    ask; read -r c; echo
    case "$c" in
      1) run_action "IPv6: выключить" ipv6_set off; pause ;;
      2) run_action "IPv6: включить" ipv6_set on; pause ;;
      0|q|"") return ;;
    esac
  done
}
