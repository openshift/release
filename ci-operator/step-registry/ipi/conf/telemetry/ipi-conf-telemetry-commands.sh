#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test true = "${TELEMETRY_ENABLED}"
then
	echo "Nothing to do with TELEMETRY_ENABLED='${TELEMETRY_ENABLED}'"
	exit
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"

# Some CI tests will assume telemetry is enabled if there is a token for cloud.openshift.com
# https://github.com/openshift/ose/blob/0751903f21edfe65f65c5eadbdb3b24d260ea289/test/extended/prometheus/prometheus.go#L50
# Remove it from the pull secret.
PULL_SECRET_STAGING=$(cat "${INSTALL_CONFIG}" | yq-go '.pullSecret' | jq 'del(.auths["cloud.openshift.com"])')
yq-go w --style folded -i "${INSTALL_CONFIG}" '.pullSecret' "${PULL_SECRET_STAGING}"


CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
PATCH="/tmp/cluster-monitoring-config.yaml.patch"

# Create config if empty
touch "${CONFIG}"
CONFIG_CONTENTS="$(yq-go r ${CONFIG} 'data."config.yaml"')"
if test -z "${CONFIG_CONTENTS}"
then
	echo "Creating ${CONFIG}"
	cat <<-EOF > "${CONFIG}"
		apiVersion: v1
		kind: ConfigMap
		metadata:
		  name: cluster-monitoring-config
		  namespace: openshift-monitoring
		data:
		  config.yaml:
		EOF
else
	echo "Adjusting existing ${CONFIG}"
fi

cat <<EOF >> "${PATCH}"
telemeterClient:
  enabled: false
EOF

CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | yq-go m - "${PATCH}")"
yq-go w --style folded -i "${CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"
cat "${CONFIG}"
