#!/bin/bash
# This script is used to configure the Konflux catalog source for the
# file-integrity-operator. It supports both connected and disconnected
# environments.
#
# In a connected environment, it creates an ImageContentSourcePolicy to mirror
# the necessary images.
#
# In a disconnected environment, it mirrors the catalog and operator images
# to a local registry, configures the cluster to use the local registry,
# and creates the necessary CatalogSource and ImageDigestMirrorSet resources.

set -e
set -u
set -o pipefail

run() {
  local cmd="$1"
  echo "running command: $cmd"
  eval "$cmd"
}

set_proxy() {
  if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    echo "setting the proxy"
    echo "source ${SHARED_DIR}/proxy-conf.sh"
    source "${SHARED_DIR}/proxy-conf.sh"
    export no_proxy=mirror.openshift.com,github.com,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
    export NO_PROXY=mirror.openshift.com,github.com,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
  else
    echo "no proxy setting. skipping this step"
  fi
}

timestamp() {
  date -u --rfc-3339=seconds
}

# create ICSP for connected env.
create_icsp_connected() {
  #Delete any existing ImageContentSourcePolicy
  oc delete imagecontentsourcepolicies brew-registry --ignore-not-found=true || {
    echo "failed to delete existing imagecontentsourcepolicies"
    return 1
  }

  cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: $ICSP_NAME
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-bundle-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-file-integrity-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-file-integrity-rhel8-operator
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/security-profiles-operator-bundle-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-security-profiles-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/security-profiles-operator-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-security-profiles-rhel8-operator
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/openshift-selinuxd-rhel8-container-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-selinuxd-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/openshift-selinuxd-rhel9-container-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-selinuxd-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-bundle-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-compliance-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-openscap-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-compliance-openscap-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-must-gather-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-compliance-must-gather-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-compliance-rhel8-operator
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-content-${TEST_TYPE}
    source: registry.redhat.io/compliance/openshift-compliance-content-rhel8
EOF
  if [ $? == 0 ]; then
    echo "create the ICSP successfully" 
  else
    echo "!!! fail to create the ICSP"
    return 1
  fi
}

check_mcp_status() {
  machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
  COUNTER=0
  while [ $COUNTER -lt 1200 ]; do
    sleep 20
    ((COUNTER += 20))
    echo "waiting ${COUNTER}s"
    updatedMachineCount=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
    if [[ ${updatedMachineCount} = "${machineCount}" ]]; then
      echo "MCP updated successfully"
      break
    fi
  done
  if [[ ${updatedMachineCount} != "${machineCount}" ]]; then
    run "oc get mcp,node"
    run "oc get mcp worker -o yaml"
    return 1
  fi
}

create_catalog_sources() {
  local node_name
  local index_image

  if [ "${MIRROR_OPERATORS}" == "true" ]; then
    index_image="${MIRROR_REGISTRY_HOST}/${TARGET_CATALOG}:latest"
  else
    index_image="${INDEX_IMAGE}"
  fi
  echo "creating catalogsource: $CATALOG_SOURCE_NAME using index image: $index_image"
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: Konflux
  image: ${index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
  local -i counter=0
  local status=""
  while [ $counter -lt 600 ]; do
    ((counter += 20))
    echo "waiting ${counter}s"
    sleep 20
    status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" -o=jsonpath="{.status.connectionState.lastObservedState}")
    [[ $status = "READY" ]] && {
      echo "$CATALOG_SOURCE_NAME CatalogSource created successfully"
      break
    }
  done
  [[ $status != "READY" ]] && {
    echo "!!! fail to create CatalogSource"
    run "oc get pods -o wide -n openshift-marketplace"
    run "oc -n openshift-marketplace get catalogsource $CATALOG_SOURCE_NAME -o yaml"
    run "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOG_SOURCE_NAME -o yaml"
    node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE_NAME" -o=jsonpath='{.items[0].spec.nodeName}')
    run "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false \
      pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
    run "oc -n debug-qe debug node/$node_name -- chroot /host podman pull --authfile /var/lib/kubelet/config.json $INDEX_IMAGE"

    run "oc get mcp,node"
    run "oc get mcp worker -o yaml"
    run "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"

    return 1
  }
  return 0
}

# From 4.11 on, the marketplace is optional.
# That means, once the marketplace disabled, its "openshift-marketplace" project will NOT be created as default.
# But, for OLM, its global namespace still is "openshift-marketplace"(details: https://bugzilla.redhat.com/show_bug.cgi?id=2076878),
# so we need to create it manually so that optional operator teams' test cases can be run smoothly.
check_marketplace() {
  local -i ret=0
  run "oc get ns openshift-marketplace" || ret=1

  [[ $ret -eq 0 ]] && {
    echo "openshift-marketplace project AlreadyExists, skip creating."
    return 0
  }

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
EOF
}

# Applicable for 'disconnected' env
check_mirror_registry() {
  if test -s "${SHARED_DIR}/mirror_registry_url"; then
    MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
    export MIRROR_REGISTRY_HOST
    echo "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
  else
    echo "This is not a disconnected environment as no mirror registry url set. Skipping rest of steps..."
    exit 1
  fi
}

# Applicable for 'disconnected' env
function configure_host_pull_secret () {
    echo "Retrieving the redhat, redhat stage, and mirror registries pull secrets from shared credentials..."
    redhat_registry_path="/var/run/vault/mirror-registry/registry_redhat.json"
    redhat_auth_user=$(jq -r '.user' $redhat_registry_path)
    redhat_auth_password=$(jq -r '.password' $redhat_registry_path)
    redhat_registry_auth=$(echo -n " " "$redhat_auth_user":"$redhat_auth_password" | base64 -w 0)

    mirror_registry_path="/var/run/vault/mirror-registry/registry_creds"
    mirror_registry_auth=$(head -n 1 "$mirror_registry_path" | base64 -w 0)

    echo "Appending the pull secrets to Podman auth configuration file '${XDG_RUNTIME_DIR}/containers/auth.json'..."
    oc extract secret/pull-secret -n openshift-config --confirm --to ${TMP_DIR}
    jq --argjson a "{\"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$mirror_registry_auth\"}}" '.auths |= . + $a' "${TMP_DIR}/.dockerconfigjson" > ${XDG_RUNTIME_DIR}/containers/auth.json
}

# set the registry auths for the cluster
function set_cluster_auth () {
    # get the registry configures of the cluster
    run "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -eq 0 ]]; then 
        registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
        jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson
        run "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson"; ret=$?
        if [[ $ret -eq 0 ]]; then
            check_mcp_status
            echo "set the mirror registry auth successfully."
	    return 0
        else
            echo "!!! fail to set the mirror registry auth"
            return 1
        fi
    else
        echo "Can not extract Auth of the cluster"
        echo "!!! fail to set the mirror registry auth"
        return 1
    fi
}

function set_CA_for_nodes () {
    ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
    if [ $ca_name ] && [ $ca_name = "registry-config" ] ; then
        echo "CA is ready, skip config..."
        return 0
    fi

    # get the QE additional CA
    if [[ "${SELF_MANAGED_ADDITIONAL_CA}" == "true" ]]; then
        QE_ADDITIONAL_CA_FILE="${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt"
    else
        QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"
    fi
    REGISTRY_HOST=`echo ${MIRROR_REGISTRY_HOST} | cut -d \: -f 1`
    run "oc create configmap registry-config --from-file=\"${REGISTRY_HOST}..5000\"=${QE_ADDITIONAL_CA_FILE} -n openshift-config"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set the proxy registry ConfigMap successfully."
    else
        echo "!!! fail to set the proxy registry ConfigMap"
        run "oc get configmap registry-config -n openshift-config -o yaml"
        return 1
    fi
    run "oc patch image.config.openshift.io/cluster --patch '{\"spec\":{\"additionalTrustedCA\":{\"name\":\"registry-config\"}}}' --type=merge"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set additionalTrustedCA successfully."
    else
        echo "!!! Fail to set additionalTrustedCA"
        run "oc get image.config.openshift.io/cluster -o yaml"
        return 1
    fi
}

# Applicable for 'disconnected' env
install_oc_mirror() {
  echo "Installing the latest oc-mirror client into /tmp..."
  run "cd /tmp && curl --noproxy '*' -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz && tar -xvzf oc-mirror.tar.gz && rm -f oc-mirror.tar.gz"
  if ls /tmp/oc-mirror > /dev/null; then
    chmod +x /tmp/oc-mirror
  else
    echo "ERROR: can not find oc-mirror"
    exit 1
  fi
}

extract_image_path() {
  local image_string="$1"
  # 1. Remove the 'quay.io/' prefix
  # 2. Remove everything from '@' or ':' to the end
  echo "$image_string" | sed 's|^quay.io/||' | sed 's|[@:].*||'
}

# Applicable for 'disconnected' env
mirror_catalog_and_operator() {
  echo "[$(timestamp)]create registry.conf"
  cat <<EOF | tee "${XDG_RUNTIME_DIR}/containers/registries.conf"
[[registry]]
  location = "registry.redhat.io/compliance/openshift-file-integrity-operator-bundle"
  insecure = true
  blocked = false
  mirror-by-digest-only = false
  [[registry.mirror]]
      location = "quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-bundle-${TEST_TYPE}"
      insecure = true
[[registry]]
 location = "registry.redhat.io/compliance/openshift-security-profiles-operator-bundle"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/security-profiles-operator-bundle-${TEST_TYPE}"
    insecure = true
[[registry]]
  location = "registry.redhat.io/compliance/openshift-security-profiles-rhel8-operator"
  insecure = true
  blocked = false
  mirror-by-digest-only = false
  [[registry.mirror]]
      location = "quay.io/redhat-user-workloads/ocp-isc-tenant/security-profiles-operator-${TEST_TYPE}"
      insecure = true
[[registry]]
 location = "registry.redhat.io/compliance/openshift-selinuxd-rhel8"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/openshift-selinuxd-rhel8-container-${TEST_TYPE}"
    insecure = true
[[registry]]
  location = "registry.redhat.io/compliance/openshift-selinuxd-rhel9"
  insecure = true
  blocked = false
  mirror-by-digest-only = false
  [[registry.mirror]]
      location = "quay.io/redhat-user-workloads/ocp-isc-tenant/openshift-selinuxd-rhel9-container-${TEST_TYPE}"
      insecure = true
[[registry]]
 location = "registry.redhat.io/compliance/openshift-compliance-operator-bundle"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-bundle-${TEST_TYPE}"
    insecure = true
[[registry]]
  location = "registry.redhat.io/compliance/openshift-compliance-openscap-rhel8"
  insecure = true
  blocked = false
  mirror-by-digest-only = false
  [[registry.mirror]]
      location = "quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-openscap-${TEST_TYPE}"
      insecure = true
[[registry]]
 location = "registry.redhat.io/compliance/openshift-compliance-must-gather-rhel8"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-must-gather-${TEST_TYPE}"
    insecure = true
[[registry]]
  location = "registry.redhat.io/compliance/openshift-compliance-rhel8-operator"
  insecure = true
  blocked = false
  mirror-by-digest-only = false
  [[registry.mirror]]
      location = "quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-${TEST_TYPE}"
      insecure = true
[[registry]]
 location = "registry.redhat.io/compliance/openshift-file-integrity-rhel8-operator"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator-content-${TEST_TYPE}"
    insecure = true
[[registry]]
  location = "registry.redhat.io/compliance/openshift-compliance-content-rhel8"
  insecure = true
  blocked = false
  mirror-by-digest-only = false
  [[registry.mirror]]
      location = "quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-bundle-${TEST_TYPE}"
      insecure = true
EOF

  echo "Check skopeo and run skopeo copy command"
  if [[ ! -f /usr/bin/skopeo ]]; then
    yum install -y skopeo
  fi
  skopeo copy "docker://${INDEX_IMAGE}" "oci://${TMP_DIR}/oci-local-catalog" --remove-signatures

  echo "create ImageSetConfiguration"
cat <<EOF |tee "${TMP_DIR}/imageset-config.yaml"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
mirror:
  operators:
  - catalog: "oci://${TMP_DIR}/oci-local-catalog"
    targetCatalog: ${TARGET_CATALOG}
    targetTag: "latest"
EOF
  run "/tmp/oc-mirror --config=${TMP_DIR}/imageset-config.yaml docker://${MIRROR_REGISTRY_HOST} --oci-registries-config=${XDG_RUNTIME_DIR}/containers/registries.conf --verbose=9 --dest-skip-tls --source-skip-tls --continue-on-error --skip-missing"
}

function create_idms_disconnected() {
  cat << EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${ICSP_NAME}
spec:
  imageDigestMirrors:
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/compliance
      source: registry.redhat.io/compliance
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/openshift4
      source: registry.redhat.io/openshift4
EOF
}
# Applicable for 'disconnected' env
# Note: This is a temporary workaround to avoid the disruptive impact of the 'enable-qe-catalogsource-disconnected' step.
# As per current implementation, that step is called by every 'disconnected' cluster provisioning workflow that maintained by QE.
# Hence this function can be removed in future once above mentioned design is well refined.
function tmp_prune_disruptive_resource() {
  echo "Pruning the disruptive resources in previous step 'enable-qe-catalogsource-disconnected'..."
  run "oc delete catalogsource qe-app-registry -n openshift-marketplace --ignore-not-found"
  run "oc delete imagecontentsourcepolicy image-policy-aosqe --ignore-not-found"
  run "oc delete imagedigestmirrorset image-policy-aosqe --ignore-not-found"

  echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
  oc wait mcp --all --for=condition=Updating --timeout=5m || true
  oc wait mcp --all --for=condition=Updated --timeout=20m || true
  echo "[$(timestamp)] Rollout progress completed"
}

main() {
  echo "Enabling konflux catalogsource"
  set_proxy

  run "oc whoami"
  run "oc version -o yaml"

  if [ "${MIRROR_OPERATORS}" == "true" ]; then
    export TMP_DIR=/tmp/mirror-operators
    export OC_MIRROR_OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    target_catalog=$(extract_image_path "${INDEX_IMAGE}")
    export TARGET_CATALOG=${target_catalog}
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    check_mirror_registry || {
      echo "failed to get mirror registry. resolve the above errors"
      return 1
    }

    set_CA_for_nodes || {
      echo "failed to set CA. resolve the above errors"
      return 1
    }
  
    set_cluster_auth || {
      echo "failed to set cluster auth. Resolve the above errors"
      return 1
    }

    configure_host_pull_secret || {
      echo "failed to configure pull secret on the host. resolve the above errors"
      return 1
    }

    tmp_prune_disruptive_resource || {
      echo "failed to prune disruptive resources. resolve the above errors"
      return 1
    }

    install_oc_mirror || {
      echo "failed to install oc mirror. resolve the above errors"
      return 1
    }

    mirror_catalog_and_operator || {
      tar -czC "${PWD}" -f "${ARTIFACT_DIR}/mirror.tar.gz" . || true
      echo "failed to mirror catalog and operator. resolve the above errors"
      return 1
    }
    tar -czC "${PWD}" -f "${ARTIFACT_DIR}/mirror.tar.gz" . || true

    create_idms_disconnected || {
       echo "failed to create icsp for disconnected env. resolve the above errors"
      return 1
    }
    check_mcp_status || {
      echo "failed to check mcp status. resolve the above errors"
      return 1
    }
  else
    create_icsp_connected || {
      echo "failed to create imagecontentsourcepolicies. resolve the above errors"
      return 1
    }

    check_mcp_status || {
      echo "failed to check mcp status. resolve the above errors"
    }
    check_marketplace || {
      echo "failed to check marketplace. resolve the above errors"
      return 1
    }

    if [[ -z "${INDEX_IMAGE}" ]]; then
      echo "'INDEX_IMAGE' is empty. Skipping catalog source creation..."
      exit 0
    fi
  fi

  create_catalog_sources || {
    echo "failed to create catalogsource. resolve the above errors"
    return 1
  }
}
main
