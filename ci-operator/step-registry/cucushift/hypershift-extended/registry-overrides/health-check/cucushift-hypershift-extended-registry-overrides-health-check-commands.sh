#!/usr/bin/env bash

set -euxo pipefail

function check_resources_using_image_from_repo() {
    local namespace_arg="$1"
    local repo="$2"
    local result

    result=$(eval "oc get $RESOURCE_TYPES $namespace_arg -o json" | \
jq -r --arg repo "$repo" \
'.items[] | select(.spec.template.spec.containers[].image | startswith($repo)) | "\(.kind) -n \(.metadata.namespace) \(.metadata.name)"')

    if [[ -n "$result" ]]; then
        printf "Found the following resources using image from repository %s:\n%s" "$repo" "$result" >&2
        return 1
    fi
}

REGISTRY_OVERRIDES_FILE="$SHARED_DIR"/hypershift_operator_registry_overrides
if [[ ! -f "$REGISTRY_OVERRIDES_FILE" ]]; then
    echo "Registry override file $REGISTRY_OVERRIDES_FILE not found, exiting" >&2
    exit 1
fi

# Get cluster namespace
CLUSTER_NAME="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
CLUSTER_NAMESPACE="clusters-$CLUSTER_NAME"

# Parse registry overrides file
SRC_LIST=()
DEST_LIST=()
while read -r line || [[ -n "$line" ]]; do
    if [[ -z $line ]]; then
        continue
    fi

    IFS='=' read -r src dest <<< "$line"
    if [[ -z $src ]]; then
        echo "Empty source repository, exiting" >&2
        exit 1
    fi
    if [[ -z $dest ]]; then
        echo "Empty destination repository, exiting" >&2
        exit 1
    fi
    SRC_LIST+=("$src")
    DEST_LIST+=("$dest")
done < "$REGISTRY_OVERRIDES_FILE"

if (( ${#SRC_LIST[@]} == 0 )); then
    echo "Empty source repository list" >&2
    exit 1
fi
if (( ${#DEST_LIST[@]} == 0 )); then
    echo "Empty destination repository list" >&2
    exit 1
fi

# Check control plane
RESOURCE_TYPES="deployments,daemonsets,statefulsets"
for src_repo in "${SRC_LIST[@]}"; do
    check_resources_using_image_from_repo "-n $CLUSTER_NAMESPACE" "$src_repo"
done

# TODO: check data plane once https://issues.redhat.com/browse/OCPBUGS-41365 is resolved
