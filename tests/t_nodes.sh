# Статус нод: параллельный опрос, разбор без eval (защита от подмены данных), понятные ошибки
source "$(dirname "$0")/lib.sh"
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'S'
#!/bin/bash
for a in "$@"; do [[ "$a" == root@* ]] && h=$a; done
case "$h" in
  root@1.1.1.1) printf 'ST=Up 5 days\nVER=2.2.4\nLOAD=0.21\nCPUS=2\nMEM=612/1987\nDISK=41%%\nUP=12d 3h\n' ;;
  root@2.2.2.2) printf "ST=Up 1 hours (unhealthy)\nVER=2.2.3'; touch /tmp/rp_pwned; '\nLOAD=1.90\nCPUS=1\nMEM=900/970\nDISK=91%%\nUP=4h\n" ;;
  root@3.3.3.3) echo "Permission denied (publickey)." >&2; exit 255 ;;
esac
S
chmod +x "$T/bin/ssh"; rm -f /tmp/rp_pwned
printf 'de-1 root@1.1.1.1 22\nnl-1 root@2.2.2.2 22\nfi-1 root@3.3.3.3 22\n' > "$T/nodes.list"
out=$(PATH="$T/bin:$PATH" bash -c 'source "'"$(funcs)"'"; NODES_FILE="'"$T"'/nodes.list"; JOURNAL=/dev/null; node_dir(){ return 1; }; nodes_status' 2>&1 | nocolor)
out_has "нода онлайн с версией" "de-1  v2.2.4" "$out"
out_has "нагрузка и память" "CPU 0.21/2  RAM 612/1987" "$out"
out_has "unhealthy виден" "unhealthy" "$out"
out_has "нет ключа — понятное сообщение" "нет SSH-ключа" "$out"
check "данные с ноды не выполняются" '[ ! -e /tmp/rp_pwned ]'
check "опрос не зависает с переводчиком (EN)" 'timeout 20 bash -c "exec > >(cat); source \"$T/funcs.sh\"; NODES_FILE=\"$T/nodes.list\"; node_dir(){ return 1; }; PATH=\"$T/bin:\$PATH\"; nodes_status >/dev/null"'
finish
