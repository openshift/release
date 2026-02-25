#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Merge the konflux prod auth into the current ocp global pull secret
function update_pull_secret () {
    
    temp_dir=$(mktemp -d)
    echo '{"auths":{"quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9jb250YWluZXJfc2VjdXJpdHlfb3BlcmF0b3JfYnVuZGxlX3YzXzlfMjZmOGFhMzc0YV9wdWxsOlVMUVhUM0c0QVBCNVAyTzI1S09XVFJHMlZPNlM5MUg4NzhWMEFHTTZNQUVLSzlPWThCQTYyQ1dETDRDNFMzVUg="},"quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9jb250YWluZXJfc2VjdXJpdHlfb3BlcmF0b3JfdjNfOV80Mjk4OTU4MWM2X3B1bGw6M1c5WEZVSVE0QlZJVVZCRVFISVZYU0pKNjJTUjlWSDdIVTRHTE05NEc1ODAxRERWNzZST0tBWExSWlE4SzUzQg=="},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X2JyaWRnZV9vcGVyYXRvcl9idW5kbGVfdjNfOV9lZjFkZDJmNDM2X3B1bGw6Wk5PN05STEg3NU1JRUtHOTdGQzZTRVgxVktaRDdTNUhLVkcyMFY5TlVTTEg5MUVQN0g4RkZMMEdGOE1QWjVIQw=="},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X2JyaWRnZV9vcGVyYXRvcl92M185Xzg5MTk2ZmNlNWZfcHVsbDo3NUtBSVRXMDlSRE9CTjFQNDVaRjBFSkZSRlZONVVQQVdIVlowWEw2RkdQWUpPM1Q1MDI2SktWWlMwU0M3WVMy"},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-builder-qemu-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X2J1aWxkZXJfcWVtdV92M185X2NmZGJmOTkxY2RfcHVsbDpRVDhJOVZTUlc3RTUyT1BLVkZOUEZRQllLSFkyQkcwSlE0QkxSVjVPVTFXMlRKV0hYOFI4MjVUSlJGSUxaRTAz"},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-builder-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X2J1aWxkZXJfdjNfOV8xNTRiYjExYmNjX3B1bGw6WkZQVzhVRlRKTFRRUVFJMVpPUDRTOFFDVk1LNjdZVzRTTTVJQUtHVDA5N0VESDc4VUhNNkMyWkg4MjBVM0k5Ug=="},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X2NsYWlyX3YzXzlfMjk1YTNjZDk0Y19wdWxsOkk0OEo5SkVFTkpNS0NDSEIxSTE2MTMyMEtWSUVXUUJEOTZRVUpVRzA4NUFJRVVXRlBSWFNJTFBOWDVVSEdXSE8="},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X29wZXJhdG9yX2J1bmRsZV92M185XzljMjdjMDQzYmRfcHVsbDpZUFBWNjRJNEhKNlNFWEEyUktDTEQ1T082Qjk3UkZEQUJGVjdRRTRIMVRJQU02TzJFOFdGTE5KN0M1SUs0UzNS"},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X29wZXJhdG9yX3YzXzlfOGExZDMwYzA5OV9wdWxsOlFRRVZRODNYNDcxQ09BNlFXS1NUODU0OU02UVZYSVVQSU8wMlZOUzNDWVY3SkFMU1gwNkoxQlVWWUQ1WktOVUo="},"quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-9":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X3F1YXlfdjNfOV8wYjlhMDhmMDM5X3B1bGw6V0tEMU9OWFRTMzk1VEsyQURMU0NZQkUxR09DMFZUQ1pIRjdJV0xRSzU0TEJKWFVTVVVOVzNYNUEwRTk4WkkyUA=="},"quay.io/redhat-user-workloads/quay-eng-tenant/quay/quay":{"auth":"cmVkaGF0LXVzZXItd29ya2xvYWRzK3F1YXlfZW5nX3RlbmFudF9xdWF5X3F1YXlfZjQ0MmYzODMyY19wdWxsOjVNT0gyMzk0UlVJRU80MlVISEdZNzBPRlhZNjNBQldROVFBOU8zNVRVOUdTT0taOEQyQlhVRllYVUNWQVQ3Vkw="}}}' > "${temp_dir}"/quay-v3-9-pull.json
    # cat /var/run/quay-qe-konflux-auth/quay-v3-9-pull > "${temp_dir}"/quay-v3-9-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-10-pull > "${temp_dir}"/quay-v3-10-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-11-pull > "${temp_dir}"/quay-v3-11-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-12-pull > "${temp_dir}"/quay-v3-12-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-13-pull > "${temp_dir}"/quay-v3-13-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-14-pull > "${temp_dir}"/quay-v3-14-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-15-pull > "${temp_dir}"/quay-v3-15-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-16-pull > "${temp_dir}"/quay-v3-16-pull.json
    cat /var/run/quay-qe-konflux-auth/quay-v3-17-pull > "${temp_dir}"/quay-v3-17-pull.json

    oc get secret/pull-secret -n openshift-config \
      --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${temp_dir}"/global_pull_secret.json

    jq -s 'map(.auths) | add | {auths: .}' \
      "${temp_dir}"/global_pull_secret.json \
      "${temp_dir}"/quay-v3-9-pull.json \
      "${temp_dir}"/quay-v3-10-pull.json \
      "${temp_dir}"/quay-v3-11-pull.json \
      "${temp_dir}"/quay-v3-12-pull.json \
      "${temp_dir}"/quay-v3-13-pull.json \
      "${temp_dir}"/quay-v3-14-pull.json \
      "${temp_dir}"/quay-v3-15-pull.json \
      "${temp_dir}"/quay-v3-16-pull.json \
      "${temp_dir}"/quay-v3-17-pull.json \
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
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-15
    source: registry.redhat.io/quay/quay-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-v3-17
    source: registry.redhat.io/quay/quay-operator-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-operator-bundle-v3-17
    source: registry.redhat.io/quay/quay-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-bundle-v3-17
    source: registry.redhat.io/quay/quay-container-security-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-15
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-bundle-v3-17
    source: registry.redhat.io/quay/quay-bridge-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-15
    source: registry.redhat.io/quay/quay-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-quay-v3-17
    source: registry.redhat.io/quay/quay-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-15
    source: registry.redhat.io/quay/quay-bridge-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-bridge-operator-v3-17
    source: registry.redhat.io/quay/quay-bridge-operator-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-15
    source: registry.redhat.io/quay/quay-container-security-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-17
    source: registry.redhat.io/quay/quay-container-security-operator-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-15
    source: registry.redhat.io/quay/container-security-operator-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/container-security-operator-v3-17
    source: registry.redhat.io/quay/container-security-operator-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-9
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-10
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-11
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-12
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-13
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-14
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-15
    source: registry.redhat.io/quay/clair-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-16
    - quay.io/redhat-user-workloads/quay-eng-tenant/quay-clair-v3-17
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
