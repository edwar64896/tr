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


# The export uses Windows-1252 code points as numeric character references
# (e.g. &#150; for an en-dash), which XML resolves to C1 control chars
# (U+0080-U+009F). Remap that range to the Windows-1252 characters the author
# meant, so dashes, smart quotes and ellipses come through cleanly.
_C1_MAP = {}
for _b in range(0x80, 0xA0):
    try:
        _C1_MAP[chr(_b)] = bytes([_b]).decode("cp1252")
    except UnicodeDecodeError:
        pass  # 0x81/0x8D/0x8F/0x90/0x9D are undefined in cp1252
_C1_TABLE = str.maketrans(_C1_MAP)


def clean(s):
    return s.translate(_C1_TABLE) if s else s


def t(el, path):
    """Return trimmed, C1-cleaned text at an ElementPath, or '' if empty."""
    if el is None:
        return ""
    n = el.find(path)
    if n is not None and n.text:
        return clean(n.text.strip())
    return ""


def image_basename(win_path):
    """C:\\...\\Archive Objects\\Z-DDJ-1-51a.jpeg  ->  Z-DDJ-1-51a.jpeg"""
    if not win_path:
        return ""
    return re.split(r"[\\/]", win_path.strip())[-1]


IMAGE_EXTS = {"jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "bmp"}


def file_ext(fn):
    return fn.rsplit(".", 1)[-1].lower() if "." in fn else ""


def is_image(fn):
    return file_ext(fn) in IMAGE_EXTS


def year_of(raw):
    """Best-effort 4-digit year from a messy DateBegin field."""
    if not raw:
        return None
    m = re.search(r"(1[89]\d{2}|20\d{2})", raw)
    return int(m.group(1)) if m else None


def load_root(src):
    """Parse the MODES export.

    The file declares iso-8859-1 but is really Windows-1252 (it comes from a
    Windows/OneDrive workflow, so it carries smart quotes, en/em dashes and
    ellipses in the 0x80-0x9F range that iso-8859-1 lacks). Browsers already
    treat iso-8859-1 as Windows-1252, so we decode the same way here to keep
    the Python build and the in-browser admin tool byte-for-byte consistent.
    """
    raw = open(src, "rb").read()
    text = raw.decode("cp1252", errors="replace")
    # ET refuses a unicode string that still declares a non-UTF encoding, so
    # normalise the declaration and hand it UTF-8 bytes.
    text = re.sub(r'(<\?xml[^>]*encoding=")[^"]*(")', r"\1utf-8\2", text, count=1)
    return ET.fromstring(text.encode("utf-8"))


def build(src):
    root = load_root(src)
    records = []
    for o in root.findall("Object"):
        number = t(o, "ObjectIdentity/Number")
        if not number:
            continue

        # Files attached to the record come from two places: scanned images in
        # <Reproduction>, and other files (PDFs, ZIPs) in <References> — the
        # latter with or without an elementtype attribute. Collect both, strip
        # the original Windows/OneDrive folder (so each is a flat S3 key), and
        # route by extension: images render as thumbnails, everything else
        # (PDFs, ZIPs, …) as downloadable/viewable files.
        images, media, seen = [], [], set()

        def add_file(raw):
            fn = image_basename((raw or "").strip())
            if not fn or fn in seen:
                return
            seen.add(fn)
            (images if is_image(fn) else media).append(fn)

        for r in o.findall("Reproduction"):
            add_file(r.findtext("Filename"))
        for r in o.findall("References"):
            add_file(r.findtext("Filename"))

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
            "media": media,
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
        "withMedia": sum(1 for r in records if r["media"]),
        "totalMedia": sum(len(r["media"]) for r in records),
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
        "summary": {k: summary[k] for k in
                    ("count", "withImages", "totalImages", "withMedia", "totalMedia")},
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
