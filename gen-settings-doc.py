#!/usr/bin/env python3
"""Generate a Markdown settings reference from resources/settings/*.xml + strings.xml.

Stdlib only (xml.etree.ElementTree) -- no external deps. Resolves the @Strings.* /
@Properties.* references and emits one section per setting (title, prompt description,
default, and the option list with the raw values used by the env-var overrides).

Usage: ./gen-settings-doc.py [out.md]   (default: agent_docs/settings.md)
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STRINGS = ROOT / "resources/strings/strings.xml"
PROPS = ROOT / "resources/settings/properties.xml"
SETTINGS = ROOT / "resources/settings/settings.xml"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "agent_docs/settings.md"

# id -> text
strings = {e.get("id"): (e.text or "") for e in ET.parse(STRINGS).getroot() if e.tag == "string"}
# id -> {type, default}
props = {p.get("id"): {"type": p.get("type"), "default": (p.text or "")}
         for p in ET.parse(PROPS).getroot() if p.tag == "property"}


def deref(ref):
    """Resolve an @Strings.x reference to its text; pass other strings through."""
    if ref and ref.startswith("@Strings."):
        return strings.get(ref[len("@Strings."):], ref)
    return ref or ""


lines = [
    "# Moonkey — settings reference",
    "",
    "_Generated from `resources/settings/` by `gen-settings-doc.py` (`make settings-doc`) — do not edit by hand._",
    "",
    "Values shown are what the property stores, i.e. what an env-var override (`make run` / "
    "`make shot` / `make install`) accepts, e.g. `metalHands=true`, `compE=103`, `accentColor=0xFF3030`.",
    "",
]

count = 0
for setting in ET.parse(SETTINGS).getroot().iter("setting"):
    count += 1
    pid = setting.get("propertyKey", "").replace("@Properties.", "")
    title = deref(setting.get("title"))
    prompt = deref(setting.get("prompt"))
    cfg = setting.find("settingConfig")
    ctype = cfg.get("type") if cfg is not None else "?"
    prop = props.get(pid, {"type": "?", "default": ""})
    default = prop["default"]
    entries = [(le.get("value"), deref(le.text)) for le in setting.iter("listEntry")]

    lines.append(f"## {title}")
    lines.append(f"`{pid}`" + (f" — {prompt}" if prompt else ""))
    lines.append("")

    if ctype == "boolean":
        lines.append(f"Toggle — default **{'On' if default == 'true' else 'Off'}**.")
    elif ctype == "alphaNumeric":
        lines.append(f"Free text — default `{default or '(empty)'}`.")
    elif entries:
        deflabel = next((lbl for v, lbl in entries if v == default), default)
        lines.append(f"Default: **{deflabel}**")
        lines.append("")
        lines.append("| Option | Value |")
        lines.append("|---|---|")
        for v, lbl in entries:
            lines.append(f"| {lbl} | `{v}` |")
    else:
        lines.append(f"Default: `{default}` (type {ctype}).")
    lines.append("")

OUT.write_text("\n".join(lines) + "\n")
print(f"wrote {OUT.relative_to(ROOT)} ({count} settings)")
