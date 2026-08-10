# Talyllyn Railway Archive — Catalogue Search (Proof of Concept)

A prototype **search engine and catalogue viewer** for the Talyllyn Railway
Company archive (fonds **Z/DDJ**, the Dolgellau deposit). It turns the MODES
XML export — **2,136 catalogued items**, 89 classifications, and **474 scanned
images across 144 items** — into a fast, browsable, searchable web catalogue.

The whole thing is a **static site**: the XML is compiled once into a single
`catalogue.json`, and all search/filtering happens in the browser. That means it
runs anywhere — a laptop via Docker, or AWS S3 + CloudFront — with **no backend,
no database, and no running costs to speak of.**

> **Live preview:** an inline-data build of this app is published as a Claude
> artifact so you can click around before building anything.

---

## What it does

- **Instant full-text search** across reference numbers, titles, classifications,
  makers, locations, and notes (`/` focuses the box).
- **Faceted filters** with live counts — classification, current location,
  decade, and "only items with scanned images".
- **Sortable results** — reference number, title, date, or illustrated-first —
  with infinite-scroll paging over all 2,136 records.
- **Detail panel** for every item showing the full catalogue record, curator's
  notes, and a gallery of its scanned images.
- **Light / dark themes**, responsive down to mobile.

### About the images
The XML references image files by their original OneDrive paths (e.g.
`Z-DDJ-1-51a.jpeg`); the JPEGs themselves are **not** in the export. The app
reduces each to a bare filename and builds image URLs from a single
`IMAGE_BASE` setting (top of `web/index.html`):

- left empty → the detail panel shows labelled **placeholders** naming each scan
  (what you see in the demo);
- set to `"/scans/"` → served from the container (drop JPEGs into `./scans`);
- set to a bucket URL → served from **S3 / CloudFront**.

---

## Run it locally with Docker  ← hand this to your mate

Requires only Docker Desktop. From the repo root:

```bash
docker compose up --build      # builds the image and starts it
```

Then open **http://localhost:8080**. That's it — the image is self-contained and
works offline. To stop: `Ctrl-C`, or `docker compose down`.

Prefer plain Docker?

```bash
docker build -t tr-archive .
docker run --rm -p 8080:80 tr-archive
```

### Showing real scans locally
1. Copy the JPEGs (named like `Z-DDJ-1-51a.jpeg`) into a `./scans` folder.
2. In `web/index.html` set `var IMAGE_BASE = "/scans/";`
3. In `docker-compose.yml` uncomment the `volumes:` block.
4. `docker compose up --build` again.

---

## Run it without Docker

```bash
python3 tools/build_catalogue.py data/tr.xml --out web/catalogue.json
cd web && python3 -m http.server 8080
# open http://localhost:8080
```

---

## Deploy to AWS (when you're ready)

Because it's a static site, hosting is a two-service story:

1. **S3** — one bucket for the site (`index.html`, `catalogue.json`) and,
   optionally, a `scans/` prefix for the JPEGs.
2. **CloudFront** — CDN + HTTPS in front of the bucket.

```bash
# regenerate the data, then sync the site
python3 tools/build_catalogue.py data/tr.xml --out web/catalogue.json
aws s3 sync web/ s3://YOUR-BUCKET/ --delete
aws s3 sync scans/ s3://YOUR-BUCKET/scans/          # if/when you have scans

# put a CDN in front (once), then set IMAGE_BASE to its domain, e.g.
#   var IMAGE_BASE = "https://dXXXX.cloudfront.net/scans/";
```

Rough cost: a catalogue this size sits comfortably in the S3/CloudFront free
tier — pennies a month once past it. If search ever needs to scale to millions
of records or server-side ranking, the natural next step is **Amazon OpenSearch
Serverless** with a small **Lambda** API, but that is deliberately out of scope
for this POC.

---

## Project layout

```
data/tr.xml               # source MODES XML export (2,136 objects)
tools/build_catalogue.py  # XML -> catalogue.json compiler
web/index.html            # the single-page app (search, facets, viewer)
web/catalogue.json        # generated data (rebuilt in the Docker image)
deploy/nginx.conf         # static-serving + gzip + caching config
Dockerfile                # 2-stage: python build -> nginx
docker-compose.yml        # `docker compose up` convenience
```

---

*Proof of concept — not production. Catalogue data belongs to the Talyllyn
Railway Company.*
