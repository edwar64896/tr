#!/usr/bin/env bash
#
# Install / update the access-control CloudFront Function.
#
#   ./deploy/publish-auth.sh            # install or update, then attach
#   ./deploy/publish-auth.sh --rotate   # new signing key: cuts off every pass
#   ./deploy/publish-auth.sh --detach   # remove the gate, site goes public again
#
# The signing key lives in SSM Parameter Store as a SecureString, never in the
# repo. It is generated on first run. Everything else — the pass rules, the
# redeem and mint endpoints — is deploy/edge-auth.js.
#
# After --rotate every outstanding pass stops working, including yours. Mint a
# fresh administrator pass with deploy/mint-token.sh before you close the tab.
#
set -euo pipefail

BUCKET="${BUCKET:-trarchive-766743414531-eu-north-1-an}"
CF_DOMAIN="${CF_DOMAIN:-dmfmj7c4s21wr.cloudfront.net}"
FN_NAME="${FN_NAME:-tr-archive-auth}"
PARAM="${PARAM:-/trarchive/auth-secret}"
# SSM and CloudFront function config are global-ish; the parameter lives in the
# bucket's region so there is one obvious place to look for it.
REGION="${AWS_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ROTATE=no; DETACH=no
for a in "$@"; do
  case "$a" in
    --rotate) ROTATE=yes ;;
    --detach) DETACH=yes ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Finding the distribution for $CF_DOMAIN"
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text)"
[ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ] || { echo "No distribution with that domain." >&2; exit 1; }
echo "  distribution: $DIST_ID"

# ---------------------------------------------------------------- detach
if [ "$DETACH" = yes ]; then
  say "Detaching the function — the archive will be PUBLIC again"
  read -r -p "  Type 'public' to confirm: " c; [ "$c" = public ] || { echo "  aborted"; exit 1; }
  aws cloudfront get-distribution-config --id "$DIST_ID" --output json > "$WORK/dist.json"
  ETAG="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ETag"])' "$WORK/dist.json")"
  python3 - "$WORK/dist.json" "$WORK/cfg.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["DistributionConfig"]
d["DefaultCacheBehavior"]["FunctionAssociations"] = {"Quantity": 0, "Items": []}
json.dump(d, open(sys.argv[2], "w"))
PY
  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
    --distribution-config "file://$WORK/cfg.json" >/dev/null
  echo "  detached. The site is open to anyone once the change deploys (~5 min)."
  exit 0
fi

# ---------------------------------------------------------- signing key
say "Signing key"
if [ "$ROTATE" = yes ]; then
  echo "  rotating — every outstanding pass will stop working"
  read -r -p "  Type 'rotate' to confirm: " c; [ "$c" = rotate ] || { echo "  aborted"; exit 1; }
fi
SECRET=""
if [ "$ROTATE" = no ]; then
  SECRET="$(aws ssm get-parameter --name "$PARAM" --with-decryption --region "$REGION" \
    --query Parameter.Value --output text 2>/dev/null || true)"
fi
if [ -z "$SECRET" ] || [ "$SECRET" = None ]; then
  SECRET="$(openssl rand -hex 32)"
  aws ssm put-parameter --name "$PARAM" --type SecureString --value "$SECRET" \
    --region "$REGION" --overwrite >/dev/null
  echo "  new key stored at $PARAM ($REGION)"
else
  echo "  reusing the key at $PARAM"
fi

# ------------------------------------------------------------- the code
say "Building the function"
# Substitute via python, not sed: the key is arbitrary text and must not be
# reinterpreted as a replacement pattern.
SECRET="$SECRET" python3 - "$DIR/edge-auth.js" "$WORK/fn.js" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
assert "REPLACE_AT_DEPLOY" in src, "placeholder already gone from edge-auth.js"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace("REPLACE_AT_DEPLOY", os.environ["SECRET"]))
PY
SIZE=$(wc -c < "$WORK/fn.js")
echo "  $SIZE bytes (CloudFront allows 10240)"
[ "$SIZE" -le 10240 ] || { echo "  too big for a CloudFront Function." >&2; exit 1; }

say "Uploading to CloudFront"
if FN_ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text 2>/dev/null)"; then
  aws cloudfront update-function --name "$FN_NAME" --if-match "$FN_ETAG" \
    --function-config "Comment=Talyllyn archive access passes,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://$WORK/fn.js" --query 'FunctionSummary.Name' --output text
else
  aws cloudfront create-function --name "$FN_NAME" \
    --function-config "Comment=Talyllyn archive access passes,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://$WORK/fn.js" --query 'FunctionSummary.Name' --output text
fi

# ---------------------------------------------------------------- verify
# Run it in CloudFront's own sandbox before publishing. This is what proves the
# runtime really gives us crypto.createHmac — if it doesn't, the function fails
# here rather than locking everyone out of a live site.
say "Testing it at the edge before publishing"
cat > "$WORK/event.json" <<'JSON'
{"version":"1.0","context":{"eventType":"viewer-request"},
 "viewer":{"ip":"203.0.113.1"},
 "request":{"method":"GET","uri":"/","querystring":{},
            "headers":{"host":{"value":"example.net"}},"cookies":{}}}
JSON
FN_ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
aws cloudfront test-function --name "$FN_NAME" --if-match "$FN_ETAG" --stage DEVELOPMENT \
  --event-object "fileb://$WORK/event.json" --output json > "$WORK/test.json"
python3 - "$WORK/test.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))["TestResult"]
err = r.get("FunctionErrorMessage") or ""
if err:
    print("  the function errored at the edge: " + err); sys.exit(1)
out = json.loads(r["FunctionOutput"])
resp = out.get("response", {})
loc = resp.get("headers", {}).get("location", {}).get("value")
if resp.get("statusCode") != 302 or loc != "/gate.html":
    print("  unexpected result for an unauthenticated request: " + json.dumps(out)); sys.exit(1)
print("  an unauthenticated request is redirected to /gate.html")
print("  compute used: %s%% of the limit" % r.get("ComputeUtilization", "?"))
PY

say "Publishing"
FN_ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
FN_ARN="$(aws cloudfront publish-function --name "$FN_NAME" --if-match "$FN_ETAG" \
  --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)"
echo "  $FN_ARN"

# ----------------------------------------------------------------- attach
say "Attaching to the default cache behaviour"
aws cloudfront get-distribution-config --id "$DIST_ID" --output json > "$WORK/dist.json"
ETAG="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ETag"])' "$WORK/dist.json")"
CHANGED="$(python3 - "$WORK/dist.json" "$WORK/cfg.json" "$FN_ARN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["DistributionConfig"]
b = d["DefaultCacheBehavior"]
want = {"Quantity": 1, "Items": [{"FunctionARN": sys.argv[3], "EventType": "viewer-request"}]}
same = b.get("FunctionAssociations") == want
b["FunctionAssociations"] = want
json.dump(d, open(sys.argv[2], "w"))
print("no" if same else "yes")
PY
)"
if [ "$CHANGED" = yes ]; then
  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
    --distribution-config "file://$WORK/cfg.json" >/dev/null
  echo "  attached (takes ~5 minutes to reach every edge)"
else
  echo "  already attached"
fi

say "Publishing the gate page"
aws s3 cp "$DIR/../web/gate.html" "s3://$BUCKET/gate.html" \
  --content-type "text/html" --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths /gate.html >/dev/null

# The cookie must stay out of the cache key, or CloudFront caches a copy of
# every page per visitor and the hit rate collapses. Say so if it isn't.
POLICY="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["DistributionConfig"];print(d["DefaultCacheBehavior"].get("CachePolicyId",""))' "$WORK/dist.json")"
if [ -n "$POLICY" ]; then
  COOKIES="$(aws cloudfront get-cache-policy --id "$POLICY" \
    --query 'CachePolicy.CachePolicyConfig.ParametersInCacheKeyAndForwardedToOrigin.CookiesConfig.CookieBehavior' \
    --output text 2>/dev/null || echo unknown)"
  if [ "$COOKIES" != none ] && [ "$COOKIES" != unknown ]; then
    echo
    echo "  NOTE: the cache policy forwards cookies ($COOKIES). Set it to 'none'"
    echo "  so the pass cookie stays out of the cache key."
  fi
fi

say "Done — the archive is now private."
cat <<EOF

  Next: you need an administrator pass before you can reach /admin.html.

      ./deploy/mint-token.sh --type 1 --for you@example.org

  Open the link it prints, and from then on issue passes from /admin.html.
EOF
