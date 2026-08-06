#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Annotate the OADP namespace
echo "Annotate the openshift-adp namespace in the test cluster..."
oc annotate --overwrite namespace/openshift-adp volsync.backube/privileged-movers='true'
