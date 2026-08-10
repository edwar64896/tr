#!/usr/bin/env bash
#
# One-time: give the EC2 instance an IAM role so it can (a) be driven by SSM
# and (b) pull from ECR — both needed for the workflow's auto-deploy job.
#
#   EC2_INSTANCE_ID=i-0123456789abcdef0 AWS_REGION=eu-west-2 ./deploy/ec2-instance-role.sh
#
# Prereq: the SSM agent must be running on the box. On Ubuntu AMIs it ships as
# a snap; if `sudo snap services amazon-ssm-agent` shows nothing, install it with
#   sudo snap install amazon-ssm-agent --classic && sudo snap start amazon-ssm-agent
# The instance also needs outbound HTTPS (443) to the SSM endpoints.

set -euo pipefail

AWS_REGION="${AWS_REGION:?set AWS_REGION, e.g. AWS_REGION=eu-west-2}"
EC2_INSTANCE_ID="${EC2_INSTANCE_ID:?set EC2_INSTANCE_ID, e.g. EC2_INSTANCE_ID=i-0abc...}"
ROLE_NAME="${ROLE_NAME:-tr-archive-ec2}"
PROFILE_NAME="${PROFILE_NAME:-$ROLE_NAME}"
TMP="$(mktemp -d)"

cat > "$TMP/ec2-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON

# 1. Role + managed policies (SSM core, ECR read-only).
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[1/4] Role $ROLE_NAME exists."
else
  echo "[1/4] Creating role $ROLE_NAME..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP/ec2-trust.json" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# 2. Instance profile wrapping the role.
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "[2/4] Instance profile $PROFILE_NAME exists."
else
  echo "[2/4] Creating instance profile $PROFILE_NAME..."
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
fi
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
      --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null | grep -qx "$ROLE_NAME"; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" || true
fi

echo "[3/4] Waiting for the instance profile to propagate..."
sleep 10

# 3. Attach the profile to the instance (idempotent-ish).
echo "[4/4] Associating profile with $EC2_INSTANCE_ID..."
if aws ec2 describe-iam-instance-profile-associations \
     --filters "Name=instance-id,Values=$EC2_INSTANCE_ID" \
     --query 'IamInstanceProfileAssociations[?State==`associated`].AssociationId' \
     --output text --region "$AWS_REGION" | grep -q .; then
  echo "     An instance profile is already associated. If it's the wrong one,"
  echo "     replace it in the console or with ec2 replace-iam-instance-profile-association."
else
  aws ec2 associate-iam-instance-profile \
    --instance-id "$EC2_INSTANCE_ID" \
    --iam-instance-profile "Name=$PROFILE_NAME" \
    --region "$AWS_REGION" >/dev/null
  echo "     Associated."
fi

rm -rf "$TMP"
echo
echo "Done. Give SSM a minute, then check the box is managed:"
echo "  aws ssm describe-instance-information --region $AWS_REGION \\"
echo "    --filters Key=InstanceIds,Values=$EC2_INSTANCE_ID --query 'InstanceInformationList[0].PingStatus'"
echo
echo "Then set the GitHub repo VARIABLE so the deploy job turns on:"
echo "  gh variable set EC2_INSTANCE_ID --body $EC2_INSTANCE_ID"
