#!/usr/bin/env bash
#
# Publish the whole static site (index.html, admin.html, gate.html, catalogue.json)
# to S3
# and invalidate CloudFront. This is how the site is deployed once EC2 is
# retired — no server, no container in production.
#
#   AWS_REGION=eu-north-1 ./deploy/publish-site.sh
#
# Scanned images / PDFs are uploaded separately (drop them straight in the
# bucket with their exact filenames); they're new keys, so no invalidation.
#
set -euo pipefail

BUCKET="${BUCKET:-trarchive-766743414531-eu-north-1-an}"
CF_DOMAIN="${CF_DOMAIN:-dmfmj7c4s21wr.cloudfront.net}"
DIR="$(cd "$(dirname "$0")" && pwd)"
WEB="$DIR/../web"

# HTML + data: no-cache so edits/updates surface on refresh. (Images, uploaded
# separately, can cache for a long time — they never change.)
echo "Uploading site files to s3://$BUCKET ..."
aws s3 cp "$WEB/index.html"     "s3://$BUCKET/index.html"     --content-type "text/html"        --cache-control "no-cache"
aws s3 cp "$WEB/admin.html"     "s3://$BUCKET/admin.html"     --content-type "text/html"        --cache-control "no-cache"
aws s3 cp "$WEB/gate.html"      "s3://$BUCKET/gate.html"      --content-type "text/html"        --cache-control "no-cache"
aws s3 cp "$WEB/catalogue.json" "s3://$BUCKET/catalogue.json" --content-type "application/json"  --cache-control "no-cache"

DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text)"
if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  echo "Invalidating on $DIST_ID..."
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" \
    --paths /index.html /admin.html /gate.html /catalogue.json >/dev/null
fi

echo "Done. Site: https://$CF_DOMAIN/"
echo "Note: set the distribution's Default Root Object to index.html so the bare"
echo "domain serves the catalogue."
