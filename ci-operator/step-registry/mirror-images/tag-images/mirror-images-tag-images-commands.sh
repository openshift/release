#!/bin/bash

set -e
set -u
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function mirror_tag_images () {
    echo "registry.redhat.io/ubi8/ruby-30:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-30:latest
registry.redhat.io/ubi8/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-27:latest
registry.redhat.io/ubi7/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi7/ruby-27:latest
registry.redhat.io/rhscl/ruby-25-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/ruby-25-rhel7:latest
registry.redhat.io/rhscl/mysql-80-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/mysql-80-rhel7:latest
registry.redhat.io/rhel8/mysql-80:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/mysql-80:latest
registry.redhat.io/rhel8/httpd-24:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/httpd-24:latest
" > /tmp/tag_images_list

    sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_PROXY_REGISTRY}/g" "/tmp/tag_images_list"
    run_command "cat /tmp/tag_images_list"
    # run_command "cat ${CLUSTER_PROFILE_DIR}/pull-secret"
    # # quay.io/openshift-qe-optional-operators
    # optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
    # optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
    # optional_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`
    
    registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
    jq --argjson a "{\"${MIRROR_PROXY_REGISTRY}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > /tmp/new-dockerconfigjson
    run_command "oc image mirror -f \"/tmp/tag_images_list\"  --insecure=true -a \"/tmp/new-dockerconfigjson\" --skip-missing=true --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'"
}

run_command "oc version --client"

# vmc.mirror-registry.qe.devcluster.openshift.com:5000
MIRROR_PROXY_REGISTRY=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"
# When mirror images using `oc image mirror` command, need unset proxies
mirror_tag_images
