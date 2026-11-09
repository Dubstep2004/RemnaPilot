# Версии контейнеров: метка образа → тег → package.json → переменная окружения; «не установлено» только без контейнера
source "$(dirname "$0")/lib.sh"
F=$(funcs)
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'D'
#!/bin/bash
c="${@: -1}"
case "$*" in
  "inspect -f {{.Id}} "*) echo "id-$c-$RANDOM$RANDOM" ;;
  "inspect -f {{index .Config.Labels \"org.opencontainers.image.version\"}} lbl") echo "v2.2.4" ;;
  "inspect -f {{index .Config.Labels "*) echo "" ;;
  "inspect -f {{.Config.Image}} tag") echo "remnawave/backend:2.3.1" ;;
  "inspect -f {{.Config.Image}} "*) echo "remnawave/backend:latest" ;;
  "exec pkg sh -c "*) echo "2.2.9" ;;
  "exec "*) exit 1 ;;
  "inspect -f {{range .Config.Env}}{{println .}}{{end}} env") printf 'NODE_ENV=production\n__RW_METADATA_VERSION=2.1.0\n' ;;
  "inspect -f {{range .Config.Env}}"*) echo "NODE_ENV=production" ;;
esac
exit 0
D
chmod +x "$T/bin/docker"
rm -rf /run/remnapilot
for case in "lbl|2.2.4|метка образа" "tag|2.3.1|тег образа" "pkg|2.2.9|package.json в контейнере" "env|2.1.0|переменная окружения" "none||нигде нет — пусто"; do
  IFS='|' read -r c want what <<< "$case"
  got=$(PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; local_ver '"$c")
  check "версия: $what" '[ "$got" = "$want" ]'
done
out=$(bash -c 'source "'"$F"'"; ver_line Панель "" 2.3.0; ver_line Нода - ""' 2>&1 | nocolor)
out_has "работает, версия неизвестна — не «не установлено»" "установлено, версия не определяется · последняя v2.3.0" "$out"
out_has "нет контейнера — «не установлено»" "Нода       ○ не установлено" "$out"

# скрипт обновления нод по SSH собирается с функцией версии
cat > "$T/bin/ssh" <<S
#!/bin/bash
cat > "$T/remote.sh"; echo "RESULT 2.2.4 | Up"
S
chmod +x "$T/bin/ssh"; echo 'de-1 root@1.1.1.1 22' > "$T/nodes.list"
PATH="$T/bin:$PATH" bash -c 'source "'"$F"'"; NODES_FILE="'"$T"'/nodes.list"; JOURNAL=/dev/null; NODES_ALL=1 nodes_update' >/dev/null 2>&1
check "удалённый скрипт: функция версии на месте" 'grep -q "^rp_ver()" "$T/remote.sh" && grep -q "v=\$(rp_ver remnanode)" "$T/remote.sh"'
check "удалённый скрипт: переменные не раскрылись раньше времени" 'grep -q "for x in /opt/remnanode" "$T/remote.sh" && grep -q "\[ -n \"\$d\" \]" "$T/remote.sh"'
check "удалённый скрипт: синтаксис" 'bash -n "$T/remote.sh"'
rm -rf /run/remnapilot
finish
