#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test true = "${TELEMETRY_ENABLED}"
then
	echo "Nothing to do with TELEMETRY_ENABLED='${TELEMETRY_ENABLED}'"

cat <<-EOF > "${SHARED_DIR}/manifest_cluster-monitoring-config-conflict-a.yaml"
	apiVersion: v1
	kind: ConfigMap
	metadata:
	  name: cluster-monitoring-config
	  namespace: openshift-monitoring
	data:
	  config.yaml:
            we: will never get this far, hopefully...
	EOF

cat <<-EOF > "${SHARED_DIR}/manifest_cluster-monitoring-config-conflict-b.yaml"
	apiVersion: v1
	kind: ConfigMap
	metadata:
	  name: cluster-monitoring-config
	  namespace: openshift-monitoring
	data:
	  config.yaml:
            because: this other manifest will conflict.
	EOF

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

cat <<-EOF > "${SHARED_DIR}/manifest_cluster-monitoring-config-conflict.yaml"
	apiVersion: v1
	kind: ConfigMap
	metadata:
	  name: cluster-monitoring-config
	  namespace: openshift-monitoring
	data:
	  config.yaml:
            we: will never get this far, hopefully...
	EOF
