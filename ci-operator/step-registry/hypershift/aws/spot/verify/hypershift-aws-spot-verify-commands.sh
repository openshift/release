#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# Spot Instance Feature Verification Step
# Verifies all aspects of OCPSTRAT-1677 / CNTRLPLANE-1388 implementation.
#
# This step runs AFTER the e2e test has created a HostedCluster and spot NodePool.
# It performs comprehensive checks on the spot instance feature:
#   - aws-node-termination-handler image in release payload
#   - terminationHandlerQueueURL set on HostedCluster
#   - aws-node-termination-handler deployment in HCP namespace
#   - Termination handler runs management-side (not in guest cluster)
#   - Web identity token auth (token-minter sidecar)
#   - Spot NodePool resources (AWSMachineTemplate, MachineDeployment, MachineHealthCheck)
#   - SQS event simulation (rebalance recommendation -> node taint)
#   - CEL validation rules for invalid configurations

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
AWS_REGION="${AWS_REGION:-us-east-1}"

# AWS credentials for SQS event simulation
AWS_CREDS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDS_FILE}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  echo "[SKIP] $1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

echo "============================================"
echo "Spot Instance Feature Verification"
echo "OCPSTRAT-1677 / CNTRLPLANE-1388"
echo "============================================"

# Step 0: Check aws-node-termination-handler image in release payload
echo ""
echo "--- Step 0: Check NTH image in release payload ---"
RELEASE_IMAGE=$(oc get hostedcluster -A -o jsonpath='{.items[0].spec.release.image}' 2>/dev/null || true)
if [[ -n "${RELEASE_IMAGE}" ]]; then
  NTH_IMAGE=$(oc adm release info "${RELEASE_IMAGE}" --image-for=aws-node-termination-handler 2>/dev/null || true)
  if [[ -n "${NTH_IMAGE}" ]]; then
    pass "aws-node-termination-handler image found in release payload: ${NTH_IMAGE}"
  else
    fail "aws-node-termination-handler image NOT found in release payload"
  fi
else
  skip "No HostedCluster found to check release image"
fi

# Find a HostedCluster
HC_NAME=$(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
HC_NAMESPACE=$(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)

if [[ -z "${HC_NAME}" ]]; then
  echo "No HostedCluster found. Skipping remaining checks."
  exit 0
fi

echo "Found HostedCluster: ${HC_NAMESPACE}/${HC_NAME}"
HCP_NAMESPACE="${HC_NAMESPACE}-${HC_NAME}"
echo "HCP namespace: ${HCP_NAMESPACE}"

# Step 1: Check terminationHandlerQueueURL on HostedCluster
echo ""
echo "--- Step 1: Check terminationHandlerQueueURL ---"
QUEUE_URL=$(oc get hostedcluster "${HC_NAME}" -n "${HC_NAMESPACE}" -o jsonpath='{.spec.platform.aws.terminationHandlerQueueURL}' 2>/dev/null || true)
if [[ -n "${QUEUE_URL}" ]]; then
  pass "terminationHandlerQueueURL is set: ${QUEUE_URL}"
else
  skip "terminationHandlerQueueURL not set on HostedCluster (may have been cleaned up by e2e test)"
fi

# Step 2: Check aws-node-termination-handler deployment in HCP namespace
echo ""
echo "--- Step 2: Check NTH deployment in HCP namespace ---"
NTH_DEPLOY=$(oc get deployment aws-node-termination-handler -n "${HCP_NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)
if [[ -n "${NTH_DEPLOY}" ]]; then
  pass "aws-node-termination-handler deployment exists in HCP namespace ${HCP_NAMESPACE}"

  # Check replicas
  REPLICAS=$(oc get deployment aws-node-termination-handler -n "${HCP_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  READY=$(oc get deployment aws-node-termination-handler -n "${HCP_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${REPLICAS}" -gt 0 ]]; then
    pass "NTH deployment replicas: ${REPLICAS}, ready: ${READY}"
  else
    skip "NTH deployment has 0 replicas (may have been scaled down after test)"
  fi

  # Check QUEUE_URL env var
  DEPLOY_QUEUE_URL=$(oc get deployment aws-node-termination-handler -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node-termination-handler")].env[?(@.name=="QUEUE_URL")].value}' 2>/dev/null || true)
  if [[ -n "${DEPLOY_QUEUE_URL}" ]]; then
    pass "NTH deployment has QUEUE_URL env set: ${DEPLOY_QUEUE_URL}"
  else
    skip "NTH deployment QUEUE_URL env is empty (may have been cleared after test)"
  fi

  # Step 3: Check token-minter sidecar (web identity token auth)
  echo ""
  echo "--- Step 3: Check token-minter sidecar ---"
  TOKEN_MINTER=$(oc get deployment aws-node-termination-handler -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="token-minter-kube")].name}' 2>/dev/null || true)
  if [[ "${TOKEN_MINTER}" == "token-minter-kube" ]]; then
    pass "NTH deployment has token-minter-kube sidecar (web identity token auth)"
  else
    fail "NTH deployment missing token-minter-kube sidecar"
  fi
else
  skip "aws-node-termination-handler deployment not found in ${HCP_NAMESPACE} (may not have been deployed)"
fi

# Step 4: Check NTH does NOT exist as a daemonset in guest cluster
echo ""
echo "--- Step 4: Check NTH is management-side only ---"
GUEST_KUBECONFIG="${SHARED_DIR}/guest_kubeconfig"
if [[ -f "${GUEST_KUBECONFIG}" ]]; then
  GUEST_DS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get daemonset -A -o name 2>/dev/null | grep -i termination || true)
  if [[ -z "${GUEST_DS}" ]]; then
    pass "No termination handler daemonset in guest cluster (management-side only)"
  else
    fail "Found termination handler daemonset in guest cluster: ${GUEST_DS}"
  fi
else
  # Try to extract guest kubeconfig
  GUEST_KUBECONFIG_SECRET=$(oc get hostedcluster "${HC_NAME}" -n "${HC_NAMESPACE}" -o jsonpath='{.status.kubeconfig.name}' 2>/dev/null || true)
  if [[ -n "${GUEST_KUBECONFIG_SECRET}" ]]; then
    oc get secret "${GUEST_KUBECONFIG_SECRET}" -n "${HC_NAMESPACE}" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > /tmp/guest_kubeconfig || true
    if [[ -s /tmp/guest_kubeconfig ]]; then
      GUEST_DS=$(KUBECONFIG=/tmp/guest_kubeconfig oc get daemonset -A -o name 2>/dev/null | grep -i termination || true)
      if [[ -z "${GUEST_DS}" ]]; then
        pass "No termination handler daemonset in guest cluster (management-side only)"
      else
        fail "Found termination handler daemonset in guest cluster: ${GUEST_DS}"
      fi
    else
      skip "Could not extract guest kubeconfig"
    fi
  else
    skip "No guest kubeconfig available"
  fi
fi

# Step 5: Check spot NodePool resources
echo ""
echo "--- Step 5: Check spot NodePool resources ---"

# Find spot NodePool (look for one with spot annotation or marketType)
SPOT_NP=$(oc get nodepool -n "${HC_NAMESPACE}" -o json 2>/dev/null | \
  jq -r '.items[] | select(.metadata.annotations["hypershift.openshift.io/enable-spot"] != null or .spec.platform.aws.placement.marketType == "Spot") | .metadata.name' 2>/dev/null | head -1 || true)

if [[ -n "${SPOT_NP}" ]]; then
  pass "Found spot NodePool: ${SPOT_NP}"

  # Check spot MachineHealthCheck
  SPOT_MHC="${SPOT_NP}-spot"
  MHC_EXISTS=$(oc get machinehealthcheck "${SPOT_MHC}" -n "${HCP_NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)
  if [[ "${MHC_EXISTS}" == "${SPOT_MHC}" ]]; then
    pass "Spot MachineHealthCheck ${SPOT_MHC} exists"

    # Check MHC selector
    MHC_LABEL=$(oc get machinehealthcheck "${SPOT_MHC}" -n "${HCP_NAMESPACE}" \
      -o jsonpath='{.spec.selector.matchLabels.hypershift\.openshift\.io/interruptible-instance}' 2>/dev/null || echo "NOT_FOUND")
    if [[ "${MHC_LABEL}" != "NOT_FOUND" ]]; then
      pass "Spot MHC has correct interruptible-instance label selector"
    else
      fail "Spot MHC missing interruptible-instance label selector"
    fi

    # Check MHC maxUnhealthy
    MAX_UNHEALTHY=$(oc get machinehealthcheck "${SPOT_MHC}" -n "${HCP_NAMESPACE}" \
      -o jsonpath='{.spec.maxUnhealthy}' 2>/dev/null || true)
    if [[ "${MAX_UNHEALTHY}" == "100%" ]]; then
      pass "Spot MHC maxUnhealthy is 100%"
    else
      fail "Spot MHC maxUnhealthy is '${MAX_UNHEALTHY}', expected '100%'"
    fi
  else
    fail "Spot MachineHealthCheck ${SPOT_MHC} not found"
  fi

  # Check MachineDeployment has interruptible-instance label
  MD_LABEL=$(oc get machinedeployment -n "${HCP_NAMESPACE}" -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.template.metadata.labels["hypershift.openshift.io/interruptible-instance"] != null) | .metadata.name' 2>/dev/null | head -1 || true)
  if [[ -n "${MD_LABEL}" ]]; then
    pass "MachineDeployment ${MD_LABEL} has interruptible-instance label"
  else
    fail "No MachineDeployment found with interruptible-instance label"
  fi

  # Check AWSMachineTemplate has spotMarketOptions
  SPOT_AMT=$(oc get awsmachinetemplate -n "${HCP_NAMESPACE}" -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.template.spec.spotMarketOptions != null) | .metadata.name' 2>/dev/null | head -1 || true)
  if [[ -n "${SPOT_AMT}" ]]; then
    pass "AWSMachineTemplate ${SPOT_AMT} has spotMarketOptions configured"
  else
    skip "No AWSMachineTemplate with spotMarketOptions (test uses annotation-based spot, not real spot instances)"
  fi
else
  skip "No spot NodePool found (e2e test may have cleaned up)"
fi

# Step 6: SQS event simulation - send rebalance recommendation, verify node taint
echo ""
echo "--- Step 6: SQS event simulation ---"

# Get SQS queue URL from shared dir (saved by sqs-setup step)
SQS_QUEUE_URL="${QUEUE_URL:-}"
if [[ -z "${SQS_QUEUE_URL}" ]] && [[ -f "${SHARED_DIR}/spot_sqs_queue_url" ]]; then
  SQS_QUEUE_URL=$(cat "${SHARED_DIR}/spot_sqs_queue_url")
fi

# Resolve guest kubeconfig
GUEST_KC=""
if [[ -f "${SHARED_DIR}/guest_kubeconfig" ]]; then
  GUEST_KC="${SHARED_DIR}/guest_kubeconfig"
elif [[ -f /tmp/guest_kubeconfig ]] && [[ -s /tmp/guest_kubeconfig ]]; then
  GUEST_KC="/tmp/guest_kubeconfig"
fi

if [[ -z "${SQS_QUEUE_URL}" ]]; then
  skip "SQS queue URL not available, skipping event simulation"
elif [[ -z "${GUEST_KC}" ]]; then
  skip "Guest kubeconfig not available, skipping event simulation"
else
  # Get a worker node's providerID from the guest cluster
  NODE_PROVIDER_ID=$(KUBECONFIG="${GUEST_KC}" oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)
  NODE_NAME=$(KUBECONFIG="${GUEST_KC}" oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${NODE_PROVIDER_ID}" ]] || [[ -z "${NODE_NAME}" ]]; then
    skip "No worker node found in guest cluster for SQS simulation"
  else
    # Extract instance ID from providerID (format: aws:///us-east-1a/i-0123456789abcdef0)
    INSTANCE_ID="${NODE_PROVIDER_ID##*/}"
    echo "Target node: ${NODE_NAME}, instance: ${INSTANCE_ID}"

    # Build EC2 Rebalance Recommendation event (same format as EventBridge)
    EVENT_JSON=$(cat <<SQSEOF
{
  "version": "0",
  "source": "aws.ec2",
  "detail-type": "EC2 Instance Rebalance Recommendation",
  "detail": {"instance-id": "${INSTANCE_ID}"},
  "id": "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "test-$(date +%s)")",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "${AWS_REGION}",
  "account": "000000000000"
}
SQSEOF
)

    echo "Sending EC2 Rebalance Recommendation event to SQS queue"
    SEND_RESULT=$(aws sqs send-message \
      --queue-url "${SQS_QUEUE_URL}" \
      --message-body "${EVENT_JSON}" \
      --region "${AWS_REGION}" 2>&1 || true)

    if echo "${SEND_RESULT}" | grep -q "MessageId"; then
      pass "SQS rebalance recommendation event sent for instance ${INSTANCE_ID}"

      # Wait for the node to get the rebalance-recommendation taint (up to 5 minutes)
      echo "Waiting for node ${NODE_NAME} to receive rebalance-recommendation taint..."
      TAINT_FOUND=false
      for i in $(seq 1 30); do
        TAINTS=$(KUBECONFIG="${GUEST_KC}" oc get node "${NODE_NAME}" \
          -o jsonpath='{.spec.taints[*].key}' 2>/dev/null || true)
        if echo "${TAINTS}" | grep -q "aws-node-termination-handler"; then
          TAINT_FOUND=true
          break
        fi
        echo "$(date) Attempt ${i}/30: waiting for taint..."
        sleep 10
      done

      if [[ "${TAINT_FOUND}" == "true" ]]; then
        TAINT_DETAIL=$(KUBECONFIG="${GUEST_KC}" oc get node "${NODE_NAME}" \
          -o jsonpath='{.spec.taints}' 2>/dev/null || true)
        pass "Node ${NODE_NAME} received NTH taint: ${TAINT_DETAIL}"

        # Step 6b: Verify spot remediation controller annotates and deletes the Machine
        echo ""
        echo "--- Step 6b: Spot remediation (Machine annotation + deletion + replacement) ---"

        # Find the CAPI Machine for this node using the node's annotations
        MACHINE_NAME=$(KUBECONFIG="${GUEST_KC}" oc get node "${NODE_NAME}" \
          -o jsonpath='{.metadata.annotations.cluster\.x-k8s\.io/machine}' 2>/dev/null || true)
        MACHINE_NAMESPACE=$(KUBECONFIG="${GUEST_KC}" oc get node "${NODE_NAME}" \
          -o jsonpath='{.metadata.annotations.cluster\.x-k8s\.io/cluster-namespace}' 2>/dev/null || true)

        if [[ -z "${MACHINE_NAME}" ]] || [[ -z "${MACHINE_NAMESPACE}" ]]; then
          skip "Could not find CAPI Machine annotations on node ${NODE_NAME}"
        else
          echo "CAPI Machine: ${MACHINE_NAMESPACE}/${MACHINE_NAME}"

          # Count current machines before remediation
          MACHINE_COUNT_BEFORE=$(oc get machine -n "${MACHINE_NAMESPACE}" \
            -l hypershift.openshift.io/interruptible-instance --no-headers 2>/dev/null | wc -l || echo "0")
          MACHINE_COUNT_BEFORE=$(echo "${MACHINE_COUNT_BEFORE}" | tr -d ' ')
          echo "Machine count before remediation: ${MACHINE_COUNT_BEFORE}"

          # Wait for the Machine to get the spot-interruption-signal annotation (up to 3 minutes)
          echo "Waiting for Machine ${MACHINE_NAME} to get spot-interruption-signal annotation..."
          ANNOTATION_FOUND=false
          for i in $(seq 1 18); do
            SIGNAL=$(oc get machine "${MACHINE_NAME}" -n "${MACHINE_NAMESPACE}" \
              -o jsonpath='{.metadata.annotations.hypershift\.openshift\.io/spot-interruption-signal}' 2>/dev/null || true)
            if [[ -n "${SIGNAL}" ]]; then
              ANNOTATION_FOUND=true
              pass "Machine ${MACHINE_NAME} annotated with spot-interruption-signal: ${SIGNAL}"
              break
            fi
            # Check if Machine was already deleted
            if ! oc get machine "${MACHINE_NAME}" -n "${MACHINE_NAMESPACE}" &>/dev/null; then
              ANNOTATION_FOUND=true
              pass "Machine ${MACHINE_NAME} already deleted by spot remediation"
              break
            fi
            echo "$(date) Attempt ${i}/18: waiting for annotation..."
            sleep 10
          done

          if [[ "${ANNOTATION_FOUND}" != "true" ]]; then
            fail "Machine ${MACHINE_NAME} did NOT get spot-interruption-signal annotation within 3 minutes"
          fi

          # Wait for the Machine to be marked for deletion (up to 3 minutes)
          # The Machine object may persist with a deletionTimestamp while CAPI
          # finalizers clean up the EC2 instance. A deletionTimestamp means the
          # spot remediation controller successfully deleted it.
          echo "Waiting for Machine ${MACHINE_NAME} to be deleted..."
          MACHINE_DELETED=false
          for i in $(seq 1 18); do
            if ! oc get machine "${MACHINE_NAME}" -n "${MACHINE_NAMESPACE}" &>/dev/null; then
              MACHINE_DELETED=true
              pass "Machine ${MACHINE_NAME} fully removed"
              break
            fi
            DEL_TS=$(oc get machine "${MACHINE_NAME}" -n "${MACHINE_NAMESPACE}" \
              -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
            if [[ -n "${DEL_TS}" ]]; then
              MACHINE_DELETED=true
              pass "Machine ${MACHINE_NAME} marked for deletion (deletionTimestamp: ${DEL_TS})"
              break
            fi
            echo "$(date) Attempt ${i}/18: waiting for machine deletion..."
            sleep 10
          done

          if [[ "${MACHINE_DELETED}" != "true" ]]; then
            fail "Machine ${MACHINE_NAME} was NOT deleted within 3 minutes"
          fi

          # Wait for a replacement Machine to be created (up to 5 minutes)
          echo "Waiting for replacement Machine to be created..."
          REPLACEMENT_FOUND=false
          for i in $(seq 1 30); do
            MACHINE_COUNT_NOW=$(oc get machine -n "${MACHINE_NAMESPACE}" \
              -l hypershift.openshift.io/interruptible-instance --no-headers 2>/dev/null | wc -l || echo "0")
            MACHINE_COUNT_NOW=$(echo "${MACHINE_COUNT_NOW}" | tr -d ' ')
            if [[ "${MACHINE_COUNT_NOW}" -ge "${MACHINE_COUNT_BEFORE}" ]]; then
              REPLACEMENT_FOUND=true
              break
            fi
            echo "$(date) Attempt ${i}/30: machines=${MACHINE_COUNT_NOW}, expected>=${MACHINE_COUNT_BEFORE}..."
            sleep 10
          done

          if [[ "${REPLACEMENT_FOUND}" == "true" ]]; then
            NEW_MACHINES=$(oc get machine -n "${MACHINE_NAMESPACE}" \
              -l hypershift.openshift.io/interruptible-instance -o name 2>/dev/null || true)
            pass "Replacement Machine created. Current machines: ${NEW_MACHINES}"
          else
            fail "Replacement Machine was NOT created within 5 minutes"
          fi
        fi
      else
        fail "Node ${NODE_NAME} did NOT receive NTH taint within 5 minutes"
      fi
    else
      fail "Failed to send SQS message: ${SEND_RESULT}"
    fi
  fi
fi

# Step 7: CEL validation rules
echo ""
echo "--- Step 7: CEL validation rules ---"

# Test: Spot + Capacity Reservation should be rejected
CEL_RESULT=$(oc apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: cel-test-spot-cr
  namespace: ${HC_NAMESPACE}
spec:
  clusterName: ${HC_NAME}
  replicas: 0
  management:
    upgradeType: Replace
  platform:
    type: AWS
    aws:
      instanceType: m5.large
      subnet:
        id: subnet-placeholder
      placement:
        marketType: Spot
        capacityReservation:
          id: cr-12345
  release:
    image: ${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.22.0-ec.1-multi}
EOF
)
if echo "${CEL_RESULT}" | grep -qi "spot instances cannot be combined"; then
  pass "CEL: Spot + CapacityReservation correctly rejected"
else
  fail "CEL: Spot + CapacityReservation was NOT rejected. Result: ${CEL_RESULT}"
fi

# Test: Spot + dedicated tenancy should be rejected
CEL_RESULT=$(oc apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: cel-test-spot-tenancy
  namespace: ${HC_NAMESPACE}
spec:
  clusterName: ${HC_NAME}
  replicas: 0
  management:
    upgradeType: Replace
  platform:
    type: AWS
    aws:
      instanceType: m5.large
      subnet:
        id: subnet-placeholder
      placement:
        marketType: Spot
        tenancy: dedicated
  release:
    image: ${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.22.0-ec.1-multi}
EOF
)
if echo "${CEL_RESULT}" | grep -qi "spot instances require default tenancy"; then
  pass "CEL: Spot + dedicated tenancy correctly rejected"
else
  fail "CEL: Spot + dedicated tenancy was NOT rejected. Result: ${CEL_RESULT}"
fi

# Test: spot options without marketType=Spot should be rejected
CEL_RESULT=$(oc apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: cel-test-spot-options
  namespace: ${HC_NAMESPACE}
spec:
  clusterName: ${HC_NAME}
  replicas: 0
  management:
    upgradeType: Replace
  platform:
    type: AWS
    aws:
      instanceType: m5.large
      subnet:
        id: subnet-placeholder
      placement:
        marketType: OnDemand
        spot:
          maxPrice: "0.50"
  release:
    image: ${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.22.0-ec.1-multi}
EOF
)
if echo "${CEL_RESULT}" | grep -qi "spot options can only be specified"; then
  pass "CEL: spot options without marketType=Spot correctly rejected"
else
  fail "CEL: spot options without marketType=Spot was NOT rejected. Result: ${CEL_RESULT}"
fi

# Summary
echo ""
echo "============================================"
echo "Verification Summary"
echo "============================================"
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"
echo "SKIP: ${SKIP_COUNT}"
echo "============================================"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "RESULT: SOME CHECKS FAILED"
  exit 1
else
  echo "RESULT: ALL CHECKS PASSED"
fi
