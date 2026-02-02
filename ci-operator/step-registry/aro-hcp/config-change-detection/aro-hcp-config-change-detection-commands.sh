#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Validate configurations
if ! make validate-config; then
  echo "##################################################################"
  echo "##                                                              ##"
  echo "##   If you intended to change the service configuration, run   ##"
  echo "##       make -C config/ materialize                            ##"
  echo "##   and check in the result.                                   ##"
  echo "##                                                              ##"
  echo "##################################################################"
  exit 1
fi

# Validate configurations and pipelines
make validate-config-pipelines

# Generate Pipeline Inventory
cd docs/
make pipelines.md
cd ..

# Check for uncommitted changes in config
cd config/
make detect-change


