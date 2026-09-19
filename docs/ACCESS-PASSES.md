# Access passes — how the archive is kept private

The Talyllyn Railway archive is private. Visitors need a **pass**: a link the
archivist emails them, which opens the catalogue for a set period and then stops
working. There is no account to create and no password to remember.

This document is the reference for whoever runs the archive. To *install* the
system on a fresh distribution, see [`../deploy/INSTALL-AUTH.md`](../deploy/INSTALL-AUTH.md).

---

## The three passes

| Type | Lasts | Can reach `/admin.html` |
|---|---|---|
| Administrator | 1 year | yes — update the catalogue, issue passes |
| Two-week | 14 days | no |
| One day | 24 hours | no |

They differ only in how long they last and whether they carry administrator
rights. There is one mechanism, not three.

Only give an administrator pass to someone who should be able to update the
catalogue *and* hand out passes of their own.

## Issuing one

Open `/admin.html`, scroll to **Access passes**, type who it's for, choose a
duration, press **Create pass**. You get a link, a copy button, and a
pre-written email.

The name is recorded inside the pass so you can tell later who it was issued
to. It isn't checked against anything — a pass works for whoever holds the link.

## How it works

The site is static — files in S3, served by CloudFront, no server and no
database. That rules out checking passes in the page itself: `catalogue.json`
and all 474 scans are ordinary URLs, and anyone could fetch them without ever
loading the page.

So the check runs in a **CloudFront Function** (`deploy/edge-auth.js`) attached
to the distribution's default behaviour. It inspects every request before
CloudFront reaches S3 — including ones served from cache — and either lets it
through or turns it away.

A pass is a short signed string:

```
<who>~<role>~<expiry>~<key version>.<signature>
```

The signature is an HMAC over the rest, using a secret key held in the function.
Change any part — the name, the role, the expiry — and the signature no longer
matches, so it can't be forged or extended. Because the expiry travels inside
the pass, **nothing is stored anywhere**: no session table, no list of who has
access, nothing to tidy up when a pass runs out.

Three URLs do the work:

- `/access?t=…` — redeems an emailed link and sets the cookie
- `/mint?type=…&sub=…` — issues a pass; administrators only
- `/whoami` — tells `/admin.html` when your own pass expires

## The signing key

One secret sits behind every pass. It lives in the function's source:
**CloudFront → Functions → `tr-archive-auth` → Build**, on the line beginning
`var SECRET`.

It is readable there by anyone with CloudFront access to the AWS account — so
**anyone who can read that page can grant themselves access to the archive**.
That is worth knowing when deciding who gets AWS access.

Keep a copy in a password manager. You need it for the two situations below.

## When an administrator pass expires

An administrator pass lasts a year. When it lapses, that person loses access to
the archive *and* to `/admin.html`, and **cannot issue themselves a
replacement** — deliberately, or an administrator would never really expire.

Readers are unaffected. Their passes are independent and keep working.

`/admin.html` warns about this: **45 days before your pass expires, a banner
appears at the top of the page with a "Renew for another year" button.** One
click issues a fresh administrator pass and signs you back in. As long as you
open the admin page occasionally, you will never be caught out.

If it does lapse, two ways back:

- **Another administrator** with a current pass issues you one — ten seconds.
- **Open `tools/mint.html`** in a browser. Double-click the file; it needs no
  installation and no internet. Paste the signing key (from the console, as
  above), and mint yourself a new administrator pass.

## Cancelling passes

Passes expire on their own. That is the intended mechanism — a two-week pass is
gone in two weeks whatever happens.

There is **no way to cancel a single pass**. Doing so would mean keeping a list
of every pass ever issued, which is exactly the stored state this design avoids.

To cancel **all** of them at once — say a link reached somewhere it shouldn't —
change the signing key. Every outstanding pass stops working immediately,
including your own, so mint yourself a new one *before* publishing the change.
The steps are in [`../deploy/INSTALL-AUTH.md`](../deploy/INSTALL-AUTH.md) under
"If a pass needs cancelling".

Rotating the key every year or two is reasonable hygiene, and takes about five
minutes.

## What this does and doesn't protect

- **A link works for whoever holds it.** If a reader forwards their email, it
  works for the recipient until it expires. That is what the one-day pass is
  for — prefer it for a one-off enquiry.
- **It controls delivery, not redistribution.** Anyone let in can download what
  they can see. This is access control, not rights management, and it is worth
  being explicit about that with the Railway.
- **It does not identify anyone.** The name in a pass is a label you chose, not
  a verified identity.

## Uploading content

Nothing about passes changes how content gets to the bucket. Scans and
`catalogue.json` still go up through **GoodSync** exactly as before, and new
uploads are covered automatically — GoodSync talks to S3 directly, while the
gate only inspects requests arriving at the CloudFront address visitors use.
The two never meet.

One thing to keep in mind: `gate.html` is a site file like `index.html` and
`admin.html`, deployed from the repository. If a GoodSync job is ever set to
delete destination files that aren't in the local folder, it will remove all
three.

## If something looks wrong

**Everyone sees the gate page, including administrators.** The key in the
published function doesn't match the passes that were issued. Mint a fresh pass
against the key currently in the function using `tools/mint.html`.

**"This archive is private" appears but the page is unstyled or broken.**
`gate.html` is missing from the bucket.

**The catalogue page loads but no records appear.** `catalogue.json` is being
refused — usually a second cache behaviour that the function isn't attached to.
Check CloudFront → Behaviors.

**Someone was let in who shouldn't have been.** Their link was forwarded.
Change the signing key (above) to cut off everything outstanding.

**To make the archive public again:** CloudFront → Distributions → Behaviors →
`Default (*)` → Edit → Function associations → viewer request → **No
association** → Save.

## Trying it without touching the live site

```bash
node tools/serve-local.js
```

Runs the real gate in front of the real files on your own machine, with no AWS
account. It prints an administrator link and a reader link to start from. See
the main [README](../README.md).

```bash
node tools/test_auth.js
```

81 checks over the gate: issuing, expiry, forgery and privilege-escalation
attempts, routing for each role, redeeming, renewal, and that all three minting
tools agree with the edge on what a valid signature looks like.
