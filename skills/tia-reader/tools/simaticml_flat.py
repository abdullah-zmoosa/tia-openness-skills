"""Flatten SimaticML exports (PLC tag tables, HMI screens/tags/connections, ...)
into readable text.

Usage: python simaticml_flat.py <export_dir>

Writes:
  <export_dir>/tags/_PLC_TAGS.txt     Name | Address | Type | Comment  (all PLC tag tables)
  <export_dir>/hmi/<hmi>/_HMI_TAGS.txt HMI tag -> PLC tag / connection / address
  <xml>.txt next to every other XML under tags/ watch/ hmi/ alarm_textlists/
"""
import pathlib
import sys
import xml.etree.ElementTree as ET


def local(tag):
    return tag.rsplit("}", 1)[-1]


def attrs(el):
    """AttributeList children as {name: text}."""
    out = {}
    al = next((c for c in el if local(c.tag) == "AttributeList"), None)
    if al is None:
        return out
    for a in al:
        txt = "".join(a.itertext()).strip()
        if txt:
            out[local(a.tag)] = " ".join(txt.split())
    return out


def links(el):
    """LinkList children as {name: target name}."""
    out = {}
    ll = next((c for c in el if local(c.tag) == "LinkList"), None)
    if ll is None:
        return out
    for l in ll:
        name = "".join(l.itertext()).strip()
        out[local(l.tag)] = name
    return out


def comment(el):
    """First MultilingualText 'Comment' text directly under this object."""
    ol = next((c for c in el if local(c.tag) == "ObjectList"), None)
    if ol is None:
        return ""
    for mt in ol:
        if local(mt.tag) == "MultilingualText" and mt.get("CompositionName") == "Comment":
            for t in mt.iter():
                if local(t.tag) == "Text" and (t.text or "").strip():
                    return " ".join(t.text.split())
    return ""


def objects(root):
    """Every engineering object = element with an ID and an AttributeList."""
    for el in root.iter():
        if el.get("ID") is not None and any(local(c.tag) == "AttributeList" for c in el):
            yield el


def plc_tags(export):
    rows = []
    for f in sorted((export / "tags").rglob("*.xml")):
        table = f.stem
        for el in objects(ET.parse(f).getroot()):
            if local(el.tag) != "SW.Tags.PlcTag":
                continue
            a = attrs(el)
            rows.append((a.get("Name", "?"), a.get("LogicalAddress", ""), a.get("DataTypeName", ""),
                         table, comment(el)))
    if not rows:
        return 0
    w = [max(len(r[i]) for r in rows) for i in range(4)]
    lines = ["# PLC tags (all tag tables)", "# Name | Address | Type | Table | Comment", ""]
    for r in sorted(rows, key=lambda r: (r[1] == "", r[1], r[0])):
        lines.append(" | ".join(r[i].ljust(w[i]) for i in range(4)) + " | " + r[4])
    (export / "tags" / "_PLC_TAGS.txt").write_text("\n".join(lines), encoding="utf-8")
    return len(rows)


def hmi_tags(hmi_dir):
    rows = []
    for f in sorted(hmi_dir.rglob("*.xml")):
        for el in objects(ET.parse(f).getroot()):
            if local(el.tag) != "Hmi.Tag.Tag":
                continue
            a, l = attrs(el), links(el)
            rows.append((a.get("Name", "?"), l.get("ControllerTag", a.get("Address", "")),
                         l.get("Connection", ""), l.get("DataType", a.get("DataType", "")), f.stem))
    if not rows:
        return 0
    w = [max(len(r[i]) for r in rows) for i in range(4)]
    lines = ["# HMI tags", "# HMI tag | PLC tag / address | Connection | Type | Table", ""]
    for r in sorted(rows):
        lines.append(" | ".join(r[i].ljust(w[i]) for i in range(4)) + " | " + r[4])
    (hmi_dir / "_HMI_TAGS.txt").write_text("\n".join(lines), encoding="utf-8")
    return len(rows)


def flatten(f):
    """Indented object tree: Type Name {interesting attrs} -> links."""
    root = ET.parse(f).getroot()
    lines = ["# " + f.name, ""]
    skip = {"ID", "AttributeList", "LinkList", "ObjectList"}

    def walk(el, depth):
        if el.get("ID") is not None and local(el.tag) not in ("MultilingualText", "MultilingualTextItem"):
            a, l = attrs(el), links(el)
            if a or l:
                name = a.pop("Name", "")
                keep = {k: v for k, v in a.items() if len(v) < 120}
                s = "  " * depth + local(el.tag) + (" " + name if name else "")
                if keep:
                    s += "  {" + ", ".join(k + "=" + v for k, v in list(keep.items())[:12]) + "}"
                if l:
                    s += "  -> " + ", ".join(k + ":" + v for k, v in l.items() if v)
                lines.append(s)
                depth += 1
        for c in el:
            if local(c.tag) not in ("AttributeList", "LinkList"):
                walk(c, depth)

    walk(root, 0)
    f.with_suffix(".xml.txt").write_text("\n".join(lines), encoding="utf-8")


def main(export):
    print("PLC tags:", plc_tags(export))
    hmi_root = export / "hmi"
    if hmi_root.exists():
        for h in sorted(p for p in hmi_root.iterdir() if p.is_dir()):
            print("HMI tags", h.name + ":", hmi_tags(h))
    n = 0
    for sub in ("tags", "watch", "hmi", "alarm_textlists"):
        for f in sorted((export / sub).rglob("*.xml")) if (export / sub).exists() else []:
            try:
                flatten(f)
                n += 1
            except ET.ParseError as e:
                print("SKIP", f, e)
    print("Flattened", n, "XML files")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: simaticml_flat.py <export_dir>")
    main(pathlib.Path(sys.argv[1]))
