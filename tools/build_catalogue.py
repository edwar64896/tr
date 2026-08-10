#!/usr/bin/env python3
"""
build_catalogue.py — Convert the Talyllyn Railway MODES XML export into a
compact JSON catalogue consumed by the static search/viewer web app.

Usage:
    python3 tools/build_catalogue.py <source.xml> [--out web/catalogue.json]

The MODES export contains one <Object> per catalogued archive item. We pull
out the fields useful for browsing/searching and normalise the scanned-image
references (which are absolute Windows OneDrive paths) down to bare filenames
so they can be served from an S3 bucket / CloudFront distribution.
"""
import argparse
import json
import os
import re
import xml.etree.ElementTree as ET


def t(el, path):
    """Return trimmed text at an ElementPath, or '' if missing/empty."""
    if el is None:
        return ""
    n = el.find(path)
    if n is not None and n.text:
        return n.text.strip()
    return ""


def image_basename(win_path):
    """C:\\...\\Archive Objects\\Z-DDJ-1-51a.jpeg  ->  Z-DDJ-1-51a.jpeg"""
    if not win_path:
        return ""
    return re.split(r"[\\/]", win_path.strip())[-1]


def year_of(raw):
    """Best-effort 4-digit year from a messy DateBegin field."""
    if not raw:
        return None
    m = re.search(r"(1[89]\d{2}|20\d{2})", raw)
    return int(m.group(1)) if m else None


def build(src):
    root = ET.parse(src).getroot()
    records = []
    for o in root.findall("Object"):
        number = t(o, "ObjectIdentity/Number")
        if not number:
            continue

        images = []
        for r in o.findall("Reproduction"):
            fn = image_basename((r.findtext("Filename") or "").strip())
            if fn:
                images.append(fn)

        date_begin = t(o, "Production/Date/DateBegin")
        rec = {
            "id": number,
            "title": t(o, "Identification/BriefDescription") or number,
            "objectName": t(o, "Identification/ObjectName[@elementtype='simple name']/Keyword"),
            "classification": t(o, "Identification/Classification/Keyword"),
            "location": t(o, "ObjectLocation[@elementtype='current location']/Location"),
            "dateBegin": date_begin,
            "dateEnd": t(o, "Production/Date/DateEnd"),
            "year": year_of(date_begin),
            "maker": t(o, "Production/Organisation/OrganisationName"),
            "content": t(o, "Content/SummaryText"),
            "description": t(o, "Description/SummaryText"),
            "notes": t(o, "Notes"),
            "recordType": t(o, "RecordType"),
            "images": images,
        }
        records.append(rec)

    # De-noise: normalise a couple of obvious location typos so facets group well.
    fixups = {
        "Dogellau Archive 2nd Deposit": "Dolgellau Archive 2nd Deposit",
    }
    for r in records:
        r["location"] = fixups.get(r["location"], r["location"])

    records.sort(key=lambda r: r["id"])
    return records


def summarise(records):
    from collections import Counter
    def top(field):
        c = Counter(r[field] for r in records if r[field])
        return c
    return {
        "count": len(records),
        "withImages": sum(1 for r in records if r["images"]),
        "totalImages": sum(len(r["images"]) for r in records),
        "classifications": top("classification").most_common(),
        "locations": top("location").most_common(),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--out", default="web/catalogue.json")
    args = ap.parse_args()

    records = build(args.src)
    summary = summarise(records)

    payload = {
        "fonds": "Z/DDJ — Talyllyn Railway Company Archive",
        "generated": "static export",
        "summary": {k: summary[k] for k in ("count", "withImages", "totalImages")},
        "records": records,
    }
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))

    print(f"Wrote {args.out}")
    print(f"  records:     {summary['count']}")
    print(f"  with images: {summary['withImages']}  ({summary['totalImages']} image files)")
    print(f"  classes:     {len(summary['classifications'])}")
    print(f"  locations:   {len(summary['locations'])}")


if __name__ == "__main__":
    main()
