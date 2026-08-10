#!/usr/bin/env bash
#
# Lock the bucket to CloudFront using Origin Access Control (OAC): apply a bucket
# policy that lets ONLY this distribution read objects, and turn Block Public
# Access back on (OAC access is via a service principal, not public).
#
#   ./deploy/cloudfront-oac.sh
#
# Prereq: the distribution's S3 origin must be configured to use an OAC. In the
# CloudFront console: Distribution -> Origins -> edit the S3 origin ->
# "Origin access" = "Origin access control settings (recommended)" -> create/
# select a control -> Save. (This script applies the matching bucket policy.)
#
set -euo pipefail

BUCKET="${BUCKET:-trarchive-766743414531-eu-north-1-an}"
CF_DOMAIN="${CF_DOMAIN:-dmfmj7c4s21wr.cloudfront.net}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text)"
[ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ] || {
  echo "Could not resolve a distribution for $CF_DOMAIN"; exit 1; }
echo "Distribution: $DIST_ID"

TMP="$(mktemp -d)"
cat > "$TMP/policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontOAC",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
        }
      }
    }
  ]
}
JSON

echo "Applying OAC bucket policy..."
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$TMP/policy.json"

echo "Re-enabling Block Public Access (the OAC policy is not public)..."
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

rm -rf "$TMP"
echo "Done."
echo "Next: set the distribution's Default Root Object to index.html, and make"
echo "sure the site files are uploaded (deploy/publish-site.sh)."
