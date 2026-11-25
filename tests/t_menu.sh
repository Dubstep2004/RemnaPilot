# Меню: все разделы и подменю открываются на русском и английском без ошибок и зависаний
source "$(dirname "$0")/lib.sh"
stub_docker
saved=""; for d in /opt/remnawave /etc/rw; do [ -e "$d" ] && { mkdir -p "$T/saved"; cp -a "$d" "$T/saved/"; saved+=" $d"; }; done
rm -rf /opt/remnawave /etc/rw; mkdir -p /opt/remnawave /etc/rw
printf 'FRONT_END_DOMAIN=panel.example.com\nSUB_PUBLIC_DOMAIN=sub.example.com\n' > /opt/remnawave/.env
printf 'de-1 root@192.0.2.1 22\n' > /etc/rw/nodes.list
touch "$HOME/.rw-nocmd"

# полный список (по умолчанию): каждое подменю → назад; оформление; затем вид «разделы»
seq_menu=$(printf '%s\n' 12 0  14 0  15 0  24 0  17 0  3 0  35 0 ''  36 0  25 0  26 0  38 0  39 0  40 0  41 0  32 0 \
  4 0  20 0  21 0  22 0  29 0  31 0  37 0 \
  42 1 3 2 5 0  43 0  44 0  48 ''  11 ''  42 6 0  1 0  7 0  0)
for L in ru en; do
  rm -f /etc/rw/ui.conf; echo flat > /etc/rw/menu_mode
  out=$(printf '%s\n' "$seq_menu" | PATH="$T/bin:$PATH" TERM=xterm-256color RP_NO_LIVE=1 RP_LANG=$L timeout 120 script -qc "bash '$SCRIPT'" /dev/null 2>&1 | nocolor)
  rc=$?
  check "[$L] меню завершилось без зависания" '[ $rc -eq 0 ]'
  check "[$L] без ошибок bash" '! grep -qE "line [0-9]+:|command not found|syntax error|unbound variable|bad substitution" <<< "$out"'
  if [ $L = ru ]; then
    out_has "[$L] полный список по умолчанию" "48  О программе и версии" "$out"
    out_has "[$L] новые пункты в списке" "17  Автобэкап" "$out"
    out_has "[$L] тема применилась (Лес)" "Тема  Лес" "$out"
    out_has "[$L] номера-кружки" "⑥  Сменить домены" "$out"
    out_has "[$L] вид «папки» по желанию" "ПАПКИ" "$out"
  else
    out_has "[$L] английский" "DOMAINS" "$out"
    left=$(perl -CSD -Mutf8 -ne 'print if /^\s+\S+\s+.*\p{Cyrillic}/ && !/Язык|\.рф/' <<< "$out" | sort -u)
    check "[$L] нет непереведённого текста в пунктах меню" '[ -z "$left" ]'; [ -n "$left" ] && printf '%s\n' "$left" | head -8 | sed 's/^/      /'
  fi
done
check "настройки оформления сохранились" 'grep -q "^THEME=forest" /etc/rw/ui.conf && grep -q "^NUMS=circle" /etc/rw/ui.conf'
check "вид меню переключился на разделы" '[ "$(cat /etc/rw/menu_mode 2>/dev/null)" = sections ]'
# папки — вид по умолчанию: главный экран, открыть «Ноды», назад
rm -f /etc/rw/menu_mode
for L in ru en; do
  out=$(printf '%s\n' 5 0 0 | PATH="$T/bin:$PATH" TERM=xterm-256color RP_NO_LIVE=1 RP_LANG=$L timeout 60 script -qc "bash '$SCRIPT'" /dev/null 2>&1 | nocolor)
  check "[$L] папки без ошибок bash" '! grep -qE "line [0-9]+:|command not found|syntax error|unbound variable" <<< "$out"'
  if [ $L = ru ]; then
    out_has "[ru] папки по умолчанию" "ПАПКИ" "$out"
    out_has "[ru] папка со значком и числом пунктов" "📡 Ноды        10 · профили Xray, Hysteria2" "$out"
    out_has "[ru] внутри папки — путь" "Главное меню › Ноды" "$out"
    out_has "[ru] внутри папки — группы" "ПРОТОКОЛЫ" "$out"
    out_has "[ru] нумерация внутри папки с 1" "①  Статус всех нод" "$out"
    out_has "[ru] назад в папки" "Назад в папки" "$out"
  else
    out_has "[en] папки" "FOLDERS" "$out"
    out_has "[en] путь" "Main menu › Nodes" "$out"
    left=$(perl -CSD -Mutf8 -ne 'print if /\p{Cyrillic}/ && !/Язык|\.рф/' <<< "$out" | sort -u)
    check "[en] в папках нет русского" '[ -z "$left" ]'; [ -n "$left" ] && printf '%s\n' "$left" | head -8 | sed 's/^/      /'
  fi
done
check "автопроверка обновлений включилась сама" '[ -f /etc/cron.d/remnapilot-update ] && grep -q -- "--auto-update" /etc/cron.d/remnapilot-update'
rm -f /etc/cron.d/remnapilot-update

rm -rf /opt/remnawave /etc/rw "$HOME/.rw-nocmd"
for d in $saved; do cp -a "$T/saved/$(basename "$d")" "$(dirname "$d")/"; done
finish
