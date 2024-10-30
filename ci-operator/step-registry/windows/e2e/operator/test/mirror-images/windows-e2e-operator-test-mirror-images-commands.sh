#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

run_command "oc whoami"
run_command "oc version -o yaml"

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

registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)

jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# Mirror operator image from CI namespace in build farm to emphemeral test cluster
wmco_image_src="registry.apps.build02.vmc.ci.openshift.org/${NAMESPACE}/pipeline"
wmco_image_dst="${MIRROR_REGISTRY_HOST}/pipeline"

oc image mirror "${wmco_image_src}" "${wmco_image_dst}" --insecure=true -a "${new_pull_secret}" \
 --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'

idms_content="apiVersion: config.openshift.io/v1\n"
idms_content+="kind: ImageDigestMirrorSet\n"
idms_content+="metadata:\n"
idms_content+="  name: wmco-e2e-digestmirrorset\n"
idms_content+="spec:\n"
idms_content+="  imageDigestMirrors:\n"
idms_content+="  - mirrors:\n"
idms_content+="    - ${wmco_image_dst}\n"
idms_content+="    source: ${wmco_image_src}\n"

echo -e "$idms_content" > "/tmp/image-digest-mirror-set.yaml"
run_command "cat /tmp/image-digest-mirror-set.yaml"

run_command "oc create -f /tmp/image-digest-mirror-set.yaml"

# Create list of source/mirror destination pairs for all images required to run the Windows e2e test suite
cat <<EOF > "/tmp/mirror-images-list.yaml"
mcr.microsoft.com/oss/kubernetes/pause:3.9=MIRROR_REGISTRY_PLACEHOLDER/oss/kubernetes/pause:3.9
mcr.microsoft.com/powershell:lts-nanoserver-1809=MIRROR_REGISTRY_PLACEHOLDER/powershell:lts-nanoserver-1809
mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022=MIRROR_REGISTRY_PLACEHOLDER/powershell:lts-nanoserver-ltsc2022
quay.io/operator-framework/upstream-registry-builder:v1.16.0=MIRROR_REGISTRY_PLACEHOLDER/operator-framework/upstream-registry-builder:v1.16.0
registry.access.redhat.com/ubi8/ubi-minimal:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ubi-minimal:latest
registry.access.redhat.com/ubi9/ubi-minimal:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi9/ubi-minimal:latest
registry.access.redhat.com/ubi8/httpd-24:1-299=MIRROR_REGISTRY_PLACEHOLDER/ubi8/httpd-24:1-299
registry.k8s.io/sig-storage/csi-provisioner:v3.3.0=MIRROR_REGISTRY_PLACEHOLDER/sig-storage/csi-provisioner:v3.3.0
registry.k8s.io/sig-storage/livenessprobe:v2.9.0=MIRROR_REGISTRY_PLACEHOLDER/sig-storage/livenessprobe:v2.9.0
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.7.0=MIRROR_REGISTRY_PLACEHOLDER/sig-storage/csi-node-driver-registrar:v2.7.0
registry.k8s.io/sig-storage/smbplugin:v1.10.0=MIRROR_REGISTRY_PLACEHOLDER/sig-storage/smbplugin:v1.10.0
registry.k8s.io/csi-vsphere/driver:v3.3.0=MIRROR_REGISTRY_PLACEHOLDER/csi-vsphere/driver:v3.3.0
mcr.microsoft.com/k8s/csi/azurefile-csi:latest=MIRROR_REGISTRY_PLACEHOLDER/k8s/csi/azurefile-csi:latest
mcr.microsoft.com/oss/kubernetes-csi/csi-node-driver-registrar:v2.8.0=MIRROR_REGISTRY_PLACEHOLDER/oss/kubernetes-csi/csi-node-driver-registrar:v2.8.0
registry.redhat.io/rhel8/support-tools:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/support-tools:latest
registry.redhat.io/rhel9/support-tools:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel9/support-tools:latest
EOF

sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_REGISTRY_HOST}/g" "/tmp/mirror-images-list.yaml"

itms_content="apiVersion: config.openshift.io/v1\n"
itms_content+="kind: ImageTagMirrorSet\n"
itms_content+="metadata:\n"
itms_content+="  name: wmco-e2e-tagmirrorset\n"
itms_content+="spec:\n"
itms_content+="  imageTagMirrors:\n"

for image in $(cat /tmp/mirror-images-list.yaml)
do
   oc image mirror $image --insecure=true -a "${new_pull_secret}" \
 --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'

    source_image=$(echo "$image" | cut -d'=' -f1)
    mirror_registry=$(echo "$image" | cut -d'=' -f2)

    # Remove the tag and its preceding colon
    # e.g. mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022 turns into mcr.microsoft.com/powershell
    source_tag_removed="${source_image%:*}"
    mirror_tag_removed="${mirror_registry%:*}"

    itms_content+="  - source: $source_tag_removed\n"
    itms_content+="    mirrors:\n"
    itms_content+="    - $mirror_tag_removed\n"
done

echo -e "$itms_content" > "/tmp/image-tag-mirror-set.yaml"
run_command "cat /tmp/image-tag-mirror-set.yaml"

run_command "oc create -f /tmp/image-tag-mirror-set.yaml"

rm -f "${new_pull_secret}"
