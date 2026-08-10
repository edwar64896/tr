#!/usr/bin/env python3
"""
build_demo.py — Produce a single self-contained HTML file with the catalogue
data inlined, for sharing without a web server (email, USB stick, artifact).

    python3 tools/build_demo.py            # -> dist/demo.html

The app in web/index.html checks for an inline <script id="catalogue-data">
first and only falls back to fetching catalogue.json, so the same code powers
both the served site and this standalone build.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
html = open(os.path.join(ROOT, "web", "index.html"), encoding="utf-8").read()
data = open(os.path.join(ROOT, "web", "catalogue.json"), encoding="utf-8").read()

tag = '<script id="catalogue-data" type="application/json">' + data + "</script>\n"
out = html.replace("<body>", "<body>\n" + tag, 1)

os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
dest = os.path.join(ROOT, "dist", "demo.html")
open(dest, "w", encoding="utf-8").write(out)
print(f"Wrote {dest}  ({len(out):,} bytes)")
