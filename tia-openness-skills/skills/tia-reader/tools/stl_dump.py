"""Render STL (Statement List) networks from SimaticML block XML to text.

Usage: python stl_dump.py <blocks_dir>   -> writes <block>.stl next to each XML with STL code
"""
import pathlib
import sys
import xml.etree.ElementTree as ET


def local(tag):
    return tag.rsplit("}", 1)[-1]


def operand(acc):
    """<Access> -> "Tag.Member", "%I0.0", constant, etc."""
    scope = acc.get("Scope", "")
    for c in acc.iter():
        n = local(c.tag)
        if n == "ConstantValue":
            return (c.text or "").strip()
        if n == "Address":
            area = c.get("Area", "")
            bit = c.get("BitOffset", "")
            typ = c.get("Type", "")
            num = c.get("BlockNumber")
            if num:
                return f"%DB{num}.?{bit}"
            return f"%{area}{typ}{bit}"
        if n == "Symbol":
            parts = []
            for comp in c:
                if local(comp.tag) == "Component":
                    parts.append(comp.get("Name", "?"))
            s = ".".join(parts)
            return "#" + s if scope in ("LocalVariable", "LocalConstant") else '"' + s + '"'
        if n == "Label":
            return c.get("Name", "")
    return "?" + scope


def render_statement(st):
    tok, ops, label, cmt = "", [], "", ""
    for c in st:
        n = local(c.tag)
        if n == "StlToken":
            tok = c.get("Text", "")
        elif n == "Access":
            ops.append(operand(c))
        elif n == "LabelDeclaration":
            lab = next((x for x in c.iter() if local(x.tag) == "Label"), None)
            label = (lab.get("Name", "") + ":") if lab is not None else ""
        elif n in ("Comment", "LineComment"):
            cmt = " ".join("".join(c.itertext()).split())
    line = f"{label:<8}{tok:<8}{', '.join(ops)}"
    if cmt:
        line += ("   " if line.strip() else "") + "// " + cmt
    return line.rstrip()


def main(blocks):
    n = 0
    for f in sorted(blocks.glob("*.xml")):
        root = ET.parse(f).getroot()
        out = []
        for i, sl in enumerate((e for e in root.iter() if local(e.tag) == "StatementList"), 1):
            stmts = [s for s in sl if local(s.tag) == "StlStatement"]
            if not stmts:
                continue
            out.append(f"--- Network {i} ---")
            out.extend(render_statement(s) for s in stmts)
            out.append("")
        if out:
            f.with_suffix(".stl").write_text("\n".join(out), encoding="utf-8")
            n += 1
            print("  rendered:", f.with_suffix(".stl").name)
    print(f"STL: {n} blocks rendered")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: stl_dump.py <blocks_dir>")
    main(pathlib.Path(sys.argv[1]))
