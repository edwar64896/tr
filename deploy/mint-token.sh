#!/usr/bin/env bash
#
# Mint an access pass from the command line.
#
#   ./deploy/mint-token.sh --type 1 --for mark@example.org     # administrator
#   ./deploy/mint-token.sh --type 2 --for jane@example.org     # two weeks
#   ./deploy/mint-token.sh --type 3 --for bob@example.org      # one day
#
# Day to day you won't need this — administrators issue passes from
# /admin.html. It exists for the two moments that page can't help with:
#
#   * bootstrapping, when nobody has an administrator pass yet, and
#   * after --rotate, when every pass including yours has just been voided.
#
# It signs with the same key as the edge function, read from SSM, so what it
# produces is identical to what /mint produces.
#
set -euo pipefail

CF_DOMAIN="${CF_DOMAIN:-dmfmj7c4s21wr.cloudfront.net}"
PARAM="${PARAM:-/trarchive/auth-secret}"
REGION="${AWS_REGION:-eu-north-1}"
KID="${KID:-1}"   # must match KID in deploy/edge-auth.js

TYPE=""; SUB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:-}"; shift 2 ;;
    --for|--sub) SUB="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$TYPE" in
  1) ROLE=a; TTL=31536000; LABEL="administrator pass (1 year)" ;;
  2) ROLE=p; TTL=1209600;  LABEL="reader pass (14 days)" ;;
  3) ROLE=p; TTL=86400;    LABEL="reader pass (24 hours)" ;;
  *) echo "Need --type 1 (admin), 2 (two weeks) or 3 (one day)." >&2; exit 2 ;;
esac
[ -n "$SUB" ] || { echo "Need --for <who the pass is for>." >&2; exit 2; }

# Same sanitising as the edge function, so a name can't smuggle in the field
# separator and forge itself a different role.
SUB="$(printf '%s' "$SUB" | tr -cd 'A-Za-z0-9@._+-' | cut -c1-64)"
[ -n "$SUB" ] || { echo "That name has no usable characters in it." >&2; exit 2; }

SECRET="$(aws ssm get-parameter --name "$PARAM" --with-decryption --region "$REGION" \
  --query Parameter.Value --output text 2>/dev/null || true)"
if [ -z "$SECRET" ] || [ "$SECRET" = None ]; then
  echo "No signing key at $PARAM ($REGION). Run ./deploy/publish-auth.sh first." >&2
  exit 1
fi

EXP=$(( $(date -u +%s) + TTL ))
PAYLOAD="$SUB~$ROLE~$EXP~$KID"
SIG="$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.*= *//')"
TOKEN="$PAYLOAD.$SIG"

if date -u -d "@$EXP" >/dev/null 2>&1; then WHEN="$(date -u -d "@$EXP" '+%-d %B %Y')"   # GNU
else WHEN="$(date -u -r "$EXP" '+%-d %B %Y')"; fi                                       # BSD/macOS

cat <<EOF

  $LABEL for $SUB
  valid until $WHEN

  https://$CF_DOMAIN/access?t=$TOKEN

EOF
