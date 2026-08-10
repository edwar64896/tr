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

## Deploy to EC2 for a quick HTTP test

Run the exact container on an EC2 box and reach it at `http://<public-ip>` — no
domain, no certificate, no Caddy. (nginx inside the image already serves the
site; Caddy is only worth adding later, for automatic HTTPS, and only once a DNS
name points at the instance.)

**1. Launch an instance.** Amazon Linux 2023, `t3.small` is ample. In its
security group allow inbound **TCP 80** (from your own IP for a private test, or
`0.0.0.0/0` to share the link). Paste `deploy/ec2-user-data.sh` into
*Advanced details → User data* so Docker is installed at first boot.

**2. Get the image onto the box** — pick one:

*Option A — copy it directly, no registry:*
```bash
# on your machine
docker build -t tr-archive:poc .
docker save tr-archive:poc | gzip | \
  ssh -i key.pem ec2-user@<public-ip> 'gunzip | docker load'
```

*Option B — via ECR* (better if you'll iterate; the instance needs an IAM role
with ECR read access):
```bash
ACCT=<acct-id>; REGION=<region>
aws ecr create-repository --repository-name tr-archive --region $REGION
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCT.dkr.ecr.$REGION.amazonaws.com
docker build -t $ACCT.dkr.ecr.$REGION.amazonaws.com/tr-archive:poc .
docker push  $ACCT.dkr.ecr.$REGION.amazonaws.com/tr-archive:poc
# then on the EC2 box: docker pull <same-image-name>
```

**3. Run it on port 80** (on the EC2 box):
```bash
docker run -d --name tr-archive --restart unless-stopped -p 80:80 tr-archive:poc
```

**4. Open** `http://<public-ip>`. The catalogue loads; image references show as
placeholders until you add scans.

**Adding the 50 GB of scans later:** don't bake them into the image. Attach an
EBS volume (or mount an S3 path), then run with
`-v /data/scans:/usr/share/nginx/html/scans:ro` and set
`var IMAGE_BASE = "/scans/";` in `web/index.html`.

**Adding HTTPS later:** point a DNS name at the instance and drop **Caddy** in
front (one-line Caddyfile, automatic Let's Encrypt certs), or put **CloudFront**
in front for a free `https://….cloudfront.net` URL with no domain.

---

## CI: build & push to ECR with GitHub Actions

`.github/workflows/build-push-ecr.yml` builds the image and pushes it to ECR on
every push (and via the *Run workflow* button). It authenticates with **OIDC** —
GitHub assumes an IAM role at runtime, so **no AWS keys are stored in GitHub**.

**One-time setup:**

1. Run the IAM setup (AWS CLI configured as an admin). It creates the GitHub
   OIDC provider, a role scoped to this repo, ECR push permissions, and the ECR
   repo itself:
   ```bash
   AWS_REGION=eu-west-2 ./deploy/aws-oidc-setup.sh
   ```
2. Copy the role ARN it prints into the repo secret **`AWS_ROLE_ARN`**
   (*Settings → Secrets and variables → Actions*), or:
   ```bash
   gh secret set AWS_ROLE_ARN --body "$(aws iam get-role \
     --role-name github-actions-ecr-push --query Role.Arn --output text)"
   ```
3. Confirm `AWS_REGION` and `ECR_REPO` in the workflow's `env:` block match
   your account.

After that, each push builds and pushes `:latest` and `:<git-sha>` tags. The run
summary prints the exact `docker pull`/`docker run` commands to deploy on the
EC2 box. (Want it to deploy automatically too? That's a small follow-on step via
SSM or SSH — ask and I'll add it.)

---

## Deploy to AWS as a static site (lowest cost / no server)

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

If search ever needs to scale to millions of records or server-side ranking,
the natural next step is **Amazon OpenSearch Serverless** with a small
**Lambda** API, but that is deliberately out of scope for this POC.

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
