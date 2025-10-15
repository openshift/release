#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Merge the konflux prod secrets into the current ocp global pull secret
function update_pull_secret () {
    cat /var/run/quay-qe-konflux-auth/quay-v3-10-pull > "${SHARED_DIR}"/quay-v3-10-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-11-pull > "${SHARED_DIR}"/quay-v3-11-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-12-pull > "${SHARED_DIR}"/quay-v3-12-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-13-pull > "${SHARED_DIR}"/quay-v3-13-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-14-pull > "${SHARED_DIR}"/quay-v3-14-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-15-pull > "${SHARED_DIR}"/quay-v3-15-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-16-pull > "${SHARED_DIR}"/quay-v3-16-pull.json

    
    # if ! command -v jq &> /dev/null
    # then
    #     echo "jq could not be found, installing..."
    #     curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq && chmod +x /tmp/jq
    #     export PATH=$PATH:/tmp
    # fi

    oc get secret/pull-secret -n openshift-config \
      --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${SHARED_DIR}"/global_pull_secret.json

    jq -s 'map(.auths) | add | {auths: .}' \
      "${SHARED_DIR}"/global_pull_secret.json \
      "${SHARED_DIR}"/quay-v3-10-pull.json \
      "${SHARED_DIR}"/quay-v3-11-pull.json \
      "${SHARED_DIR}"/quay-v3-12-pull.json \
      "${SHARED_DIR}"/quay-v3-13-pull.json \
      "${SHARED_DIR}"/quay-v3-14-pull.json \
      "${SHARED_DIR}"/quay-v3-15-pull.json \
      "${SHARED_DIR}"/quay-v3-16-pull.json \
      > "${SHARED_DIR}"/merged_pull_secret.json

    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${SHARED_DIR}"/merged_pull_secret.json
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
#https://docs.redhat.com/en/documentation/openshift_container_platform/4.13/html/images/image-configuration
#ImageContentSourcePolicy is deprecated, will change to ImageDigestMirrorSet after 4.12 EOL
function create_icsp () {
  cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: konflux-quay-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-16
    source: registry.redhat.io/quay/quay-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-16
    source: registry.redhat.io/quay/quay-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-16
    source: registry.redhat.io/quay/quay-container-security-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-16
    source: registry.redhat.io/quay/quay-bridge-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-16
    source: registry.redhat.io/quay/quay-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-16
    source: registry.redhat.io/quay/quay-bridge-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-16
    source: registry.redhat.io/quay/quay-container-security-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-16
    source: registry.redhat.io/quay/container-security-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-16
    source: registry.redhat.io/quay/clair-rhel8
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
  image: $QUAY_INDEX_IMAGE_BUILD
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
elif [ -z "$QUAY_INDEX_IMAGE_BUILD" ]; then 
  echo "Installing from custom catalog source $QUAY_OPERATOR_SOURCE, but not provoide index image: $QUAY_INDEX_IMAGE_BUILD"
  exit 1
else #Install Quay operator with fbc image
  echo "Installing Quay from unreleased fbc image: $QUAY_INDEX_IMAGE_BUILD"
  update_pull_secret
  create_icsp
  create_catalog_source
  check_catalog_source_status
  wait_mcp_ready
  
fi
