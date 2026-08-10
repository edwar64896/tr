#!/usr/bin/env bash
#
# Configure the archive S3 bucket for the website:
#   * CORS so the site can fetch catalogue.json cross-origin
#   * (optional) public-read so scanned images/PDFs load via <img>/links
#   * upload the current catalogue.json to bootstrap it
#
# Usage:
#   AWS_REGION=eu-north-1 ./deploy/s3-setup.sh                 # CORS + upload only
#   ALLOW_PUBLIC=yes AWS_REGION=eu-north-1 ./deploy/s3-setup.sh  # also make objects public
#
# Public-read is the simplest way to serve the images for a POC. The private
# alternative is to keep the bucket locked and put CloudFront (with an Origin
# Access Control) in front — then set IMAGE_BASE/CATALOGUE_URL to the CloudFront
# domain instead of the S3 URL.

set -euo pipefail

BUCKET="${BUCKET:-trarchive-766743414531-eu-north-1-an}"
AWS_REGION="${AWS_REGION:-eu-north-1}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Bucket: $BUCKET   Region: $AWS_REGION"

# 1. CORS (needed for the site to fetch catalogue.json from the bucket).
echo "[1/3] Applying CORS..."
aws s3api put-bucket-cors --bucket "$BUCKET" \
  --cors-configuration "file://$DIR/s3-cors.json"

# 2. Upload the current data so the site has something to read immediately.
if [ -f "$DIR/../web/catalogue.json" ]; then
  echo "[2/3] Uploading catalogue.json..."
  aws s3 cp "$DIR/../web/catalogue.json" "s3://$BUCKET/catalogue.json" \
    --content-type application/json --cache-control "no-cache"
else
  echo "[2/3] web/catalogue.json not found — skipping upload."
fi

# 3. Public read (opt-in). Relaxes Block Public Access, then applies the policy.
if [ "${ALLOW_PUBLIC:-no}" = "yes" ]; then
  echo "[3/3] Enabling public read (Block Public Access -> off, applying policy)..."
  echo "      WARNING: this makes every object in the bucket world-readable."
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-policy --bucket "$BUCKET" \
    --policy "file://$DIR/s3-bucket-policy.json"
else
  echo "[3/3] Skipping public-read (set ALLOW_PUBLIC=yes to enable, or use CloudFront)."
fi

echo "Done."
