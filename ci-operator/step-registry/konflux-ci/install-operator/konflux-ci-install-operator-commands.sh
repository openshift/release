#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Konflux on OpenShift..."

# With clone: true, ci-operator clones the repo to the current working directory
# Check if deploy script exists in current dir (cloned by ci-operator)
if [[ -f "./deploy-konflux-on-ocp.sh" ]]; then
    echo "Using repo cloned by ci-operator in current directory"
elif [[ -d "/go/src/github.com/konflux-ci/konflux-ci" ]]; then
    echo "Using repo at /go/src/github.com/konflux-ci/konflux-ci"
    cd /go/src/github.com/konflux-ci/konflux-ci
else
    echo "Repo not found, cloning manually to /tmp/konflux-ci..."
    git clone --branch "${KONFLUX_BRANCH:-main}" https://github.com/konflux-ci/konflux-ci.git /tmp/konflux-ci
    cd /tmp/konflux-ci
fi

echo "Running deploy-konflux-on-ocp.sh..."
./deploy-konflux-on-ocp.sh

echo "Konflux installation complete."
