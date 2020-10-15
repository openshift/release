#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]
then
	# HACK: backwards-compat while the cluster profiles are updated.
	cp "${CLUSTER_PROFILE_DIR}/insights-live.yaml" "${CLUSTER_PROFILE_DIR}/day-2-manifests-insights-live.yaml"
fi

for FILE in "${CLUSTER_PROFILE_DIR}"/day-2-manifests-*.yaml "${SHARED_DIR}"/day-2-manifests-*.yaml
do
	echo "Creating ${FILE}..."
	oc create -f "${FILE}"
done

echo "Finished creating manifests."
