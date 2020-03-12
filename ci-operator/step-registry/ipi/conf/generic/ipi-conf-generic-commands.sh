#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
cluster_name=${NAMESPACE}-${JOB_NAME_HASH}

out=${SHARED_DIR}/install-config.yaml

cluster_variant=
if [[ -e "${SHARED_DIR}/install-config-variant.txt" ]]; then
	cluster_variant=$(<"${SHARED_DIR}/install-config-variant.txt")
fi

function has_variant() {
	regex="(^|,)$1($|,)"
	if [[ $cluster_variant =~ $regex ]]; then
		return 0
	fi
	return 1
}

echo "Installing from release ${RELEASE_IMAGE_LATEST}"

ssh_pub_key=$(<"${cluster_profile}/ssh-publickey")
pull_secret=$(<"${cluster_profile}/pull-secret")

cat > "${out}" << EOF
apiVersion: v1
metadata:
  name: ${cluster_name}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

if has_variant fips; then
	cat >> "${out}" <<-EOF
	fips: true
	EOF
fi
