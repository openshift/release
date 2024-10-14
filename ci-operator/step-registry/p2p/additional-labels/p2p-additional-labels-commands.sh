#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

operator_configs=$(env | grep -E '^OPERATOR[0-9]+_CONFIG' | sort --version-sort)

# Login to cluster
eval "$(cat "${SHARED_DIR}/api.login")"

# Populate operator version labels
extract_operator_config() {
    echo "$1" | sed -E 's/^OPERATOR[0-9]+_CONFIG=//'
}

for operator_value in $operator_configs; do
    operator_value=$(extract_operator_config "$operator_value")
    if [ "${operator_value}" ]; then
        name=$(echo $operator_value | sed -E 's/.*name=([^;]+);.*/\1/')
        namespace=$(echo $operator_value | sed -E 's/.*namespace=([^;]+);?.*/\1/')
        version=$(oc get csv -n "$namespace" -o json | jq -r --arg NAME_VALUE "$name" '.items[] | select(.metadata.name | contains($NAME_VALUE)) | .spec.version')
        echo "$name-v$version" >> "${SHARED_DIR}/firewatch-additional-labels"
    fi
done

# Populate cluster version label
cluster_version=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}')
if [ "$cluster_version" ]; then
    echo "ocp-v${cluster_version}" >> "${SHARED_DIR}/firewatch-additional-labels"
fi

echo "ADDITIONAL LABELS:"
cat "$SHARED_DIR"/firewatch-additional-labels