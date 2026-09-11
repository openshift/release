#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
REPO_ROOT="$DIR/../.."

METERING_NS=metering

# project must exist before we can create other resources in it
echo "Creating metering project"
oc apply \
    -f "$DIR/project.yaml"

echo "Creating team-metering group"
# update our metering groups
oc apply \
    -f "$DIR/group.yaml"

echo "Installing metering project RBAC"
# install everything else to our project
oc apply \
    -n "$METERING_NS" \
    -f "$DIR/rbac.yaml"

echo "Installing metering project image-pruner"
oc apply \
    -n "$METERING_NS" \
    -f "$REPO_ROOT/cluster/ci/jobs/image-pruner.yaml"
