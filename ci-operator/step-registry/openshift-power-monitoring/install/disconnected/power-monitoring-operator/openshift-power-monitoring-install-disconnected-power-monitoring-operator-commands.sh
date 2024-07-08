#!/bin/bash

set -e -u -o pipefail

# Set XDG_RUNTIME_DIR/containers to be used by oc mirror
declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"

declare -r HOME=${HOME:-"/tmp/home"}
declare -r XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-"${HOME}/run"}
declare -r REGISTRY_AUTH_PREFERENCE=${REGISTRY_AUTH_PREFERENCE:-"podman"}
declare -r OCP_INSTALL_URL=${OCP_INSTALL_URL:-"https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/oc-mirror.tar.gz"}
declare -r CATALOG_SOURCE=${CATALOG_SOURCE:-"cs-redhat-operator-index"}
#TODO: Import the follwing variables from the secret

# export HOME=/tmp/home
# export XDG_RUNTIME_DIR="${HOME}/run"
# export REGISTRY_AUTH_PREFERENCE=podman

# from OCP 4.15, the OLM is optional, details: https://issues.redhat.com/browse/OCPVE-634
check_olm_capability() {
  # check if OLM capability is added
  local knownCapabilities=""
  local enableCapabilities=""
  knownCapabilities=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}")
  [[ $knownCapabilities =~ "OperatorLifecycleManager" ]] && {
    echo "knownCapabilities contains OperatorLifecycleManager"
    # check if OLM capability enabled
    enableCapabilities=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}")
    [[ ! $enableCapabilities =~ "OperatorLifecycleManager" ]] && {
      echo "OperatorLifecycleManager capability is not enabled, skip the following tests..."
      return 1
    }
  }
  return 0
}

# From 4.11 on, the marketplace is optional.
# That means, once the marketplace disabled, its "openshift-marketplace" project will NOT be created as default.
# But, for OLM, its global namespace still is "openshift-marketplace"(details: https://bugzilla.redhat.com/show_bug.cgi?id=2076878),
# so we need to create it manually so that optional operator teams' test cases can be run smoothly.
check_marketplace() {

  local -i ret=0
  oc get ns openshift-marketplace || {
    ret=$?
  }
  [[ $ret -eq 0 ]] && {
    echo "openshift-marketplace project AlreadyExists, skip creating."
    return $ret
  }

  echo "creating openshift-marketplace project"
  cat <<EOF | oc create -f -
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
  ret=$?
  [[ $ret -eq 0 ]] && {
    echo "openshift-marketplace project created successfully"
    return 0
  }
  return 1
}

# Mirror operator and test images to the Mirror registry. Create Catalog sources and Image Content Source Policy.
mirror_catalog_icsp() {
  local registry_cred=""
  local optional_auth_user=""
  local optional_auth_password=""
  local qe_registry_auth=""
  local openshift_test_auth_user=""
  local openshift_test_auth_password=""
  local openshift_test_registry_auth=""
  local brew_auth_user=""
  local brew_auth_password=""
  local brew_registry_auth=""
  local stage_auth_user=""
  local stage_auth_password=""
  local stage_registry_auth=""
  local redhat_auth_user=""
  local redhat_auth_password=""
  local redhat_registry_auth=""
  local mirror_registry_host=""
  local registry_cred=""

  registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)

  optional_auth_user=$(jq -r '.user' "/var/run/vault/mirror-registry/registry_quay.json")
  optional_auth_password=$(jq -r '.password' "/var/run/vault/mirror-registry/registry_quay.json")
  qe_registry_auth=$(echo -n "$optional_auth_user:$optional_auth_password" | base64 -w 0)

  openshift_test_auth_user=$(jq -r '.user' "/var/run/vault/mirror-registry/registry_quay_openshifttest.json")
  openshift_test_auth_password=$(jq -r '.password' "/var/run/vault/mirror-registry/registry_quay_openshifttest.json")
  openshift_test_registry_auth=$(echo -n "$openshift_test_auth_user:$openshift_test_auth_password" | base64 -w 0)

  brew_auth_user=$(jq -r '.user' "/var/run/vault/mirror-registry/registry_brew.json")
  brew_auth_password=$(jq -r '.password' "/var/run/vault/mirror-registry/registry_brew.json")
  brew_registry_auth=$(echo -n "$brew_auth_user:$brew_auth_password" | base64 -w 0)

  stage_auth_user=$(jq -r '.user' "/var/run/vault/mirror-registry/registry_stage.json")
  stage_auth_password=$(jq -r '.password' "/var/run/vault/mirror-registry/registry_stage.json")
  stage_registry_auth=$(echo -n "$stage_auth_user:$stage_auth_password" | base64 -w 0)

  redhat_auth_user=$(jq -r '.user' "/var/run/vault/mirror-registry/registry_redhat.json")
  redhat_auth_password=$(jq -r '.password' "/var/run/vault/mirror-registry/registry_redhat.json")
  redhat_registry_auth=$(echo -n "$redhat_auth_user:$redhat_auth_password" | base64 -w 0)

  if [[ $(oc extract secret/pull-secret -n openshift-config --confirm --to /tmp) ]]; then
    mirror_registry_host=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
    echo "$mirror_registry_host"
    jq --argjson a "{\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"brew.registry.redhat.io\": {\"auth\": \"$brew_registry_auth\"}, \"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"${mirror_registry_host}\": {\"auth\": \"$registry_cred\"}, \"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshifttest\": {\"auth\": \"${openshift_test_registry_auth}\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" >"$XDG_RUNTIME_DIR/containers/auth.json"
    reg_crds=${XDG_RUNTIME_DIR}/containers/auth.json
    # TODO: export reg_crds
  else
    echo "!!! fail to extract the auth of the cluster"
    return 1
  fi
  # prepare ImageSetConfiguration
  echo "creating ImageSetConfiguration for mirror registry"

  mkdir /tmp/images
  cat <<EOF >/tmp/image-set.yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
archiveSize: 30
storageConfig:
  local:
    path: /tmp/images
mirror:
  operators:
  - catalog: registry.stage.redhat.io/redhat/redhat-operator-index:v4.15
    packages:
    - name: power-monitoring-operator
      channels:
      - name: tech-preview
EOF

  #TODO: come up with a better way to do this
  cd /tmp
  curl -L -o oc-mirror.tar.gz "$OCP_INSTALL_URL" && tar -xvzf oc-mirror.tar.gz && chmod +x oc-mirror"
  ./oc-mirror --config=/tmp/image-set.yaml docker://$mirror_registry_host --continue-on-error --ignore-history --source-skip-tls --dest-skip-tls || true"
  cp oc-mirror-workspace/results-*/mapping.txt .
  sed 's/registry.redhat.io/registry.stage.redhat.io/g' mapping.txt >mapping-stage.txt"
  oc image mirror -a $reg_crds -f mapping-stage.txt --insecure --filter-by-os='.*'"

  # print and apply generated ICSP and catalog source
  cat oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml
  cat oc-mirror-workspace/results-*/catalogSource*
  oc apply -f ./oc-mirror-workspace/results-*/

  local -i counter=0
  local status=""
  while [ $counter -lt 600 ]; do
    counter+=20
    echo "waiting ${counter}s"
    sleep 20
    status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE" -o=jsonpath="{.status.connectionState.lastObservedState}")
    [[ $status = "READY" ]] && {
      echo "$CATALOG_SOURCE CatalogSource created successfully"
      break
    }
  done
  [[ $status != "READY" ]] && {
    echo "!!! fail to create QE CatalogSource"
    oc get pods -o wide -n openshift-marketplace | tee "$LOGS_DIR/pods.yaml"
    oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE" -o yaml | tee "$LOGS_DIR/catalogsource.yaml"
    oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE" -o yaml | tee "$LOGS_DIR/pods-by-catalogsource.yaml"

    local node_name=""

    node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE" -o=jsonpath='{.items[0].spec.nodeName}')
    oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false \
      pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite
    oc -n debug-qe debug node/"$node_name" -- chroot /host podman pull --authfile /var/lib/kubelet/config.json registry.stage.redhat.io/redhat/redhat-operator-index:v4.15

    oc get mcp,node | tee "$LOGS_DIR/mcp-node.yaml"
    oc get mcp worker -o yaml | tee "$LOGS_DIR/mcp-worker.yaml"

    local mcp_worker=""
    mcp_worker=$(oc get mcp/worker --no-headers | awk '{print $2}')
    oc get mc "$mcp_worker" -o=jsonpath="{.spec.config.storage.files}" | jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")' | tee "$LOGS_DIR/mc-config.json"
    return 1
  }
  echo "QE CatalogSource created successfully"
  return 0

}

main() {
  mkdir -p "$LOGS_DIR"

  echo "get the details of the cluster"
  oc whoami | tee "$LOGS_DIR/whoami.yaml"
  oc version -o yaml | tee "$LOGS_DIR/version.yaml"

  #TODO: fix this
  mkdir -p "${XDG_RUNTIME_DIR}/containers"
  cd "$HOME" || return 1

  check_olm_capability
  check_marketplace
  mirror_catalog_icsp
}
main "$@"
