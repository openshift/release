#!/bin/bash

set -e
set -u
set -o pipefail

run() {
  local cmd="$1"
  echo "running command: $cmd"
  eval "$cmd"
}

set_proxy() {
  [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
    echo "setting the proxy"
    echo "source ${SHARED_DIR}/proxy-conf.sh"
    source "${SHARED_DIR}/proxy-conf.sh"
    export no_proxy=mirror.openshift.com,github.com,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
    export NO_PROXY=mirror.openshift.com,github.com,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
  }
  echo "no proxy setting. skipping this step"
  return 0
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

  cat <<EOF | oc apply -f - || {
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: $ICSP_NAME
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-bundle-$TEST_TYPE
    source: registry.redhat.io/compliance/openshift-file-integrity-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-$TEST_TYPE
    source: registry.redhat.io/compliance/openshift-file-integrity-rhel8-operator
EOF
    echo "!!! fail to create the ICSP"
    return 1
  }

  echo "ICSP $ICSP_NAME created successfully"
  return 0
}

check_mcp_status() {
  machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
  COUNTER=0
  while [ $COUNTER -lt 1200 ]; do
    sleep 20
    COUNTER=$(expr $COUNTER + 20)
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
  echo "creating catalogsource: $CATALOG_SOURCE_NAME using index image: $INDEX_IMAGE"

  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE_NAME
  namespace: openshift-marketplace
spec:
  displayName: Konflux
  image: $INDEX_IMAGE
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
  local -i counter=0
  local status=""
  while [ $counter -lt 600 ]; do
    counter+=20
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
  return 0
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
install_oc_mirror() {
  echo "Installing the latest oc-mirror client..."
  run "cd /tmp && curl --noproxy '*' -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
  run "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
}

# Applicable for 'disconnected' env
mirror_catalog_and_operator() {
  echo "[$(timestamp)] Creaing ImageSetConfiguration for catalog and operator related images..."
  cat >${TMP_DIR}/imageset.yaml <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
    - catalog: ${INDEX_IMAGE}
      packages:
        - name: ${PACKAGE_NAME}
          channels:
          - name: stable 
EOF

    echo "[$(timestamp)]create registry.conf"
    cat <<EOF |tee "${TMP_DIR}/registry.conf"
[[registry]]
 location = "registry.redhat.io/compliance/openshift-file-integrity-operator-bundle"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-bundle-${TEST_TYPE}"
    insecure = true
[[registry]]
 location = "registry.redhat.io/compliance/openshift-file-integrity-rhel8-operator"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-${TEST_TYPE}"
    insecure = true
EOF

  echo "[$(timestamp)] Mirroring the images to the mirror registry..."
  run "./oc-mirror --v2 --config=${TMP_DIR}/imageset.yaml --registries.d ${TMP_DIR} --workspace=file://${TMP_DIR} docker://${MIRROR_REGISTRY_HOST} --log-level=info --retry-times=5 --src-tls-verify=false --dest-tls-verify=false"
  run "oc-mirror --config ${TMP_DIR}/imageset.yaml docker://${MIRROR_REGISTRY_HOST} --oci-registries-config=${TMP_DIR}/registry.conf --continue-on-error --skip-missing --dest-skip-tls --source-skip-tls"
  echo "[$(timestamp)] Replacing the generated catalog source name with the ENV var '$CATSRC_NAME'..."
  run "curl --noproxy '*' -k -L -o yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/') && chmod +x ./yq"
  run "./yq eval '.metadata.name = \"$CATSRC_NAME\"' -i ${OC_MIRROR_OUTPUT_DIR}/cs-*.yaml"

  echo "[$(timestamp)] Checking and applying the generated resource files..."
  run "find ${OC_MIRROR_OUTPUT_DIR} -type f | xargs -I{} bash -c 'cat {}; echo \"---\"'"
  run "oc apply -f ${OC_MIRROR_OUTPUT_DIR}"

  echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
  oc wait mcp --all --for=condition=Updating --timeout=5m || true
  oc wait mcp --all --for=condition=Updated --timeout=20m || true
  echo "[$(timestamp)] Rollout progress completed"
}

# Applicable for 'disconnected' env
# Note: This is a temporary workaround to avoid the disruptive impact of the 'enable-qe-catalogsource-disconnected' step.
# As per current implementation, that step is called by every 'disconnected' cluster provisioning workflow that maintained by QE.
# Hence this function can be removed in future once above mentioned design is well refined.
function tmp_prune_distruptive_resource() {
  echo "Pruning the disruptive resources in pervious step 'enable-qe-catalogsource-disconnected'..."
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
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    check_mirror_registry || {
      echo "failed to get mirror registry. resolve the above errors"
      return 1
    }

    tmp_prune_distruptive_resource || {
      echo "failed to prune distruptive resources. resolve the above errors"
      return 1
    }

    install_oc_mirror || {
      echo "failed to install oc mirror. resolve the above errors"
      return 1
    }

    mirror_catalog_and_operator || {
      echo "failed to mirror catalog and operator. resolve the above errors"
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

  #support hypershift config guest cluster's icsp
  oc get imagecontentsourcepolicy -oyaml >/tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' - | sed '/---*/d' >"$SHARED_DIR"/mgmt_icsp.yaml
}
main
