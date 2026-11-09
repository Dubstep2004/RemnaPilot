# Сертификаты: запасной способ при занятом/закрытом порте, очистка старых заказов acme.sh
source "$(dirname "$0")/lib.sh"
cat > "$T/acme.sh" <<'A'
#!/bin/bash
echo "acme $*" >> "$(dirname "$0")/calls.log"
case "$*" in
  *--standalone*) echo "Verify error: Fetching http://x/.well-known: Timeout during connect (likely firewall problem)"; exit 1 ;;
esac
exit 0
A
chmod +x "$T/acme.sh"
out=$(cd "$T" && bash -c 'source "'"$(funcs)"'"; RW_DIR="'"$T"'"; HOOK_DIR="'"$T"'/hooks"; JOURNAL=/dev/null
  acme_bin(){ echo "'"$T"'/acme.sh"; }; nginx_has_ssl(){ return 0; }
  cert_paths_for(){ printf "%s\t%s\n" "'"$T"'/f.pem" "'"$T"'/k.key"; }; names_sharing_cert(){ echo "a.example.com b.example.com"; }
  port_busy(){ return 0; }; port_owner(){ echo "xray"; }; free_port(){ return 0; }; fw_open(){ :; }; behind_proxy(){ return 1; }
  ensure_acme_cron(){ :; }; acme_forget_others(){ echo "[forget $1 $2]"; }; docker(){ :; }
  command(){ [[ "$2" == socat ]] && return 0; builtin command "$@"; }
  printf "1\n1\n" | issue_cert a.example.com; echo "rc=$?"' 2>&1 | nocolor)
out_has "объяснена причина: порт закрыт" "закрыт снаружи" "$out"
out_has "предложен другой способ" "Попробовать другой способ?" "$out"
out_has "сертификат выпущен через 443" "rc=0" "$out"
out_has "старые заказы acme.sh отключаются" "[forget $T/f.pem a.example.com]" "$out"
check "сертификат на оба имени" 'grep -q -- "-d a.example.com -d b.example.com" "$T/calls.log"'
check "хуки продления свои для домена" '[ -x "$T/hooks/a.example.com-pre.sh" ] && [ -x "$T/hooks/a.example.com-post.sh" ]'

# acme_forget_others: удаляет только чужие заказы на тот же файл
H="$T/home"; mkdir -p "$H/.acme.sh/old.com_ecc" "$H/.acme.sh/new.com_ecc" "$H/.acme.sh/other.com"
printf "Le_Domain='old.com'\nLe_RealFullChainPath='/x/full.pem'\n" > "$H/.acme.sh/old.com_ecc/old.com.conf"
printf "Le_Domain='new.com'\nLe_RealFullChainPath='/x/full.pem'\n" > "$H/.acme.sh/new.com_ecc/new.com.conf"
printf "Le_Domain='other.com'\nLe_RealFullChainPath='/x/sub.pem'\n" > "$H/.acme.sh/other.com/other.com.conf"
: > "$T/calls.log"
HOME="$H" bash -c 'source "'"$T"'/funcs.sh"; HOOK_DIR=/nonexistent; acme_bin(){ echo "'"$T"'/acme.sh"; }; acme_forget_others /x/full.pem new.com' >/dev/null 2>&1
check "старый заказ на тот же файл удалён" 'grep -qx "acme --remove -d old.com --ecc" "$T/calls.log"'
check "текущий и чужие заказы не тронуты" '! grep -qE "new.com|other.com" "$T/calls.log"'
finish
