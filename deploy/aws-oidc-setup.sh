#!/usr/bin/env bash
#
# One-time AWS setup so GitHub Actions can push to ECR via OIDC — no access
# keys stored in GitHub. Run this once with the AWS CLI configured as an admin.
#
#   AWS_REGION=eu-west-2 ./deploy/aws-oidc-setup.sh
#
# It prints the role ARN at the end; add that as the GitHub repo secret
# AWS_ROLE_ARN (Settings -> Secrets and variables -> Actions).

set -euo pipefail

AWS_REGION="${AWS_REGION:?set AWS_REGION, e.g. AWS_REGION=eu-west-2}"
GH_REPO="${GH_REPO:-edwar64896/tr}"          # owner/repo allowed to assume the role
ECR_REPO="${ECR_REPO:-tr-archive}"
ROLE_NAME="${ROLE_NAME:-github-actions-ecr-push}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
TMP="$(mktemp -d)"

echo "Account:  $ACCOUNT_ID"
echo "Region:   $AWS_REGION"
echo "Repo:     $GH_REPO"
echo

# 1. GitHub OIDC identity provider (create only if missing).
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "[1/5] OIDC provider already present."
else
  echo "[1/5] Creating GitHub OIDC provider..."
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
#    (find yours in the "Print OIDC token claims" workflow step). We also pin
#    `aud` and `repository` as extra guards.
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
  echo "[2/5] Updating existing role $ROLE_NAME..."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$TMP/trust.json"
else
  echo "[2/5] Creating role $ROLE_NAME..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP/trust.json" >/dev/null
fi

# 4. Least-privilege ECR push policy (scoped to the one repo; the auth-token
#    action must be Resource:* per the ECR API).
cat > "$TMP/ecr.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}" }
  ]
}
JSON
echo "[3/5] Attaching ECR push policy..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ecr-push --policy-document "file://$TMP/ecr.json"

# 4b. SSM deploy permissions so the workflow can pull-and-restart on the box.
#     SendCommand is scoped to the target instance (if EC2_INSTANCE_ID is set,
#     else any instance in the account) plus the RunShellScript document.
SSM_INSTANCE_ARN="arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${EC2_INSTANCE_ID:-*}"
cat > "$TMP/ssm.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "${SSM_INSTANCE_ARN}",
        "arn:aws:ssm:${AWS_REGION}::document/AWS-RunShellScript"
      ] },
    { "Effect": "Allow",
      "Action": [ "ssm:GetCommandInvocation", "ssm:ListCommandInvocations" ],
      "Resource": "*" }
  ]
}
JSON
echo "[3b] Attaching SSM deploy policy..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ssm-deploy --policy-document "file://$TMP/ssm.json"

# 5. Ensure the ECR repository exists.
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "[4/5] ECR repo $ECR_REPO already exists."
else
  echo "[4/5] Creating ECR repo $ECR_REPO..."
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION" >/dev/null
fi

rm -rf "$TMP"
echo "[5/5] Done."
echo
echo "=================================================================="
echo " Add this as the GitHub repo secret  AWS_ROLE_ARN :"
aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text
echo "=================================================================="
echo " gh secret set AWS_ROLE_ARN --body \"\$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)\""
