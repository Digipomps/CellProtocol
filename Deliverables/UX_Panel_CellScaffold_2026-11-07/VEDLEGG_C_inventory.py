#!/usr/bin/env python3
"""Inventory of all JSON-defined HAVEN surfaces (CellConfiguration / skeleton) in CellScaffold."""
import json, os, re, sys, collections
ROOT = sys.argv[1]
OUT = sys.argv[2]
ELEMENTS = {"Text","TextField","TextArea","Image","Spacer","HStack","VStack","ZStack","List","Object","Reference",
            "Button","Divider","ScrollView","Section","Grid","Toggle","Picker","Tabs","FileUpload","AttachmentField",
            "Link","Audio","Theme","Tab","Board","Markdown","Table","Map","Chart","Video","WebView","Menu","Presentation"}
SKIP = ("node_modules", ".build", "/.git/", "desktop-zips", "Package.resolved", "package-lock")
HEX = re.compile(r"^#[0-9A-Fa-f]{6,8}$")

def is_skeleton_root(d):
    return isinstance(d, dict) and len(d) == 1 and next(iter(d)) in ELEMENTS

def walk(node, st, depth=0, parent=None):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ELEMENTS and isinstance(v, dict):
                st["types"][k] += 1
                st["maxdepth"] = max(st["maxdepth"], depth)
                if k == "Button":
                    lbl = v.get("label") or v.get("title") or v.get("text") or v.get("keypath") or "?"
                    st["buttons"].append(str(lbl)[:60])
                if k == "Text" and "text" in v:
                    st["texts"].append(str(v["text"])[:80])
                if k in ("TextField","TextArea") and not (v.get("placeholder") or v.get("label") or v.get("title")):
                    st["unlabelled_inputs"] += 1
                if k == "Image" and not (v.get("alt") or v.get("accessibilityLabel") or v.get("name")):
                    st["images_no_alt"] += 1
                mods = v.get("modifiers") or {}
                for mk, mv in mods.items():
                    if isinstance(mv, str) and HEX.match(mv): st["hex"][mv] += 1
                    if mk == "fontSize": st["fontSizes"][str(mv)] += 1
                    if mk == "styleRole": st["styleRoles"][str(mv)] += 1
                    if mk in ("accessibilityLabel","ariaLabel"): st["a11y_labels"] += 1
                for kk in ("keypath","sourceKeypath","targetKeypath","actionKeypath","valueKeypath","selectionActionKeypath","activationActionKeypath"):
                    if kk in v: st["keypaths"] += 1
                walk(v, st, depth+1, k)
            else:
                walk(v, st, depth, parent)
    elif isinstance(node, list):
        for x in node: walk(x, st, depth, parent)

rows = []
for dp, dn, fn in os.walk(ROOT):
    if any(s in dp for s in SKIP): continue
    for f in fn:
        if not f.endswith(".json"): continue
        p = os.path.join(dp, f)
        if any(s in p for s in SKIP): continue
        try:
            d = json.load(open(p))
        except Exception:
            continue
        cfg = None; skel = None
        if isinstance(d, dict) and "skeleton" in d and isinstance(d["skeleton"], dict):
            cfg, skel = d, d["skeleton"]
        elif is_skeleton_root(d):
            skel = d
        elif isinstance(d, dict) and "configuration" in d and isinstance(d["configuration"], dict) and "skeleton" in d["configuration"]:
            cfg, skel = d["configuration"], d["configuration"]["skeleton"]
        if skel is None: continue
        st = {"types": collections.Counter(), "maxdepth": 0, "buttons": [], "texts": [], "hex": collections.Counter(),
              "fontSizes": collections.Counter(), "styleRoles": collections.Counter(), "keypaths": 0,
              "unlabelled_inputs": 0, "images_no_alt": 0, "a11y_labels": 0}
        walk(skel, st)
        disc = (cfg or {}).get("discovery") or {}
        rows.append({
            "path": os.path.relpath(p, ROOT),
            "name": (cfg or {}).get("name"),
            "description": (cfg or {}).get("description"),
            "purpose": disc.get("purpose"),
            "purposeDescription": disc.get("purposeDescription"),
            "purposeRefs": disc.get("purposeRefs"),
            "interests": disc.get("interests"),
            "menuSlots": disc.get("menuSlots"),
            "cellReferences": [c.get("endpoint") for c in (cfg or {}).get("cellReferences", [])],
            "elementCount": sum(st["types"].values()),
            "types": dict(st["types"]),
            "maxDepth": st["maxdepth"],
            "buttons": st["buttons"],
            "textSamples": st["texts"][:12],
            "hexColors": dict(st["hex"]),
            "fontSizes": dict(st["fontSizes"]),
            "styleRoles": dict(st["styleRoles"]),
            "keypathBindings": st["keypaths"],
            "unlabelledInputs": st["unlabelled_inputs"],
            "imagesWithoutAlt": st["images_no_alt"],
            "a11yLabels": st["a11y_labels"],
        })
rows.sort(key=lambda r: r["path"])
json.dump(rows, open(os.path.join(OUT, "inventory.json"), "w"), ensure_ascii=False, indent=1)
with open(os.path.join(OUT, "inventory.md"), "w") as md:
    md.write("| # | path | name | purpose | purposeDescription? | elements | buttons | hex colors | fontSizes | styleRoles | keypaths | unlabelled inputs |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n")
    for i, r in enumerate(rows, 1):
        md.write(f"| {i} | `{r['path']}` | {r['name'] or '—'} | {r['purpose'] or '—'} | {'ja' if r['purposeDescription'] else 'nei'} | {r['elementCount']} | {len(r['buttons'])} | {len(r['hexColors'])} | {len(r['fontSizes'])} | {len(r['styleRoles'])} | {r['keypathBindings']} | {r['unlabelledInputs']} |\n")
print(len(rows), "surfaces")
for r in rows: print(f"{r['elementCount']:4d} el  purpose={'Y' if r['purpose'] else '-'} pdesc={'Y' if r['purposeDescription'] else '-'}  {r['path']}  [{r['name']}]")
