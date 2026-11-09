#!/usr/bin/env bash
#  ╦═╗┌─┐┌┬┐┌┐┌┌─┐╔═╗┬┬  ┌─┐┌┬┐
#  ╠╦╝├┤ │││││││├─┤╠═╝││  │ │ │
#  ╩╚═└─┘┴ ┴┘└┘┴ ┴╩  ┴┴─┘└─┘ ┴   — пульт управления Remnawave
#
# Copyright (c) 2026 Dubstep2004. Все права защищены. / All rights reserved.
# Условия использования — файл LICENSE: https://github.com/Dubstep2004/RemnaPilot/blob/main/LICENSE
# Копировать, выкладывать и продавать изменённые версии без разрешения автора запрещено.
#
# Репозиторий:    https://github.com/Dubstep2004/RemnaPilot
# Установка:      bash <(curl -sSL https://raw.githubusercontent.com/Dubstep2004/RemnaPilot/main/remnapilot.sh)
#                 или скопируй файл на сервер и запусти  sudo bash remnapilot.sh
# Запуск с меню:  rw   (или sudo bash remnapilot.sh)
# Без меню:       sudo bash remnapilot.sh new.domain.com [--old old.domain.com] [--dir /opt/remnawave] [--dry-run] [--skip-cert]
#                 --cert-method http|alpn|dns|manual  (dns = Cloudflare, токен в CF_Token; manual = TXT вручную)
#                 --sub sub.domain.com [--dry-run] сменить домен подписки
#                 --update                       обновить панель    --update-all   панель + ноды
#                 --self-update [файл]           обновить RemnaPilot с GitHub (с проверкой подлинности) или из файла
#                 --verify                       проверить, что этот файл совпадает с официальным релизом
#                 --whats-new / --changelog      что нового в этой версии / вся история изменений
#                 --uninstall                    удалить RemnaPilot (панель и ноды не трогаются)
#                 --selftest                     самопроверка сервера: всё ли готово (ничего не меняет)
#                 --lang en|ru                   язык интерфейса (меню: «Language / Язык»)
#                 --cert-status                  статус сертификатов
#                 --check-updates                проверить обновления RemnaPilot, панели, ноды
#                 --auto-update                  то, что делает автообновление (для cron)
#                 --backup                       бэкап по расписанию: архив + Telegram (для cron)
#                 --decrypt файл.tar.gz.enc       расшифровать архив бэкапа из Telegram

RP_DEFAULT_SOURCE="Dubstep2004/RemnaPilot"   # официальный репозиторий: отсюда установка и обновления

# Запуск через «curl … | bash»: stdin занят текстом скрипта, меню не сможет читать ввод.
# Скачиваем себя в /usr/local/bin/rw и перезапускаемся уже с клавиатурой.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == bash || "${BASH_SOURCE[0]}" == /dev/stdin ]] && [[ ! -t 0 ]]; then
  [[ $EUID -eq 0 ]] || { echo "Запусти от root (sudo -i)"; exit 1; }
  _t=$(mktemp); _b="https://github.com/$RP_DEFAULT_SOURCE/releases/latest/download"
  if curl -fsSL "$_b/remnapilot.sh" -o "$_t" 2>/dev/null; then
    _s=$(curl -fsSL "$_b/remnapilot.sh.sha256" 2>/dev/null | awk '{print $1}')
    if [[ -n "$_s" && "$(sha256sum "$_t" | awk '{print $1}')" != "$_s" ]]; then
      rm -f "$_t"; echo "Контрольная сумма не совпала с релизом — файл подменён или повреждён. Установка отменена."; exit 1
    fi
  else
    curl -fsSL "https://raw.githubusercontent.com/$RP_DEFAULT_SOURCE/main/remnapilot.sh" -o "$_t" 2>/dev/null
  fi
  if bash -n "$_t" 2>/dev/null && grep -q 'RP_NAME="RemnaPilot"' "$_t" && install -m 755 "$_t" /usr/local/bin/rw; then
    rm -f "$_t"; echo "RemnaPilot установлен. Дальше запускай командой:  rw"
    if (exec </dev/tty) 2>/dev/null; then exec /usr/local/bin/rw "$@" </dev/tty; fi
    exit 0
  fi
  rm -f "$_t"; echo "Не удалось скачать RemnaPilot. Сохрани скрипт в файл и запусти:  sudo bash remnapilot.sh"; exit 1
fi

set -o pipefail
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"   # cron даёт урезанный PATH
RP_NAME="RemnaPilot"
RP_VERSION="2.3"
CERT_METHOD="${CERT_METHOD:-}"
STOPPED_CT=(); STOPPED_SVC=(); FW_OPENED=()

RW_DIR="/opt/remnawave"
NEW=""; OLD=""; DRY=0; SKIP_CERT=0

