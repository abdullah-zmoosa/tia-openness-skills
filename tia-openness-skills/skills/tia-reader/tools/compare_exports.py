"""Compare two tia-reader exports and report real differences (noise removed).

Usage: python compare_exports.py <exportA> <exportB> [--show N]
  <exportX> = the "export" folder (or its parent) of a tia-reader run.

Ignored noise: <Created> timestamps; in hw/project.aml GUID IDs, LastWritingDateTime, project name.
"""
import difflib
import json
import pathlib
import re
import sys

SKIP_PARTS = {"_src", "_retrieved", "edit"}


def root(p):
    p = pathlib.Path(p)
    return p / "export" if (p / "export").is_dir() else p


def norm(rel, text, project_names):
    text = re.sub(r"<Created>[^<]*</Created>", "", text)
    if rel.endswith(".aml"):
        text = re.sub(r'\b(ID|RefPartnerSide[AB]|RefBaseSystemUnitPath)="[^"]*"', "", text)
        text = re.sub(r"<LastWritingDateTime>[^<]*</LastWritingDateTime>", "", text)
        text = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "", text)
        for n in project_names:
            text = text.replace(n, "<PROJECT>")
        text = re.sub(r"<PROJECT>(_V\d+)?", "<PROJECT>", text)
    return text


def files(r):
    return {p.relative_to(r).as_posix() for p in r.rglob("*")
            if p.is_file() and not SKIP_PARTS & set(p.relative_to(r).parts)}


def main():
    a, b = root(sys.argv[1]), root(sys.argv[2])
    show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 12
    names = []
    for r in (a, b):
        try:
            names.append(pathlib.Path(json.load(open(r / "manifest.json"))["project"]).stem)
        except Exception:
            pass
    ma = {x["name"]: x for x in json.load(open(a / "manifest.json"))["blocks"]}
    mb = {x["name"]: x for x in json.load(open(b / "manifest.json"))["blocks"]}
    print(f"A: {a}\nB: {b}\n")
    print("Blocks only in A:", sorted(set(ma) - set(mb)) or "none")
    print("Blocks only in B:", sorted(set(mb) - set(ma)) or "none")
    fa, fb = files(a), files(b)
    print("Files only in A:", sorted(fa - fb) or "none")
    print("Files only in B:", sorted(fb - fa) or "none")
    diffs = 0
    for rel in sorted(fa & fb):
        if rel == "manifest.json" or rel.endswith(".log"):
            continue
        ta = norm(rel, (a / rel).read_text(encoding="utf-8-sig", errors="replace"), names)
        tb = norm(rel, (b / rel).read_text(encoding="utf-8-sig", errors="replace"), names)
        if ta == tb:
            continue
        diffs += 1
        print(f"\n--- DIFF {rel}")
        lines = [l for l in difflib.unified_diff(ta.splitlines(), tb.splitlines(), "A", "B", n=0, lineterm="")
                 if not l.startswith(("---", "+++", "@@"))]
        for l in lines[:show]:
            print("   " + l.strip()[:220])
        if len(lines) > show:
            print(f"   ... {len(lines) - show} more changed lines")
    print(f"\nCompared {len(fa & fb)} common files: {diffs} differ after removing noise.")


if __name__ == "__main__":
    main()
