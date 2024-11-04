#!/bin/bash

set -e
set -u
set -o pipefail

# Set XDG_RUNTIME_DIR/containers to be used by oc mirror
export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# from OCP 4.15, the OLM is optional, details: https://issues.redhat.com/browse/OCPVE-634
function check_olm_capability(){
    # check if OLM capability is added 
    knownCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}"`
    if [[ ${knownCaps} =~ "OperatorLifecycleManager" ]]; then
        echo "knownCapabilities contains OperatorLifecycleManager"
        # check if OLM capability enabled
        enabledCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
          if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager" ]]; then
              echo "OperatorLifecycleManager capability is not enabled, skip the following tests..."
              exit 0
          fi
    fi
}

# From 4.11 on, the marketplace is optional.
# That means, once the marketplace disabled, its "openshift-marketplace" project will NOT be created as default.
# But, for OLM, its global namespace still is "openshift-marketplace"(details: https://bugzilla.redhat.com/show_bug.cgi?id=2076878),
# so we need to create it manually so that optional operator teams' test cases can be run smoothly.
function check_marketplace () {
    # caps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
    # if [[ ${caps} =~ "marketplace" ]]; then
    #     echo "marketplace installed, skip..."
    #     return 0
    # fi
    ret=0
    run_command "oc get ns openshift-marketplace" || ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "openshift-marketplace project AlreadyExists, skip creating."
        return 0
    fi
    
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
}


# Mirror operator and test images to the Mirror registry. Create Catalog sources and Image Content Source Policy.
function mirror_catalog_icsp() {
    registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`

    optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
    optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
    qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

    openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
    openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
    openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

    brew_auth_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
    brew_auth_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
    brew_registry_auth=`echo -n "${brew_auth_user}:${brew_auth_password}" | base64 -w 0`

    stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
    stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
    stage_registry_auth=`echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0`

    redhat_auth_user=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.user')
    redhat_auth_password=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.password')
    redhat_registry_auth=`echo -n "${redhat_auth_user}:${redhat_auth_password}" | base64 -w 0`

    # run_command "cat ${CLUSTER_PROFILE_DIR}/pull-secret"
    # Running Command: cat /tmp/.dockerconfigjson
    # {"auths":{"ec2-3-92-162-185.compute-1.amazonaws.com:5000":{"auth":"XXXXXXXXXXXXXXXX"}}}
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
    echo $MIRROR_REGISTRY_HOST
    if [[ $ret -eq 0 ]]; then 
        jq --argjson a "{\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"brew.registry.redhat.io\": {\"auth\": \"$brew_registry_auth\"}, \"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}, \"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > ${XDG_RUNTIME_DIR}/containers/auth.json
      export REG_CREDS=${XDG_RUNTIME_DIR}/containers/auth.json
    else
        echo "!!! fail to extract the auth of the cluster"
        return 1
    fi

# prepare ImageSetConfiguration
run_command "mkdir /tmp/images"
cat <<EOF > /tmp/image-set.yaml

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
    - name: tempo-product
      channels:
      - name: stable
    - name: opentelemetry-product
      channels:
      - name: stable
    - name: jaeger-product
      channels:
      - name: stable
    - name: elasticsearch-operator
      channels:
      - name: stable-5.8
    - name: amq-streams
      channels:
      - name: stable
  additionalImages:
  # Used for running disconnected tests
  - name: quay.io/minio/minio@sha256:7586fd4e11b48d7e41efdc6898b73147231da847cd0d4383d0a718ad2c98e6d8
  - name: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen@sha256:a036b2ec403f445adc68bfcc359d5040a6603af4081a76a6cf02a5de55138a4e
  - name: ghcr.io/grafana/tempo-operator/test-utils@sha256:7cf76bad82feb2cc338d23b29d7585c9399dfc8105bbab0c0636a776916aa3bc
  - name: docker.io/jaegertracing/vertx-create-span@sha256:6704312715644554fe4d51e0ce5cb0032e9231653ac61bdbdb5f290cb637d421
EOF

    run_command "cd /tmp"
    run_command "curl -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/oc-mirror.tar.gz && tar -xvzf oc-mirror.tar.gz && chmod +x oc-mirror"
    run_command "./oc-mirror --config=/tmp/image-set.yaml docker://${MIRROR_REGISTRY_HOST} --continue-on-error --ignore-history --source-skip-tls --dest-skip-tls || true"
    run_command "cp oc-mirror-workspace/results-*/mapping.txt ."
    run_command "sed 's/registry.redhat.io/registry.stage.redhat.io/g' mapping.txt > mapping-stage.txt"
    run_command "oc image mirror -a ${REG_CREDS} -f mapping-stage.txt --insecure --filter-by-os='.*'"

    # print and apply generated ICSP and catalog source
    run_command "cat oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml"
    run_command "cat oc-mirror-workspace/results-*/catalogSource*"
    run_command "oc apply -f ./oc-mirror-workspace/results-*/"

    CATALOG_SOURCE="cs-redhat-operator-index"
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
      run "oc get pods -o wide -n openshift-marketplace"
      run "oc -n openshift-marketplace get catalogsource $CATALOG_SOURCE -o yaml"
      run "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOG_SOURCE -o yaml"
      node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE" -o=jsonpath='{.items[0].spec.nodeName}')
      run "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false \
        pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
      run "oc -n debug-qe debug node/$node_name -- chroot /host podman pull --authfile /var/lib/kubelet/config.json registry.stage.redhat.io/redhat/redhat-operator-index:v4.15"

      run "oc get mcp,node"
      run "oc get mcp worker -o yaml"
      run "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"

      return 1
    }
    return 0

}

run_command "oc whoami"
run_command "oc version -o yaml"

check_olm_capability
check_marketplace
mirror_catalog_icsp
