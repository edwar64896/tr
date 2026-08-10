#!/usr/bin/env bash
#
# One-time AWS setup so GitHub Actions can deploy the static site via OIDC —
# no access keys stored in GitHub. Run once with the AWS CLI configured as admin.
#
#   AWS_REGION=eu-north-1 ./deploy/aws-oidc-setup.sh
#
# Grants the deploy role: write to the site S3 bucket + CloudFront invalidation.
# (Older ECR/SSM/EC2 permissions from the previous container-on-EC2 setup are
# removed if present — the site is now static on S3 + CloudFront.)
#
# It prints the role ARN at the end; add that as the GitHub repo secret
# AWS_ROLE_ARN (Settings -> Secrets and variables -> Actions).

set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-north-1}"
GH_REPO="${GH_REPO:-edwar64896/tr}"                 # owner/repo allowed to assume the role
BUCKET="${BUCKET:-trarchive-766743414531-eu-north-1-an}"
CF_DOMAIN="${CF_DOMAIN:-dmfmj7c4s21wr.cloudfront.net}"
ROLE_NAME="${ROLE_NAME:-github-actions-ecr-push}"   # kept for continuity with the existing secret

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
TMP="$(mktemp -d)"

echo "Account:  $ACCOUNT_ID"
echo "Repo:     $GH_REPO"
echo "Bucket:   $BUCKET"
echo "CF:       $CF_DOMAIN"
echo

# 1. GitHub OIDC identity provider (create only if missing).
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "[1/4] OIDC provider already present."
else
  echo "[1/4] Creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 1c58a3a8518e8759bf075b76b750d4f2df264fca >/dev/null
fi

# 2. Trust policy — only this repo may assume the role.
#    AWS requires the trust to be scoped on `sub` (or `job_workflow_ref`), so we
#    can't rely on `repository` alone. This account customizes the OIDC subject
#    with immutable numeric IDs, so the real sub looks like
#    `repo:owner@<ownerId>/repo@<repoId>:...` rather than `repo:owner/repo:...`.
#    OIDC_SUB defaults to that confirmed value; override it if the IDs differ
#    (find yours in an OIDC token-claims debug step). `aud`/`repository` guard it.
OIDC_SUB="${OIDC_SUB:-repo:edwar64896@2887548/tr@1330152525:*}"
cat > "$TMP/trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:repository": "${GH_REPO}"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "${OIDC_SUB}"
      }
    }
  }]
}
JSON

# 3. Create or update the role.
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[2/4] Updating existing role $ROLE_NAME..."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$TMP/trust.json"
else
  echo "[2/4] Creating role $ROLE_NAME..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP/trust.json" >/dev/null
fi

# 4. Deploy permissions: write site files to the bucket + invalidate CloudFront.
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text 2>/dev/null || echo None)"
if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  CF_RESOURCE="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
else
  CF_RESOURCE="*"
  echo "      (could not resolve distribution for $CF_DOMAIN — CreateInvalidation left unscoped)"
fi
cat > "$TMP/site.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*" },
    { "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation"],
      "Resource": "${CF_RESOURCE}" },
    { "Effect": "Allow",
      "Action": ["cloudfront:ListDistributions"],
      "Resource": "*" }
  ]
}
JSON
echo "[3/4] Attaching site-deploy policy (S3 + CloudFront)..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name site-deploy --policy-document "file://$TMP/site.json"

# 4b. Remove obsolete policies from the container-on-EC2 era, if present.
for p in ecr-push ssm-deploy; do
  if aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$p" >/dev/null 2>&1; then
    echo "      removing obsolete inline policy: $p"
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$p"
  fi
done

rm -rf "$TMP"
echo "[4/4] Done."
echo
echo "=================================================================="
echo " GitHub repo secret AWS_ROLE_ARN should be:"
aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text
echo "=================================================================="
echo " gh secret set AWS_ROLE_ARN --body \"\$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)\""
