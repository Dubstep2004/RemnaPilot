# ---------- оформление ----------
# UTF-8 нужен для рамок и правильного выравнивания
if [[ "${LANG:-}${LC_ALL:-}" != *[Uu][Tt][Ff]* ]]; then
  for l in C.UTF-8 C.utf8 en_US.UTF-8; do locale -a 2>/dev/null | grep -qix "${l/UTF-8/utf8}\|$l" && { export LC_ALL="$l"; break; }; done
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]] && (( $(tput colors 2>/dev/null || echo 0) >= 256 )); then
  C0=$'\e[0m'; CB=$'\e[1m'; CD=$'\e[2m'
  C_ACC=$'\e[38;5;45m'   # бирюзовый — акцент
  C_ACC2=$'\e[38;5;141m' # сиреневый
  C_OK=$'\e[38;5;114m'; C_WARN=$'\e[38;5;221m'; C_ERR=$'\e[38;5;203m'
  C_MUT=$'\e[38;5;245m'; C_LINE=$'\e[38;5;239m'
  GRAD=($'\e[38;5;51m' $'\e[38;5;45m' $'\e[38;5;39m' $'\e[38;5;63m' $'\e[38;5;99m' $'\e[38;5;141m')
elif [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C0=$'\e[0m'; CB=$'\e[1m'; CD=$'\e[2m'
  C_ACC=$'\e[36m'; C_ACC2=$'\e[35m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
  C_MUT=$'\e[90m'; C_LINE=$'\e[90m'; GRAD=($'\e[36m' $'\e[36m' $'\e[34m' $'\e[34m' $'\e[35m' $'\e[35m')
else
  C0=""; CB=""; CD=""; C_ACC=""; C_ACC2=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUT=""; C_LINE=""; GRAD=("" "" "" "" "" "")
fi
W=54   # ширина интерфейса

# ---------- настройки оформления (/etc/rw/ui.conf) ----------
UI_CONF="/etc/rw/ui.conf"
ui_get() { local v; v=$(grep -m1 "^$1=" "$UI_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
ui_set() {
  mkdir -p "$(dirname "$UI_CONF")"; touch "$UI_CONF"
  if grep -q "^$1=" "$UI_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$UI_CONF"; else echo "$1=$2" >> "$UI_CONF"; fi
}

RP_THEMES=(ocean sunset forest neon ice mono)
apply_ui() { # тема → цвета акцентов и градиент логотипа
  UI_THEME=$(ui_get THEME ocean); UI_NUMS=$(ui_get NUMS plain); UI_LOGO=$(ui_get LOGO big)
  UI_HINTS=$(ui_get HINTS on);    UI_STATUS=$(ui_get STATUS full)
  UI_COMPACT=$(ui_get COMPACT off)
  UI_LIVE=$(ui_get LIVE 5); [[ "$UI_LIVE" =~ ^(off|3|5|10|30)$ ]] || UI_LIVE=5
  [[ -n "${RP_NO_LIVE:-}" ]] && UI_LIVE=off          # для автоматических прогонов с готовым вводом
  [[ -z "$C0" ]] && return 0                       # без цветов — только стиль
  if (( $(tput colors 2>/dev/null || echo 0) < 256 )); then
    [[ "$UI_THEME" == mono ]] && { C_ACC="$CB"; C_ACC2="$CB"; GRAD=("$CB" "$CB" "$CB" "$CB" "$CB" "$CB"); }
    return 0
  fi
  local g
  case "$UI_THEME" in
    sunset) C_ACC=$'\e[38;5;214m'; C_ACC2=$'\e[38;5;205m'; g="226 220 214 208 203 198" ;;
    forest) C_ACC=$'\e[38;5;114m'; C_ACC2=$'\e[38;5;149m'; g="48 41 35 71 107 143" ;;
    neon)   C_ACC=$'\e[38;5;201m'; C_ACC2=$'\e[38;5;51m';  g="201 165 129 93 57 51" ;;
    ice)    C_ACC=$'\e[38;5;153m'; C_ACC2=$'\e[38;5;189m'; g="195 159 153 117 111 147" ;;
    mono)   C_ACC=$'\e[1;38;5;255m'; C_ACC2=$'\e[38;5;250m'; g="255 253 251 249 247 245" ;;
    *)      C_ACC=$'\e[38;5;45m';  C_ACC2=$'\e[38;5;141m'; g="51 45 39 63 99 141" ;;
  esac
  GRAD=(); local c; for c in $g; do GRAD+=($'\e[38;5;'"${c}m"); done
}

theme_name() { case "$1" in ocean) echo "Океан";; sunset) echo "Закат";; forest) echo "Лес";; neon) echo "Неон";; ice) echo "Лёд";; mono) echo "Моно";; esac; }

num_fmt() { # номер пункта в выбранном стиле (ширина 4)
  local n="$1" circ=(⓪ ① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ ⑪ ⑫ ⑬ ⑭ ⑮ ⑯ ⑰ ⑱ ⑲ ⑳)
  [[ "$n" =~ ^[0-9]+$ ]] || { printf '%4s' "$n"; return; }
  case "${UI_NUMS:-plain}" in
    paren)   printf '%4s' "$n)" ;;
    bracket) printf '%4s' "[$n]" ;;
    dot)     printf '%4s' "$n." ;;
    circle)  if (( n <= 20 )); then printf '%3s%s' "" "${circ[$n]}"; else printf '%4s' "($n)"; fi ;;
    *)       printf '%4s' "$n" ;;
  esac
}

# ---------- язык ----------
RP_SELF=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
RP_LANG="${RP_LANG:-$(cat /etc/rw/lang 2>/dev/null)}"; [[ "$RP_LANG" == en ]] || RP_LANG=ru

rp_translate() { # фильтр вывода RU→EN по словарю в конце этого файла (без буферизации — подсказки видны сразу)
  perl -e '
    my %d; my $on = 0;
    open(my $f, "<", $ARGV[0]) or die;
    while (<$f>) { chomp; if ($_ eq "__RP_EN__") { $on = 1; next } next unless $on;
      last if $_ eq "__RP_EN_END__";
      my ($r, $e) = split /\t/, $_, 2; $d{$r} = $e if defined $e && length $r }
    my $alt = join "|", map { quotemeta } sort { length($b) <=> length($a) } keys %d;
    my $re = qr/(?<![\xD0\xD1][\x80-\xBF])($alt)(?![\xD0\xD1][\x80-\xBF])/;
    $| = 1; my $buf;
    while (sysread(STDIN, $buf, 65536)) {
      # не резать UTF-8 символ на границе чтения
      while ($buf =~ /[\xC0-\xFF]$/ || $buf =~ /[\xE0-\xFF][\x80-\xBF]$/) { my $more; last unless sysread(STDIN, $more, 1); $buf .= $more }
      $buf =~ s/$re/$d{$1}/g; syswrite(STDOUT, $buf);
    }' "$RP_SELF"
}

# перевод строки целиком внутри скрипта — нужен там, где важна ширина (рамки, заголовки)
declare -A RP_D=(); RP_KEYS=()
rp_load_dict() {
  local r e
  while IFS=$'\t' read -r r e; do
    [[ -n "$e" && ${#r} -ge 3 ]] || continue
    RP_D["$r"]="$e"; RP_KEYS+=("$r")
  done < <(awk '/^__RP_EN__$/{on=1;next} /^__RP_EN_END__$/{exit} on' "$RP_SELF" \
           | awk -F'\t' '{print length($1) "\t" $0}' | sort -t$'\t' -k1,1nr | cut -f2-)
}
T() {
  local s="$1" k
  if [[ "$RP_LANG" == en && ${#RP_KEYS[@]} -gt 0 && "$s" == *[А-Яа-яЁё]* ]]; then
    for k in "${RP_KEYS[@]}"; do [[ "$s" == *"$k"* ]] && s="${s//"$k"/"${RP_D[$k]}"}"; [[ "$s" == *[А-Яа-яЁё]* ]] || break; done
  fi
  printf '%s' "$s"
}

rp_reexec() { # перезапустить скрипт с чистым stdout/stderr
  [[ -n "${RP_TR_PID:-}" ]] && { exec 1>&3 2>&4; trap - EXIT; }
  tty_restore
  if [[ -n "${RP_LOCKED:-}" ]]; then rm -f "$RP_LOCK.who"; flock -u 8 2>/dev/null; RP_LOCKED=""; fi   # не уносить блокировку в новый процесс
  { exec 8>&-; } 2>/dev/null
  exec "$@"
}

lang_toggle() {
  local n; [[ "$RP_LANG" == en ]] && n=ru || n=en
  mkdir -p /etc/rw && echo "$n" > /etc/rw/lang
  jlog INFO "Язык: $n"
  rp_reexec env RP_LANG="$n" bash "$RP_SELF"
}

red()   { printf '%s%s%s\n' "$C_ERR"  "$*" "$C0"; }
green() { printf '%s%s%s\n' "$C_OK"   "$*" "$C0"; }
yel()   { printf '%s%s%s\n' "$C_WARN" "$*" "$C0"; }
bold()  { printf '%s%s%s\n' "$CB"     "$*" "$C0"; }
info()  { printf '%s›%s %s\n' "$C_ACC" "$C0" "$*"; }
err()   { red "✖ $*"; return 1; }
pause() { echo; read -rp "  ${C_MUT}↵ Enter — назад${C0} " _; }
ask()   { printf '\n  %s❯%s %s' "$C_ACC" "$C0" "${1:-Выбор}: "; }   # usage: ask "Текст"; read -r var

repeat() { local s="" i; for ((i=0; i<$2; i++)); do s+="$1"; done; printf '%s' "$s"; }
vislen() { local s; s=$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'); echo "${#s}"; }

hr() { printf '  %s%s%s\n' "$C_LINE" "$(repeat ─ $((W-2)))" "$C0"; }

section() { # заголовок группы в меню:  ДОМЕН ─────────
  local t=" $(T "$1") " n; n=$(( W - 2 - $(vislen "$t") ))
  [[ "${UI_COMPACT:-off}" == on ]] || echo
  printf '  %s%s%s%s%s%s\n' "$C_ACC2$CB" "$t" "$C0" "$C_LINE" "$(repeat ─ $n)" "$C0"
}

item() { # пункт меню: номер, текст, [подсказка]
  printf '  %s%s%s  %s' "$C_ACC$CB" "$(num_fmt "$1")" "$C0" "$2"
  [[ -n "${3:-}" ]] && printf '  %s%s%s' "$C_MUT" "$3" "$C0"
  echo
}

box_top()    { printf '  %s╭%s╮%s\n' "$C_LINE" "$(repeat ─ $((W-4)))" "$C0"; }
box_bottom() { printf '  %s╰%s╯%s\n' "$C_LINE" "$(repeat ─ $((W-4)))" "$C0"; }
box_line()   { # строка внутри рамки с выравниванием по видимой ширине
  local s; s=$(T "$1"); local pad; pad=$(( W - 6 - $(vislen "$s") )); (( pad < 0 )) && pad=0
  printf '  %s│%s %s%s %s│%s\n' "$C_LINE" "$C0" "$s" "$(repeat ' ' $pad)" "$C_LINE" "$C0"
}

banner() {
  local rows=(
    "╦═╗┌─┐┌┬┐┌┐┌┌─┐╔═╗┬┬  ┌─┐┌┬┐"
    "╠╦╝├┤ │││││││├─┤╠═╝││  │ │ │ "
    "╩╚═└─┘┴ ┴┘└┘┴ ┴╩  ┴┴─┘└─┘ ┴ "
  )
  local r i ch out col n=${#GRAD[@]} u="─"
  echo
  if [[ "${UI_LOGO:-big}" == none ]]; then return 0; fi
  if [[ "${UI_LOGO:-big}" == small ]]; then
    printf '   %s◆ %s%sRemnaPilot%s  %sv%s%s\n' "${GRAD[0]}" "$C0" "$CB" "$C0" "$C_LINE" "$RP_VERSION" "$C0"; return 0
  fi
  if (( ${#u} != 1 )); then for r in "${rows[@]}"; do printf '   %s%s%s\n' "$C_ACC" "$r" "$C0"; done
  else for r in "${rows[@]}"; do
    out="   "
    for ((i=0; i<${#r}; i++)); do
      ch="${r:i:1}"; col=$(( i * n / ${#r} ))
      out+="${GRAD[$col]}$ch"
    done
    printf '%s%s\n' "$out" "$C0"
  done; fi
  printf '   %sпульт управления Remnawave%s  %sv%s%s\n' "$C_MUT" "$C0" "$C_LINE" "$RP_VERSION" "$C0"
}

screen() { # экран подменю: заголовок-плашка
  clear
  local t; t=$(T "$1"); local n; n=$(( W - 6 - $(vislen "$t") ))
  echo
  printf '  %s◆%s %s%s%s %s%s%s\n' "$C_ACC" "$C0" "$CB" "$t" "$C0" "$C_LINE" "$(repeat ─ $n)" "$C0"
  printf '  %s%s%s\n' "$C_MUT" "$RP_NAME" "$C0"
}

dot() { # цветная точка статуса: ok|warn|err|off
  case "$1" in ok) printf '%s●%s' "$C_OK" "$C0" ;; warn) printf '%s●%s' "$C_WARN" "$C0" ;;
               err) printf '%s●%s' "$C_ERR" "$C0" ;; *) printf '%s○%s' "$C_MUT" "$C0" ;; esac
}

status_box() {
  local DPS; dps_refresh          # снимок живёт только на время отрисовки (видят вложенные функции)
  case "${UI_STATUS:-full}" in off) return 0 ;; compact) status_line; return 0 ;; esac
  status_box_full
}

status_line() { # одна строка вместо рамки
  local app st d=ok dom; app=$(cut -d'|' -f2- <<< "$DPS" | awk -F'|' '$3 ~ /remnawave\/backend/ {print; exit}')
  if [[ ! -f "$RW_DIR/.env" ]]; then st="$(T "панели нет")"; d=off
  elif [[ "$app" == *"|Up"*unhealthy* || "$app" == *Restarting* ]]; then st="$(T "проблемы")"; d=warn
  elif [[ "$app" == *"|Up"* ]]; then st="$(T "работает")"
  else st="$(T "остановлена")"; d=err; fi
  dom=$(detect_old 2>/dev/null)
  printf '   %s %s%s%s  %s%s%s\n' "$(dot $d)" "$CB" "${dom:-RemnaPilot}" "$C0" "$C_MUT" "$st" "$C0"
  update_hints
}

# Снимок контейнеров: один вызов docker на отрисовку экрана вместо нескольких
DPS=""
dps_refresh() { DPS=$(docker ps -a --no-trunc --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null); }
dps_id() { awk -F'|' -v n="$1" '$2==n {print $1; exit}' <<< "$DPS"; }

status_box_full() {
  local panel_st panel_ver dom days ssl nodes db_st lbl
  lbl() { local l; l=$(T "$1"); local w=9; [[ "$RP_LANG" == en ]] && w=13; local pad=$(( w - ${#l} )); (( pad < 1 )) && pad=1; printf '%s%s%s%s' "$C_MUT" "$l" "$C0" "$(repeat ' ' $pad)"; }

  if [[ -f "$RW_DIR/.env" ]]; then
    local ps; ps=$(cut -d'|' -f2- <<< "$DPS")
    local app; app=$(echo "$ps" | awk -F'|' '$3 ~ /remnawave\/backend|remnawave\/panel/ {print; exit}')
    [[ -z "$app" ]] && app=$(echo "$ps" | grep -E '^remnawave\|' | head -1)
    if   [[ "$app" == *"|Up"*"unhealthy"* || "$app" == *Restarting* ]]; then panel_st="$(dot warn) ${C_WARN}проблемы${C0}"
    elif [[ "$app" == *"|Up"* ]]; then panel_st="$(dot ok) ${C_OK}работает${C0}"
    elif [[ -n "$app" ]];        then panel_st="$(dot err) ${C_ERR}остановлена${C0}"
    else                              panel_st="$(dot off) ${C_MUT}не найдена${C0}"; fi
    panel_ver=$(local_ver "${app%%|*}")
    [[ -n "$panel_ver" ]] && panel_st+="  ${C_MUT}v${panel_ver}${C0}"

    if echo "$ps" | grep -E 'remnawave-db\||postgres' | grep -q '|Up'; then db_st="$(dot ok) ${C_OK}ok${C0}"
    else db_st="$(dot err) ${C_ERR}недоступна${C0}"; fi

    dom=$(detect_old); dom="${dom:-—}"

    local f cp; cp=$(cert_paths_for "$dom" 2>/dev/null); f="${cp%%$'\t'*}"; f="${f:-$RW_DIR/nginx/fullchain.pem}"
    local endd; endd=$(openssl x509 -noout -enddate -in "$f" 2>/dev/null | cut -d= -f2)
    if [[ -f "$f" && -n "$endd" ]]; then
      days=$(( ( $(date -d "$endd" +%s) - $(date +%s) ) / 86400 ))
      if   (( days < 0 ));  then ssl="$(dot err) ${C_ERR}истёк${C0}"
      elif (( days < 15 )); then ssl="$(dot warn) ${C_WARN}${days} дн.${C0}"
      else                       ssl="$(dot ok) ${C_OK}${days} дн.${C0}"; fi
    else ssl="$(dot off) ${C_MUT}через Caddy/Traefik${C0}"; fi

    box_top
    box_line "$(lbl Панель)$panel_st"
    box_line "$(lbl Домен)${CB}${dom}${C0}"
    local sd; sd=$(env_get SUB_PUBLIC_DOMAIN)
    [[ -n "$sd" ]] && box_line "$(lbl Подписка)${sd}"
    box_line "$(lbl SSL)$ssl"
    box_line "$(lbl База)$db_st"
  else
    box_top
    box_line "$(lbl Панель)$(dot off) ${C_MUT}на этом сервере нет${C0}"
  fi
  if [[ -s "${NODES_FILE:-/etc/rw/nodes.list}" ]]; then
    nodes="$(wc -l < "${NODES_FILE:-/etc/rw/nodes.list}") в списке"
  else nodes="список пуст"; fi
  local local_node=""
  grep -q '^[^|]*|remnanode|Up' <<< "$DPS" && local_node="  $(dot ok) ${C_MUT}+ нода здесь${C0}"
  box_line "$(lbl Ноды)${nodes}${local_node}"
  box_bottom
  update_hints
}

ver_newer() { [[ -n "$1" && -n "$2" && "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]; } # $2 новее $1

update_hints() { # строки под рамкой: что можно обновить, последние автодействия (только из кэша, без сети)
  local lv pv lp nv ln app f
  lv=$(cat /etc/rw/.latest_version 2>/dev/null)
  ver_newer "$RP_VERSION" "$lv" && printf '   %s %sДоступен RemnaPilot v%s%s\n' "$(dot warn)" "$C_WARN" "$lv" "$C0"
  if [[ -f "$RW_DIR/.env" ]]; then
    lp=$(cat /etc/rw/.latest_panel 2>/dev/null)
    local DPS="$DPS"; [[ -n "$DPS" ]] || dps_refresh
    app=$(awk -F'|' '$3 ~ /^Up/ && $4 ~ /remnawave\/backend/ {print $2; exit}' <<< "$DPS")
    [[ -n "$app" && -n "$lp" ]] && { pv=$(local_ver "$app"); ver_newer "$pv" "$lp" && printf '   %s %sДоступна панель v%s%s  %s(сейчас v%s)%s\n' "$(dot warn)" "$C_WARN" "$lp" "$C0" "$C_MUT" "$pv" "$C0"; }
  fi
  ln=$(cat /etc/rw/.latest_node 2>/dev/null)
  if [[ -n "$ln" ]] && { [[ -n "$DPS" ]] || local DPS; [[ -n "$DPS" ]] || dps_refresh; grep -q '^[^|]*|remnanode|Up' <<< "$DPS"; }; then
    nv=$(local_ver remnanode); ver_newer "$nv" "$ln" && printf '   %s %sДоступна нода v%s%s\n' "$(dot warn)" "$C_WARN" "$ln" "$C0"
  fi
  for f in /etc/rw/.autoupdate_last /etc/rw/.backup_last; do
    [[ -f "$f" ]] && grep -q '|FAIL|' "$f" && printf '   %s %s%s%s\n' "$(dot err)" "$C_ERR" "$(cut -d'|' -f3- "$f")" "$C0"
  done
  return 0
}

