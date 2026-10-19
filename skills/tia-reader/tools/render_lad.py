"""
render_lad.py  —  Task 8: SimaticML FlgNet → readable .lad.txt

Usage:
    python tools/tia-export/render_lad.py <blocks_dir>

For every <name>.xml in <blocks_dir> that contains at least one <FlgNet>
CompileUnit, writes <name>.lad.txt alongside the XML.

Covers:
  - <Call>       : FC/FB calls via CallInfo + Parameter blocks
  - <Part Name>  : Built-in instructions + MC_ technology-object instructions
                   (instances via <Instance Scope="LocalVariable">)
  - <Coil/SCoil/RCoil/PCoil/NCoil> : Output coils
  - <Contact>    : Input contacts (for context in boolean nets)
  - Network titles and comments from MultilingualText

Namespace handling: strips namespace prefixes using local-name matching so
the same code works for /v4, /v5, and safety FlgNet variants.

Faithfulness priority: (1) Calls + param→operand bindings, (2) Part
instructions + bindings, (3) Coils + operands, (4) titles/comments.
SCL networks are skipped (already in .scl).
"""

import re
import sys
import pathlib
import xml.etree.ElementTree as ET
from typing import Optional

# ---------------------------------------------------------------------------
# Helpers — namespace-agnostic element access
# ---------------------------------------------------------------------------

def part_is_negated(part: ET.Element) -> bool:
    """LAD contact/pin negation is a child <Negated Name="operand"/>, not an attribute."""
    if part.get("Negated"):
        return True
    for ch in part:
        if ch.tag.rsplit('}', 1)[-1] == "Negated":
            return True
    return False


def local(tag: str) -> str:
    """Return the local name, stripping namespace URI."""
    return tag.split("}", 1)[-1] if "}" in tag else tag


def find_text(elem: ET.Element, *local_names: str, attrib: str = None) -> Optional[str]:
    """BFS search for first element whose local-name is in local_names."""
    stack = list(elem)
    while stack:
        child = stack.pop(0)
        if local(child.tag) in local_names:
            if attrib:
                return child.get(attrib)
            return (child.text or "").strip()
        stack.extend(child)
    return None


def iter_local(elem: ET.Element, local_name: str):
    """Yield all descendants with given local name."""
    for child in elem.iter():
        if local(child.tag) == local_name:
            yield child


# ---------------------------------------------------------------------------
# Operand resolution
# ---------------------------------------------------------------------------

def resolve_access(access_elem: ET.Element) -> str:
    """Turn an <Access> element into a readable string."""
    # Symbol: chain of Component Name attributes
    symbol_parts = []
    for comp in access_elem.iter():
        if local(comp.tag) == "Component":
            name = comp.get("Name", "")
            if name:
                symbol_parts.append(name)
    if symbol_parts:
        return ".".join(symbol_parts)

    # Constant fallback
    for child in access_elem.iter():
        if local(child.tag) == "ConstantValue":
            ctype_elem = None
            for sib in access_elem.iter():
                if local(sib.tag) == "ConstantType":
                    ctype_elem = sib
                    break
            ctype = (ctype_elem.text or "").strip() if ctype_elem is not None else ""
            val = (child.text or "").strip()
            return f"{val}" if not ctype else f"{val} ({ctype})"

    return "<unresolved>"


# ---------------------------------------------------------------------------
# Wire index
# ---------------------------------------------------------------------------

def build_wire_index(flgnet: ET.Element):
    """
    Returns two dicts:
      uid_to_part[uid]   -> Part/Call/Access elem
      uid_to_wires[uid]  -> list of Wire elems this uid appears in

    Also returns:
      access_by_uid[uid] -> resolved operand string
    """
    access_by_uid: dict[str, str] = {}
    part_by_uid: dict[str, ET.Element] = {}
    call_by_uid: dict[str, ET.Element] = {}
    wire_by_uid: dict[str, list[ET.Element]] = {}

    # Index Parts section
    parts_elem = None
    for child in flgnet:
        if local(child.tag) == "Parts":
            parts_elem = child
            break

    if parts_elem is not None:
        for child in parts_elem:
            uid = child.get("UId", "")
            ltag = local(child.tag)
            if ltag == "Access":
                access_by_uid[uid] = resolve_access(child)
            elif ltag == "Part":
                part_by_uid[uid] = child
            elif ltag == "Call":
                call_by_uid[uid] = child

    # Index Wires section
    wires_elem = None
    for child in flgnet:
        if local(child.tag) == "Wires":
            wires_elem = child
            break

    if wires_elem is not None:
        for wire in wires_elem:
            if local(wire.tag) != "Wire":
                continue
            for con in wire:
                uid = con.get("UId", "")
                if uid:
                    wire_by_uid.setdefault(uid, []).append(wire)

    return access_by_uid, part_by_uid, call_by_uid, wire_by_uid


# ---------------------------------------------------------------------------
# Wire following
# ---------------------------------------------------------------------------

def access_connected_to_namecon(
    namecon_uid: str,
    pin_name: str,
    access_by_uid: dict,
    wire_by_uid: dict,
) -> str:
    """Find the Access operand on the other end of a NameCon wire."""
    for wire in wire_by_uid.get(namecon_uid, []):
        # This wire connects namecon_uid.pin_name to something
        # Find NameCon with matching uid and pin
        namecon_found = False
        for con in wire:
            ltag = local(con.tag)
            if ltag == "NameCon" and con.get("UId") == namecon_uid and con.get("Name") == pin_name:
                namecon_found = True
                break
        if not namecon_found:
            continue
        # Find the Access (IdentCon or other end)
        for con in wire:
            ltag = local(con.tag)
            uid = con.get("UId", "")
            if ltag == "IdentCon" and uid in access_by_uid:
                return access_by_uid[uid]
            # Also check NameCon on the other side (e.g. output of Part to Access)
            if ltag == "NameCon" and con.get("UId") != namecon_uid:
                other_uid = con.get("UId", "")
                if other_uid in access_by_uid:
                    return access_by_uid[other_uid]
    return ""


def access_for_contact_operand(contact_uid: str, access_by_uid: dict, wire_by_uid: dict) -> str:
    """Find the operand Access for a Contact's 'operand' pin."""
    return access_connected_to_namecon(contact_uid, "operand", access_by_uid, wire_by_uid)


def access_for_coil_operand(coil_uid: str, access_by_uid: dict, wire_by_uid: dict) -> str:
    """Find the operand Access for a Coil/SCoil/RCoil 'operand' pin."""
    return access_connected_to_namecon(coil_uid, "operand", access_by_uid, wire_by_uid)


# ---------------------------------------------------------------------------
# Contact chain tracing (best-effort)
# ---------------------------------------------------------------------------

def contacts_driving_uid(target_uid: str, pin: str,
                          part_by_uid: dict, access_by_uid: dict,
                          wire_by_uid: dict,
                          _visited=None) -> list[str]:
    """
    Trace backwards through the wire graph from target_uid.pin to find all
    Contact operand names that feed this input (shallow, not deep).
    Returns list of operand strings.
    """
    if _visited is None:
        _visited = set()
    if target_uid in _visited:
        return []
    _visited.add(target_uid)

    operands: list[str] = []
    # Find wires that have a NameCon UId=target_uid Name=pin
    for wire in wire_by_uid.get(target_uid, []):
        namecon_matches = False
        for con in wire:
            if local(con.tag) == "NameCon" and con.get("UId") == target_uid and con.get("Name") == pin:
                namecon_matches = True
                break
        if not namecon_matches:
            continue
        # Walk the other pins on this wire
        for con in wire:
            ltag = local(con.tag)
            uid = con.get("UId", "")
            if ltag == "Powerrail":
                continue
            if ltag == "IdentCon" and uid in access_by_uid:
                # Direct access connected → not a Contact; just note it
                operands.append(access_by_uid[uid])
            elif ltag == "NameCon" and uid != target_uid:
                # Output of another part
                src_uid = uid
                src_name = con.get("Name", "")
                if src_uid in part_by_uid:
                    part = part_by_uid[src_uid]
                    pname = part.get("Name", "")
                    if pname == "Contact":
                        op = access_for_contact_operand(src_uid, access_by_uid, wire_by_uid)
                        if op:
                            # Check for negated contact
                            neg_attr = part_is_negated(part)
                            operands.append(f"NOT({op})" if neg_attr else op)
                    elif pname in ("Coil", "SCoil", "RCoil", "PCoil", "NCoil"):
                        pass  # coil output feeding another coil — unusual, skip
                    else:
                        # Another function block output → recurse 1 level
                        ops = contacts_driving_uid(src_uid, src_name,
                                                   part_by_uid, access_by_uid,
                                                   wire_by_uid, _visited)
                        operands.extend(ops)
    return operands


# ---------------------------------------------------------------------------
# Network rendering
# ---------------------------------------------------------------------------

COIL_TYPES = {
    "Coil": "COIL",
    "SCoil": "COIL_S",
    "RCoil": "COIL_R",
    "PCoil": "COIL_P",
    "NCoil": "COIL_N",
}

# These are "instruction" Part Names that behave like FB calls (named pins)
INSTRUCTION_PARTS = {
    "MC_POWER", "MC_RESET", "MC_MOVEVELOCITY", "MC_MOVEJOG", "MC_GEARIN",
    "MC_HALT", "MC_STOP", "MC_WRITEPARAMETER", "MC_MOVERELATIVE",
    "MC_MOVEABSOLUTE", "MC_MOVEADDITIVE", "MC_MOVESUPERIMPOSED",
    "MC_CAMOUT", "MC_SYNCACTION", "MC_PHASING", "MC_GEAROUT",
    "MC_TORQUECONTROL", "MC_CHANGEDYNAMIC", "ESTOP1", "FDBACK", "FESTO",
    "IACK", "ACK_GL",
    "TON", "TOF", "TP",
    "LIMIT", "MIN", "MAX", "ABS",
    "Eq", "Ne", "Gt", "Lt", "Ge", "Le",
    "Add", "Sub", "Mul", "Div", "Mod",
    "Move", "Calc",
}

# These generate per-pin binding output
PARAM_PART_NAMES = {
    "MC_POWER", "MC_RESET", "MC_MOVEVELOCITY", "MC_MOVEJOG", "MC_GEARIN",
    "MC_HALT", "MC_STOP", "MC_WRITEPARAMETER", "MC_MOVERELATIVE",
    "MC_MOVEABSOLUTE", "MC_MOVEADDITIVE", "MC_MOVESUPERIMPOSED",
    "MC_CAMOUT", "MC_SYNCACTION", "MC_PHASING", "MC_GEAROUT",
    "MC_TORQUECONTROL", "MC_CHANGEDYNAMIC", "ESTOP1", "FDBACK",
    "TON", "TOF", "TP",
}


def get_instance_name(part_elem: ET.Element) -> str:
    """Extract Instance/Component Name from a Part element."""
    for child in part_elem.iter():
        if local(child.tag) == "Instance":
            for comp in child.iter():
                if local(comp.tag) == "Component":
                    return comp.get("Name", "")
    return ""


def get_all_pins_for_part(part_uid: str, wire_by_uid: dict) -> list[tuple[str, str, str]]:
    """
    Return list of (pin_name, direction, connected_uid) for all wires
    touching this part_uid.
    direction: 'in' if NameCon is a sink (connected IdentCon feeds it),
               'out' if NameCon is a source.
    We just return (pin_name, con_uid) pairs from matching wires.
    """
    pins: list[tuple[str, str]] = []
    seen = set()
    for wire in wire_by_uid.get(part_uid, []):
        for con in wire:
            if local(con.tag) == "NameCon" and con.get("UId") == part_uid:
                pin = con.get("Name", "")
                key = pin
                if key not in seen:
                    seen.add(key)
                    pins.append((pin, wire))
    return pins


def render_part_bindings(part_uid: str, part_name: str, instance: str,
                         access_by_uid: dict, wire_by_uid: dict) -> list[str]:
    """
    For an instruction Part, emit:
      CALL <part_name> [instance: <instance>]
        <pin> := <operand>
        ...
    Returns list of lines.
    """
    lines: list[str] = []
    inst_str = f" [instance: {instance}]" if instance else ""
    lines.append(f"  CALL {part_name}{inst_str}")

    # Walk all wires that mention this part_uid
    pin_bindings: dict[str, str] = {}  # pin_name → operand string

    # Collect all wires that have a NameCon for this uid
    processed_wires: set[int] = set()
    for wire in wire_by_uid.get(part_uid, []):
        wid = id(wire)
        if wid in processed_wires:
            continue
        processed_wires.add(wid)

        # Find NameCon for our part
        our_pins_in_wire: list[str] = []
        other_uids: list[tuple[str, str]] = []  # (uid, ltag)

        for con in wire:
            ltag = local(con.tag)
            con_uid = con.get("UId", "")
            if ltag == "NameCon" and con_uid == part_uid:
                pin = con.get("Name", "")
                if pin and pin != "en" and pin != "eno":
                    our_pins_in_wire.append(pin)
            elif ltag == "IdentCon":
                other_uids.append((con_uid, "IdentCon"))
            elif ltag == "NameCon" and con_uid != part_uid:
                other_uids.append((con_uid, "NameCon_other"))
            elif ltag == "Powerrail":
                other_uids.append(("__POWERRAIL__", "Powerrail"))
            elif ltag == "OpenCon":
                other_uids.append(("__OPEN__", "OpenCon"))

        for pin in our_pins_in_wire:
            # Find the access on the other end
            operand = ""
            for uid, kind in other_uids:
                if kind == "IdentCon" and uid in access_by_uid:
                    operand = access_by_uid[uid]
                    break
                elif kind == "OpenCon":
                    operand = "<not connected>"
                    break
                elif kind == "Powerrail":
                    operand = "<powerrail>"
                    break
            if pin and operand:
                pin_bindings[pin] = operand
            elif pin and not operand:
                # Try reverse: pin is output, access is on the right
                for uid, kind in other_uids:
                    if kind == "IdentCon" and uid in access_by_uid:
                        pin_bindings[pin] = access_by_uid[uid]
                        break

    for pin, operand in sorted(pin_bindings.items()):
        lines.append(f"    {pin} := {operand}")

    return lines


def get_multilingual_text(obj_list: ET.Element, composition_name: str) -> str:
    """Extract en-US text from a MultilingualText by CompositionName."""
    for ml in obj_list.iter():
        if local(ml.tag) == "MultilingualText" and ml.get("CompositionName") == composition_name:
            for item in ml.iter():
                if local(item.tag) == "MultilingualTextItem":
                    # Check for en-US culture
                    culture = ""
                    text = ""
                    for attr_child in item.iter():
                        if local(attr_child.tag) == "Culture":
                            culture = (attr_child.text or "").strip()
                        if local(attr_child.tag) == "Text":
                            text = (attr_child.text or "").strip()
                    if culture == "en-US" and text:
                        return text
                    elif text:
                        return text
    return ""


def render_flgnet(flgnet: ET.Element, net_num: int, title: str, comment: str) -> list[str]:
    """
    Render one FlgNet to lines of text.
    """
    lines: list[str] = []

    # Network header
    title_str = f": {title}" if title else ""
    lines.append(f"--- Network {net_num}{title_str} ---")
    if comment:
        lines.append(f"  // {comment}")
    lines.append("")

    access_by_uid, part_by_uid, call_by_uid, wire_by_uid = build_wire_index(flgnet)

    rendered_part_uids: set[str] = set()

    # ------------------------------------------------------------------
    # 1. Render <Call> elements (FC/FB calls with CallInfo/Parameter)
    # ------------------------------------------------------------------
    parts_elem = None
    for child in flgnet:
        if local(child.tag) == "Parts":
            parts_elem = child
            break

    if parts_elem is not None:
        for child in parts_elem:
            uid = child.get("UId", "")
            ltag = local(child.tag)

            if ltag == "Call":
                call_info = None
                for ci in child.iter():
                    if local(ci.tag) == "CallInfo":
                        call_info = ci
                        break
                if call_info is None:
                    continue

                block_name = call_info.get("Name", "<unknown>")
                block_type = call_info.get("BlockType", "")
                # Instance DB
                instance_db = ""
                for param_child in call_info.iter():
                    if local(param_child.tag) == "Instance":
                        for comp in param_child.iter():
                            if local(comp.tag) == "Component":
                                instance_db = comp.get("Name", "")
                                break
                        break

                inst_str = f" [instance: {instance_db}]" if instance_db else f" [{block_type}]" if block_type else ""
                lines.append(f"  CALL {block_name}{inst_str}")
                rendered_part_uids.add(uid)

                # Parameters from CallInfo
                for param in call_info:
                    if local(param.tag) != "Parameter":
                        continue
                    param_name = param.get("Name", "")
                    # Find wire connecting this Call's param pin
                    operand = access_connected_to_namecon(uid, param_name, access_by_uid, wire_by_uid)
                    if operand:
                        lines.append(f"    {param_name} := {operand}")

                lines.append("")

    # ------------------------------------------------------------------
    # 2. Render named-instruction Parts (MC_, TON, etc.) and Coils
    # ------------------------------------------------------------------
    if parts_elem is not None:
        for child in parts_elem:
            uid = child.get("UId", "")
            ltag = local(child.tag)

            if ltag != "Part":
                continue

            part_name = child.get("Name", "")
            if not part_name:
                continue

            rendered_part_uids.add(uid)

            # Coil / output coil types
            if part_name in COIL_TYPES:
                coil_label = COIL_TYPES[part_name]
                operand = access_for_coil_operand(uid, access_by_uid, wire_by_uid)
                # Try to find driving contacts
                drivers = contacts_driving_uid(uid, "in", part_by_uid, access_by_uid, wire_by_uid)
                if operand:
                    if drivers:
                        lines.append(f"  {coil_label} {operand}  [conditions: {', '.join(drivers)}]")
                    else:
                        lines.append(f"  {coil_label} {operand}")
                else:
                    lines.append(f"  {coil_label} <unresolved>")
                continue

            # Named instruction parts that we render with bindings
            if part_name in PARAM_PART_NAMES:
                instance = get_instance_name(child)
                part_lines = render_part_bindings(uid, part_name, instance,
                                                  access_by_uid, wire_by_uid)
                lines.extend(part_lines)
                lines.append("")
                continue

            # Contact — note but don't emit separately unless nothing else
            # (contacts are captured as drivers of coils/instructions above)
            if part_name == "Contact":
                # Only emit standalone if not already captured
                operand = access_for_contact_operand(uid, access_by_uid, wire_by_uid)
                neg = part_is_negated(child)
                if operand:
                    label = f"NOT({operand})" if neg else operand
                    lines.append(f"  CONTACT {label}")
                continue

            # Other instruction parts (Move, Calc, Eq, etc.) — brief inline
            # Collect input/output pin bindings
            inst_bindings: list[str] = []
            for wire in wire_by_uid.get(uid, []):
                for con in wire:
                    ltag2 = local(con.tag)
                    cuid = con.get("UId", "")
                    if ltag2 == "NameCon" and cuid == uid:
                        pin = con.get("Name", "")
                        if pin in ("en", "eno", "pre", "out"):
                            continue
                        # Find the other side
                        for con2 in wire:
                            ltag3 = local(con2.tag)
                            cuid2 = con2.get("UId", "")
                            if ltag3 == "IdentCon" and cuid2 in access_by_uid:
                                inst_bindings.append(f"{pin}={access_by_uid[cuid2]}")
                                break
            if inst_bindings:
                lines.append(f"  {part_name}({', '.join(inst_bindings)})")

    # Blank line if anything was rendered
    if len(lines) > 3:
        lines.append("")

    return lines


# ---------------------------------------------------------------------------
# Block processing
# ---------------------------------------------------------------------------

def render_block(xml_path: pathlib.Path) -> Optional[str]:
    """
    Parse one XML block file.  Return rendered text if it has any FlgNet
    networks, else None (pure-SCL or DB blocks are skipped).
    """
    try:
        tree = ET.parse(str(xml_path))
    except ET.ParseError as exc:
        print(f"  WARN: XML parse error in {xml_path.name}: {exc}", file=sys.stderr)
        return None

    root = tree.getroot()

    output_lines: list[str] = []

    # Find block name
    block_name = xml_path.stem

    output_lines.append(f"Block: {block_name}")
    output_lines.append("=" * 60)
    output_lines.append("")

    has_flgnet = False
    net_num = 0

    # Iterate over all CompileUnit elements in document order
    for cu in root.iter():
        if local(cu.tag) != "SW.Blocks.CompileUnit":
            continue

        # Find NetworkSource
        ns_elem = None
        attr_list = None
        for child in cu:
            if local(child.tag) == "AttributeList":
                attr_list = child
                break
        if attr_list is None:
            continue

        for child in attr_list:
            if local(child.tag) == "NetworkSource":
                ns_elem = child
                break
        if ns_elem is None:
            continue

        # Check language tag
        prog_lang = ""
        for child in attr_list:
            if local(child.tag) == "ProgrammingLanguage":
                prog_lang = (child.text or "").strip()
                break

        # Find FlgNet or StructuredText child in NetworkSource
        flgnet_elem = None
        is_scl = False
        for ns_child in ns_elem:
            lname = local(ns_child.tag)
            if lname == "FlgNet":
                flgnet_elem = ns_child
                break
            elif lname == "StructuredText":
                # SCL — skip
                is_scl = len(ns_child) > 0   # empty <StructuredText/> = empty network
                break

        if flgnet_elem is None:
            net_num += 1
            label = "SCL — see .scl" if is_scl else "empty network"
            output_lines.append(f"--- Network {net_num}: [{label}] ---")
            output_lines.append("")
            continue

        has_flgnet = True
        net_num += 1

        # Get title + comment from ObjectList
        title = ""
        comment = ""
        obj_list = None
        for child in cu:
            if local(child.tag) == "ObjectList":
                obj_list = child
                break
        if obj_list is not None:
            title = get_multilingual_text(obj_list, "Title")
            comment = get_multilingual_text(obj_list, "Comment")

        # Render
        net_lines = render_flgnet(flgnet_elem, net_num, title, comment)
        output_lines.extend(net_lines)

    if not has_flgnet:
        return None

    return "\n".join(output_lines) + "\n"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(blocks_dir: pathlib.Path) -> int:
    xml_files = sorted(blocks_dir.glob("*.xml"))
    rendered = 0
    skipped = 0

    for xml_path in xml_files:
        text = render_block(xml_path)
        if text is None:
            skipped += 1
            continue
        out_path = xml_path.with_suffix(".lad.txt")
        out_path.write_text(text, encoding="utf-8")
        rendered += 1
        print(f"  rendered: {out_path.name}")

    print(f"\nDone: {rendered} LAD/FBD blocks rendered, {skipped} pure-SCL/DB blocks skipped.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <blocks_dir>", file=sys.stderr)
        sys.exit(1)
    blocks = pathlib.Path(sys.argv[1])
    if not blocks.is_dir():
        print(f"Error: {blocks} is not a directory", file=sys.stderr)
        sys.exit(1)
    sys.exit(main(blocks))
