#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

mirror_registry_url="$(< /var/run/vault/vsphere/vmc_mirror_registry_url)"
additional_ca_file="/var/run/vault/vsphere/client_ca.crt"

#inject mirror registry creds to pullSecrets which used in install-config.yaml
registry_creds="$(base64 < /var/run/vault/vsphere/registry_creds)"
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
echo "${pull_secret}" | jq ".auths.\"${mirror_registry_url}\".auth=\"${registry_creds}\"" > /tmp/installer_pull_secret.json

#get payload version
oc registry login
release_version=$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r .metadata.version)
release_image_path="ci/release"

#Mirror payload image to private registry on VMC
jq -s '.[0] * .[1]' /tmp/installer_pull_secret.json ~/.docker/config.json > /tmp/mirror_image_pull_secret.json
echo "Mirror payload image ${release_version} to private registry ${mirror_registry_url}"
oc adm release mirror -a /tmp/mirror_image_pull_secret.json --from="${RELEASE_IMAGE_LATEST}" --to="${mirror_registry_url}/${release_image_path}" --to-release-image="${mirror_registry_url}/${release_image_path}:${release_version}" --insecure | tee /tmp/mirror_release_image_log_file &

set +e
wait "$!"
ret="$?"
set -e

cp /tmp/mirror_release_image_log_file "${ARTIFACT_DIR}/mirror_release_image_log_file"
if [ $ret -ne 0 ]; then
  echo "Fail to mirror payload image to private registry!"
  exit "$ret"
fi

#Get haproxy-router image for upi disconnected installation
haproxy_router_image=$(grep "haproxy-router" /tmp/mirror_release_image_log_file | grep "${mirror_registry_url}" | awk '{print $2}')
cat > "${SHARED_DIR}/haproxy-router-image" << EOF
${haproxy_router_image}
$(cat /var/run/vault/vsphere/registry_creds)
EOF

#Retrieve release image mirror info from output
line_num=$(grep -n "To use the new mirrored repository for upgrades" /tmp/mirror_release_image_log_file | awk -F: '{print $1}')
install_end_line_num=$(( line_num - 3))
sed -n "/^imageContentSources:/,${install_end_line_num}p" /tmp/mirror_release_image_log_file > /tmp/release_image_mirror.install.yaml

#update pullSecret to include mirror registry's secret
pull_secret=$(tr -d '[:space:]' < /tmp/installer_pull_secret.json)
sed -i "/^pullSecret:/{n;s/.*/  $pull_secret/}" "${SHARED_DIR}/install-config.yaml"

#inject mirror content and additional ca
cat >> "${SHARED_DIR}/install-config.yaml" << EOF
$(< /tmp/release_image_mirror.install.yaml)
additionalTrustBundle: |
$(sed 's/^/  &/g' ${additional_ca_file})
EOF

rm -rf /tmp/installer_pull_secret.json
rm -rf /tmp/mirror_image_pull_secret.json
