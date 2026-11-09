#!/usr/bin/env python3
"""История изменений RemnaPilot из одного источника — массива RP_CHANGELOG в remnapilot.sh.

  python3 tools/changelog.py --write          обновить CHANGELOG.md и блоки «Что нового» в README
  python3 tools/changelog.py --check          проверить, что они актуальны (для тестов)
  python3 tools/changelog.py --release 2.2    описание релиза для GitHub (stdout)
                             [--archived]     для старой версии без файла
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "remnapilot.sh"
REPO = "Dubstep2004/RemnaPilot"
RAW = f"https://raw.githubusercontent.com/{REPO}/main/remnapilot.sh"

CATS = [  # порядок показа
    ("new",      "✨", "Новое",        "New"),
    ("improve",  "🚀", "Улучшено",     "Improved"),
    ("fix",      "🐛", "Исправлено",   "Fixed"),
    ("security", "🛡️", "Безопасность", "Security"),
    ("change",   "🔄", "Изменено",     "Changed"),
]
START = "<!-- whats-new:start -->"
END = "<!-- whats-new:end -->"


def load():
    s = SCRIPT.read_text(encoding="utf-8")
    m = re.search(r"^RP_CHANGELOG=\(\n(.*?)\n\)", s, re.S | re.M)
    entries = []
    for ver, cat, text in re.findall(r'^\s*"([^"|]+)\|([a-z]+)\|((?:[^"\\]|\\.)*)"\s*$', m.group(1), re.M):
        entries.append((ver, cat, text.replace('\\"', '"')))
    dic = {}
    if "\n__RP_EN__\n" in s:
        for line in s.split("\n__RP_EN__\n", 1)[1].splitlines():
            if line == "__RP_EN_END__":
                break
            if "\t" in line:
                ru, en = line.split("\t", 1)
                dic.setdefault(ru, en)
    current = re.search(r'^RP_VERSION="([^"]+)"', s, re.M).group(1)
    return entries, dic, current


def versions(entries):
    out = []
    for v, _, _ in entries:
        if v not in out:
            out.append(v)
    return out


def section(entries, ver, lang="ru", dic=None, level="###"):
    lines = []
    for cat, icon, ru, en in CATS:
        items = [t for v, c, t in entries if v == ver and c == cat]
        if not items:
            continue
        lines.append(f"{level} {icon} {ru if lang == 'ru' else en}")
        lines.append("")
        for t in items:
            if lang == "en":
                t = dic.get(t, t)
            lines.append(f"- {t}")
        lines.append("")
    return lines


def legend(lang):
    return " · ".join(f"{i} {ru if lang == 'ru' else en}" for _, i, ru, en in CATS)


def changelog(entries, dic):
    out = ["# 📜 История изменений RemnaPilot", "",
           f"> {legend('ru')}", "",
           f"Последняя версия — [в релизах](https://github.com/{REPO}/releases/latest). "
           "В терминале: `rw --whats-new` и `rw --changelog`.", ""]
    for v in versions(entries):
        out += [f"## v{v}", ""] + section(entries, v)
    return "\n".join(out).rstrip() + "\n"


def readme_block(entries, dic, current, lang):
    vs = versions(entries)
    latest = vs[0]
    pic = ['<img src="assets/whats-new.png" width="420" align="right" alt="Экран «Что нового»">', ""] if lang == "ru" else []
    if lang == "ru":
        head = [START, f"## 🆕 Что нового в v{latest}", ""] + pic
        tail = [f"📜 [Вся история изменений](CHANGELOG.md) · 🏷️ [Все релизы](https://github.com/{REPO}/releases)"]
        prev = f"<details>\n<summary><b>Предыдущая версия — v{vs[1]}</b></summary>\n" if len(vs) > 1 else ""
    else:
        head = [START, f"## 🆕 What's new in v{latest}", ""]
        tail = [f"📜 [Full changelog (RU)](CHANGELOG.md) · 🏷️ [All releases](https://github.com/{REPO}/releases)"]
        prev = f"<details>\n<summary><b>Previous version — v{vs[1]}</b></summary>\n" if len(vs) > 1 else ""
    body = section(entries, latest, lang, dic, level="####")
    if prev:
        body += [prev] + section(entries, vs[1], lang, dic, level="####") + ["</details>", ""]
    note = (["", "> После обновления RemnaPilot сам покажет, что нового. Вся история в терминале — `rw --changelog`.", ""] if lang == "ru"
            else ["", "> After an update RemnaPilot shows what's new by itself. Full history in the terminal — `rw --changelog`.", ""])
    return "\n".join(head + body + tail + note + ['<br clear="right">' if lang == "ru" else "", END])


def put_block(path, block):
    s = path.read_text(encoding="utf-8")
    if START in s:
        s = re.sub(re.escape(START) + r".*?" + re.escape(END), lambda _: block, s, flags=re.S)
    return s


def release_notes(entries, dic, ver, archived):
    if ver not in versions(entries):
        sys.exit(f"нет версии {ver} в RP_CHANGELOG")
    out = ['<div align="center">', "",
           f"# 🛰️ RemnaPilot v{ver}", "",
           "**Пульт управления Remnawave прямо в терминале**", "",
           f"{legend('ru')}", "", "</div>", ""]
    if archived:
        out += ["> [!NOTE]",
                f"> Архивная версия: её файл не сохранился. Ставь актуальную — [последний релиз](https://github.com/{REPO}/releases/latest).",
                ""]
    out += section(entries, ver)
    out += ["<details>", "<summary>🇬🇧 <b>English</b></summary>", ""] + section(entries, ver, "en", dic, level="####") + ["</details>", ""]
    out += ["---", "",
            "### 📦 Установка", "", "На сервере под `root`:", "",
            "```bash", f"bash <(curl -sSL {RAW})", "```", "",
            "### 🔄 Уже установлен", "",
            "`rw` → **Панель → Обновления → RemnaPilot → 1** или `rw --self-update`.", "",
            "### 🛡️ Подлинность", "",
            "К релизу приложен `remnapilot.sh.sha256` — RemnaPilot сверяет с ним каждое обновление "
            "и не ставит файл, если сумма не совпала. Проверить установленный: `rw --verify`.", "",
            f"📜 [Вся история изменений](https://github.com/{REPO}/blob/main/CHANGELOG.md) · "
            f"📄 [Лицензия](https://github.com/{REPO}/blob/main/LICENSE) — © 2026 Dubstep2004, все права защищены"]
    return "\n".join(out) + "\n"


def main(argv):
    entries, dic, current = load()
    if "--release" in argv:
        ver = argv[argv.index("--release") + 1].lstrip("v")
        sys.stdout.write(release_notes(entries, dic, ver, "--archived" in argv))
        return 0
    targets = {
        ROOT / "CHANGELOG.md": changelog(entries, dic),
        ROOT / "README.md": put_block(ROOT / "README.md", readme_block(entries, dic, current, "ru")),
        ROOT / "README.en.md": put_block(ROOT / "README.en.md", readme_block(entries, dic, current, "en")),
    }
    stale = [p.name for p, text in targets.items() if p.read_text(encoding="utf-8") != text]
    if "--check" in argv:
        if stale:
            print("Устарели: " + ", ".join(stale) + " — запусти: python3 tools/changelog.py --write")
            return 1
        return 0
    for p, text in targets.items():
        p.write_text(text, encoding="utf-8")
    print("Обновлено: " + (", ".join(stale) if stale else "всё уже актуально"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
