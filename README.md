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
- **Private by invitation** — time-limited access passes issued by the
  archivist, enforced at the CDN edge (see [Access control](#access-control--passes)).

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

### Locking the bucket to CloudFront (OAC)

With CloudFront in front, keep the bucket **private** and let only the
distribution read it via Origin Access Control:

1. In the CloudFront console, set the S3 origin's **Origin access** to *Origin
   access control settings*, create/select a control, and save.
2. Apply the matching bucket policy and turn Block Public Access back on:
   ```bash
   ./deploy/cloudfront-oac.sh
   ```
3. Set the distribution's **Default Root Object** to `index.html` (else a bare
   `/` request returns AccessDenied).

`AccessDenied` on the root usually means one of: no Default Root Object, the
site files aren't uploaded yet (`deploy/publish-site.sh`), or the OAC policy /
origin isn't set. Test a specific path (`/index.html`, `/catalogue.json`) to tell
which.

### CORS / public-read (only if not fronting the site with CloudFront)

If instead you serve the site from somewhere else and only pull assets from S3
directly, run `./deploy/s3-setup.sh` (optionally `ALLOW_PUBLIC=yes`) to apply
`deploy/s3-cors.json` and `deploy/s3-bucket-policy.json`. Not needed for the
all-CloudFront setup above.

---

## Access control — passes

The archive is private. A visitor needs a **pass**: a signed, self-expiring
token that the archivist issues and emails as a link. Opening the link drops a
cookie and lets them in; when the pass runs out they're shown the gate page
again. There's nothing for them to remember and no account to create.

| Type | Who | Lasts | Can reach `/admin.html` |
|---|---|---|---|
| 1 | administrator | 1 year | yes |
| 2 | reader | 14 days | no |
| 3 | reader | 24 hours | no |

### Why it can't live in the page

The site is static — S3 behind CloudFront, no backend — so a gate written into
`index.html` would be decoration. `catalogue.json` and every scan are plain
URLs, and anyone could skip the page entirely:

```bash
curl https://dmfmj7c4s21wr.cloudfront.net/catalogue.json
```

So the check runs in **`deploy/edge-auth.js`, a CloudFront Function on
viewer-request**, attached to the default cache behaviour. It sees every
request — including cache hits — before CloudFront reaches S3. No server, no
database, and at this traffic it stays inside the free tier.

### The token

```
<who>~<role>~<expiry>~<key-version>.<hmac-sha256-hex>
```

Signed with a key held in **SSM Parameter Store** (`/trarchive/auth-secret`,
SecureString) and substituted into the function at deploy time — it is never
committed and never reaches a browser. The token carries its own expiry, so
nothing is stored anywhere: there is no session table, and expired passes need
no cleaning up.

### Setting it up

**From a browser** (no AWS CLI) — follow
**[`deploy/INSTALL-AUTH.md`](deploy/INSTALL-AUTH.md)**. It generates the key
locally with Node, then walks through the CloudFront console click by click.
This is the route to hand to whoever operates the site, since their other
routines (GoodSync, cache invalidations) are already console-based.

**From a terminal**, if you have the AWS CLI and credentials:

```bash
./deploy/publish-auth.sh                              # install + attach the gate
./deploy/mint-token.sh --type 1 --for you@example.org # your own admin pass
```

`publish-auth.sh` generates the signing key on first run, uploads the function,
**tests it in CloudFront's sandbox before publishing** (which is what proves the
runtime really offers `crypto.createHmac`), attaches it, and publishes
`gate.html`. Changes take about five minutes to reach every edge.

You need a minting tool exactly twice: now, to bootstrap — `/admin.html` is
behind the gate, so there's a chicken-and-egg to break — and after a key
rotation. `mint-token.sh` reads the key from SSM; `tools/mint.js` takes it
directly and needs nothing but Node, which is what the console route uses. Open
the link it prints; from then on issue passes from the **Access passes** panel
on `/admin.html`.

### It does not change how content is uploaded

Scans and `catalogue.json` still go up through GoodSync exactly as before, and
new uploads are covered by the gate automatically. GoodSync writes to S3
through the S3 API; the function only inspects requests arriving at the
CloudFront address visitors use. The two never meet.

The one thing to watch is that **`gate.html` must be in the bucket** — it's a
site file like `index.html` and `admin.html`, deployed by CI. If a GoodSync job
is configured to delete destination files that aren't in the local folder, it
will remove all three.

### Day to day

Open `/admin.html`, enter who the pass is for, pick a duration, press **Create
pass**. You get a link, a copy button, and a pre-written email. Minting happens
at the edge (`/mint`), authenticated by your own admin cookie — the page only
ever asks for a link.

### Revoking

Passes expire by themselves, which is the intended mechanism. To cut off
**every** outstanding pass at once — a key rotation:

```bash
./deploy/publish-auth.sh --rotate
```

That voids yours too, so mint a fresh admin pass straight afterwards. There is
deliberately no per-pass revocation: it would need stored state, and short
passes make it unnecessary. To open the archive to the public again,
`./deploy/publish-auth.sh --detach`.

### What this does and doesn't give you

- A link works for **whoever holds it**. If a reader forwards their email, it
  works for the recipient until it expires. That is what the one-day pass is
  for — prefer it for a one-off enquiry.
- It controls **delivery, not redistribution**. Anyone admitted can download
  what they can see. It's access control, not rights management — worth being
  explicit about with the Railway.
- Keep the cache policy's cookie behaviour set to **`none`** so the pass cookie
  stays out of the cache key; `publish-auth.sh` warns if it isn't.

### Testing

```bash
node tools/test_auth.js
```

50 assertions over the real `edge-auth.js`, loaded into a stub of the CloudFront
runtime: issuing, expiry, forgery and privilege-escalation attempts, routing for
each role, redeeming, and a check that `mint-token.sh` (openssl) and the edge
(`crypto`) agree on the signature — if those drifted apart, bootstrapping would
silently break.

To click through it rather than read assertions, see
[Try it locally](#try-it-locally--with-the-gate) — no AWS account needed.

---

## Try it locally — with the gate

You don't need AWS, the bucket, or any credentials to exercise the access
passes. You do need more than a static server, though: `vite`, `http-server`
and `python3 -m http.server` will serve `web/` happily but won't run
`edge-auth.js`, so you'd be looking at the old, ungated site.

```bash
node tools/serve-local.js          # then open the links it prints
```

That puts the **real edge function in front of the real files**: it loads
`deploy/edge-auth.js` into a stub of the CloudFront runtime, turns each request
into a CloudFront event, and either serves the file or returns whatever the
function decided. Passes, redeeming, expiry, roles and minting all behave as
they will in production.

It prints an administrator link and a reader link to start from. Sign in as the
reader and `/admin.html` turns you away; sign in as the administrator and you
can mint further passes from the **Access passes** panel — the links it
generates work immediately in a private window. The dev signing key is fixed,
so passes survive a restart, and `--port=9000` moves it off 8080. Scans aren't
in the repo, so images show as placeholders; everything else is the real
catalogue.

**What this can't tell you:** whether the *deployment* works — the 10 KB and
1 ms CloudFront limits, and whether the runtime really offers
`crypto.createHmac`. `deploy/publish-auth.sh` checks all of that against
CloudFront itself, in its sandbox, before publishing anything.

Note that `docker compose up` (below) serves `web/` through nginx with **no
gate** — useful for working on the catalogue UI, not for testing access.

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
web/gate.html                   # "you need a pass" landing / redeem page
web/catalogue.json              # generated data
deploy/publish-site.sh          # push index/admin/catalogue to S3 + invalidate CF
deploy/publish-catalogue.sh     # push just catalogue.json + invalidate CF (Mark)
deploy/edge-auth.js             # CloudFront Function: the access-pass gate
deploy/publish-auth.sh          # install/update/rotate/detach the gate
deploy/mint-token.sh            # mint a pass from the CLI (bootstrap + break-glass)
deploy/INSTALL-AUTH.md          # console walkthrough for turning the gate on
tools/test_auth.js              # tests for the gate (node tools/test_auth.js)
tools/serve-local.js            # run the site locally with the gate in front
tools/mint.js                   # generate the key / mint a pass, no AWS needed
deploy/aws-oidc-setup.sh        # one-time IAM: OIDC role for S3 + CloudFront deploy
deploy/s3-*.{sh,json}           # optional CORS/public-read (non-CloudFront setups)
.github/workflows/deploy-site.yml  # CI: deploy app shell to S3 + CloudFront (OIDC)
Dockerfile, docker-compose.yml  # local testing only (production is static)
deploy/nginx.conf, deploy/ec2-* # legacy container/EC2 helpers
```

---

*Proof of concept — not production. Catalogue data belongs to the Talyllyn
Railway Company.*
