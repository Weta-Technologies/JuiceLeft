# make-dmg.sh: builds the UDIF software-licence-agreement resources (the Agree/Disagree dialog shown when the DMG opens)
# Usage: make-sla.py <licence.txt> <out.xml>. Builds the UDIF software-licence-agreement resources (LPic + STR# + TEXT) for `hdiutil udifrez -xml`.
import base64, plistlib, struct, sys
import re
def reflow(raw):
    """The licence file is hard-wrapped; the dialog wraps by itself. Join each paragraph's lines, keeping headings
    ("1. LICENCE TO USE") and list items ("  (a) ...") on their own lines."""
    out = []
    for para in raw.strip().split("\n\n"):
        lines, cur = [], ""
        for line in para.split("\n"):
            if re.match(r"^\s*\([a-z]\)\s", line) or re.match(r"^\d+\. [A-Z ]+$", line) or re.match(r"^[A-Z0-9 ]+$", line):
                if cur: lines.append(cur)
                cur = line.strip()
                if re.match(r"^\d+\. [A-Z ]+$", line) or re.match(r"^[A-Z0-9 ]+$", line): lines.append(cur); cur = ""
            else:
                cur = (cur + " " + line.strip()).strip()
        if cur: lines.append(cur)
        out.append("\n".join(lines))
    return "\n\n".join(out)
text = reflow(open(sys.argv[1], encoding="utf-8").read()).replace("\n", "\r").encode("mac_roman", errors="replace")
def pstr(s): b = s.encode("mac_roman"); return bytes([len(b)]) + b
buttons = ["English", "Agree", "Disagree", "Print", "Save...",
           'If you agree with the terms of this licence, click "Agree" to open the installer. If you do not agree, click "Disagree".']
strs = struct.pack(">H", len(buttons)) + b"".join(pstr(s) for s in buttons)
lpic = struct.pack(">HH", 0, 1) + struct.pack(">HHH", 0, 0, 0)   # default region 0 (English), 1 entry: region 0 → resource 5000, single-byte
res = lambda data, name: [{"Attributes": "0x0000", "Data": data, "ID": "5000", "Name": name}]
plistlib.dump({"LPic": res(lpic, ""), "STR#": res(strs, "English buttons"), "TEXT": res(text, "English SLA")}, open(sys.argv[2], "wb"))
