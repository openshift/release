#!/usr/bin/env bash
set -euo pipefail

echo "Applying ImageTagMirrorSet for origin-cli (${ORIGIN_CLI_SOURCE} -> ${ORIGIN_CLI_MIRROR})..."

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: kueue-e2e-origin-cli
spec:
  imageTagMirrors:
    - source: ${ORIGIN_CLI_SOURCE}
      mirrors:
        - ${ORIGIN_CLI_MIRROR}
EOF

echo "Waiting for MachineConfigPool rollout..."
sleep 10
for pool in master worker; do
  oc wait "machineconfigpool/${pool}" --for=condition=Updating=True --timeout=120s 2>/dev/null || true
  oc wait "machineconfigpool/${pool}" --for=condition=Updated=True --for=condition=Degraded=False --timeout=20m
done

echo "origin-cli ImageTagMirrorSet rollout completed."
