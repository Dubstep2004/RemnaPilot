# ---------- старт ----------
RP_ARGS=("$@")
need_val() { [[ -n "${2:-}" && "$2" != -* ]] || { echo "Флаг $1 требует значение (см. --help)"; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --old|--dir|--cert-method|--sub|--lang) need_val "$1" "${2:-}" ;;
  esac
  case "$1" in
    --old)       OLD="$2"; shift 2 ;;
    --dir)       RW_DIR="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    --skip-cert) SKIP_CERT=1; shift ;;
    --cert-method) CERT_METHOD="$2"; [[ "$CERT_METHOD" =~ ^(http|alpn|dns|manual)$ ]] || { echo "--cert-method: http|alpn|dns|manual"; exit 1; }; shift 2 ;;
    --update)    DO_UPDATE=1; shift ;;
    --update-all) DO_UPDATE_ALL=1; shift ;;
    --auto-update) DO_AU=1; shift ;;
    --backup)    DO_BACKUP=1; shift ;;
    --check-updates) DO_CHECK=1; shift ;;
    --verify)    DO_VERIFY=1; shift ;;
    --selftest)  DO_SELFTEST=1; shift ;;
    --changelog) DO_CHANGELOG=1; shift ;;
    --decrypt)   [[ -n "${2:-}" ]] || { echo "Укажи файл: rw --decrypt архив.tar.gz.enc"; exit 1; }; DO_DECRYPT="$2"; shift 2 ;;
    --whats-new) DO_WHATSNEW=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    --geo-update-local) DO_GEO="${2:-loyal}"; [[ "$DO_GEO" == -* ]] && DO_GEO=loyal || shift; shift ;;
    --self-update) [[ $EUID -eq 0 ]] || { echo "Нужен root"; exit 1; }
                   if [[ -n "${2:-}" && "$2" != -* ]]; then self_update "$2"; else self_update_online; fi; exit $? ;;
    --sub)       SUB_NEW="$2"; shift 2 ;;
    --cert-status) DO_CERT_STATUS=1; shift ;;
    -h|--help)   DO_HELP=1; shift ;;
    -v|--version) echo "$RP_NAME $RP_VERSION"; exit 0 ;;
    --lang)      RP_LANG="$2"; [[ "$RP_LANG" == en ]] || RP_LANG=ru; shift 2 ;;
    -*)          red "Неизвестный флаг $1"; exit 1 ;;
    *)           NEW="$1"; shift ;;
  esac
done

if [[ -n "${DO_HELP:-}" ]]; then        # справка не требует root и идёт до остальной инициализации
  apply_ui
  if [[ "$RP_LANG" == en && -f "$RP_SELF" ]] && command -v perl >/dev/null; then rp_load_dict; show_help | rp_translate
  else show_help; fi
  exit 0
fi

[[ $EUID -eq 0 ]] || { red "Запусти от root (sudo)"; exit 1; }

# Запуск через «bash <(curl …)»: файла скрипта нет — ставим его в /usr/local/bin/rw и перезапускаемся оттуда,
# иначе не работают перевод, cron-задачи и смена языка
if [[ ! -f "$RP_SELF" ]]; then
  _t=$(mktemp)
  if rp_fetch_latest "$_t" && install -m 755 "$_t" /usr/local/bin/rw; then
    rm -f "$_t"; echo "RemnaPilot установлен в /usr/local/bin/rw — дальше запускай командой: rw"
    exec /usr/local/bin/rw "${RP_ARGS[@]}"
  fi
  rm -f "$_t"
fi

apply_ui

if [[ "$RP_LANG" == en && -f "$RP_SELF" ]] && command -v perl >/dev/null; then
  rp_load_dict
  exec 3>&1 4>&2
  exec > >(rp_translate) 2>&1
  RP_TR_PID=$!
  trap 'tty_restore; exec >&- 2>&-; wait "$RP_TR_PID" 2>/dev/null' EXIT
fi
if [[ -n "$NEW" || -n "${SUB_NEW:-}" || ${DO_UPDATE:-0} == 1 || ${DO_CERT_STATUS:-0} == 1 ]]; then
  need_panel || exit 1
fi

if (( ${DO_SELFTEST:-0} )); then
  rp_selftest; exit 0
elif [[ -n "${DO_DECRYPT:-}" ]]; then
  bk_decrypt "$DO_DECRYPT"; exit $?
elif (( ${DO_CHANGELOG:-0} )); then
  { printf '\n  %s%sИстория изменений RemnaPilot%s\n' "$C_ACC2" "$CB" "$C0"; show_changes; echo; } | RP_PAGER_TOP=1 show_paged; exit 0
elif (( ${DO_WHATSNEW:-0} )); then
  whats_new ""; exit 0
elif (( ${DO_UNINSTALL:-0} )); then
  rp_uninstall; exit 0
elif (( ${DO_VERIFY:-0} )); then
  case "$(rp_verify_self)" in
    ok)       green "✔ Подлинный RemnaPilot v$RP_VERSION — файл совпадает с официальным релизом"; exit 0 ;;
    modified) yel "⚠ Файл не совпадает с официальным релизом v$RP_VERSION: он изменён или скачан не из релиза."
              echo "  Поставить официальный: Панель → Обновления → RemnaPilot → 1"; exit 2 ;;
    *)        yel "Не удалось проверить: нет связи с GitHub или у релиза нет контрольной суммы"; exit 3 ;;
  esac
elif (( ${DO_AU:-0} )); then
  with_lock "Автообновление" au_run; rc=$?; (( rc == 75 )) && lock_timeout "Автообновление" /etc/rw/.autoupdate_last; exit $rc
elif (( ${DO_BACKUP:-0} )); then
  with_lock "Автобэкап" bk_run; rc=$?; (( rc == 75 )) && lock_timeout "Автобэкап" /etc/rw/.backup_last; [[ -f /etc/rw/.backup_last ]] && cut -d'|' -f3 /etc/rw/.backup_last; exit $rc
elif (( ${DO_CHECK:-0} )); then
  au_check_all; update_hints | sed -E 's/\x1b\[[0-9;]*m//g'; exit 0
elif [[ -n "${DO_GEO:-}" ]]; then
  with_lock "Обновление geo" bash -c "$(geo_script "$DO_GEO")"
elif (( ${DO_CERT_STATUS:-0} )); then
  cert_status
elif [[ -n "${SUB_NEW:-}" ]]; then
  run_action "Смена домена подписки" change_sub_domain "$SUB_NEW" "$DRY"
elif (( ${DO_UPDATE_ALL:-0} )); then
  run_action "Обновление: всё" update_all
elif (( ${DO_UPDATE:-0} )); then
  run_action "Обновление панели" update_panel
elif [[ -n "$NEW" ]]; then
  run_action "Смена домена" change_domain "$NEW" "$OLD" "$DRY"
else
  offer_cmd
  check_whats_new
  # автопроверка обновлений включена по умолчанию (раз в сутки ночью); выключается в Панель → Обновления → Автообновление
  [[ -f "$AU_CONF" || -f /etc/cron.d/remnapilot-update ]] || au_install_cron 2>/dev/null
  # раз в сутки при запуске — тихо обновить кэш версий в фоне
  if [[ ! -f /etc/rw/.latest_version ]] || (( $(date +%s) - $(stat -c %Y /etc/rw/.latest_version 2>/dev/null || echo 0) > 86400 )); then
    ( au_check_all >/dev/null 2>&1 & ) 2>/dev/null
  fi
  menu
fi
exit $?          # код действия: cron и скрипты видят, если обновление или смена домена не удались

