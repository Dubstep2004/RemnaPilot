# Меню: все разделы и подменю открываются на русском и английском без ошибок и зависаний
source "$(dirname "$0")/lib.sh"
stub_docker
saved=""; for d in /opt/remnawave /etc/rw; do [ -e "$d" ] && { mkdir -p "$T/saved"; cp -a "$d" "$T/saved/"; saved+=" $d"; }; done
rm -rf /opt/remnawave /etc/rw; mkdir -p /opt/remnawave /etc/rw
printf 'FRONT_END_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > /opt/remnawave/.env
printf 'de-1 root@192.0.2.1 22\n' > /etc/rw/nodes.list
touch "$HOME/.rw-nocmd"

# раздел → каждый пункт-подменю → назад; затем полный список
seq_sections=$(printf '%s\n' 1 0  2 1 '' 2 0 4 0 5 0 6 0 0  3 0  4 1 0 3 0 '' 4 0 0 \
  5 1 0 2 0 3 0 4 0 5 0 6 0 0  6 2 0 0  7 1 0 6 '' 5  0)
for L in ru en; do
  rm -f /etc/rw/menu_mode
  out=$(printf '%s\n' "$seq_sections" | PATH="$T/bin:$PATH" TERM=xterm-256color RP_LANG=$L timeout 120 script -qc "bash '$SCRIPT'" /dev/null 2>&1 | nocolor)
  rc=$?
  check "[$L] меню завершилось без зависания" '[ $rc -eq 0 ]'
  check "[$L] без ошибок bash" '! grep -qE "line [0-9]+:|command not found|syntax error|unbound variable|bad substitution" <<< "$out"'
  if [ $L = ru ]; then out_has "[$L] разделы на главном экране" "РАЗДЕЛЫ" "$out"; out_has "[$L] пункты внутри раздела" "Удалить старые домены" "$out"
  else out_has "[$L] разделы на английском" "SECTIONS" "$out"
       left=$(perl -CSD -Mutf8 -ne 'print if /^\s+\d+\s+.*\p{Cyrillic}/ && !/Язык/' <<< "$out")
       check "[$L] нет непереведённого текста в пунктах меню" '[ -z "$left" ]'; [ -n "$left" ] && printf '%s\n' "$left" | head -5 | sed 's/^/      /'; fi
done
check "вид меню переключился на полный список" '[ "$(cat /etc/rw/menu_mode 2>/dev/null)" = flat ]'
out=$(printf '0\n' | PATH="$T/bin:$PATH" TERM=xterm-256color timeout 30 script -qc "bash '$SCRIPT'" /dev/null 2>&1 | nocolor)
out_has "полный список: сквозная нумерация" "31  Вид меню" "$out"

rm -rf /opt/remnawave /etc/rw "$HOME/.rw-nocmd"
for d in $saved; do cp -a "$T/saved/$(basename "$d")" "$(dirname "$d")/"; done
finish
