#!/bin/bash
# Живой статус: меню само перерисовывается при изменении состояния; ввод в терминале работает как раньше
. "$(dirname "$0")/lib.sh"
echo "Живой статус"
command -v python3 >/dev/null || { ok "python3 нет — пропуск"; finish; exit; }

F=$(funcs)
cat > "$T/drv.sh" <<D
. "$F"
RW_DIR="$T/rw"; UI_STATUS=full; UI_LIVE=1
docker() { cat "$T/state" 2>/dev/null; }
n=0
while true; do
  n=\$((n+1)); printf 'DRAW%s:' "\$n"
  menu_read v; rc=\$?
  (( rc == 2 )) && { echo "<REFRESH>"; continue; }
  printf 'GOT[%s]\n' "\$v"
  [[ "\$v" == 0 ]] && break
done
stty -a | grep -o -- '-\?icanon\|-\?echo ' | tr -d '\n'; echo "<END>"
D
mkdir -p "$T/rw"; echo 'remnawave|Up 3 minutes (healthy)|remnawave/backend:2' > "$T/state"

cat > "$T/ptydrv.py" <<'P'
import os, pty, sys, time, select
drv, state = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", drv])
out = b""
def pump(t):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: out += os.read(fd, 4096)
            except OSError: return
def send(b): os.write(fd, b)
pump(0.6)
send(b"1"); pump(0.3); send(b"2"); pump(0.2); send(b"\r"); pump(0.4)          # обычный ввод
send(b"abc\x7f\x7fd\r"); pump(0.4)                                            # backspace
send("серт".encode() + b"\x7f" + "т".encode() + b"\r"); pump(0.4)           # кириллица + backspace
send(b"\x1b[A\x1b[B7\r"); pump(0.4)                                           # стрелки игнорируются
send(b"34"); pump(0.01); send(b"\r"); pump(0.4); send(b"5\r"); pump(0.4)       # быстрый ввод не двоится
send(b"61\r99\r"); pump(0.5)                                                 # вставка двух строк: вторая отбрасывается
open(state, "w").write("remnawave|Up 4 minutes (healthy)|remnawave/backend:2\n"); pump(2.6)   # только время — без перерисовки
mark = len(out)
open(state, "w").write("remnawave|Exited (1) 2 seconds ago|remnawave/backend:2\n"); pump(2.6)  # упала — перерисовка
after = out[mark:]
send(b"9"); pump(0.2)
open(state, "w").write("remnawave|Up 1 second|remnawave/backend:2\n"); pump(2.6)               # печатает — не мешаем
send(b"\r"); pump(0.4)
send(b"0\r"); pump(0.6)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.stdout.write("\nAFTERCRASH=" + ("yes" if b"<REFRESH>" in after else "no") + "\n")
P
OUT=$(python3 "$T/ptydrv.py" "$T/drv.sh" "$T/state" 2>&1 | tr -d '\r')
out_has "обычный ввод" "DRAW1:12" "$OUT"
out_has "значение передано" "GOT[12]" "$OUT"
out_has "backspace стирает" "GOT[ad]" "$OUT"
out_has "кириллица и backspace" "GOT[серт]" "$OUT"
out_has "стрелки не попадают в ввод" "GOT[7]" "$OUT"
out_has "быстрый ввод: первая строка" "GOT[34]" "$OUT"
out_has "быстрый ввод: вторая строка" "GOT[5]" "$OUT"
out_has "вставка: первая строка принята" "GOT[61]" "$OUT"
check "вставка: лишняя строка не попадает в следующий вопрос" '! grep -q "GOT\[99\]" <<< "$OUT"'
check "символы не двоятся на экране" '! grep -q "3344\|1122" <<< "$OUT"'
check "перерисовка ровно один раз (только когда панель упала)" '[[ $(grep -o "<REFRESH>" <<< "$OUT" | wc -l) == 1 ]]'
out_has "перерисовка после падения панели" "AFTERCRASH=yes" "$OUT"
out_has "во время набора экран не трогается" "GOT[9]" "$OUT"
check "терминал возвращён в обычный режим" 'grep -q "^icanonecho <END>\|^echo icanon<END>\|icanon.*echo.*<END>" <<< "$OUT" && ! grep -q -- "-icanon\|-echo <END>" <<< "$(grep "<END>" <<< "$OUT")"'

# --- настоящее меню в терминале, оба языка: ввод, подменю, перерисовка при падении панели ---
mkdir -p "$T/bin" "$T/panel"; echo 'FRONT_END_DOMAIN=p.example.com' > "$T/panel/.env"
cat > "$T/bin/docker" <<D
#!/bin/bash
case "\$*" in
  *"{{.ID}}"*) sed 's/^/aaaabbbbccccdddd|/' "$T/state2" ;;
  "ps -a --format {{.Names}}|{{.Status}}|{{.Image}}") cat "$T/state2" ;;
  "compose version"*) echo 2.29.0 ;;
esac; exit 0
D
printf '#!/bin/sh\nexit 7\n' > "$T/bin/curl"; chmod +x "$T/bin"/*
cat > "$T/menu.py" <<'P'
import os, pty, sys, time, select
script, state, lang = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(RP_LANG=lang, RP_TESTS_FORCE="1", TERM="xterm-256color")
    os.execvp("bash", ["bash", script, "--dir", os.path.dirname(state) + "/panel"])
out = b""
def pump(t):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: out += os.read(fd, 65536)
            except OSError: return
pump(4)
os.write(fd, b"6\r"); pump(2.5); os.write(fd, b"0\r"); pump(2.5)
out += b"\n<<BEFORE>>\n"
open(state, "w").write("remnawave|Exited (1) 3 seconds ago|remnawave/backend:2.2.4\n"); pump(5)
out += b"\n<<AFTER>>\n"
os.write(fd, b"0\r")
code = -1
for _ in range(40):
    pump(0.25)
    try:
        w, st = os.waitpid(pid, os.WNOHANG)
    except OSError: break
    if w: code = st; break
out += b"\nEXIT=%d\n" % code
if code == -1:
    import subprocess
    out += b"\n<<PS>>\n" + subprocess.run(["ps","-eo","pid,ppid,stat,wchan:20,args","--forest"],capture_output=True).stdout
sys.stdout.write(out.decode("utf-8", "replace"))
P
for L in ru en; do
  rm -f /etc/rw/ui.conf /etc/rw/menu_mode; mkdir -p /etc/rw; echo "LIVE=3" > /etc/rw/ui.conf; touch /etc/rw/.latest_version /etc/rw/autoupdate.conf "$HOME/.rw-nocmd"
  echo 'remnawave|Up 3 minutes (healthy)|remnawave/backend:2.2.4' > "$T/state2"
  O=$(PATH="$T/bin:$PATH" python3 "$T/menu.py" "$SCRIPT" "$T/state2" $L 2>&1 | nocolor)
  [ $L = ru ] && { w_upd="Обновления ─"; w_ok="работает"; w_bad="остановлена"; } || { w_upd="Updates ─"; w_ok="running"; w_bad="stopped"; }
  out_has "[$L] подменю открылось по вводу" "$w_upd" "$O"
  check "[$L] до падения — «$w_ok»" 'sed -n "1,/<<BEFORE>>/p" <<< "$O" | grep -q "$w_ok"'
  check "[$L] меню само показало «$w_bad»" 'sed -n "/<<BEFORE>>/,/<<AFTER>>/p" <<< "$O" | grep -q "$w_bad"'
  out_has "[$L] выход по 0" "EXIT=0" "$O"
  check "[$L] без ошибок bash" '! grep -qE "line [0-9]+:|command not found|syntax error" <<< "$O"'
done
rm -rf /etc/rw "$HOME/.rw-nocmd"

# ожидание ввода не забирает символ (у «read -t» клавиша, пришедшая в момент таймаута, терялась)
R=$(printf 'x' | bash -c ". '$F'; tty_wait 2; echo rc=\$?; read -rn1 k; echo k=\$k")
out_has "tty_wait: ввод есть — сразу 0" "rc=0" "$R"
out_has "tty_wait: символ остался для read" "k=x" "$R"
R=$( (sleep 2; echo) | bash -c ". '$F'; s=\$(date +%s%N); tty_wait 0.3; echo rc=\$? ms=\$(( (\$(date +%s%N) - s) / 1000000 ))")
out_has "tty_wait: тишина — 1" "rc=1" "$R"
check "tty_wait: ждёт заданное время, не дольше" '[[ "$R" =~ ms=([0-9]+) ]] && (( BASH_REMATCH[1] >= 250 && BASH_REMATCH[1] < 1500 ))'
check "основной цикл не читает терминал через read -t" '! sed -n "/^menu_read()/,/^}/p" "$SCRIPT" | grep -q "read -rs -n1 -t \"\$iv\""'

# без терминала (pipe) и при LIVE=off — обычное чтение строки
R=$(printf '17\n' | bash -c ". '$F'; UI_LIVE=5; menu_read v; echo \"rc=\$? v=\$v\"")
out_has "без терминала читает строку" "rc=0 v=17" "$R"
R=$(bash -c ". '$F'; apply_ui; echo \$UI_LIVE")
check "по умолчанию 5 секунд" '[[ "$R" == 5 ]]'
SIG1=$(bash -c ". '$F'; docker() { echo 'a|Up 3 days (healthy)|img'; }; live_sig" | head -1)
SIG2=$(bash -c ". '$F'; docker() { echo 'a|Up About an hour (healthy)|img'; }; live_sig" | head -1)
check "время работы не влияет на отпечаток" '[[ "$SIG1" == "$SIG2" && "$SIG1" == *healthy* ]]'
finish
