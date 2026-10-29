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
    while [ $COUNTER -lt 600 ] #10 min at most
    do
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        sleep 20
        STATUS=`oc get catalogsources -n openshift-marketplace $QUAY_OPERATOR_SOURCE -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "Create Quay CatalogSource successfully"
            break
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
  create_icsp
  create_catalog_source
  check_catalog_source_status
  wait_mcp_ready
  
fi
