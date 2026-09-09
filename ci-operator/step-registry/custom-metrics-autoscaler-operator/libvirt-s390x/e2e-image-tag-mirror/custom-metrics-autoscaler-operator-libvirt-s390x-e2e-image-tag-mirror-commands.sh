#!/usr/bin/env bash
set -euo pipefail

echo "Applying ImageTagMirrorSet ${ITMS_NAME} for CMA/KEDA e2e test images..."

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ${ITMS_NAME}
spec:
  imageTagMirrors:
  - source: docker.io/library/busybox
    mirrors:
    - quay.io/libpod/busybox
  - source: docker.io/busybox
    mirrors:
    - quay.io/libpod/busybox
  - source: ghcr.io/kedacore/tests-metrics-api
    mirrors:
    - quay.io/meghagaur/tests-metrics-api
  - source: ghcr.io/kedacore/tests-external-scaler-e2e
    mirrors:
    - quay.io/meghagaur/tests-external-scaler-e2e
  - source: ghcr.io/kedacore/tests-hey
    mirrors:
    - quay.io/meghagaur/tests-hey
  - source: ghcr.io/kedacore/tests-external-scaler
    mirrors:
    - quay.io/meghagaur/tests-external-scaler
  - source: registry.k8s.io/hpa-example
    mirrors:
    - quay.io/meghagaur/hpa-example
  - source: docker.io/curlimages/curl
    mirrors:
    - quay.io/meghagaur/curl
  - source: docker.io/jimmidyson/configmap-reload
    mirrors:
    - quay.io/meghagaur/configmap-reload
  - source: docker.io/prom/prometheus
    mirrors:
    - quay.io/meghagaur/prom/prometheus
  - source: docker.io/library/rabbitmq
    mirrors:
    - quay.io/meghagaur/rabbitmq
  - source: ghcr.io/kedacore/tests-rabbitmq
    mirrors:
    - quay.io/meghagaur/tests-rabbitmq
EOF

wait_for_mcp_rollout() {
  local pool=$1
  echo "Waiting for MachineConfigPool/${pool} to start updating after ImageTagMirrorSet apply..."
  if ! oc wait "machineconfigpool/${pool}" --for=condition=Updating=True --timeout=7m; then
    echo "MachineConfigPool/${pool} did not start updating within 7m; ImageTagMirrorSet may not have been reconciled."
    exit 1
  fi
  echo "MachineConfigPool/${pool} is updating. Waiting for rollout to complete..."
  if ! oc wait "machineconfigpool/${pool}" --for=condition=Updated=True --for=condition=Degraded=False --timeout=20m; then
    echo "MachineConfigPool/${pool} rollout did not complete within 20m."
    exit 1
  fi
}

for pool in master worker; do
  wait_for_mcp_rollout "${pool}"
done

echo "ImageTagMirrorSet ${ITMS_NAME} rollout completed."
