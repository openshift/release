#!/bin/bash

set -euo pipefail

echo "=== AWS CSPI-QE Resource Cleanup ==="
echo "Regions: ${CLEANUP_REGIONS}"
echo "Min age: ${CLEANUP_MIN_AGE}"

# Configure AWS credentials from the cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Clone openshift/hypershift at a pinned commit and build the cleanleaked tool
# Update this SHA periodically to pick up cleanleaked improvements
HYPERSHIFT_SHA="a98bd6d40025667761387f9d9589e75140c7fbc0"
echo ""
echo "=== Cloning openshift/hypershift at ${HYPERSHIFT_SHA} ==="
HYPERSHIFT_DIR=$(mktemp -d)
git clone --depth 1 https://github.com/openshift/hypershift.git "${HYPERSHIFT_DIR}"
cd "${HYPERSHIFT_DIR}"
git fetch --depth 1 origin "${HYPERSHIFT_SHA}"
git checkout "${HYPERSHIFT_SHA}"

echo ""
echo "=== Building cleanleaked ==="
cd "${HYPERSHIFT_DIR}/contrib/aws-leaked-resources"
export GOTOOLCHAIN=auto
go build -o /tmp/cleanleaked .
echo "cleanleaked built successfully"

# Loop over each comma-separated region
IFS=',' read -ra REGIONS <<< "${CLEANUP_REGIONS}"
for region in "${REGIONS[@]}"; do
  region=$(echo "${region}" | xargs)  # trim whitespace
  echo ""
  echo "=== Running scan for region ${region} (report only) ==="
  /tmp/cleanleaked scan --min-age "${CLEANUP_MIN_AGE}" --region "${region}" || true

  echo ""
  echo "=== Running delete for region ${region} (min-age ${CLEANUP_MIN_AGE}) ==="
  /tmp/cleanleaked delete --confirm --min-age "${CLEANUP_MIN_AGE}" --region "${region}"
done

# ============================================================
# Shared Setup: AWS CLI and age threshold
# ============================================================
# The Route 53 and IAM cleanup phases below both need the AWS CLI and
# a parsed age threshold. Install and configure them once here.

echo ""
echo "=== Installing AWS CLI v2 ==="
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && ./aws/install --bin-dir /tmp/aws-bin --install-dir /tmp/aws-cli 2>/dev/null
export PATH="/tmp/aws-bin:${PATH}"
aws --version

# Route 53 and IAM are global services; use us-east-1 for the API endpoint
export AWS_DEFAULT_REGION="us-east-1"

# Parse CLEANUP_MIN_AGE (e.g. "24h") into hours for age comparison
MIN_AGE_HOURS=$(echo "${CLEANUP_MIN_AGE}" | sed -n 's/^\([0-9]*\)h$/\1/p')
if [[ -z "${MIN_AGE_HOURS}" ]]; then
  echo "ERROR: CLEANUP_MIN_AGE='${CLEANUP_MIN_AGE}' must be '<N>h' for Route 53/IAM cleanup" >&2
  exit 1
fi
CUTOFF_EPOCH=$(date -d "${MIN_AGE_HOURS} hours ago" +%s)
echo "Age threshold: ${MIN_AGE_HOURS}h (cutoff: $(date -d "@${CUTOFF_EPOCH}" -u +%Y-%m-%dT%H:%M:%SZ))"

# ============================================================
# Route 53 Hosted Zone Cleanup (Global – run once)
# ============================================================
# cleanleaked scans VPCs to find leaked infra but does NOT independently
# enumerate or clean Route 53 hosted zones. Orphaned zones from failed
# IPI installs (where the VPC was never created or was already destroyed)
# are invisible to cleanleaked and accumulate toward the
# MAX_HOSTED_ZONES_BY_OWNER quota. This section finds and removes them.

echo ""
echo "=== Phase 1.5: Route 53 Hosted Zone Cleanup ==="

# Write a python3 helper for JSON processing (creating change batches for
# Route 53 record deletion). The Route 53 API requires a JSON change-batch
# payload; python3 (available on RHEL 9) handles the transformation.
cat > /tmp/r53_make_batches.py << 'PYEOF'
"""Create Route 53 change batches for record deletion.

Reads list-resource-record-sets JSON from stdin.
Args: <zone_name> <output_file>
Prints the number of records to delete to stdout.
Writes change batch JSON (one per line, max 1000 changes each) to output_file.
"""
import json, sys

zone_name = sys.argv[1]
batches_file = sys.argv[2]

data = json.load(sys.stdin)
# Keep only the apex NS and SOA records; everything else must be deleted
# before the hosted zone itself can be removed.
records = [r for r in data.get('ResourceRecordSets', [])
           if not (r['Type'] in ('NS', 'SOA') and r['Name'] == zone_name)]
if not records:
    print(0)
    sys.exit(0)

with open(batches_file, 'w') as f:
    for i in range(0, len(records), 1000):
        batch = {'Changes': [{'Action': 'DELETE', 'ResourceRecordSet': r}
                             for r in records[i:i+1000]]}
        f.write(json.dumps(batch) + '\n')
print(len(records))
PYEOF

R53_SKIP_REASON=""
if ! command -v python3 &>/dev/null; then
  R53_SKIP_REASON="python3 not available (required for JSON processing)"
fi

ZONES_DELETED=0
ZONES_SKIPPED_YOUNG=0
ZONES_SKIPPED_APEX=0
ZONES_SKIPPED_NOT_SUBDOMAIN=0
ZONES_ERRORS=0

if [[ -n "${R53_SKIP_REASON}" ]]; then
  echo "WARNING: ${R53_SKIP_REASON}. Skipping Route 53 hosted zone cleanup."
else

# --- Determine the base domain for identifying CI-created cluster zones ---
if [[ -n "${CLEANUP_BASE_DOMAIN:-}" ]]; then
  BASE_DOMAIN="${CLEANUP_BASE_DOMAIN}"
  # Ensure trailing dot (Route 53 zone names always end with a dot)
  [[ "${BASE_DOMAIN}" != *. ]] && BASE_DOMAIN="${BASE_DOMAIN}."
  echo "Using configured base domain: ${BASE_DOMAIN}"
else
  echo "Auto-detecting base domain from hosted zones..."
  # Collect all public zone names into an array
  mapfile -t ALL_ZONE_NAMES < <(aws route53 list-hosted-zones \
    --query 'HostedZones[].Name' \
    --output text 2>/dev/null | tr '\t' '\n' | sort)

  # The apex zone is the one with the most other zones as subdomains
  BASE_DOMAIN=""
  BEST_COUNT=0
  for candidate in "${ALL_ZONE_NAMES[@]}"; do
    count=0
    for other in "${ALL_ZONE_NAMES[@]}"; do
      if [[ "${other}" != "${candidate}" && "${other}" == *".${candidate}" ]]; then
        ((count++)) || true
      fi
    done
    if (( count > BEST_COUNT )); then
      BEST_COUNT=${count}
      BASE_DOMAIN="${candidate}"
    fi
  done

  if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "WARNING: Could not auto-detect base domain. Skipping Route 53 cleanup."
    echo "Set CLEANUP_BASE_DOMAIN to specify the base domain explicitly."
  else
    echo "Auto-detected base domain: ${BASE_DOMAIN} (${BEST_COUNT} subdomain zone(s) found)"
  fi
fi

if [[ -n "${BASE_DOMAIN}" ]]; then

  # --- Age check: query CloudTrail for recently-created zones ---
  # Route 53 does not expose hosted zone creation timestamps. We query
  # CloudTrail management events (retained 90 days) to find zones created
  # within CLEANUP_MIN_AGE. Zones not found in CloudTrail are older than
  # 90 days and clearly past any reasonable threshold.
  echo "Querying CloudTrail for recently-created hosted zones..."
  RECENT_ZONE_IDS_FILE=$(mktemp)
  CT_NEXT_TOKEN=""
  CT_FAILED="false"
  while true; do
    CT_ARGS=(
      --region us-east-1
      --lookup-attributes "AttributeKey=EventName,AttributeValue=CreateHostedZone"
      --start-time "$(date -d "@${CUTOFF_EPOCH}" -u +%Y-%m-%dT%H:%M:%SZ)"
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      --max-results 50
      --output json
    )
    [[ -n "${CT_NEXT_TOKEN}" ]] && CT_ARGS+=(--next-token "${CT_NEXT_TOKEN}")

    CT_RESULT=$(aws cloudtrail lookup-events "${CT_ARGS[@]}" 2>/dev/null) || {
      echo "WARNING: CloudTrail query failed (missing permissions or service issue)."
      echo "         Route 53 zone deletion will be skipped for this run."
      CT_FAILED="true"
      break
    }

    # Extract hosted zone IDs from the CloudTrail events
    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for event in data.get('Events', []):
    for resource in event.get('Resources', []):
        if resource.get('ResourceType') == 'AWS::Route53::HostedZone':
            rn = resource.get('ResourceName', '')
            if rn:
                print(rn)
" <<< "${CT_RESULT}" >> "${RECENT_ZONE_IDS_FILE}" 2>/dev/null || {
      echo "WARNING: Failed to extract zone IDs from CloudTrail events."
      echo "         Route 53 zone deletion will be skipped for this run."
      CT_FAILED="true"
      break
    }

    # Check for pagination
    CT_NEXT_TOKEN=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(data.get('NextToken', ''))
" <<< "${CT_RESULT}" 2>/dev/null) || {
      echo "WARNING: Failed to parse CloudTrail pagination token."
      echo "         Route 53 zone deletion will be skipped for this run."
      CT_FAILED="true"
      break
    }
    [[ -z "${CT_NEXT_TOKEN}" ]] && break
  done
  sort -u -o "${RECENT_ZONE_IDS_FILE}" "${RECENT_ZONE_IDS_FILE}" 2>/dev/null || {
    echo "WARNING: Failed to deduplicate recent zone IDs."
    echo "         Route 53 zone deletion will be skipped for this run."
    CT_FAILED="true"
  }
  if [[ "${CT_FAILED}" != "true" ]]; then
    YOUNG_ZONE_COUNT=$(wc -l < "${RECENT_ZONE_IDS_FILE}" 2>/dev/null | tr -d ' ')
    echo "Found ${YOUNG_ZONE_COUNT} recently-created zone(s) to protect"
  fi

  # --- Enumerate and process all public hosted zones ---
  echo ""
  echo "Enumerating hosted zones..."
  ZONE_DATA=$(aws route53 list-hosted-zones \
    --query 'HostedZones[].[Id,Name]' \
    --output text 2>/dev/null) || ZONE_DATA=""

  TOTAL_ZONES=0
  [[ -n "${ZONE_DATA}" ]] && TOTAL_ZONES=$(echo "${ZONE_DATA}" | wc -l | tr -d ' ')
  echo "Found ${TOTAL_ZONES} hosted zone(s)"

  if [[ "${CT_FAILED}" == "true" ]]; then
    echo "WARNING: CloudTrail data unavailable — skipping Route 53 zone deletion for this run."
    echo "  ${TOTAL_ZONES} zone(s) found but cannot verify age; no zones will be deleted."
  else

  while IFS=$'\t' read -r zone_id zone_name; do
    [[ -z "${zone_id}" ]] && continue

    # Safety: NEVER delete the apex/base domain zone
    if [[ "${zone_name}" == "${BASE_DOMAIN}" ]]; then
      echo "  SKIP (apex zone): ${zone_name}"
      ((ZONES_SKIPPED_APEX++)) || true
      continue
    fi

    # Only process zones that are subdomains of the base domain
    if [[ "${zone_name}" != *".${BASE_DOMAIN}" ]]; then
      ((ZONES_SKIPPED_NOT_SUBDOMAIN++)) || true
      continue
    fi

    # Strip /hostedzone/ prefix for CloudTrail ID comparison
    zone_id_short="${zone_id#/hostedzone/}"

    # Age check: skip zones created within CLEANUP_MIN_AGE
    if grep -qF "${zone_id_short}" "${RECENT_ZONE_IDS_FILE}" 2>/dev/null; then
      echo "  SKIP (young): ${zone_name} (created within ${MIN_AGE_HOURS}h)"
      ((ZONES_SKIPPED_YOUNG++)) || true
      continue
    fi

    echo "  DELETE: ${zone_name} (zone ID: ${zone_id_short})"

    # Step 1: Delete all resource records except apex NS/SOA
    # (Route 53 requires a zone to contain only its apex NS and SOA
    # records before the zone itself can be deleted)
    R53_RECORDS_FILE=$(mktemp)
    R53_BATCHES_FILE=$(mktemp)

    if ! aws route53 list-resource-record-sets \
      --hosted-zone-id "${zone_id}" \
      --output json > "${R53_RECORDS_FILE}" 2>/dev/null; then
      echo "    ERROR: Failed to list records for ${zone_name}"
      ((ZONES_ERRORS++)) || true
      rm -f "${R53_RECORDS_FILE}" "${R53_BATCHES_FILE}"
      continue
    fi

    NUM_RECORDS=0
    NUM_RECORDS=$(python3 /tmp/r53_make_batches.py "${zone_name}" \
      "${R53_BATCHES_FILE}" < "${R53_RECORDS_FILE}" 2>/dev/null) || {
      echo "    ERROR: Failed to process records for ${zone_name}"
      ((ZONES_ERRORS++)) || true
      rm -f "${R53_RECORDS_FILE}" "${R53_BATCHES_FILE}"
      continue
    }
    rm -f "${R53_RECORDS_FILE}"

    if (( NUM_RECORDS > 0 )); then
      echo "    Deleting ${NUM_RECORDS} resource record(s)"
      BATCH_OK="true"
      while IFS= read -r batch; do
        [[ -z "${batch}" ]] && continue
        if ! aws route53 change-resource-record-sets \
          --hosted-zone-id "${zone_id}" \
          --change-batch "${batch}" >/dev/null 2>&1; then
          echo "    ERROR: Failed to delete records from ${zone_name}"
          BATCH_OK="false"
          break
        fi
      done < "${R53_BATCHES_FILE}"
      rm -f "${R53_BATCHES_FILE}"

      if [[ "${BATCH_OK}" != "true" ]]; then
        ((ZONES_ERRORS++)) || true
        continue
      fi
    else
      rm -f "${R53_BATCHES_FILE}"
    fi

    # Step 2: Delete the hosted zone
    if aws route53 delete-hosted-zone --id "${zone_id}" >/dev/null 2>&1; then
      echo "    Zone deleted successfully"
      ((ZONES_DELETED++)) || true
    else
      echo "    ERROR: Failed to delete zone ${zone_name}"
      ((ZONES_ERRORS++)) || true
    fi

  done <<< "${ZONE_DATA}"

  fi  # CT_FAILED check

  rm -f "${RECENT_ZONE_IDS_FILE}"
fi  # [[ -n "${BASE_DOMAIN}" ]]

fi  # R53_SKIP_REASON check

echo ""
echo "Route 53 Hosted Zones: deleted=${ZONES_DELETED} skipped-young=${ZONES_SKIPPED_YOUNG} skipped-apex=${ZONES_SKIPPED_APEX} skipped-other=${ZONES_SKIPPED_NOT_SUBDOMAIN} errors=${ZONES_ERRORS}"

# ============================================================
# IAM Role and Instance Profile Cleanup (Global – run once)
# ============================================================
# cleanleaked cascades IAM cleanup from VPC/OIDC deletion but does NOT
# independently enumerate standalone IAM roles/profiles. Orphaned roles
# from failed deprovisioning accumulate and can hit the 1000-role AWS
# quota. This section finds roles/profiles created by the OCP IPI
# installer (by suffix) and removes stale ones directly.

# ---- IAM Roles ----
echo ""
echo "=== Cleaning up orphaned IAM roles (-master-role / -worker-role) ==="
ROLES_DELETED=0
ROLES_SKIPPED_YOUNG=0
ROLES_SKIPPED_UNTAGGED=0

ROLE_DATA=$(aws iam list-roles \
  --query 'Roles[*].[RoleName,CreateDate]' --output text | \
  grep -E '(-master-role|-worker-role)[[:space:]]' | sort) || true

while IFS=$'\t' read -r role_name create_date; do
  [[ -z "${role_name}" ]] && continue

  # Check age: skip roles newer than the threshold
  role_epoch=$(date -d "${create_date}" +%s 2>/dev/null || echo "0")
  if (( role_epoch > CUTOFF_EPOCH )); then
    echo "  SKIP (young): ${role_name} created ${create_date}"
    (( ROLES_SKIPPED_YOUNG++ )) || true
    continue
  fi

  # Safety gate: require kubernetes.io/cluster/<infraID> tag
  K8S_TAG=$(aws iam list-role-tags --role-name "${role_name}" \
    --query 'Tags[?starts_with(Key, `kubernetes.io/cluster/`)].Key' \
    --output text 2>/dev/null) || true
  if [[ -z "${K8S_TAG}" ]]; then
    echo "  SKIP (no k8s tag): ${role_name}"
    (( ROLES_SKIPPED_UNTAGGED++ )) || true
    continue
  fi

  # Extract infraID from tag key (kubernetes.io/cluster/<infraID>)
  INFRA_ID="${K8S_TAG#kubernetes.io/cluster/}"
  INFRA_ID="${INFRA_ID%%[[:space:]]*}"

  # Check if cluster still has resources in any region
  CLUSTER_ALIVE=""
  for r in "${REGIONS[@]}"; do
    r=$(echo "${r}" | xargs)
    # Check VPCs
    VPC_OUT=""
    if ! VPC_OUT=$(aws ec2 describe-vpcs --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
      --query 'Vpcs[*].VpcId' --output text 2>/dev/null); then
      echo "  SKIP (VPC lookup failed in ${r}): ${role_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${VPC_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
    # Check running EC2 instances
    INST_OUT=""
    if ! INST_OUT=$(aws ec2 describe-instances --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
                "Name=instance-state-name,Values=running,pending,stopping,stopped" \
      --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null); then
      echo "  SKIP (instance lookup failed in ${r}): ${role_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${INST_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
  done
  if [[ "${CLUSTER_ALIVE}" == "true" ]]; then
    echo "  SKIP (cluster still has VPCs/instances): ${role_name} [infraID: ${INFRA_ID}]"
    continue
  fi

  echo "  DELETE: ${role_name} (created ${create_date}, tag: ${K8S_TAG})"

  # Detach all managed policies
  ATTACHED=$(aws iam list-attached-role-policies --role-name "${role_name}" \
    --query 'AttachedPolicies[*].PolicyArn' --output text) || true
  for arn in ${ATTACHED}; do
    [[ "${arn}" == "None" ]] && continue
    aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${arn}" || true
  done

  # Delete all inline policies
  INLINE=$(aws iam list-role-policies --role-name "${role_name}" \
    --query 'PolicyNames[*]' --output text) || true
  for pol in ${INLINE}; do
    [[ "${pol}" == "None" ]] && continue
    aws iam delete-role-policy --role-name "${role_name}" --policy-name "${pol}" || true
  done

  # Remove from any instance profiles
  INST_PROFILES=$(aws iam list-instance-profiles-for-role --role-name "${role_name}" \
    --query 'InstanceProfiles[*].InstanceProfileName' --output text) || true
  for ip in ${INST_PROFILES}; do
    [[ "${ip}" == "None" ]] && continue
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${ip}" --role-name "${role_name}" || true
  done

  # Delete the role
  if aws iam delete-role --role-name "${role_name}"; then
    (( ROLES_DELETED++ )) || true
  fi
done <<< "${ROLE_DATA}"

echo "IAM Roles: deleted=${ROLES_DELETED} skipped-young=${ROLES_SKIPPED_YOUNG} skipped-untagged=${ROLES_SKIPPED_UNTAGGED}"

# ---- Instance Profiles ----
echo ""
echo "=== Cleaning up orphaned instance profiles (-master-profile / -worker-profile) ==="
PROFILES_DELETED=0
PROFILES_SKIPPED_YOUNG=0
PROFILES_SKIPPED_UNTAGGED=0

PROFILE_DATA=$(aws iam list-instance-profiles \
  --query 'InstanceProfiles[*].[InstanceProfileName,CreateDate]' --output text | \
  grep -E '(-master-profile|-worker-profile)[[:space:]]' | sort) || true

while IFS=$'\t' read -r profile_name create_date; do
  [[ -z "${profile_name}" ]] && continue

  # Check age
  profile_epoch=$(date -d "${create_date}" +%s 2>/dev/null || echo "0")
  if (( profile_epoch > CUTOFF_EPOCH )); then
    echo "  SKIP (young): ${profile_name} created ${create_date}"
    (( PROFILES_SKIPPED_YOUNG++ )) || true
    continue
  fi

  # Safety gate: require kubernetes.io/cluster/<infraID> tag
  K8S_TAG=$(aws iam list-instance-profile-tags --instance-profile-name "${profile_name}" \
    --query 'Tags[?starts_with(Key, `kubernetes.io/cluster/`)].Key' \
    --output text 2>/dev/null) || true
  if [[ -z "${K8S_TAG}" ]]; then
    echo "  SKIP (no k8s tag): ${profile_name}"
    (( PROFILES_SKIPPED_UNTAGGED++ )) || true
    continue
  fi

  # Extract infraID from tag key (kubernetes.io/cluster/<infraID>)
  INFRA_ID="${K8S_TAG#kubernetes.io/cluster/}"
  INFRA_ID="${INFRA_ID%%[[:space:]]*}"

  # Check if cluster still has resources in any region
  CLUSTER_ALIVE=""
  for r in "${REGIONS[@]}"; do
    r=$(echo "${r}" | xargs)
    # Check VPCs
    VPC_OUT=""
    if ! VPC_OUT=$(aws ec2 describe-vpcs --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
      --query 'Vpcs[*].VpcId' --output text 2>/dev/null); then
      echo "  SKIP (VPC lookup failed in ${r}): ${profile_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${VPC_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
    # Check running EC2 instances
    INST_OUT=""
    if ! INST_OUT=$(aws ec2 describe-instances --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
                "Name=instance-state-name,Values=running,pending,stopping,stopped" \
      --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null); then
      echo "  SKIP (instance lookup failed in ${r}): ${profile_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${INST_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
  done
  if [[ "${CLUSTER_ALIVE}" == "true" ]]; then
    echo "  SKIP (cluster still has VPCs/instances): ${profile_name} [infraID: ${INFRA_ID}]"
    continue
  fi

  echo "  DELETE: ${profile_name} (created ${create_date}, tag: ${K8S_TAG})"

  # Remove all roles from the instance profile
  IP_ROLES=$(aws iam get-instance-profile --instance-profile-name "${profile_name}" \
    --query 'InstanceProfile.Roles[*].RoleName' --output text) || true
  for rn in ${IP_ROLES}; do
    [[ "${rn}" == "None" ]] && continue
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${profile_name}" --role-name "${rn}" || true
  done

  # Delete the instance profile
  if aws iam delete-instance-profile --instance-profile-name "${profile_name}"; then
    (( PROFILES_DELETED++ )) || true
  fi
done <<< "${PROFILE_DATA}"

echo "Instance Profiles: deleted=${PROFILES_DELETED} skipped-young=${PROFILES_SKIPPED_YOUNG} skipped-untagged=${PROFILES_SKIPPED_UNTAGGED}"

echo ""
echo "=== Cleanup complete ==="
