#!/bin/bash

# TODO: do here only the preliminary workarounds
# so that we can have the cleanest possible set of
# changes in the hypershift-kubevirt-create step

set -exuo pipefail

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "root@${IP}:/etc/pki/ca-trust/source/anchors/registry.2.crt" "${SHARED_DIR}/registry.2.crt"
