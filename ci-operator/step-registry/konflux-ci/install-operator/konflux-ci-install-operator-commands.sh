#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Konflux on OpenShift..."

echo "Running deploy-konflux-on-ocp.sh..."
./deploy-konflux-on-ocp.sh

echo "Konflux installation complete."
