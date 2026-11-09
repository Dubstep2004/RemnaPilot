# Обновление панели с бэкапом и откат на прежние образы
source "$(dirname "$0")/lib.sh"
mkdir -p "$T/rw/backups" "$T/bin"
echo 'FRONT_END_DOMAIN=p.example.com' > "$T/rw/.env"
printf 'services:\n  remnawave:\n    image: "remnawave/backend:latest"\n  db:\n    image: postgres:17\n' > "$T/rw/docker-compose.yml"
cat > "$T/bin/docker" <<D
#!/bin/bash
echo "docker \$*" >> "$T/calls.log"
case "\$*" in
  "compose -f "*" ps -q") echo cid1 ;;
  "inspect -f {{.Config.Image}} cid1") echo remnawave/backend:latest ;;
  "inspect -f {{.Image}} cid1") echo sha256:old ;;
  "inspect --format"*) echo 2.2.4 ;;
  "inspect -f {{.State.Status}}"*) echo "running healthy" ;;
  "ps --format {{.Names}}\t{{.Image}}") printf 'remnawave\tremnawave/backend:latest\n' ;;
esac
exit 0
D
chmod +x "$T/bin/docker"
out=$(PATH="$T/bin:$PATH" bash -c 'source "'"$(funcs)"'"; RW_DIR="'"$T"'/rw"; NODES_FILE=/nonexistent; JOURNAL=/dev/null
  backup_db(){ touch "$RW_DIR/backups/db-1-pre-update.sql.gz"; }; restore_db(){ echo "[restore $RESTORE_FILE]"; }; sleep(){ :; }
  update_panel 1; printf "y\ny\n" | rollback_update' 2>&1 | nocolor)
check "перед обновлением старый образ сохранён" 'grep -q "docker tag sha256:old remnawave/backend:rp-prev" "$T/calls.log"'
check "образы скачаны и пересозданы" 'grep -q "compose -f .* pull" "$T/calls.log" && grep -q "up -d --remove-orphans" "$T/calls.log"'
check "запись об обновлении с дампом" 'grep -q "^DUMP .*pre-update" "$T"/rw/backups/update-*.log'
check "откат возвращает образ" 'grep -q "docker tag remnawave/backend:rp-prev remnawave/backend:latest" "$T/calls.log"'
out_has "откат предлагает вернуть базу" "[restore $T/rw/backups/db-1-pre-update.sql.gz]" "$out"
# закрепление версии
V=2.2.4 perl -pi -e 's/(image:\s*["\x27]?remnawave\/backend:)[^"\x27\s]+/${1}$ENV{V}/' "$T/rw/docker-compose.yml"
has "закрепление версии в compose" 'remnawave/backend:2.2.4"' "$T/rw/docker-compose.yml"
has "чужие образы не тронуты" "image: postgres:17" "$T/rw/docker-compose.yml"
finish
