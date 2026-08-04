#!/bin/bash
set -euo pipefail

# ============================================================================
# Tag-based AWS cleanup for orphaned MAPT EKS resources
#
# Catches resources that MAPT/Pulumi failed to destroy:
# - Clusters with lost/corrupted Pulumi S3 state
# - Resources MAPT destroy left behind (LBs, Target Groups, ENIs)
# - Partially failed destroys (VPC stuck on dependencies)
#
# Discovery: EKS clusters tagged origin=mapt, projectName=eks
# with expired expirationDate or creation time > 24h (fallback)
# ============================================================================

##############################################################################
# Phase 0: Load credentials
##############################################################################
echo "[INFO] 🔐 Loading AWS credentials..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

##############################################################################
# Phase 1: Discover orphaned EKS clusters by tag
##############################################################################
echo "[INFO] 🔍 Discovering orphaned EKS clusters..."
ORPHANED_CLUSTERS=()

# We need the Account ID to construct ARNs for EKS
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "[WARN] Unable to resolve AWS account ID; skipping AWS cleanup."
  echo "aws-cleanup: 0 clusters processed, discovery failed" > "${ARTIFACT_DIR}/aws-cleanup-summary.txt"
  exit 0
fi

mapfile -t CLUSTERS < <(aws eks list-clusters --query 'clusters[]' --output text | tr '\t' '\n' || true)

CURRENT_TIME=$(date --utc +%s)
ONE_DAY_AGO=$((CURRENT_TIME - 86400))

for cluster in "${CLUSTERS[@]}"; do
  if [[ -z "${cluster}" ]]; then continue; fi

  CLUSTER_ARN="arn:aws:eks:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:cluster/${cluster}"
  
  # 1. Get tags
  TAGS_JSON=$(aws eks list-tags-for-resource --resource-arn "${CLUSTER_ARN}" --query 'tags' --output json 2>/dev/null || echo "{}")
  
  ORIGIN=$(echo "${TAGS_JSON}" | jq -r '.origin // empty')
  PROJECT_NAME=$(echo "${TAGS_JSON}" | jq -r '.projectName // empty')
  
  # 2. Skip if NOT tagged with origin=mapt AND projectName=eks
  if [[ "${ORIGIN}" != "mapt" ]] || [[ "${PROJECT_NAME}" != "eks" ]]; then
    continue
  fi

  EXPIRATION_DATE=$(echo "${TAGS_JSON}" | jq -r '.expirationDate // empty')
  LAUNCH_ID=$(echo "${TAGS_JSON}" | jq -r '.["launch-id"] // empty')
  
  IS_ORPHAN=false
  
  # 3. If expirationDate tag exists
  if [[ -n "${EXPIRATION_DATE}" ]]; then
    EXP_TIME=$(date -d "${EXPIRATION_DATE}" +%s 2>/dev/null || echo "0")
    if [[ ${EXP_TIME} -gt 0 ]] && [[ ${CURRENT_TIME} -gt ${EXP_TIME} ]]; then
      echo "[INFO] ⚠️ Found expired cluster: ${cluster} (launch-id: ${LAUNCH_ID}, expired at: ${EXPIRATION_DATE})"
      IS_ORPHAN=true
    elif [[ ${EXP_TIME} -le 0 ]]; then
      # expirationDate tag exists but failed to parse — fall back to createdAt age check
      CREATED_AT=$(aws eks describe-cluster --name "${cluster}" --query 'cluster.createdAt' --output text 2>/dev/null || echo "0")
      if [[ -n "${CREATED_AT}" ]] && [[ "${CREATED_AT}" != "0" ]]; then
        CREATED_TIME=$(date -d "${CREATED_AT}" +%s 2>/dev/null || echo "0")
        if [[ ${CREATED_TIME} -gt 0 ]] && [[ ${CREATED_TIME} -lt ${ONE_DAY_AGO} ]]; then
          echo "[INFO] ⚠️ Found cluster with unparseable expirationDate older than 24h: ${cluster} (created at: ${CREATED_AT})"
          IS_ORPHAN=true
        fi
      fi
    fi
  else
    # 4. If no expirationDate tag (legacy clusters)
    CREATED_AT=$(aws eks describe-cluster --name "${cluster}" --query 'cluster.createdAt' --output text 2>/dev/null || echo "0")
    if [[ -n "${CREATED_AT}" ]] && [[ "${CREATED_AT}" != "0" ]]; then
      CREATED_TIME=$(date -d "${CREATED_AT}" +%s 2>/dev/null || echo "0")
      if [[ ${CREATED_TIME} -gt 0 ]] && [[ ${CREATED_TIME} -lt ${ONE_DAY_AGO} ]]; then
        echo "[INFO] ⚠️ Found legacy cluster older than 24h: ${cluster} (created at: ${CREATED_AT})"
        IS_ORPHAN=true
      fi
    fi
  fi

  # 5. Add to orphaned list
  if ${IS_ORPHAN}; then
    ORPHANED_CLUSTERS+=("${cluster}")
  fi
done

if [[ ${#ORPHANED_CLUSTERS[@]} -eq 0 ]]; then
  echo "[INFO] ✅ No orphaned EKS clusters found."
  echo "aws-cleanup: 0 clusters cleaned" > "${ARTIFACT_DIR}/aws-cleanup-summary.txt"
  exit 0
fi

echo "[INFO] 🗑️ Found ${#ORPHANED_CLUSTERS[@]} orphaned clusters to clean up."

##############################################################################
# Phase 2: For each orphaned cluster, delete in dependency order
##############################################################################
TOTAL_PROCESSED=0
FAILED_CLUSTERS=()

# Helper function to delete resources safely
clean_cluster() {
  local cluster=$1
  echo "[INFO] =========================================================="
  echo "[INFO] 🧹 Starting cleanup for cluster: ${cluster}"
  echo "[INFO] =========================================================="
  
  # All commands within use `|| true` for error tolerance

  # a. Get cluster details (VPC ID + OIDC issuer for scoped cleanup later)
  local VPC_ID=""
  VPC_ID=$(aws eks describe-cluster --name "${cluster}" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)
  local OIDC_ISSUER=""
  OIDC_ISSUER=$(aws eks describe-cluster --name "${cluster}" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)
  
  # b. Delete Kubernetes workloads
  # Since the API server might be inaccessible and we want to remove the cluster anyway, 
  # we skip attempting to use kubectl to delete workloads and rely on AWS resource deletion.
  
  if [[ -n "${VPC_ID}" ]] && [[ "${VPC_ID}" != "None" ]]; then
    echo "[INFO] 🕸️  VPC ID for cluster: ${VPC_ID}"
    
    # c. Delete Load Balancers (ELBv2)
    echo "[INFO] ⚖️  Cleaning up ALB/NLB..."
    local ALBS
    ALBS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null)
    for arn in ${ALBS}; do
      if [[ -n "${arn}" ]] && [[ "${arn}" != "None" ]]; then
        echo "Deleting ELBv2: ${arn}"
        aws elbv2 delete-load-balancer --load-balancer-arn "${arn}" || true
      fi
    done
    
    # Classic ELB
    echo "[INFO] ⚖️  Cleaning up Classic ELBs..."
    local CLB_NAMES
    CLB_NAMES=$(aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].LoadBalancerName" --output text 2>/dev/null)
    for name in ${CLB_NAMES}; do
      if [[ -n "${name}" ]] && [[ "${name}" != "None" ]]; then
        echo "Deleting Classic ELB: ${name}"
        aws elb delete-load-balancer --load-balancer-name "${name}" || true
      fi
    done

    # Wait 30s for LB draining / ENI release
    if [[ -n "${ALBS}" ]] || [[ -n "${CLB_NAMES}" ]]; then
      echo "[INFO] ⏳ Waiting 30s for Load Balancers to drain and release ENIs..."
      sleep 30
    fi
    
    # d. Delete Target Groups
    echo "[INFO] 🎯 Cleaning up Target Groups..."
    local TGS
    TGS=$(aws elbv2 describe-target-groups --query "TargetGroups[?VpcId=='${VPC_ID}'].TargetGroupArn" --output text 2>/dev/null)
    for arn in ${TGS}; do
      if [[ -n "${arn}" ]] && [[ "${arn}" != "None" ]]; then
        echo "Deleting Target Group: ${arn}"
        aws elbv2 delete-target-group --target-group-arn "${arn}" || true
      fi
    done
  fi

  # e. Delete EKS addons
  echo "[INFO] 🧩 Cleaning up EKS addons..."
  local ADDONS
  ADDONS=$(aws eks list-addons --cluster-name "${cluster}" --query 'addons[]' --output text 2>/dev/null)
  for addon in ${ADDONS}; do
    if [[ -n "${addon}" ]] && [[ "${addon}" != "None" ]]; then
      echo "Deleting EKS addon: ${addon}"
      aws eks delete-addon --cluster-name "${cluster}" --addon-name "${addon}" || true
    fi
  done
  
  # f. Delete self-managed node group (ASG)
  echo "[INFO] 💻 Cleaning up ASGs..."
  # MAPT tags ASGs with origin=mapt and kubernetes.io/cluster/<cluster-name>=owned
  local ASGS
  ASGS=$(aws autoscaling describe-auto-scaling-groups --filters "Name=tag:kubernetes.io/cluster/${cluster},Values=owned" --query 'AutoScalingGroups[].AutoScalingGroupName' --output text 2>/dev/null)
  for asg in ${ASGS}; do
    if [[ -n "${asg}" ]] && [[ "${asg}" != "None" ]]; then
      echo "Scaling down ASG: ${asg}"
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${asg}" --min-size 0 --desired-capacity 0 || true
      echo "Force deleting ASG: ${asg}"
      aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "${asg}" --force-delete || true
    fi
  done

  # g. Delete the EKS cluster
  echo "[INFO] 💥 Deleting EKS cluster..."
  aws eks delete-cluster --name "${cluster}" || true
  
  # Note: Wait can timeout, we don't want to block everything
  echo "[INFO] ⏳ Waiting up to 10m for cluster deletion..."
  timeout 600 aws eks wait cluster-deleted --name "${cluster}" || echo "[WARN] Cluster deletion wait timed out, proceeding anyway..."

  # h. Delete IAM OIDC providers (scoped to this cluster's OIDC issuer)
  echo "[INFO] 🔑 Cleaning up IAM OIDC providers..."
  if [[ -n "${OIDC_ISSUER}" ]] && [[ "${OIDC_ISSUER}" != "None" ]]; then
    # Extract the OIDC ID from the issuer URL (last path segment)
    local OIDC_ID
    OIDC_ID=$(echo "${OIDC_ISSUER}" | awk -F'/' '{print $NF}')
    local OIDCS
    OIDCS=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null)
    for arn in ${OIDCS}; do
      if [[ -n "${arn}" ]] && [[ "${arn}" != "None" ]]; then
        # Only delete OIDC providers that match this cluster's OIDC ID
        if [[ "${arn}" == *"${OIDC_ID}"* ]]; then
          echo "Deleting IAM OIDC Provider: ${arn}"
          aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${arn}" || true
        fi
      fi
    done
  else
    echo "[WARN] ⚠️ No OIDC issuer found for cluster ${cluster}, skipping OIDC cleanup"
  fi

  # i. Delete IAM roles (scoped to this cluster via kubernetes.io/cluster tag)
  echo "[INFO] 🎭 Cleaning up IAM roles..."
  local ROLES
  ROLES=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=origin,Values=mapt Key=projectName,Values=eks "Key=kubernetes.io/cluster/${cluster},Values=owned" --resource-type-filters iam:role --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | awk -F'/' '{print $NF}' || true)
  for role in ${ROLES}; do
    if [[ -n "${role}" ]] && [[ "${role}" != "None" ]]; then
      echo "Cleaning up role: ${role}"
      
      # Detach managed policies
      local POLICIES
      POLICIES=$(aws iam list-attached-role-policies --role-name "${role}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
      for policy in ${POLICIES}; do
        if [[ -n "${policy}" ]] && [[ "${policy}" != "None" ]]; then
          aws iam detach-role-policy --role-name "${role}" --policy-arn "${policy}" || true
        fi
      done
      
      # Delete inline policies
      local INLINES
      INLINES=$(aws iam list-role-policies --role-name "${role}" --query 'PolicyNames[]' --output text 2>/dev/null || true)
      for inline in ${INLINES}; do
        if [[ -n "${inline}" ]] && [[ "${inline}" != "None" ]]; then
          aws iam delete-role-policy --role-name "${role}" --policy-name "${inline}" || true
        fi
      done
      
      # Remove from instance profiles
      local PROFILES
      PROFILES=$(aws iam list-instance-profiles-for-role --role-name "${role}" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true)
      for profile in ${PROFILES}; do
        if [[ -n "${profile}" ]] && [[ "${profile}" != "None" ]]; then
          aws iam remove-role-from-instance-profile --role-name "${role}" --instance-profile-name "${profile}" || true
          aws iam delete-instance-profile --instance-profile-name "${profile}" || true
        fi
      done
      
      # Delete role
      aws iam delete-role --role-name "${role}" || true
    fi
  done

  # j. Delete IAM policies (scoped to this cluster via kubernetes.io/cluster tag)
  echo "[INFO] 📜 Cleaning up IAM policies..."
  local MAPT_POLICIES
  MAPT_POLICIES=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=origin,Values=mapt Key=projectName,Values=eks "Key=kubernetes.io/cluster/${cluster},Values=owned" --resource-type-filters iam:policy --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
  for policy_arn in ${MAPT_POLICIES}; do
    if [[ -n "${policy_arn}" ]] && [[ "${policy_arn}" != "None" ]]; then
      echo "Deleting IAM Policy: ${policy_arn}"
      aws iam delete-policy --policy-arn "${policy_arn}" || true
    fi
  done

  # k. Clean up VPC resources
  if [[ -n "${VPC_ID}" ]] && [[ "${VPC_ID}" != "None" ]]; then
    echo "[INFO] 🌐 Cleaning up VPC resources for ${VPC_ID}..."
    
    # ENIs
    local ENIS
    ENIS=$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values="${VPC_ID}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
    for eni in ${ENIS}; do
      if [[ -n "${eni}" ]] && [[ "${eni}" != "None" ]]; then
        local ATTACHMENT
        ATTACHMENT=$(aws ec2 describe-network-interfaces --network-interface-ids "${eni}" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
        if [[ -n "${ATTACHMENT}" ]] && [[ "${ATTACHMENT}" != "None" ]]; then
          aws ec2 detach-network-interface --attachment-id "${ATTACHMENT}" --force || true
          sleep 5 # Wait a bit after detaching
        fi
        aws ec2 delete-network-interface --network-interface-id "${eni}" || true
      fi
    done
    
    # Security Groups
    local SGS
    SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="${VPC_ID}" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)
    # First pass: revoke all rules to break circular refs
    for sg in ${SGS}; do
      if [[ -n "${sg}" ]] && [[ "${sg}" != "None" ]]; then
        local INGRESS
        INGRESS=$(aws ec2 describe-security-groups --group-ids "${sg}" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo "[]")
        if [[ "${INGRESS}" != "[]" ]] && [[ "${INGRESS}" != "null" ]]; then
          aws ec2 revoke-security-group-ingress --group-id "${sg}" --ip-permissions "${INGRESS}" || true
        fi
        
        local EGRESS
        EGRESS=$(aws ec2 describe-security-groups --group-ids "${sg}" --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null || echo "[]")
        if [[ "${EGRESS}" != "[]" ]] && [[ "${EGRESS}" != "null" ]]; then
          aws ec2 revoke-security-group-egress --group-id "${sg}" --ip-permissions "${EGRESS}" || true
        fi
      fi
    done
    # Second pass: delete
    for sg in ${SGS}; do
      if [[ -n "${sg}" ]] && [[ "${sg}" != "None" ]]; then
        aws ec2 delete-security-group --group-id "${sg}" || true
      fi
    done
    
    # Subnets
    local SUBNETS
    SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)
    for subnet in ${SUBNETS}; do
      if [[ -n "${subnet}" ]] && [[ "${subnet}" != "None" ]]; then
        aws ec2 delete-subnet --subnet-id "${subnet}" || true
      fi
    done
    
    # Internet Gateways
    local IGS
    IGS=$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="${VPC_ID}" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)
    for ig in ${IGS}; do
      if [[ -n "${ig}" ]] && [[ "${ig}" != "None" ]]; then
        aws ec2 detach-internet-gateway --internet-gateway-id "${ig}" --vpc-id "${VPC_ID}" || true
        aws ec2 delete-internet-gateway --internet-gateway-id "${ig}" || true
      fi
    done
    
    # Route Tables
    local RTS
    RTS=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="${VPC_ID}" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null || true)
    for rt in ${RTS}; do
      if [[ -n "${rt}" ]] && [[ "${rt}" != "None" ]]; then
        aws ec2 delete-route-table --route-table-id "${rt}" || true
      fi
    done
    
    # VPC
    echo "Deleting VPC: ${VPC_ID}"
    aws ec2 delete-vpc --vpc-id "${VPC_ID}" || true
  fi

  # l. Delete launch templates (scoped to this cluster via kubernetes.io/cluster tag)
  echo "[INFO] 🚀 Cleaning up launch templates..."
  local LTS
  LTS=$(aws ec2 describe-launch-templates --filters Name=tag:origin,Values=mapt Name=tag:projectName,Values=eks "Name=tag:kubernetes.io/cluster/${cluster},Values=owned" --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null || true)
  for lt in ${LTS}; do
    if [[ -n "${lt}" ]] && [[ "${lt}" != "None" ]]; then
      aws ec2 delete-launch-template --launch-template-id "${lt}" || true
    fi
  done

  echo "[INFO] ✅ Finished cleanup for cluster: ${cluster}"
}

for cluster in "${ORPHANED_CLUSTERS[@]}"; do
  # Run in a subshell so set -e state of the parent is never affected
  (clean_cluster "${cluster}") || FAILED_CLUSTERS+=("${cluster}")
  TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
done

##############################################################################
# Phase 3: Summary
##############################################################################
echo "[INFO] =========================================================="
echo "[INFO] 📊 Cleanup Summary"
echo "[INFO] =========================================================="
echo "Total orphaned clusters found: ${#ORPHANED_CLUSTERS[@]}"
echo "Total clusters processed: ${TOTAL_PROCESSED}"

if [[ ${#FAILED_CLUSTERS[@]} -gt 0 ]]; then
  echo "[WARN] ⚠️ Some clusters encountered errors during cleanup:"
  for failed in "${FAILED_CLUSTERS[@]}"; do
    echo "  - ${failed}"
  done
else
  echo "[SUCCESS] ✅ All discovered orphaned clusters processed successfully."
fi

echo "aws-cleanup: ${TOTAL_PROCESSED} clusters processed, ${#FAILED_CLUSTERS[@]} failed" > "${ARTIFACT_DIR}/aws-cleanup-summary.txt"

# Always exit 0 to prevent failing the periodic job
exit 0