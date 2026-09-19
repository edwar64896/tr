# Turning on the access gate — AWS console walkthrough

This makes the archive private. Visitors need a **pass**: a link the archivist
emails them, which opens the catalogue for a set period.

You only do this once. Afterwards, passes are issued from `/admin.html` in a
browser, and nothing here needs touching again.

**You need:** sign-in to the AWS console with permission to edit CloudFront, and
a computer with [Node.js](https://nodejs.org) installed (any recent version).
You do **not** need the AWS CLI, and you do **not** need to change anything
about how GoodSync uploads scans — the gate and GoodSync don't touch each
other. GoodSync talks to S3 directly; the gate only inspects requests arriving
at the CloudFront address people visit.

**Roughly 20 minutes.** Read step 6 before you start — it is the one step where
the order matters.

---

## 1. Generate the signing key

In a terminal, in this repo:

```bash
node tools/mint.js --new-key
```

It prints a long key and writes `deploy/edge-auth.ready.js`.

> **Save the key in a password manager now.** It is the single secret behind
> every pass. It is not stored anywhere else — not in this repo, not in AWS in
> a form you can read back. Lose it and you can still turn the gate off, but
> you can't issue passes without redoing this page.

`deploy/edge-auth.ready.js` contains the key, so it is deliberately excluded
from git. Don't commit it or email it. Delete it once step 4 is done.

## 2. Issue yourself an administrator pass — before the gate is live

```bash
node tools/mint.js --key PASTE_YOUR_KEY_HERE \
  --type 1 --for you@example.org
```

Keep the link it prints. Doing this **first** means the gate can never lock you
out: `/admin.html` will be behind it, so there'd otherwise be no way to issue
the first pass.

## 3. Create the function

AWS console → **CloudFront** → **Functions** in the left-hand menu →
**Create function**.

| Field | Value |
|---|---|
| Name | `tr-archive-auth` |
| Description | `Talyllyn archive access passes` |
| Runtime | **cloudfront-js-2.0** |

The runtime matters — `2.0` is what provides the cryptography the passes rely
on. If only `1.0` is offered, stop here and say so; the design needs a
different approach (Lambda@Edge).

Open `deploy/edge-auth.ready.js` in a text editor, copy **all** of it, and
paste it into the code box, replacing the sample code. **Save changes.**

## 4. Test it before it goes anywhere near the site

The **Test** tab runs the function in CloudFront's own sandbox. Nothing is live
yet, and you can run it as often as you like. It tests whatever is saved in the
*Development* stage, so make sure you saved in step 3.

Set **Function stage** to `Development` and **Event type** to `Viewer request`.

Then look for the option to edit the test event **as JSON** rather than filling
in the form fields — the form makes you hunt for the cookie inputs, and their
labels move between console versions. Paste each event below in turn and click
**Test function**.

**A stranger, with no pass:**

```json
{
  "version": "1.0",
  "context": { "eventType": "viewer-request" },
  "viewer": { "ip": "203.0.113.1" },
  "request": {
    "method": "GET",
    "uri": "/",
    "querystring": {},
    "headers": { "host": { "value": "YOUR-DOMAIN.cloudfront.net" } },
    "cookies": {}
  }
}
```

Expect a **`response`** with `statusCode` 302 and a `location` of
`/gate.html` — the visitor is being sent to the "you need a pass" page.

**You, with the pass from step 2.** Replace `PASTE_YOUR_TOKEN_HERE` with
everything in your link after `?t=`:

```json
{
  "version": "1.0",
  "context": { "eventType": "viewer-request" },
  "viewer": { "ip": "203.0.113.1" },
  "request": {
    "method": "GET",
    "uri": "/",
    "querystring": {},
    "headers": { "host": { "value": "YOUR-DOMAIN.cloudfront.net" } },
    "cookies": {
      "tr_pass": { "value": "PASTE_YOUR_TOKEN_HERE", "attributes": "" }
    }
  }
}
```

Expect the **`request`** handed straight back, unchanged.

> `attributes` is required by the console's event validator even though it only
> means anything on a *response* cookie. Leave it as an empty string. Omitting
> it makes the console reject the event before the function ever runs.

**That difference is the whole test.** A `response` means the function
intervened and turned the request away; a `request` handed back means it
approved it and CloudFront carries on to S3. The first must be a response, the
second a request.

Also note **Compute utilization** in the result — a number out of 100, how much
of the function's 1 ms budget was used. Under about 40 is comfortable.

If the first test **errors** rather than returning a 302, the runtime is almost
certainly wrong: on `cloudfront-js-1.0` the cryptography the passes rely on
doesn't exist and it fails immediately. That needs a new function, not an edit.
If the first test hands back a `request`, the paste was incomplete — re-copy
the whole file including the final `}`.

You can now delete `deploy/edge-auth.ready.js`.

## 5. Publish

**Publish** tab → **Publish function**. This copies it from Development to
Live. It still isn't attached to anything.

## 6. Put `gate.html` in the bucket — do this before step 7

When the gate turns someone away it sends them to `/gate.html`. If that file
isn't in the bucket, they get a raw S3 error page instead of "this archive is
private, ask the archivist".

Either:

- **Merge the pull request** and let the GitHub Action deploy it, alongside
  `index.html` and `admin.html`; or
- **Drop `web/gate.html` into the "Archive Objects" folder** and run GoodSync,
  the same way `catalogue.json` gets there.

Then check it: open `https://<your-cloudfront-domain>/gate.html`. You should
see the "This archive is private" page.

> If GoodSync is set up to *delete files at the destination that aren't in the
> local folder*, it will remove `index.html`, `admin.html` and `gate.html` on
> the next sync. That risk already exists today — but confirm it, because a
> missing `gate.html` makes the site look broken to every visitor who isn't
> signed in.

## 7. Attach it to the site

CloudFront → **Distributions** → your distribution → **Behaviors** → select the
`Default (*)` behaviour → **Edit**.

Scroll to **Function associations**:

| Field | Value |
|---|---|
| Viewer request — Function type | **CloudFront Functions** |
| Viewer request — Function ARN / Name | `tr-archive-auth` |

Leave viewer response, origin request and origin response alone. **Save
changes.**

While you're on this page, check the **Cache policy**: its *Cookies* setting
should be **None**. If CloudFront includes the pass cookie in the cache key it
will keep a separate copy of every page for every visitor, which is slow and
needlessly expensive. It does not affect whether the gate works.

The change takes about five minutes to reach every CloudFront location.

## 8. Check it

1. Open the site in a **private/incognito window**. You should get the "This
   archive is private" page.
2. Paste your link from step 2. You should land in the catalogue.
3. Go to `/admin.html`. You should reach the **Update the Catalogue** page,
   which now has an **Access passes** panel at the bottom.
4. Issue yourself a one-day pass from that panel and open it in another private
   window. It should let you into the catalogue but turn you away from
   `/admin.html`.

That's it. The archive is private.

---

## Day to day

Open `/admin.html` → **Access passes** → type who it's for, choose how long,
**Create pass**. You get a link, a copy button, and a pre-written email.

| Type | Lasts | Can reach `/admin.html` |
|---|---|---|
| Administrator | 1 year | yes |
| Two weeks | 14 days | no |
| One day | 24 hours | no |

Only give an administrator pass to someone who should be able to update the
catalogue *and* issue passes of their own.

Nothing else changes. Scans and `catalogue.json` still go up through GoodSync
exactly as before, and new uploads are covered by the gate automatically.

## If a pass needs cancelling

Passes expire on their own, which is the intended mechanism — a two-week pass
is gone in two weeks whatever happens.

There's no way to cancel *one* pass. To cancel **all** of them (say a link was
forwarded somewhere it shouldn't have been):

1. `node tools/mint.js --new-key` — a new key, and a new
   `deploy/edge-auth.ready.js`.
2. Mint yourself a fresh administrator pass with the new key (step 2).
3. CloudFront → Functions → `tr-archive-auth` → **Build** → paste the new code
   → **Save changes** → **Test** → **Publish**.

Every outstanding pass stops working, including your old one — which is why you
mint the new one first. The function stays attached; you don't redo step 7.

## Turning the gate off

CloudFront → Distributions → your distribution → Behaviors → `Default (*)` →
Edit → **Function associations** → set the viewer request function to **No
association** → Save. The site is public again within a few minutes.

## If something goes wrong

**Everyone including you sees the gate page, and your link doesn't work.**
The key in the published function doesn't match the key you minted with.
Re-mint with the key you pasted in step 3, or redo steps 1–5 together.

**"This archive is private" appears but the page looks broken.**
`gate.html` isn't in the bucket — see step 6.

**The catalogue page loads but no records appear.**
`catalogue.json` is being refused. Check that step 7 attached the function to
the `Default (*)` behaviour and not to a more specific one, so that the data
and the page are treated the same way.

**AccessDenied at the bare domain.**
Unrelated to the gate — it's the distribution's *Default Root Object*, which
should be `index.html`. See the main README.

---

*Prefer the command line? `deploy/publish-auth.sh` does all of steps 1, 3, 4, 5
and 7 in one go, keeping the key in SSM Parameter Store, and
`deploy/mint-token.sh` replaces `tools/mint.js`.*
