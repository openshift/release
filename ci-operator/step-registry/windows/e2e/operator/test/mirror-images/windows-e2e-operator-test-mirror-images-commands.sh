#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

new_pull_secret="${SHARED_DIR}/new_pull_secret"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG

# Create list of images required to run the Windows e2e test suite
cat <<EOF > "/tmp/mirror-images-list.yaml"
mcr.microsoft.com/oss/kubernetes/pause:3.9=MIRROR_REGISTRY_PLACEHOLDER/oss/kubernetes/pause:3.9
mcr.microsoft.com/powershell:lts-nanoserver-1809=MIRROR_REGISTRY_PLACEHOLDER/powershell:lts-nanoserver-1809
mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022=MIRROR_REGISTRY_PLACEHOLDER/powershell:lts-nanoserver-ltsc2022
quay.io/operator-framework/upstream-registry-builder:v1.16.0=MIRROR_REGISTRY_PLACEHOLDER/operator-framework/upstream-registry-builder:v1.16.0
EOF

registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)

jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_REGISTRY_HOST}/g" "/tmp/mirror-images-list.yaml" 

for image in $(cat /tmp/mirror-images-list.yaml)
do
    oc image mirror $image  --insecure=true -a "${new_pull_secret}" \
 --skip-missing=true --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'
done

rm -f "${new_pull_secret}"
