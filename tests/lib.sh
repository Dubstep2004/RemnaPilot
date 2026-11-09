# Общие помощники для тестов RemnaPilot
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/remnapilot.sh"
T_FAILS=0

# Временная папка теста, удаляется в конце
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Функции скрипта без запуска меню
funcs() { awk '/^# ---------- старт/{exit} {print}' "$SCRIPT" > "$T/funcs.sh"; echo "$T/funcs.sh"; }

nocolor() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r'; }

ok()   { printf '  \e[32m✔\e[0m %s\n' "$1"; }
fail() { printf '  \e[31m✖ %s\e[0m\n' "$1"; T_FAILS=$((T_FAILS+1)); }

check()       { if eval "$2"; then ok "$1"; else fail "$1"; fi; }            # название, условие
has()         { if grep -qF -- "$2" "$3"; then ok "$1"; else fail "$1 — нет «$2» в $(basename "$3")"; fi; }
has_not()     { if grep -qF -- "$2" "$3"; then fail "$1 — лишнее «$2» в $(basename "$3")"; else ok "$1"; fi; }
out_has()     { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else fail "$1 — нет «$2»"; printf '%s\n' "$3" | tail -15 | sed 's/^/      /'; fi; }

# Заглушка docker: всё «работает», версия 2.2.4
stub_docker() {
  mkdir -p "$T/bin"
  cat > "$T/bin/docker" <<'D'
#!/bin/bash
case "$*" in
  "ps -a --format {{.Names}}|{{.Status}}|{{.Image}}") printf 'remnawave|Up 3 days (healthy)|remnawave/backend:latest\nremnawave-db|Up 3 days|postgres:17\n' ;;
  ps*) printf 'remnawave\tremnawave/backend:latest\n' ;;
  "inspect --format"*) echo 2.2.4 ;;
  "system df"*) echo "Images 1.2GB 300MB (25%)" ;;
esac; exit 0
D
  for t in ufw sshd timedatectl fail2ban-client systemctl journalctl acme.sh; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$t"; done
  printf '#!/bin/sh\nexit 7\n' > "$T/bin/curl"      # без сети
  chmod +x "$T/bin"/*
}

finish() { (( T_FAILS == 0 )); }
