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

## Hosting: S3 + CloudFront (no server)

The site is a static bundle — `index.html`, `admin.html`, `catalogue.json` — plus
the scanned images/PDFs, all in one S3 bucket, served over HTTPS by CloudFront:

```
bucket:      s3://trarchive-766743414531-eu-north-1-an   (eu-north-1)
distribution: https://dmfmj7c4s21wr.cloudfront.net
```

`web/index.html` is wired to that distribution:

```js
var IMAGE_BASE    = "https://dmfmj7c4s21wr.cloudfront.net/";
var CATALOGUE_URL = "https://dmfmj7c4s21wr.cloudfront.net/catalogue.json";
```

Each image URL is `IMAGE_BASE + <url-encoded filename>` (filenames with
spaces/parentheses are handled). Because everything is served from the one
CloudFront origin it's effectively same-origin, so no CORS is needed. With
CloudFront in front you can keep the bucket **private** (Origin Access Control)
— no public-read required. Set `IMAGE_BASE = ""` to fall back to placeholders.

**Deploy the site** (once EC2 is retired — no server in production):

```bash
AWS_REGION=eu-north-1 ./deploy/publish-site.sh
```

This uploads the three site files and invalidates CloudFront. Set the
distribution's **Default Root Object** to `index.html` so the bare domain loads
the catalogue. Scanned images/PDFs are uploaded straight to the bucket with their
exact MODES filenames (new keys, so no invalidation needed).

### Updating the catalogue (for Mark) — `admin.html`
When new artifacts are added, re-export from MODES and open the **Update the
catalogue** page (linked in the site header, or `/admin.html`). It runs entirely
in the browser: choose the `.xml`, it converts to `catalogue.json` (identical
logic to `tools/build_catalogue.py` — verified byte-for-byte), shows a summary,
and downloads the file. Then publish it in one step:

```bash
./deploy/publish-catalogue.sh ~/Downloads/catalogue.json
```

That uploads it and invalidates `/catalogue.json`, so the change is live on the
next refresh — **no server, no rebuild**. (Both publish scripts look up the
CloudFront distribution ID from its domain automatically.)

### CORS / public-read (only if not fronting the site with CloudFront)

If instead you serve the site from somewhere else and only pull assets from S3
directly, run `./deploy/s3-setup.sh` (optionally `ALLOW_PUBLIC=yes`) to apply
`deploy/s3-cors.json` and `deploy/s3-bucket-policy.json`. Not needed for the
all-CloudFront setup above.

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

## Continuous deployment (GitHub Actions → S3 + CloudFront)

`.github/workflows/deploy-site.yml` deploys the site on every push that touches
`web/index.html`/`web/admin.html` (and via the *Run workflow* button). It
authenticates with **OIDC** — GitHub assumes an IAM role at runtime, so **no AWS
keys are stored in GitHub** — then uploads the app shell to the bucket and
invalidates CloudFront.

It deliberately deploys **only `index.html` + `admin.html`**. `catalogue.json` is
owned by the admin/publish flow (Mark's uploads), so a code deploy never clobbers
live data. Bootstrap the first `catalogue.json` with `deploy/publish-site.sh`.

**One-time setup:**

1. Run the IAM setup (AWS CLI as admin). It creates the GitHub OIDC provider, a
   repo-scoped role, and grants **S3 write + CloudFront invalidation** (removing
   the old ECR/SSM permissions if present):
   ```bash
   AWS_REGION=eu-north-1 ./deploy/aws-oidc-setup.sh
   ```
2. Set the role ARN it prints as the repo secret **`AWS_ROLE_ARN`** (unchanged if
   you had it before):
   ```bash
   gh secret set AWS_ROLE_ARN --body "$(aws iam get-role \
     --role-name github-actions-ecr-push --query Role.Arn --output text)"
   ```
3. Confirm `BUCKET` / `CF_DOMAIN` in the workflow's `env:` block are correct.

---

## Legacy: Docker / EC2

The project began as an nginx container run on EC2; that path is **retired** in
favour of static S3 + CloudFront hosting (above). The `Dockerfile` /
`docker-compose.yml` remain useful for **running the site locally** (see “Run it
locally with Docker”). The EC2 helper scripts (`deploy/ec2-*.sh`) and the
`deploy/s3-setup.sh` public-read/CORS helper are only needed if you *don't* front
the site with CloudFront.

To finish retiring EC2: terminate the instance, remove the `EC2_INSTANCE_ID` repo
variable (`gh variable delete EC2_INSTANCE_ID`), and optionally delete the ECR
repo (`aws ecr delete-repository --repository-name tr-archive --force`).

---

## Scaling & cost

Deployment is covered under **Hosting** and **Continuous deployment** above. If
search ever needs to scale to millions of records or server-side ranking, the
natural next step is **Amazon OpenSearch Serverless** with a small **Lambda**
API — deliberately out of scope for this POC.

### Cost estimate

Scenario: ~**50 GB** of scanned images, HTTPS but no custom DNS (domain hosted
elsewhere), **very limited / infrequent** traffic. Figures are us-east-1;
London (eu-west-2) is ~5% more. Treat as estimates — AWS pricing and free-tier
rules change.

**Recommended — S3 + CloudFront, no server (~$1–2/month):**

| Item | Basis | Monthly |
|---|---|---|
| S3 storage (50 GB, Standard-IA) | $0.0125/GB — fits "infrequent" | ~$0.63 |
| — or S3 Standard | $0.023/GB, simpler | ~$1.15 |
| S3 requests | pennies at low traffic | ~$0.00 |
| Data egress | first 100 GB/mo free AWS-wide; won't be hit | $0.00 |
| CloudFront (CDN + HTTPS) | perpetual free tier: 1 TB + 10M req/mo | $0.00 |
| **Total** | | **≈ $1–2** |

Plus a one-time ~$0.25 for the PUT requests to upload 50 GB (ingress is free).
No Route 53 (DNS is hosted elsewhere) = $0. The S3 website endpoint is
HTTP-only, so CloudFront is what gives you a free `https://….cloudfront.net`
URL — worth having and free at this volume.

**If you want a server instead (EC2 `t3.micro` running the container):** ~$7.50/mo
on-demand after the free/intro period, plus ~$4/mo EBS for the 50 GB ≈
**$11–12/month** — more cost and upkeep for no benefit on a static site. Note
AWS revised the free tier in mid-2025: older accounts get 12 months free,
newer accounts get intro credits (~$100–200) instead, so "free" depends on the
account's age.

**Bottom line:** at infrequent use, S3 + CloudFront is effectively free
(~$1–2/mo); keep the Docker image for local testing only.

---

## Project layout

```
data/tr.xml                     # source MODES XML export (2,136 objects)
tools/build_catalogue.py        # XML -> catalogue.json compiler
web/index.html                  # the single-page app (search, facets, viewer)
web/admin.html                  # in-browser tool to regenerate catalogue.json
web/catalogue.json              # generated data
deploy/publish-site.sh          # push index/admin/catalogue to S3 + invalidate CF
deploy/publish-catalogue.sh     # push just catalogue.json + invalidate CF (Mark)
deploy/aws-oidc-setup.sh        # one-time IAM: OIDC role for S3 + CloudFront deploy
deploy/s3-*.{sh,json}           # optional CORS/public-read (non-CloudFront setups)
.github/workflows/deploy-site.yml  # CI: deploy app shell to S3 + CloudFront (OIDC)
Dockerfile, docker-compose.yml  # local testing only (production is static)
deploy/nginx.conf, deploy/ec2-* # legacy container/EC2 helpers
```

---

*Proof of concept — not production. Catalogue data belongs to the Talyllyn
Railway Company.*
