#!/usr/bin/env python3
"""Проверка английского перевода: все строки с кириллицей из src/*.sh после словаря src/i18n/en.tsv
должны стать английскими — так же, как их переводит скрипт (замена фраз целиком, не внутри слов).

  python3 tools/i18n_check.py            список непереведённых фраз (код 1, если есть)
  python3 tools/i18n_check.py --stats    только число
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
CYR = re.compile(r"[А-Яа-яЁё]")

# Строки, которые не показываются пользователю или показываются как есть намеренно
SKIP_FILES = {"17-version-changelog.sh"}          # история изменений проверяется отдельно (changelog.py)
SKIP_LINE = re.compile(r"^\s*#|RP_CHANGELOG|grep -[a-zA-Z]*[qoc]|=~|case .* in|\bperl -.*lc\b|sed -n 's/")
ALLOW = {"Русский", "Language / Язык", "Язык", ".рф", "рф"}  # имя языка в переключателе показывается по-русски


def load_dict():
    d = {}
    for line in (SRC / "i18n" / "en.tsv").read_text(encoding="utf-8").splitlines():
        if "\t" in line:
            ru, en = line.split("\t", 1)
            if ru:
                d.setdefault(ru, en)
    keys = sorted(d, key=len, reverse=True)
    rx = re.compile(r"(?<![А-Яа-яЁё])(" + "|".join(map(re.escape, keys)) + r")(?![А-Яа-яЁё])")
    return d, rx


def code_only(line):
    """строка без хвостового комментария (# вне кавычек)"""
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q and line[i - 1] != "\\":
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t") and line[i - 1:i + 1] != "$#":
            return line[:i]
    return line


def strings(text):
    # содержимое "..." и '...' на одной строке
    for m in re.finditer(r'"((?:[^"\\\n]|\\.)*)"|\'([^\'\n]*)\'', text):
        yield m.group(1) if m.group(1) is not None else m.group(2)


SPLIT = re.compile(r"\$\{[^}]*\}|\$\((?:[^()]|\([^()]*\))*\)|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?@*]|%-?[0-9]*[sd]|\\[nte]|\\033\[[0-9;]*m|[`|]")


def fragments(s):
    s = s.replace('\\"', '"')
    for part in SPLIT.split(s):
        part = part.strip()
        if CYR.search(part) and not part.startswith("#"):
            yield part


def main(argv):
    d, rx = load_dict()
    left = {}
    for f in sorted(SRC.glob("*.sh")):
        if f.name in SKIP_FILES:
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if SKIP_LINE.search(line):
                continue
            for s in strings(code_only(line)):
                for frag in fragments(s):
                    if frag.strip(" :;,.!?—«»()[]") in ALLOW:
                        continue
                    out = rx.sub(lambda m: d[m.group(1)], frag)
                    if CYR.search(out):
                        left.setdefault(frag, f"{f.name}:{n}")
    if "--stats" not in argv:
        for frag, where in sorted(left.items(), key=lambda x: x[1]):
            print(f"{where}\t{frag}")
    print(f"Непереведённых фраз: {len(left)}", file=sys.stderr)
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
