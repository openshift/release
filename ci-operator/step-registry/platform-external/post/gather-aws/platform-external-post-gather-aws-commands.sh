#!/bin/bash

#
# Gather AWS-specific diagnostics for platform-external installations on failure.
# This step collects:
# - Bootstrap logs via openshift-install gather bootstrap
# - EC2 instance console logs (bootstrap, masters, workers)
# - Load balancer target group health status
# - CloudFormation stack events (if not already collected)
#

set -o nounset
set -o pipefail

# Don't exit on error - we want to collect as much as possible
set +o errexit

source "${SHARED_DIR}/init-fn.sh" || true

log "Starting AWS-specific diagnostic collection for platform-external"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Determine AWS region
if [ ! -f "${SHARED_DIR}/metadata.json" ]; then
  log "WARNING: No metadata.json found, attempting to extract region from other sources"
  if [ -f "${SHARED_DIR}/terraform.tfvars.json" ]; then
    AWS_REGION=$(jq -r '.aws_region // empty' "${SHARED_DIR}/terraform.tfvars.json" 2>/dev/null || echo "")
  fi
  if [ -z "${AWS_REGION}" ] && [ -n "${LEASED_RESOURCE:-}" ]; then
    AWS_REGION="${LEASED_RESOURCE}"
  fi
  if [ -z "${AWS_REGION}" ]; then
    log "ERROR: Unable to determine AWS region, skipping AWS diagnostics"
    exit 0
  fi
else
  AWS_REGION="$(jq -r .aws.region "${SHARED_DIR}/metadata.json")"
fi

export AWS_DEFAULT_REGION="${AWS_REGION}"
log "AWS Region: ${AWS_REGION}"

# Get infrastructure ID
if [ -f "${SHARED_DIR}/metadata.json" ]; then
  INFRA_ID="$(jq -r .infraID "${SHARED_DIR}/metadata.json")"
elif [ -f "${SHARED_DIR}/terraform.tfvars.json" ]; then
  INFRA_ID="$(jq -r .cluster_id "${SHARED_DIR}/terraform.tfvars.json")"
else
  log "WARNING: Unable to determine infrastructure ID, will skip some diagnostics"
  INFRA_ID=""
fi

log "Infrastructure ID: ${INFRA_ID}"

#
# 1. Collect Bootstrap Logs
#
log "=========================================="
log "1. Collecting Bootstrap Logs"
log "=========================================="

if [ -f "${SHARED_DIR}/BOOTSTRAP_IP" ]; then
  BOOTSTRAP_IP=$(<"${SHARED_DIR}/BOOTSTRAP_IP")
  log "Bootstrap IP: ${BOOTSTRAP_IP}"

  SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

  if [ -f "${SSH_PRIV_KEY_PATH}" ]; then
    log "Attempting to gather bootstrap logs via openshift-install..."

    # Create temporary install directory with kubeconfig
    TEMP_INSTALL_DIR="${ARTIFACT_DIR}/bootstrap-gather-install-dir"
    mkdir -p "${TEMP_INSTALL_DIR}/auth"

    if [ -f "${SHARED_DIR}/kubeconfig" ]; then
      cp "${SHARED_DIR}/kubeconfig" "${TEMP_INSTALL_DIR}/auth/kubeconfig" 2>/dev/null || true
    fi

    # Try to gather bootstrap logs
    if command -v openshift-install &> /dev/null; then
      log "Running: openshift-install gather bootstrap --bootstrap ${BOOTSTRAP_IP} --key ${SSH_PRIV_KEY_PATH}"

      cd "${TEMP_INSTALL_DIR}" || exit 1
      timeout 600 openshift-install gather bootstrap \
        --bootstrap "${BOOTSTRAP_IP}" \
        --key "${SSH_PRIV_KEY_PATH}" \
        --log-level debug 2>&1 | tee "${ARTIFACT_DIR}/bootstrap-gather.log" || {
        log "WARNING: openshift-install gather bootstrap failed or timed out"
      }

      # Copy any log bundles to artifacts
      if ls log-bundle-*.tar.gz 1> /dev/null 2>&1; then
        cp -v log-bundle-*.tar.gz "${ARTIFACT_DIR}/" || true
        log "Bootstrap logs collected successfully"
      else
        log "WARNING: No bootstrap log bundle created"
      fi

      cd - || exit 1
    else
      log "WARNING: openshift-install command not found, cannot gather bootstrap logs"
    fi
  else
    log "WARNING: SSH private key not found at ${SSH_PRIV_KEY_PATH}"
  fi
else
  log "WARNING: BOOTSTRAP_IP file not found, skipping bootstrap log collection"
fi

#
# 2. Extract Instance IDs from CloudFormation Stacks
#
log "=========================================="
log "2. Extracting Instance IDs from CloudFormation"
log "=========================================="

INSTANCE_IDS_FILE="${ARTIFACT_DIR}/aws-instance-ids.txt"
touch "${INSTANCE_IDS_FILE}"

# Function to extract instance IDs from CloudFormation stack
extract_instances_from_stack() {
  local stack_name=$1
  log "Extracting instances from stack: ${stack_name}"

  aws --region "${AWS_REGION}" cloudformation describe-stack-resources \
    --stack-name "${stack_name}" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' \
    --output text 2>/dev/null | tr '\t' '\n' >> "${INSTANCE_IDS_FILE}" || {
    log "WARNING: Failed to extract instances from stack ${stack_name}"
  }
}

# Extract from known stack files
if [ -f "${SHARED_DIR}/STACK_NAME_BOOTSTRAP" ]; then
  BOOTSTRAP_STACK=$(<"${SHARED_DIR}/STACK_NAME_BOOTSTRAP")
  extract_instances_from_stack "${BOOTSTRAP_STACK}"
fi

# Try to find all cluster stacks by infrastructure ID
if [ -n "${INFRA_ID}" ]; then
  log "Searching for all CloudFormation stacks with InfrastructureName=${INFRA_ID}"

  aws --region "${AWS_REGION}" cloudformation describe-stacks \
    --query "Stacks[?Tags[?Key=='Name'&&contains(Value,'${INFRA_ID}')]].StackName" \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r stack_name; do
    if [ -n "${stack_name}" ]; then
      extract_instances_from_stack "${stack_name}"
    fi
  done
fi

# Also try to find instances directly by tag
if [ -n "${INFRA_ID}" ]; then
  log "Searching for EC2 instances with tag kubernetes.io/cluster/${INFRA_ID}=owned"

  aws --region "${AWS_REGION}" ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null | tr '\t' '\n' >> "${INSTANCE_IDS_FILE}" || {
    log "WARNING: Failed to query instances by tag"
  }
fi

# Remove duplicates
if [ -f "${INSTANCE_IDS_FILE}" ]; then
  sort -u "${INSTANCE_IDS_FILE}" -o "${INSTANCE_IDS_FILE}"
  INSTANCE_COUNT=$(wc -l < "${INSTANCE_IDS_FILE}")
  log "Found ${INSTANCE_COUNT} unique instance(s)"

  if [ "${INSTANCE_COUNT}" -gt 0 ]; then
    log "Instance IDs:"
    cat "${INSTANCE_IDS_FILE}" | while read -r instance_id; do
      log "  - ${instance_id}"
    done
  fi
fi

#
# 3. Collect EC2 Console Logs
#
log "=========================================="
log "3. Collecting EC2 Instance Console Logs"
log "=========================================="

if [ -f "${INSTANCE_IDS_FILE}" ] && [ -s "${INSTANCE_IDS_FILE}" ]; then
  mkdir -p "${ARTIFACT_DIR}/ec2-console-logs"

  cat "${INSTANCE_IDS_FILE}" | while read -r instance_id; do
    if [ -n "${instance_id}" ]; then
      log "Gathering console log for instance ${instance_id}"

      # Get instance name tag for better file naming
      INSTANCE_NAME=$(aws --region "${AWS_REGION}" ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value' \
        --output text 2>/dev/null || echo "unknown")

      INSTANCE_NAME=$(echo "${INSTANCE_NAME}" | tr '/' '-' | tr ' ' '-')

      # Get console output
      LC_ALL=C.utf8 aws --region "${AWS_REGION}" ec2 get-console-output \
        --instance-id "${instance_id}" \
        --output text > "${ARTIFACT_DIR}/ec2-console-logs/${instance_id}-${INSTANCE_NAME}.log" 2>&1 || {
        log "WARNING: Failed to get console output for ${instance_id}"
      }

      # Also save instance metadata
      aws --region "${AWS_REGION}" ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --output json > "${ARTIFACT_DIR}/ec2-console-logs/${instance_id}-${INSTANCE_NAME}-metadata.json" 2>&1 || {
        log "WARNING: Failed to get instance metadata for ${instance_id}"
      }
    fi
  done

  log "EC2 console logs collected to ${ARTIFACT_DIR}/ec2-console-logs/"
else
  log "WARNING: No instance IDs found, skipping console log collection"
fi

#
# 4. Collect Load Balancer Target Group Health
#
log "=========================================="
log "4. Collecting Load Balancer Diagnostics"
log "=========================================="

if [ -n "${INFRA_ID}" ]; then
  mkdir -p "${ARTIFACT_DIR}/load-balancer-diagnostics"

  # Find all load balancers for this cluster
  log "Searching for load balancers..."
  aws --region "${AWS_REGION}" elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName,'${INFRA_ID}')]" \
    --output json > "${ARTIFACT_DIR}/load-balancer-diagnostics/load-balancers.json" 2>&1 || {
    log "WARNING: Failed to describe load balancers"
  }

  # Find all target groups for this cluster
  log "Searching for target groups..."
  aws --region "${AWS_REGION}" elbv2 describe-target-groups \
    --query "TargetGroups[?contains(TargetGroupName,'${INFRA_ID}')]" \
    --output json > "${ARTIFACT_DIR}/load-balancer-diagnostics/target-groups.json" 2>&1 || {
    log "WARNING: Failed to describe target groups"
  }

  # Get target health for each target group
  if [ -f "${ARTIFACT_DIR}/load-balancer-diagnostics/target-groups.json" ]; then
    jq -r '.TargetGroups[].TargetGroupArn' "${ARTIFACT_DIR}/load-balancer-diagnostics/target-groups.json" 2>/dev/null | while read -r tg_arn; do
      if [ -n "${tg_arn}" ]; then
        TG_NAME=$(echo "${tg_arn}" | awk -F: '{print $NF}' | sed 's/targetgroup\///')
        log "Checking target health for: ${TG_NAME}"

        aws --region "${AWS_REGION}" elbv2 describe-target-health \
          --target-group-arn "${tg_arn}" \
          --output json > "${ARTIFACT_DIR}/load-balancer-diagnostics/target-health-${TG_NAME}.json" 2>&1 || {
          log "WARNING: Failed to describe target health for ${TG_NAME}"
        }

        # Also create a human-readable summary
        aws --region "${AWS_REGION}" elbv2 describe-target-health \
          --target-group-arn "${tg_arn}" \
          --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
          --output table > "${ARTIFACT_DIR}/load-balancer-diagnostics/target-health-${TG_NAME}.txt" 2>&1 || true
      fi
    done
  fi

  log "Load balancer diagnostics collected to ${ARTIFACT_DIR}/load-balancer-diagnostics/"
else
  log "WARNING: No infrastructure ID available, skipping load balancer diagnostics"
fi

#
# 5. Collect CloudFormation Stack Events (if not already collected)
#
log "=========================================="
log "5. Collecting CloudFormation Stack Events"
log "=========================================="

if [ -n "${INFRA_ID}" ]; then
  mkdir -p "${ARTIFACT_DIR}/cloudformation-events"

  # Find all stacks for this cluster
  aws --region "${AWS_REGION}" cloudformation describe-stacks \
    --query "Stacks[?Tags[?Key=='Name'&&contains(Value,'${INFRA_ID}')]].StackName" \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r stack_name; do
    if [ -n "${stack_name}" ]; then
      log "Collecting events for stack: ${stack_name}"

      aws --region "${AWS_REGION}" cloudformation describe-stack-events \
        --stack-name "${stack_name}" \
        --output json > "${ARTIFACT_DIR}/cloudformation-events/${stack_name}-events.json" 2>&1 || {
        log "WARNING: Failed to get events for stack ${stack_name}"
      }

      # Also create human-readable table
      aws --region "${AWS_REGION}" cloudformation describe-stack-events \
        --stack-name "${stack_name}" \
        --query 'StackEvents[0:50].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        --output table > "${ARTIFACT_DIR}/cloudformation-events/${stack_name}-events.txt" 2>&1 || true
    fi
  done

  log "CloudFormation events collected to ${ARTIFACT_DIR}/cloudformation-events/"
fi

#
# 6. Create Summary Report
#
log "=========================================="
log "6. Creating Diagnostic Summary"
log "=========================================="

SUMMARY_FILE="${ARTIFACT_DIR}/aws-diagnostics-summary.txt"

cat > "${SUMMARY_FILE}" << EOF
AWS Platform-External Diagnostic Collection Summary
====================================================
Date: $(date -u --rfc-3339=seconds)
Region: ${AWS_REGION}
Infrastructure ID: ${INFRA_ID}

Bootstrap Information:
----------------------
$(if [ -f "${SHARED_DIR}/BOOTSTRAP_IP" ]; then
  echo "Bootstrap IP: $(<"${SHARED_DIR}/BOOTSTRAP_IP")"
  echo "Bootstrap logs: $(if [ -f "${ARTIFACT_DIR}"/log-bundle-*.tar.gz ]; then echo "Collected"; else echo "Not available"; fi)"
else
  echo "Bootstrap IP: Not available"
fi)

Instance Information:
---------------------
Total instances found: $(if [ -f "${INSTANCE_IDS_FILE}" ]; then wc -l < "${INSTANCE_IDS_FILE}"; else echo "0"; fi)
$(if [ -f "${INSTANCE_IDS_FILE}" ] && [ -s "${INSTANCE_IDS_FILE}" ]; then
  echo "Instance IDs:"
  cat "${INSTANCE_IDS_FILE}" | while read -r id; do echo "  - ${id}"; done
fi)

Console logs collected: $(if [ -d "${ARTIFACT_DIR}/ec2-console-logs" ]; then ls -1 "${ARTIFACT_DIR}/ec2-console-logs"/*.log 2>/dev/null | wc -l; else echo "0"; fi)

Load Balancer Information:
---------------------------
$(if [ -f "${ARTIFACT_DIR}/load-balancer-diagnostics/target-groups.json" ]; then
  echo "Target Groups:"
  jq -r '.TargetGroups[] | "  - \(.TargetGroupName) (\(.Protocol):\(.Port))"' "${ARTIFACT_DIR}/load-balancer-diagnostics/target-groups.json" 2>/dev/null || echo "  Unable to parse"
else
  echo "  No target groups found"
fi)

CloudFormation Stacks:
----------------------
$(if [ -d "${ARTIFACT_DIR}/cloudformation-events" ]; then
  echo "Stack events collected:"
  ls -1 "${ARTIFACT_DIR}/cloudformation-events"/*-events.json 2>/dev/null | while read -r f; do
    basename "$f" | sed 's/-events.json//'
  done | sed 's/^/  - /'
else
  echo "  No stack events collected"
fi)

Collected Artifacts:
--------------------
$(ls -lh "${ARTIFACT_DIR}" | tail -n +2 | awk '{print $9, $5}' | sed 's/^/  /')

EOF

log "Summary report created: ${SUMMARY_FILE}"
cat "${SUMMARY_FILE}"

log "=========================================="
log "AWS diagnostic collection completed"
log "=========================================="

# Exit successfully - this is a best-effort gather step
exit 0
