#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Every AWS cluster should have a PV for prometheus data so that data is preserved across
# reschedules of pods. This may need to be conditionally disabled in the future if certain
# instance types are used that cannot access persistent volumes.
cat >> "${SHARED_DIR}/manifest_cluster-monitoring-pvc.yml" << EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    prometheusK8s:
      volumeClaimTemplate:
        metadata:
          name: prometheus-data
        spec:
          resources:
            requests:
              storage: 10Gi
EOF
