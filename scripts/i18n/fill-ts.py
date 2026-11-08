#!/usr/bin/env python3
"""Fills a Qt Linguist .ts file from a JSON dictionary {English source: translation}.

Usage: fill-ts.py ui/i18n/borne_fr.ts ui/i18n/fr.json
Disambiguated messages use the key "source|comment". Plural messages (%n) take a list of forms in the JSON. Untranslated sources are reported
and the script exits with status 1, so CI catches strings added without a translation.
"""
import json, sys
import xml.etree.ElementTree as ET

ts_path, dict_path = sys.argv[1], sys.argv[2]
tr = json.load(open(dict_path, encoding="utf-8"))
tree = ET.parse(ts_path)
missing = set()
for msg in tree.iter("message"):
    src = msg.find("source").text
    comment = msg.find("comment")
    key = f"{src}|{comment.text}" if comment is not None else src
    t = msg.find("translation")
    if key not in tr:
        missing.add(key)
        continue
    value = tr[key]
    t.attrib.pop("type", None)
    if msg.get("numerus") == "yes":
        for c in list(t):
            t.remove(c)
        for form in value:
            ET.SubElement(t, "numerusform").text = form
        t.text = None
    else:
        t.text = value
tree.write(ts_path, encoding="utf-8", xml_declaration=True)
for m in sorted(missing):
    print(f"untranslated: {m!r}")
sys.exit(1 if missing else 0)
