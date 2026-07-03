#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

KONFLUX_REGISTRY="image-rbac-proxy.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com"

# Merge the konflux prod auth into the current ocp global pull secret
function update_pull_secret () {
    
    temp_dir=$(mktemp -d)

    # Generate pull auth from konflux-quay-pull-auth credentials
    KONFLUX_PULL_USER=$(cat /var/run/konflux-quay-pull-auth/username)
    KONFLUX_PULL_PASS=$(cat /var/run/konflux-quay-pull-auth/password)
    KONFLUX_PULL_AUTH=$(echo -n "${KONFLUX_PULL_USER}:${KONFLUX_PULL_PASS}" | base64 -w0)
    echo '{"auths":{"'"${KONFLUX_REGISTRY}"'":{"auth":"'"${KONFLUX_PULL_AUTH}"'"}}}' > "${temp_dir}"/konflux-quay-pull.json

    oc get secret/pull-secret -n openshift-config \
      --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${temp_dir}"/global_pull_secret.json

    jq -s 'map(.auths) | add | {auths: .}' \
      "${temp_dir}"/global_pull_secret.json \
      "${temp_dir}"/konflux-quay-pull.json \
      > "${temp_dir}"/merged_pull_secret.json

    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${temp_dir}"/merged_pull_secret.json

    #Remove temp_dir 
    rm -rf "${temp_dir}"
}

function wait_mcp_ready () {
    set +e 
    COUNTER=0
    while [ $COUNTER -lt 1800 ] #30 min at most
    do
        COUNTER=$(("$COUNTER" + 30))
        echo "waiting ${COUNTER}s"
        sleep 30
        STATUS="$(oc get mcp worker -o=jsonpath='{.status.conditions[?(@.type=="Updated")].status}')"
        if [[ $STATUS = "True" ]]; then
            echo "MCP worker is ready"
            break
        fi
    done
    if [[ $STATUS != "True" ]]; then
        echo "!!! MCP worker is not ready"
         return 1
    fi
    set -e   

}
#create image content source policy
#https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/images/image-configuration
#ImageContentSourcePolicy is deprecated, will replace with ImageDigestMirrorSet with OCP 4.12 EOL(January 17, 2027)
function create_icsp () {
  cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: konflux-quay-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-15
    source: registry.redhat.io/quay/quay-operator-rhel8
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-18
    source: registry.redhat.io/quay/quay-operator-rhel9
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-15
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-18
    source: registry.redhat.io/quay/quay-operator-bundle
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-15
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-18
    source: registry.redhat.io/quay/quay-container-security-operator-bundle
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-15
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-18
    source: registry.redhat.io/quay/quay-bridge-operator-bundle
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-15
    source: registry.redhat.io/quay/quay-rhel8
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-18
    source: registry.redhat.io/quay/quay-rhel9
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-15
    source: registry.redhat.io/quay/quay-bridge-operator-rhel8
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-18
    source: registry.redhat.io/quay/quay-bridge-operator-rhel9
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-15
    source: registry.redhat.io/quay/quay-container-security-operator-rhel8
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-18
    source: registry.redhat.io/quay/quay-container-security-operator-rhel9
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-15
    source: registry.redhat.io/quay/container-security-operator-rhel8
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-18
    source: registry.redhat.io/quay/container-security-operator-rhel9
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-9
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-10
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-11
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-12
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-13
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-14
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-15
    source: registry.redhat.io/quay/clair-rhel8
  - mirrors:
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-16
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-17
    - ${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-18
    source: registry.redhat.io/quay/clair-rhel9
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
EOF
  if [ $? == 0 ]; then
    echo "Create the ICSP successfully"
  else
    echo "!!! Fail to create the ICSP"
    return 1
  fi

}

# Retry wrapper for rosa commands that hit 409 ManifestWork conflicts
function rosa_with_retry () {
  local attempt
  for attempt in 1 2 3 4 5; do
    if /tmp/rosa "$@" 2>&1; then
      return 0
    fi
    echo "  Attempt ${attempt}/5 failed, retrying in 15s..."
    sleep 15
  done
  echo "!!! Failed after 5 attempts: rosa $*"
  return 1
}

#create image mirrors via rosa CLI (for ROSA HCP clusters where ICSP/IDMS are blocked)
function create_rosa_image_mirrors () {
  echo "Downloading rosa CLI (v1.2.64+, required for image-mirror support)..."
  curl -sL https://github.com/openshift/rosa/releases/latest/download/rosa_Linux_x86_64.tar.gz \
    | tar xzf - -C /tmp/
  chmod +x /tmp/rosa

  echo "Logging into ROSA..."
  set +x
  local sso_client_id sso_client_secret rosa_token
  sso_client_id=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
  sso_client_secret=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
  rosa_token=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

  if [[ -n "${sso_client_id}" && -n "${sso_client_secret}" ]]; then
    /tmp/rosa login --env "${OCM_LOGIN_ENV}" \
      --client-id "${sso_client_id}" --client-secret "${sso_client_secret}"
  elif [[ -n "${rosa_token}" ]]; then
    /tmp/rosa login --env "${OCM_LOGIN_ENV}" --token "${rosa_token}"
  else
    echo "!!! No ROSA credentials found in cluster profile"
    return 1
  fi
  set -x

  local cluster_name
  cluster_name=$(cat "${SHARED_DIR}/cluster-name")
  echo "Creating image mirrors for cluster: ${cluster_name}"

  local R="${KONFLUX_REGISTRY}/redhat-user-workloads/quay-eng-tenant"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-operator-rhel8 \
    --mirrors="${R}/quay-operator-v3-9,${R}/quay-operator-v3-10,${R}/quay-operator-v3-11,${R}/quay-operator-v3-12,${R}/quay-operator-v3-13,${R}/quay-operator-v3-14,${R}/quay-operator-v3-15"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-operator-rhel9 \
    --mirrors="${R}/quay-operator-v3-16,${R}/quay-operator-v3-17,${R}/quay-operator-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-operator-bundle \
    --mirrors="${R}/quay-operator-bundle-v3-9,${R}/quay-operator-bundle-v3-10,${R}/quay-operator-bundle-v3-11,${R}/quay-operator-bundle-v3-12,${R}/quay-operator-bundle-v3-13,${R}/quay-operator-bundle-v3-14,${R}/quay-operator-bundle-v3-15,${R}/quay-operator-bundle-v3-16,${R}/quay-operator-bundle-v3-17,${R}/quay-operator-bundle-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-container-security-operator-bundle \
    --mirrors="${R}/container-security-operator-bundle-v3-9,${R}/container-security-operator-bundle-v3-10,${R}/container-security-operator-bundle-v3-11,${R}/container-security-operator-bundle-v3-12,${R}/container-security-operator-bundle-v3-13,${R}/container-security-operator-bundle-v3-14,${R}/container-security-operator-bundle-v3-15,${R}/container-security-operator-bundle-v3-16,${R}/container-security-operator-bundle-v3-17,${R}/container-security-operator-bundle-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-bridge-operator-bundle \
    --mirrors="${R}/quay-bridge-operator-bundle-v3-9,${R}/quay-bridge-operator-bundle-v3-10,${R}/quay-bridge-operator-bundle-v3-11,${R}/quay-bridge-operator-bundle-v3-12,${R}/quay-bridge-operator-bundle-v3-13,${R}/quay-bridge-operator-bundle-v3-14,${R}/quay-bridge-operator-bundle-v3-15,${R}/quay-bridge-operator-bundle-v3-16,${R}/quay-bridge-operator-bundle-v3-17,${R}/quay-bridge-operator-bundle-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-rhel8 \
    --mirrors="${R}/quay-quay-v3-9,${R}/quay-quay-v3-10,${R}/quay-quay-v3-11,${R}/quay-quay-v3-12,${R}/quay-quay-v3-13,${R}/quay-quay-v3-14,${R}/quay-quay-v3-15"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-rhel9 \
    --mirrors="${R}/quay-quay-v3-16,${R}/quay-quay-v3-17,${R}/quay-quay-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-bridge-operator-rhel8 \
    --mirrors="${R}/quay-bridge-operator-v3-9,${R}/quay-bridge-operator-v3-10,${R}/quay-bridge-operator-v3-11,${R}/quay-bridge-operator-v3-12,${R}/quay-bridge-operator-v3-13,${R}/quay-bridge-operator-v3-14,${R}/quay-bridge-operator-v3-15"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-bridge-operator-rhel9 \
    --mirrors="${R}/quay-bridge-operator-v3-16,${R}/quay-bridge-operator-v3-17,${R}/quay-bridge-operator-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-container-security-operator-rhel8 \
    --mirrors="${R}/container-security-operator-v3-9,${R}/container-security-operator-v3-10,${R}/container-security-operator-v3-11,${R}/container-security-operator-v3-12,${R}/container-security-operator-v3-13,${R}/container-security-operator-v3-14,${R}/container-security-operator-v3-15"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/quay-container-security-operator-rhel9 \
    --mirrors="${R}/container-security-operator-v3-16,${R}/container-security-operator-v3-17,${R}/container-security-operator-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/container-security-operator-rhel8 \
    --mirrors="${R}/container-security-operator-v3-9,${R}/container-security-operator-v3-10,${R}/container-security-operator-v3-11,${R}/container-security-operator-v3-12,${R}/container-security-operator-v3-13,${R}/container-security-operator-v3-14,${R}/container-security-operator-v3-15"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/container-security-operator-rhel9 \
    --mirrors="${R}/container-security-operator-v3-16,${R}/container-security-operator-v3-17,${R}/container-security-operator-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/clair-rhel8 \
    --mirrors="${R}/quay-clair-v3-9,${R}/quay-clair-v3-10,${R}/quay-clair-v3-11,${R}/quay-clair-v3-12,${R}/quay-clair-v3-13,${R}/quay-clair-v3-14,${R}/quay-clair-v3-15"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.redhat.io/quay/clair-rhel9 \
    --mirrors="${R}/quay-clair-v3-16,${R}/quay-clair-v3-17,${R}/quay-clair-v3-18"

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry.stage.redhat.io \
    --mirrors=brew.registry.redhat.io

  rosa_with_retry create image-mirror --cluster="${cluster_name}" --type=digest \
    --source=registry-proxy.engineering.redhat.com \
    --mirrors=brew.registry.redhat.io

  echo "Image mirrors created successfully"
}

# On ROSA HCP, the global pull-secret update via "oc set data" takes time
# to propagate through the HostedCluster controller to worker nodes.
# Create a namespace-level pull secret so the CatalogSource pod can pull
# immediately without waiting for node-level propagation.
# (Same pattern as rosa-operator-install-commands.sh)
function create_marketplace_pull_secret () {
  echo "Creating pull secret in openshift-marketplace for immediate image access..."
  oc get secret/pull-secret -n openshift-config \
    --template='{{index .data ".dockerconfigjson" | base64decode}}' > /tmp/marketplace-pull-secret.json

  oc create secret docker-registry marketplace-pull-secret \
    -n openshift-marketplace \
    --from-file=.dockerconfigjson=/tmp/marketplace-pull-secret.json \
    --dry-run=client -o yaml | oc apply -f -

  oc patch sa default -n openshift-marketplace \
    --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"marketplace-pull-secret"}}]' 2>/dev/null || true

  rm -f /tmp/marketplace-pull-secret.json
  echo "Marketplace pull secret created"
}

#Create custom catalog source
function create_catalog_source(){
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $QUAY_OPERATOR_SOURCE
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE
  displayName: FBC Testing Operator Catalog
  publisher: grpc
EOF

}

#Check catalog source status to Ready
function check_catalog_source_status(){
    set +e
    COUNTER=0
    local timeout=600
    if [[ "${QUAY_CLUSTER_TYPE:-ocp}" == "rosahcp" ]]; then
      timeout=900
    fi
    while [ $COUNTER -lt $timeout ]
    do
        COUNTER=$((COUNTER + 20))
        echo "waiting ${COUNTER}s"
        sleep 20
        STATUS=$(oc get catalogsources -n openshift-marketplace $QUAY_OPERATOR_SOURCE -o=jsonpath="{.status.connectionState.lastObservedState}")
        if [[ $STATUS = "READY" ]]; then
            echo "Create Quay CatalogSource successfully"
            break
        fi
        # On HCP, the global pull secret takes time to propagate to nodes.
        # Delete stuck pods every 2 min to reset ImagePullBackOff backoff.
        if [[ "${QUAY_CLUSTER_TYPE:-ocp}" == "rosahcp" && "$STATUS" == "TRANSIENT_FAILURE" && $((COUNTER % 120)) -eq 0 ]]; then
          local pod_status
          pod_status=$(oc get pods -n openshift-marketplace -l olm.catalogSource=$QUAY_OPERATOR_SOURCE \
            -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
          if [[ "$pod_status" == "ImagePullBackOff" || "$pod_status" == "ErrImagePull" ]]; then
            echo "  Catalog pod in ${pod_status}, deleting to reset backoff..."
            oc delete pod -n openshift-marketplace -l olm.catalogSource=$QUAY_OPERATOR_SOURCE 2>/dev/null || true
          fi
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! Fail to create Quay CatalogSource"
        return 1
    fi
    set -e
}


#"redhat-operators" is official catalog source for released build
if [ $QUAY_OPERATOR_SOURCE == "redhat-operators" ]; then 
  echo "Installing Quay from released build"
elif [ -z "$MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE" ]; then
  echo "Installing from custom catalog source $QUAY_OPERATOR_SOURCE, but not provoide index image: $MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE"
  exit 1
else #Install Quay operator with fbc image
  echo "Installing Quay from unreleased fbc image: $MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE"
  update_pull_secret
  if [[ "$QUAY_CLUSTER_TYPE" == "rosahcp" ]]; then
    create_rosa_image_mirrors
    create_marketplace_pull_secret
  else
    create_icsp
  fi
  create_catalog_source
  check_catalog_source_status
  if [[ "$QUAY_CLUSTER_TYPE" != "rosahcp" ]]; then
    wait_mcp_ready
  fi

fi
