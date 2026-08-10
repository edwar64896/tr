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

### Images & attached media (served from S3)
The XML references files by their original OneDrive paths; the build **strips the
folder** from every scanned image (`Reproduction`) and attached file such as a
PDF (`References` multimedia), leaving a bare filename (e.g. `Z-DDJ-1-51a.jpeg`)
that maps directly to a flat key in the S3 bucket. The files themselves are not
in the export — they live in the bucket:

```
s3://trarchive-766743414531-eu-north-1-an
```

The app builds each URL as `IMAGE_BASE + <url-encoded filename>` (filenames with
spaces/parentheses are handled). `IMAGE_BASE` is set at the top of
`web/index.html` and currently points at that bucket's HTTPS endpoint. For the
images to load in the browser the objects must be **publicly readable**, or the
bucket fronted by **CloudFront** (then set `IMAGE_BASE` to the CloudFront domain).
Set `IMAGE_BASE = ""` to fall back to labelled placeholders.

### Updating the catalogue (for Mark) — `admin.html`
When new artifacts are added, re-export from MODES and use the **Update the
catalogue** page (linked in the site header, or open `/admin.html`). It runs
entirely in the browser: choose the `.xml`, it converts it to `catalogue.json`
(identical logic to `tools/build_catalogue.py` — verified byte-for-byte), shows a
summary, and downloads the file. Then publish it:

```bash
aws s3 cp catalogue.json s3://trarchive-766743414531-eu-north-1-an/catalogue.json
```

`CATALOGUE_URL` (top of `web/index.html`) is already set to that object's URL, so
the site loads the data straight from the bucket — Mark's uploads go live on the
next refresh, no rebuild. (The inline demo build ignores it; the offline bundle
still works.) To turn that off, set `CATALOGUE_URL = ""` and the copy served
beside `index.html` is used instead.

### One-time bucket setup

Run once (with the AWS CLI configured). It applies CORS (so the fetch works),
uploads the current `catalogue.json`, and — with `ALLOW_PUBLIC=yes` — makes the
objects publicly readable so images/PDFs load:

```bash
ALLOW_PUBLIC=yes AWS_REGION=eu-north-1 ./deploy/s3-setup.sh
```

It uses `deploy/s3-cors.json` and `deploy/s3-bucket-policy.json`. Public-read is
the simplest option for a POC; the private alternative is CloudFront + Origin
Access Control, then point `IMAGE_BASE`/`CATALOGUE_URL` at the CloudFront domain.
Leave off `ALLOW_PUBLIC` to apply only CORS + upload (e.g. if you'll use
CloudFront).

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

After that, each push builds and pushes `:latest` and `:<git-sha>` tags.

### Auto-deploy to EC2 (optional)

The workflow's second job (`deploy`) pulls the new image onto the EC2 box and
restarts the container — driven remotely via **SSM**, so no inbound SSH is
needed. It stays **skipped until you set the repo variable `EC2_INSTANCE_ID`**.

One-time setup:

1. Give the instance an IAM role for SSM + ECR-read, and attach it:
   ```bash
   EC2_INSTANCE_ID=i-0123... AWS_REGION=eu-west-2 ./deploy/ec2-instance-role.sh
   ```
   (If the SSM agent isn't running on Ubuntu:
   `sudo snap install amazon-ssm-agent --classic && sudo snap start amazon-ssm-agent`.)
2. Grant the CI role permission to call SSM — re-run the OIDC setup, which now
   adds an `ssm-deploy` policy (optionally scoped to just this instance):
   ```bash
   EC2_INSTANCE_ID=i-0123... AWS_REGION=eu-west-2 ./deploy/aws-oidc-setup.sh
   ```
3. Turn the job on by setting the repo variable:
   ```bash
   gh variable set EC2_INSTANCE_ID --body i-0123...
   ```

Now every green build also runs, on the box:
`docker login` → `docker pull …:latest` → `docker rm -f tr-archive` →
`docker run … -p 80:80 …:latest`. The job polls the SSM command and fails if the
on-box deploy fails, surfacing its output in the run log.

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
