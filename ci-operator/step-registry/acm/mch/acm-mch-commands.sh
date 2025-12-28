#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

DEFAULT_OPERATOR_SOURCE="redhat-operators"
DEFAULT_OPERATOR_SOURCE_DISPLAY="Red Hat Operators"

namespaces_to_check=(
  "${MCH_NAMESPACE}"
  "multicluster-engine"
)

function get_failed_pods_by_name {
  oc get pods \
    -n ${1} \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

function dump_multiclusterhub_pod_logs {
  echo
  echo "Dumping logs for failing PODs..."
  echo
  for ns in "${namespaces_to_check[@]}"; do
   for failed_pod_name in $(get_failed_pods_by_name ${ns}); do
     echo "Gathering '${failed_pod_name}' POD logs in the '${ns}' namespace..."
     echo
     set -x
     oc -n ${ns} describe pod/${failed_pod_name} > ${ARTIFACT_DIR}/${ns}_${failed_pod_name}.describe.txt
     oc -n ${ns} logs pods/$failed_pod_name > ${ARTIFACT_DIR}/${ns}_${failed_pod_name}.logs
     set +x
     echo
   done
  done
}

function show_multiclusterhub_related_objects {
  echo
  echo "### $(date) ###"
  echo
  set -x
  oc get clusterversions,node,mcp,co,operators || echo
  oc get subscriptions.operators.coreos.com -A || echo
  oc get ClusterManagementAddOn || echo
  oc get operator advanced-cluster-management.open-cluster-management -oyaml || echo
  oc get operator multicluster-engine.multicluster-engine -oyaml || echo
  oc -n ${MCH_NAMESPACE} get mch multiclusterhub -oyaml || echo
  set +x
  echo
  for ns in "${namespaces_to_check[@]}"; do
    echo
    echo "------ ${ns} namespace ------"
    echo
    set -x
    oc -n ${ns} get configmaps,secrets,all || echo
    set +x
  done
}

###############################################################################
# WORKAROUND FRAMEWORK
#
# Workarounds are opt-in via the ENABLE_WORKAROUND_LIST environment variable.
# This ensures workarounds are explicitly enabled and easily traceable.
#
# Format: ENABLE_WORKAROUND_LIST="[72976, 12345]" (list of PR numbers)
# Default: "[]" (no workarounds enabled)
#
# To enable a workaround:
#   1. Add the PR number to ENABLE_WORKAROUND_LIST in the Prow config
#   2. Once the upstream fix is released, remove the PR from the list
###############################################################################

# Check if a workaround is enabled by its PR number
# Usage: is_workaround_enabled 72976
function is_workaround_enabled {
  local pr_number="$1"
  local workaround_list="${ENABLE_WORKAROUND_LIST:-[]}"

  # Check if the PR number is in the list
  # The list format is "[72976, 12345]" or "[72976]" or "[]"
  if [[ "${workaround_list}" =~ (^|[^0-9])${pr_number}([^0-9]|$) ]]; then
    echo "Workaround PR #${pr_number} is ENABLED (ENABLE_WORKAROUND_LIST=${workaround_list})"
    return 0
  else
    echo "Workaround PR #${pr_number} is DISABLED (ENABLE_WORKAROUND_LIST=${workaround_list})"
    return 1
  fi
}

###############################################################################
# WORKAROUND: OCM CA Bundle Race Condition
#
# CI Workaround PR: https://github.com/openshift/release/pull/72976
# Upstream Fix PR: https://github.com/open-cluster-management-io/ocm/pull/1309
#
# Problem: The cluster-manager controller has a race condition where it may
# create CRDs with an invalid "placeholder" CA bundle before the cert rotation
# controller creates the actual CA bundle ConfigMap. This causes:
#   1. CRDs to have caBundle: cGxhY2Vob2xkZXI= (base64 of "placeholder")
#   2. Webhook conversion fails with "InvalidCABundle"
#   3. CRDs not becoming Established
#   4. MCH fails with: "no matches for kind ClusterManagementAddOn"
#
# This workaround detects and remediates the issue by:
#   1. Checking if CRDs have the placeholder CA bundle
#   2. Patching webhook services with serving-cert-secret-name annotation
#   3. Waiting for secrets to be created by service-ca-operator
#   4. Extracting real CA bundle and patching CRDs
#   5. Restarting MCE operator to force reconciliation
#
# Enable by adding 72976 to ENABLE_WORKAROUND_LIST in Prow config.
# Once upstream fix is released in ACM/MCE, remove 72976 from the list.
###############################################################################

CLUSTER_MANAGER_NAMESPACE="open-cluster-management-hub"
PLACEHOLDER_CABUNDLE="cGxhY2Vob2xkZXI="  # base64 of "placeholder"

# Check if a CRD has the placeholder CA bundle (indicating the race condition)
function is_crd_cabundle_placeholder {
  local crd_name="$1"
  local current_cabundle
  current_cabundle=$(oc get crd "${crd_name}" -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null || echo "")

  if [[ "${current_cabundle}" == "${PLACEHOLDER_CABUNDLE}" ]]; then
    return 0  # true - has placeholder
  fi
  return 1  # false - does not have placeholder
}

# Check if the OCM CA bundle race condition is present
function detect_ocm_cabundle_race_condition {
  echo "Checking for OCM CA bundle race condition (PR #1309)..."

  # Check if ClusterManagementAddOn CRD exists and has placeholder caBundle
  if oc get crd clustermanagementaddons.addon.open-cluster-management.io &>/dev/null; then
    if is_crd_cabundle_placeholder "clustermanagementaddons.addon.open-cluster-management.io"; then
      echo "DETECTED: clustermanagementaddons CRD has placeholder CA bundle"
      return 0
    fi
  fi

  # Check if ManagedClusterAddOn CRD exists and has placeholder caBundle
  if oc get crd managedclusteraddons.addon.open-cluster-management.io &>/dev/null; then
    if is_crd_cabundle_placeholder "managedclusteraddons.addon.open-cluster-management.io"; then
      echo "DETECTED: managedclusteraddons CRD has placeholder CA bundle"
      return 0
    fi
  fi

  echo "No CA bundle race condition detected"
  return 1
}

# Patch a webhook service with the serving-cert-secret-name annotation
function patch_webhook_service_annotation {
  local service_name="$1"
  local secret_name="$2"

  echo "Patching service ${service_name} with serving-cert-secret-name annotation..."

  # Check if annotation already exists
  local current_annotation
  current_annotation=$(oc get svc -n "${CLUSTER_MANAGER_NAMESPACE}" "${service_name}" \
    -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}' 2>/dev/null || echo "")

  if [[ -n "${current_annotation}" ]]; then
    echo "  Service ${service_name} already has annotation: ${current_annotation}"
    return 0
  fi

  oc patch svc -n "${CLUSTER_MANAGER_NAMESPACE}" "${service_name}" \
    --type=merge \
    -p "{\"metadata\":{\"annotations\":{\"service.beta.openshift.io/serving-cert-secret-name\":\"${secret_name}\"}}}"

  echo "  Patched ${service_name} with secret ${secret_name}"
}

# Wait for a secret to be created by service-ca-operator
function wait_for_secret {
  local secret_name="$1"
  local timeout="${2:-120}"

  echo "Waiting for secret ${secret_name} to be created (timeout: ${timeout}s)..."

  if oc wait --for=jsonpath='{.data.tls\.crt}' \
      -n "${CLUSTER_MANAGER_NAMESPACE}" \
      "secret/${secret_name}" \
      --timeout="${timeout}s" 2>/dev/null; then
    echo "  Secret ${secret_name} is ready"
    return 0
  else
    echo "  WARNING: Secret ${secret_name} not ready after ${timeout}s"
    return 1
  fi
}

# Extract CA bundle from a secret and patch a CRD
function patch_crd_cabundle {
  local crd_name="$1"
  local secret_name="$2"

  echo "Patching CRD ${crd_name} with CA bundle from secret ${secret_name}..."

  # Extract the CA bundle from the secret (base64 encoded)
  local ca_bundle
  ca_bundle=$(oc get secret -n "${CLUSTER_MANAGER_NAMESPACE}" "${secret_name}" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")

  if [[ -z "${ca_bundle}" ]]; then
    echo "  ERROR: Could not extract CA bundle from secret ${secret_name}"
    return 1
  fi

  # Patch the CRD with the real CA bundle
  oc patch crd "${crd_name}" --type=json \
    -p "[{\"op\": \"replace\", \"path\": \"/spec/conversion/webhook/clientConfig/caBundle\", \"value\": \"${ca_bundle}\"}]"

  echo "  Patched ${crd_name} with CA bundle from ${secret_name}"
}

# Force MCE operator to reconcile
function force_mce_reconciliation {
  echo "Forcing MCE operator to reconcile..."

  # Restart the MCE operator deployment
  local mce_namespace="multicluster-engine"
  if oc get deployment -n "${mce_namespace}" multicluster-engine-operator &>/dev/null; then
    oc rollout restart deployment/multicluster-engine-operator -n "${mce_namespace}"
    echo "  Restarted multicluster-engine-operator deployment"

    # Wait for rollout to complete
    oc rollout status deployment/multicluster-engine-operator -n "${mce_namespace}" --timeout=120s || true
  fi

  # Force reconciliation by annotating the MCE resource
  local mce_name
  mce_name=$(oc get multiclusterengine -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${mce_name}" ]]; then
    oc annotate multiclusterengine "${mce_name}" \
      "workaround.ocm.io/force-reconcile=$(date +%s)" \
      --overwrite
    echo "  Annotated multiclusterengine/${mce_name} to force reconciliation"
  fi
}

# Main workaround function for OCM CA bundle race condition
# Returns 0 if workaround was applied, 1 if not needed or failed
function apply_ocm_cabundle_workaround {
  echo ""
  echo "============================================================"
  echo "Applying OCM CA Bundle Race Condition Workaround"
  echo "Upstream fix: https://github.com/open-cluster-management-io/ocm/pull/1309"
  echo "============================================================"
  echo ""

  # Step 1: Verify the race condition is present
  if ! detect_ocm_cabundle_race_condition; then
    echo "Workaround not needed - no race condition detected"
    return 1
  fi

  echo ""
  echo "Step 1/6: Patching webhook services with serving-cert-secret-name annotation..."

  # Define webhook services and their corresponding secrets
  # Format: "service_name:secret_name"
  local webhook_services=(
    "cluster-manager-addon-webhook:addon-webhook-serving-cert"
    "cluster-manager-registration-webhook:registration-webhook-serving-cert"
    "cluster-manager-work-webhook:work-webhook-serving-cert"
  )

  for entry in "${webhook_services[@]}"; do
    local svc_name="${entry%%:*}"
    local secret_name="${entry##*:}"

    if oc get svc -n "${CLUSTER_MANAGER_NAMESPACE}" "${svc_name}" &>/dev/null; then
      patch_webhook_service_annotation "${svc_name}" "${secret_name}"
    else
      echo "  Service ${svc_name} not found, skipping..."
    fi
  done

  echo ""
  echo "Step 2/6: Waiting for service-ca-operator to create secrets..."
  sleep 5  # Give service-ca-operator time to notice the annotation

  for entry in "${webhook_services[@]}"; do
    local svc_name="${entry%%:*}"
    local secret_name="${entry##*:}"

    if oc get svc -n "${CLUSTER_MANAGER_NAMESPACE}" "${svc_name}" &>/dev/null; then
      wait_for_secret "${secret_name}" 60 || true
    fi
  done

  echo ""
  echo "Step 3/6: Creating ca-bundle-configmap from serving cert..."

  # The cluster-manager controller reads CA from ca-bundle-configmap.
  # If this ConfigMap doesn't exist or is empty, it uses "placeholder".
  # We need to create it from the serving cert secret.
  local ca_bundle_cm_exists
  ca_bundle_cm_exists=$(oc get configmap -n "${CLUSTER_MANAGER_NAMESPACE}" ca-bundle-configmap -o name 2>/dev/null || echo "")

  if [[ -z "${ca_bundle_cm_exists}" ]]; then
    echo "  ca-bundle-configmap does not exist, creating..."
    local ca_cert
    ca_cert=$(oc get secret -n "${CLUSTER_MANAGER_NAMESPACE}" addon-webhook-serving-cert \
      -o go-template='{{index .data "tls.crt"}}' 2>/dev/null | base64 -d || echo "")

    if [[ -n "${ca_cert}" ]]; then
      oc create configmap ca-bundle-configmap \
        -n "${CLUSTER_MANAGER_NAMESPACE}" \
        --from-literal="ca-bundle.crt=${ca_cert}"
      echo "  Created ca-bundle-configmap with CA from addon-webhook-serving-cert"
    else
      echo "  WARNING: Could not extract CA from addon-webhook-serving-cert"
    fi
  else
    # Check if the configmap is empty
    local cm_data
    cm_data=$(oc get configmap -n "${CLUSTER_MANAGER_NAMESPACE}" ca-bundle-configmap \
      -o go-template='{{index .data "ca-bundle.crt"}}' 2>/dev/null || echo "")

    if [[ -z "${cm_data}" || "${cm_data}" == "placeholder" ]]; then
      echo "  ca-bundle-configmap exists but is empty/placeholder, updating..."
      local ca_cert
      ca_cert=$(oc get secret -n "${CLUSTER_MANAGER_NAMESPACE}" addon-webhook-serving-cert \
        -o go-template='{{index .data "tls.crt"}}' 2>/dev/null | base64 -d || echo "")

      if [[ -n "${ca_cert}" ]]; then
        oc delete configmap -n "${CLUSTER_MANAGER_NAMESPACE}" ca-bundle-configmap
        oc create configmap ca-bundle-configmap \
          -n "${CLUSTER_MANAGER_NAMESPACE}" \
          --from-literal="ca-bundle.crt=${ca_cert}"
        echo "  Recreated ca-bundle-configmap with real CA"
      fi
    else
      echo "  ca-bundle-configmap already has valid CA data"
    fi
  fi

  echo ""
  echo "Step 4/6: Patching CRDs with real CA bundles..."

  # Patch ClusterManagementAddOn CRD
  if is_crd_cabundle_placeholder "clustermanagementaddons.addon.open-cluster-management.io"; then
    patch_crd_cabundle \
      "clustermanagementaddons.addon.open-cluster-management.io" \
      "addon-webhook-serving-cert" || true
  fi

  # Patch ManagedClusterAddOn CRD
  if is_crd_cabundle_placeholder "managedclusteraddons.addon.open-cluster-management.io"; then
    patch_crd_cabundle \
      "managedclusteraddons.addon.open-cluster-management.io" \
      "addon-webhook-serving-cert" || true
  fi

  echo ""
  echo "Step 5/6: Verifying CRDs are now Established..."
  sleep 5  # Give the API server time to process the changes

  local crds_ok=true
  for crd in "clustermanagementaddons.addon.open-cluster-management.io" "managedclusteraddons.addon.open-cluster-management.io"; do
    if oc get crd "${crd}" &>/dev/null; then
      local established
      established=$(oc get crd "${crd}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
      if [[ "${established}" == "True" ]]; then
        echo "  ${crd}: Established=True ✓"
      else
        echo "  ${crd}: Established=${established} ✗"
        crds_ok=false
      fi
    fi
  done

  echo ""
  echo "Step 6/6: Restarting cluster-manager and forcing reconciliation..."

  # Restart cluster-manager deployment to pick up the new ca-bundle-configmap
  # This ensures it stops trying to re-apply CRDs with placeholder CA
  echo "Restarting cluster-manager deployment..."
  if oc get deployment cluster-manager -n multicluster-engine &>/dev/null; then
    oc rollout restart deployment cluster-manager -n multicluster-engine
    echo "  Restarted cluster-manager deployment"
    oc rollout status deployment cluster-manager -n multicluster-engine --timeout=120s || true
  fi

  # Force MCE reconciliation
  force_mce_reconciliation

  echo ""
  if [[ "${crds_ok}" == "true" ]]; then
    echo "============================================================"
    echo "Workaround applied successfully!"
    echo "CRDs are now Established, MCH should progress normally."
    echo "============================================================"
  else
    echo "============================================================"
    echo "Workaround applied but some CRDs are not yet Established."
    echo "MCH will retry and should eventually succeed."
    echo "============================================================"
  fi
  echo ""

  return 0
}

# create image pull secret for MCH
oc create secret generic ${IMAGE_PULL_SECRET} -n ${MCH_NAMESPACE} --from-file=.dockerconfigjson=$CLUSTER_PROFILE_DIR/pull-secret --type=kubernetes.io/dockerconfigjson

annotations="annotations: {}"
if [ -n "${MCH_CATALOG_ANNOTATION}" ];then
  # Extract operator_source and operator_channel using the provided commands
  operator_name="multicluster-engine"

  # Prioritize the use of the default catalog
  operator_source=$(oc get packagemanifest | grep "${operator_name}.*${DEFAULT_OPERATOR_SOURCE_DISPLAY}" || echo)
  if [[ -n "${operator_source}" ]]; then
    operator_source="${DEFAULT_OPERATOR_SOURCE}" ;
  else
    operator_source=$(oc get packagemanifest ${operator_name} -ojsonpath='{.metadata.labels.catalog}' || echo)
    if [[ -z "${operator_source}" ]]; then
        echo "ERROR: '${operator_name}' packagemanifest not found in any available catalog"
        exit 1
    fi
  fi

  # 1. Check if "source": "!any" is found and substitute with "source": "${operator_source}"
  if [[ "$MCH_CATALOG_ANNOTATION" == *'"source": "!any"'* ]]; then
    MCH_CATALOG_ANNOTATION=${MCH_CATALOG_ANNOTATION//'"source": "!any"'/'"source": "'$operator_source'"'}
  # 2. Check if only "!any" (not within "source") is found and substitute with "${operator_source}"
  elif [[ "$MCH_CATALOG_ANNOTATION" == *'!any'* ]]; then
    MCH_CATALOG_ANNOTATION=${MCH_CATALOG_ANNOTATION//"!any"/"$operator_source"}
  else
    # To get current source value...
    # .. remove everything before "source": and after the value of source
    operator_source=${MCH_CATALOG_ANNOTATION#*\"source\": \"} # Remove the leading part
    operator_source=${operator_source%%\"*} # Remove the trailing part
  fi

  # 2. Check if "channel": "!default" is found and substitute with "channel": "${operator_channel}"
  if [[ "$MCH_CATALOG_ANNOTATION" == *'"channel": "!default"'* ]]; then
    operator_channel=$(oc get packagemanifest \
        -l catalog=${operator_source} \
        -ojsonpath='{.items[?(.metadata.name=="'${operator_name}'")].status.defaultChannel}')
    MCH_CATALOG_ANNOTATION=${MCH_CATALOG_ANNOTATION//'"channel": "!default"'/'"channel": "'$operator_channel'"'}
  fi

  annotations="annotations:
    installer.open-cluster-management.io/mce-subscription-spec: '${MCH_CATALOG_ANNOTATION}'"

  echo "Selecting '${MCH_CATALOG_ANNOTATION}' catalog for the '${operator_name}' packagemanifest"
fi

echo "Apply multiclusterhub"
# apply MultiClusterHub crd
oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${MCH_NAMESPACE}
  ${annotations}
spec:
  availabilityConfig: ${MCH_AVAILABILITY_CONFIG}
  imagePullSecret: ${IMAGE_PULL_SECRET}
EOF

{
  sleep 10 ;
  set -x ;
  oc -n ${MCH_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running mch/multiclusterhub --timeout 30m ;

} || {
  set +x ;
  echo ""
  echo "MCH did not reach Running status in the first attempt."
  echo "Checking for known issues and applying workarounds if needed..."
  echo ""

  workaround_applied=false

  # WORKAROUND PR #72976: OCM CA bundle race condition
  # Enable by setting: ENABLE_WORKAROUND_LIST="[72976]"
  if is_workaround_enabled 72976; then
    if apply_ocm_cabundle_workaround; then
      workaround_applied=true
    fi
  else
    # Check if the race condition exists but workaround is disabled
    if detect_ocm_cabundle_race_condition; then
      echo ""
      echo "WARNING: OCM CA bundle race condition detected but workaround is DISABLED."
      echo "To enable, set ENABLE_WORKAROUND_LIST=\"[72976]\" in Prow config."
      echo ""
    fi
  fi

  if [[ "${workaround_applied}" == "true" ]]; then
    echo ""
    echo "Workaround applied. Waiting for MCH to reach Running status (second attempt)..."
    echo ""

    # Wait again for MCH to reach Running status
    if oc -n ${MCH_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running mch/multiclusterhub --timeout 30m; then
      echo ""
      echo "MCH reached Running status after applying workaround!"
      echo ""
    else
      # Second attempt also failed - gather diagnostics and exit
      set +x ;
      show_multiclusterhub_related_objects ;
      dump_multiclusterhub_pod_logs ;
      echo "Error: MCH failed to reach Running status even after applying workaround." ;
      exit 1 ;
    fi
  else
    # No workaround was applicable or enabled - this is some other issue
    show_multiclusterhub_related_objects ;
    dump_multiclusterhub_pod_logs ;
    echo "Error: MCH failed to reach Running status in alloted time." ;
    echo ""
    echo "No applicable workaround was found or enabled."
    echo "Current ENABLE_WORKAROUND_LIST: ${ENABLE_WORKAROUND_LIST:-[]}"
    echo ""
    exit 1 ;
  fi
}

set +x ;
acm_version=$(oc -n ${MCH_NAMESPACE} get mch multiclusterhub -o jsonpath='{.status.currentVersion}{"\n"}')
echo "Success! ACM ${acm_version} is Running"
