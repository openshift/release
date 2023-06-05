#!/bin/bash

#
# This step change replaces the default CSI from
# gp2-csi to gp3-csi.
# Some tests is failing when trying to provision gp3 volumes
# in AWS Local Zones that does not support that EBS type.
# AWS does not provide API to query it.
# See also the TEST_SKIPS related to gp3 volumes failing for
# incorrect EC2 endpoint on AWS Local Zones:
# https://issues.redhat.com/browse/OCPBUGS-11609
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Setting the gp2-csi storage class as default"
oc patch storageclass gp2-csi -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'

echo "Removing gp3-csi as default storage class"
oc patch storageclass gp3-csi -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'