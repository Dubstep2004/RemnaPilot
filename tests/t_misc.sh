# Разное: перевод, проверка IP, самообновление из файла, firewall, разбор sshd
source "$(dirname "$0")/lib.sh"
F=$(funcs)

# перевод: символ & в переводе не портит строку (bash 5.2)
out=$(RP_LANG=en bash -c 'source "'"$F"'"; RP_SELF="'"$SCRIPT"'"; rp_load_dict; T "Новый раздел «О программе и версии»"')
check "перевод с & без мусора" '[ "$out" = "New \"About & version\" section" ]'

# проверка IP: разбор ответов check-host.net
out=$(bash -c 'source "'"$F"'"; JOURNAL=/dev/null
ch_api(){ case "$1" in
 nodes/hosts) echo "{\"nodes\":{\"ru1.node.check-host.net\":{\"location\":[\"ru\",\"Russia\",\"Moscow\"]},\"ru2.node.check-host.net\":{\"location\":[\"ru\",\"Russia\",\"Saint Petersburg\"]},\"de1.node.check-host.net\":{\"location\":[\"de\",\"Germany\",\"Frankfurt\"]}}}";;
 check-tcp*) echo "{\"ok\":1,\"request_id\":\"tcp1\"}";; check-ping*) echo "{\"ok\":1,\"request_id\":\"ping1\"}";;
 check-result/tcp1) echo "{\"ru1.node.check-host.net\":[{\"time\":0.052}],\"ru2.node.check-host.net\":[{\"error\":\"Connection timed out\"}],\"de1.node.check-host.net\":[{\"time\":0.011}]}";;
 check-result/ping1) echo "{\"ru1.node.check-host.net\":[[[\"OK\",0.051],[\"OK\",0.053],[\"OK\",0.05],[\"OK\",0.052]]],\"ru2.node.check-host.net\":[[[\"TIMEOUT\",3.0],[\"TIMEOUT\",3.0]]],\"de1.node.check-host.net\":null}";;
esac; }
curl(){ case "$*" in *ifconfig.me*) echo 9.9.9.9;; *ipinfo.io*) echo "{\"country\": \"NL\", \"city\": \"Amsterdam\", \"org\": \"AS1 Test\"}";; *speed.cloudflare*) echo 12500000;; esac; }
ping(){ echo "rtt min/avg/max/mdev = 1/12/14/0 ms"; }; sleep(){ :; }
echo | ip_check' 2>&1 | nocolor)
out_has "узел РФ: доступен" "Moscow" "$out"
out_has "частичная блокировка распознана" "1 из 2" "$out"
out_has "скорость посчитана" "100 Мбит/с" "$out"

# самообновление из файла: битый файл отклоняется, новый ставится
sed 's/^RP_VERSION="[^"]*"/RP_VERSION="99.0"/' "$SCRIPT" > "$T/new.sh"; echo "not a script" > "$T/bad.sh"
out=$(bash -c 'source "'"$F"'"; JOURNAL=/dev/null; install(){ echo "[install $*]"; }; rp_reexec(){ echo "[reexec]"; }; sleep(){ :; }
  self_update "'"$T"'/bad.sh"; self_update "'"$T"'/new.sh"' 2>&1 | nocolor)
out_has "битый файл отклонён" "не RemnaPilot или файл повреждён" "$out"
out_has "новая версия ставится" "→ v99.0" "$out"
out_has "и скрипт перезапускается" "[reexec]" "$out"

# ссылки обновления собираются из owner/repo
out=$(bash -c 'source "'"$F"'"; RP_SRC_FILE="'"$T"'/src"; echo "user/repo" > "$RP_SRC_FILE"; rp_source_urls')
out_has "ссылка на последний релиз" "https://github.com/user/repo/releases/latest/download/remnapilot.sh" "$out"
out_has "запасная ссылка на main" "https://raw.githubusercontent.com/user/repo/main/remnapilot.sh" "$out"

# firewall: SSH, 80, 443, порты Xray (TCP и UDP), нода только с IP панели
mkdir -p "$T/bin" "$T/node"
printf '#!/bin/bash\necho "ufw $*" >> %s/ufw.log\n[[ "$1" == status ]] && echo "Status: inactive"\nexit 0\n' "$T" > "$T/bin/ufw"
cat > "$T/bin/ss" <<'S'
#!/bin/bash
cat <<'X'
tcp   LISTEN 0 4096   0.0.0.0:22      0.0.0.0:*  users:(("sshd",pid=1,fd=3))
tcp   LISTEN 0 4096   0.0.0.0:443     0.0.0.0:*  users:(("xray",pid=2,fd=3))
tcp   LISTEN 0 4096   0.0.0.0:8443    0.0.0.0:*  users:(("xray",pid=2,fd=4))
tcp   LISTEN 0 4096   0.0.0.0:2222    0.0.0.0:*  users:(("node",pid=3,fd=5))
udp   UNCONN 0 0      0.0.0.0:443     0.0.0.0:*  users:(("xray",pid=2,fd=6))
X
S
printf '#!/bin/sh\n[ "$1" = -T ] && echo "port 22"\nexit 0\n' > "$T/bin/sshd"; chmod +x "$T/bin"/*
printf 'services:\n  remnanode:\n    environment:\n      - NODE_PORT=2222\n' > "$T/node/docker-compose.yml"
PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; RW_DIR=/nonexistent; JOURNAL=/dev/null; node_dir(){ echo "'"$T"'/node"; }; docker(){ :; }
  printf "5.5.5.5\n\ny\n" | fw_setup' >/dev/null 2>&1
check "SSH разрешён первым" '[ "$(grep -m1 allow "$T/ufw.log")" = "ufw allow 22/tcp comment SSH" ]'
check "порты Xray TCP и UDP открыты" 'grep -q "allow 8443/tcp" "$T/ufw.log" && grep -q "allow 443/udp" "$T/ufw.log"'
check "порт ноды только с IP панели" 'grep -q "allow from 5.5.5.5 to any port 2222" "$T/ufw.log" && ! grep -q "allow 2222/tcp" "$T/ufw.log"'
finish
