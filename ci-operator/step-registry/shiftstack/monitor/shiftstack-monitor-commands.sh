#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD

echo 'Generating the metrics file...'
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"

METRICS_FILE="${SHARED_DIR}/metrics-${CLUSTER_TYPE}.txt"

if ./metrics.sh > "$METRICS_FILE"; then
	echo 'Metrics generation was successful. Uploading...'
	export OS_CLIENT_CONFIG_FILE=/var/run/cluster-secrets/openstack/clouds.yaml
	openstack object create \
		--name "$(basename "$METRICS_FILE")" \
		shiftstack-metrics \
		"$METRICS_FILE"
else
	echo 'Metrics generation was unsuccessful. Deleting the old metrics file...'
	export OS_CLIENT_CONFIG_FILE=/var/run/cluster-secrets/openstack/clouds.yaml
	openstack object delete shiftstack-metrics "$(basename "$METRICS_FILE")" || true
fi
