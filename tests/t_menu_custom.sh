# Меню: избранное, скрытие, быстрые клавиши, поиск, компактный режим; удаление RemnaPilot
source "$(dirname "$0")/lib.sh"
stub_docker
saved=""; for d in /opt/remnawave /etc/rw; do [ -e "$d" ] && { mkdir -p "$T/saved"; cp -a "$d" "$T/saved/"; saved+=" $d"; }; done
rm -rf /opt/remnawave /etc/rw; mkdir -p /opt/remnawave/backups /etc/rw
printf 'FRONT_END_DOMAIN=panel.example.com\n' > /opt/remnawave/.env
touch "$HOME/.rw-nocmd" /etc/rw/autoupdate.conf
printf 'FAV=6,9\nHIDE=16,25\nCOMPACT=on\n' > /etc/rw/ui.conf
menu() { printf '%s\n' "$@" | PATH="$T/bin:$PATH" TERM=xterm-256color RP_LANG=${L:-ru} timeout 60 script -qc "bash '$SCRIPT'" /dev/null 2>&1 | nocolor; }

out=$(menu 0)
out_has "избранное наверху" "ИЗБРАННОЕ" "$out"
out_has "избранное под номером 1" "1  Обновления" "$out"
out_has "избранное под номером 2" "2  Сертификаты" "$out"
check "скрытые пункты пропали" '! grep -q "WARP на ноде\|Подбор SNI" <<< "$out"'
check "избранное не дублируется ниже" '[ "$(grep -c "  Сертификаты$" <<< "$out")" = 1 ]'
check "компактный режим: нет пустых строк перед разделами" '! grep -B1 "ДОМЕНЫ ─" <<< "$out" | grep -q "^$"'
out_has "подсказка о клавишах" "Быстро: d домены" "$out"

out=$(menu c 0 0);   out_has "буква c → сертификаты" "◆ Сертификаты" "$out"
out=$(menu с 0 0);   out_has "русская раскладка (с) → сертификаты" "◆ Сертификаты" "$out"
out=$(menu журн 0 0); out_has "поиск «журн» → журнал" "◆ Журнал действий" "$out"
out=$(menu warp 0 0); out_has "поиск находит и скрытый пункт" "◆ WARP на ноде" "$out"
out=$(menu ноды 0 0); out_has "несколько совпадений — список" "НАЙДЕНО" "$out"
out=$(menu абырвалг 0); out_has "ничего не найдено — сообщение" "Ничего не найдено" "$out"
out=$(L=en menu cert 0 0); out_has "поиск по-английски" "◆ Certificates" "$out"

# выбор избранного в оформлении: снять 6 (номер в общем списке = 6), добавить 1
out=$(menu o 7 '6 1' '' 0 0); check "избранное меняется" 'grep -q "^FAV=9,1$" /etc/rw/ui.conf'
out=$(menu o 8 27 '' 0 0); out_has "«Оформление» скрыть нельзя" "скрыть нельзя" "$out"

# удаление: без YES ничего не удаляется
rm -f /etc/rw/ui.conf; install -m 755 "$SCRIPT" /usr/local/bin/rw; echo "x" > /etc/cron.d/remnapilot-update
out=$(menu 34 n no 0)
check "без YES ничего не удалено" '[ -x /usr/local/bin/rw ] && [ -d /etc/rw ] && [ -f /etc/cron.d/remnapilot-update ]'
echo dump > /opt/remnawave/backups/db-1.sql.gz
out=$(menu 34 y YES)
out_has "удаление завершено" "RemnaPilot удалён" "$out"
check "команда rw удалена" '[ ! -e /usr/local/bin/rw ]'
check "настройки и расписания удалены" '[ ! -e /etc/rw ] && [ ! -e /etc/cron.d/remnapilot-update ]'
check "бэкапы базы остались" '[ -f /opt/remnawave/backups/db-1.sql.gz ]'
check "настройки сохранены в архив" 'ls /opt/remnawave/backups/remnapilot-settings-*.tar.gz >/dev/null 2>&1 && tar -tzf /opt/remnawave/backups/remnapilot-settings-*.tar.gz | grep -q rw/autoupdate.conf'
check "панель не тронута" '[ -f /opt/remnawave/.env ]'

rm -rf /opt/remnawave /etc/rw "$HOME/.rw-nocmd" /usr/local/bin/rw /etc/cron.d/remnapilot-*
for d in $saved; do cp -a "$T/saved/$(basename "$d")" "$(dirname "$d")/"; done
finish
