#!/usr/bin/env bash
#
# Publish an updated catalogue.json: upload to S3 and invalidate CloudFront so
# the change is live immediately. This is the one step after Mark downloads a
# new catalogue.json from the admin page.
#
#   ./deploy/publish-catalogue.sh path/to/catalogue.json
#   ./deploy/publish-catalogue.sh            # defaults to web/catalogue.json
#
set -euo pipefail

BUCKET="${BUCKET:-trarchive-766743414531-eu-north-1-an}"
CF_DOMAIN="${CF_DOMAIN:-dmfmj7c4s21wr.cloudfront.net}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="${1:-$DIR/../web/catalogue.json}"

[ -f "$FILE" ] || { echo "File not found: $FILE"; exit 1; }

echo "Uploading $(basename "$FILE") -> s3://$BUCKET/catalogue.json"
aws s3 cp "$FILE" "s3://$BUCKET/catalogue.json" \
  --content-type application/json --cache-control "no-cache"

DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text)"
if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  echo "Invalidating /catalogue.json on $DIST_ID..."
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" \
    --paths /catalogue.json >/dev/null
  echo "Done — refresh the site to see the new catalogue."
else
  echo "Could not find a distribution for $CF_DOMAIN — uploaded, but skipped"
  echo "invalidation. The change appears once the CloudFront cache expires."
fi
