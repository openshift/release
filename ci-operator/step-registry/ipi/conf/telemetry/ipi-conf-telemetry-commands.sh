#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -z "${TELEMETRY_ENABLED}"
then
	if [[ "${JOB_NAME}" =~ (^|[^[:digit:]]+)4.11([^[:digit:]]+|$) ]]
	then
		TELEMETRY_ENABLED=true
		echo "TELEMETRY_ENABLED is empty, defaulting to '${TELEMETRY_ENABLED}' for the 4.11 ${JOB_NAME}"
	else
		TELEMETRY_ENABLED=false
		echo "TELEMETRY_ENABLED is empty, defaulting to '${TELEMETRY_ENABLED}' for the not-4.11 ${JOB_NAME}"
	fi
fi

if test true = "${TELEMETRY_ENABLED}"
then
	echo "Nothing to do with TELEMETRY_ENABLED='${TELEMETRY_ENABLED}'"
	exit
fi

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
