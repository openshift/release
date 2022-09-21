#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE=/var/run/cluster-secrets/openstack/clouds.yaml

for metrics_file in "${SHARED_DIR}"/metrics-*.txt; do
	openstack object create \
		--name "$(basename "$metrics_file")" \
		shiftstack-metrics \
		"$metrics_file"
done
