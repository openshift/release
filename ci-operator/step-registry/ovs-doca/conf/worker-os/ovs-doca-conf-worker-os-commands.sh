#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Scope the DOCA-layered RHCOS image to the WORKER POOL ONLY: write an
# install-time MachineConfig (worker role label) whose spec.osImageURL points
# at the pre-built layered image. ipi-install picks up
# ${SHARED_DIR}/manifest_*.yml into the installer's manifests, so the config
# is rendered during cluster bring-up and worker nodes rebase onto the layered
# image while provisioning (day-0) -- while control-plane nodes keep the stock
# OS. Same mechanism as the OVN IPsec pre-built layered image
# (ovn-conf-ipsec-manifest) and the baremetalds custom-RHCOS rollouts.
#
# The layered image must be a bootable ostree container (built with
# `ostree container commit`) and must be pullable by the nodes: anonymous
# pull from a public registry, or covered by the cluster pull-secret.

if [[ -z "${OVS_DOCA_LAYERED_IMAGE}" ]]; then
  echo "ERROR: OVS_DOCA_LAYERED_IMAGE must be set (full pullspec of the DOCA-layered RHCOS image)"
  exit 1
fi

MANIFEST="${SHARED_DIR}/manifest_ovs-doca-worker-os.yml"
cat > "${MANIFEST}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-ovs-doca-os
spec:
  osImageURL: "${OVS_DOCA_LAYERED_IMAGE}"
EOF

echo "wrote ${MANIFEST}:"
cat "${MANIFEST}"
echo "workers will rebase onto ${OVS_DOCA_LAYERED_IMAGE} during provisioning; control-plane nodes keep the stock OS"
