# Защита обновлений: контрольная сумма релиза; подмена не ставится; проверка подлинности своего файла
source "$(dirname "$0")/lib.sh"
F=$(funcs)
sed 's/^RP_VERSION=.*/RP_VERSION="99.0"/' "$SCRIPT" > "$T/new.sh"
good=$(sha256sum "$T/new.sh" | awk '{print $1}')
# сервер: MODE=good | bad | nosum | norelease
fake='curl(){ local o="" u=""; while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift;; https://*) u="$1";; esac; shift; done
  echo "$u" >> "'"$T"'/urls.log"
  case "$u" in
    *releases/latest/download/remnapilot.sh.sha256) case "$MODE" in good) echo "'"$good"'  remnapilot.sh";; bad) echo "0000000000000000000000000000000000000000000000000000000000000000  remnapilot.sh";; *) return 22;; esac ;;
    *releases/latest/download/remnapilot.sh) [ "$MODE" = norelease ] && return 22; cp "'"$T"'/new.sh" "$o" ;;
    *raw.githubusercontent.com*) cp "'"$T"'/new.sh" "$o" ;;
    *releases/download/v*/remnapilot.sh.sha256) echo "$SELFSUM  remnapilot.sh" ;;
    *) return 22 ;;
  esac; }'
run() { MODE="$1" SELFSUM="${2:-}" bash -c 'source "'"$F"'"; JOURNAL=/dev/null; '"$fake"'
  install(){ echo "[install]"; }; rp_reexec(){ echo "[reexec]"; }; sleep(){ :; }; tg_text(){ :; }; mkdir(){ :; }; rm(){ command rm -f "$@" 2>/dev/null; return 0; }
  '"$3" 2>&1 | nocolor; }

out=$(run good "" 'rp_fetch_latest "'"$T"'/a"; echo "rc=$? verified=$RP_FETCH_VERIFIED bad=$RP_FETCH_BAD"')
out_has "сумма совпала — файл принят и проверен" "rc=0 verified=1 bad=0" "$out"
out=$(run bad "" 'rp_fetch_latest "'"$T"'/b"; echo "rc=$? verified=$RP_FETCH_VERIFIED bad=$RP_FETCH_BAD size=$(stat -c %s "'"$T"'/b")"')
out_has "подмена — файл отвергнут и стёрт" "rc=1 verified=0 bad=1 size=0" "$out"
out=$(run nosum "" 'rp_fetch_latest "'"$T"'/c"; echo "rc=$? verified=$RP_FETCH_VERIFIED"')
out_has "релиз без суммы — скачан, но не проверен" "rc=0 verified=0" "$out"
out=$(run norelease "" 'rp_fetch_latest "'"$T"'/d"; echo "rc=$? verified=$RP_FETCH_VERIFIED"')
out_has "нет релиза — запасной путь через main" "rc=0 verified=0" "$out"

out=$(run good "" 'self_update_online')
out_has "обновление: подлинность подтверждена" "Подлинность подтверждена" "$out"
out_has "обновление: ставится" "[install]" "$out"
out=$(run bad "" 'self_update_online')
out_has "обновление: подмена — отказ" "Контрольная сумма не совпала" "$out"
check "обновление: подмена — ничего не поставлено" '! grep -q "\[install\]" <<< "$out"'
out=$(RP_AUTO=1 run nosum "" 'self_update_online; echo "rc=$?"')
check "автообновление без суммы — не ставит" '! grep -q "\[install\]" <<< "$out" && grep -q "rc=1" <<< "$out"'

# проверка своего файла
me=$(sha256sum "$SCRIPT" | awk '{print $1}')
out=$(run good "$me" 'RP_SELF="'"$SCRIPT"'"; rp_verify_self')
check "свой файл совпадает с релизом" '[ "$out" = ok ]'
out=$(run good "1111111111111111111111111111111111111111111111111111111111111111" 'RP_SELF="'"$SCRIPT"'"; rp_verify_self')
check "изменённый файл распознан" '[ "$out" = modified ]'

# установка одной командой: подмена не ставится
cat > "$T/bin_curl" <<C
#!/bin/bash
o=""; u=""; while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift;; https://*) u="\$1";; esac; shift; done
case "\$u" in *.sha256) echo "0000000000000000000000000000000000000000000000000000000000000000  x" ;; *) cp "$T/new.sh" "\$o" ;; esac
C
mkdir -p "$T/bin"; mv "$T/bin_curl" "$T/bin/curl"; chmod +x "$T/bin/curl"
out=$(PATH="$T/bin:$PATH" bash < "$SCRIPT" 2>&1)
out_has "curl | bash: подмена — установка отменена" "Установка отменена" "$out"
check "релиз прикладывает .sha256" 'grep -q "remnapilot.sh remnapilot.sh.sha256" "$ROOT/.github/workflows/release.yml"'
finish
