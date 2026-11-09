#!/usr/bin/env python3
"""Сборка remnapilot.sh из модулей src/*.sh и словаря src/i18n/en.tsv.

  python3 tools/build.py           собрать remnapilot.sh
  python3 tools/build.py --check   проверить, что remnapilot.sh собран из текущих src/ (для CI)

Редактируй файлы в src/, потом собери. Сам remnapilot.sh руками не правь —
CI это заметит и не пропустит.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "remnapilot.sh"


def build() -> str:
    parts = [p.read_text(encoding="utf-8") for p in sorted(SRC.glob("*.sh"))]
    for p, text in zip(sorted(SRC.glob("*.sh")), parts):
        if not text.endswith("\n"):
            sys.exit(f"{p.name}: файл должен заканчиваться переводом строки")
    en = (SRC / "i18n" / "en.tsv").read_text(encoding="utf-8")
    if en and not en.endswith("\n"):
        en += "\n"
    for n, line in enumerate(en.splitlines(), 1):
        if line and "\t" not in line:
            sys.exit(f"src/i18n/en.tsv:{n}: нужна табуляция между русским и английским текстом")
    return ("".join(parts)
            + "# Словарь интерфейса RU → EN (используется при RP_LANG=en)\n"
            + ": <<'__RP_EN_END__'\n__RP_EN__\n"
            + en
            + "__RP_EN_END__\n")


def main(argv):
    text = build()
    if "--check" in argv:
        if OUT.read_text(encoding="utf-8") != text:
            print("remnapilot.sh не совпадает с src/ — запусти: python3 tools/build.py")
            return 1
        return 0
    OUT.write_text(text, encoding="utf-8")
    OUT.chmod(0o755)
    print(f"Собрано: {OUT.name} ({len(text.splitlines())} строк из {len(list(SRC.glob('*.sh')))} модулей)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
