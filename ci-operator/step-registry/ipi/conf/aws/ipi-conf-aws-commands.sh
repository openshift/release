#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '4 hours' --iso=minutes --utc)

function join_by { local IFS="$1"; shift; echo "$*"; }

REGION="${LEASED_RESOURCE}"
case "${REGION}" in
us-east-1)
    ZONES=("us-east-1b" "us-east-1c")
    ;;
*)
    ZONES=("${REGION}a" "${REGION}b")
esac

ZONES_COUNT=${ZONES_COUNT:-2}
ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
ZONES_STR="[ "
ZONES_STR+=$(join_by , "${ZONES[@]}")
ZONES_STR+=" ]"
echo "AWS region: ${REGION} (zones: ${ZONES_STR})"


# Every AWS cluster should have a PV for prometheus data so that data is preserved across
# reschedules of pods. This may need to be conditionally disabled in the future if certain
# instance types are used that cannot access persistent volumes.
cat >> "${SHARED_DIR}/manifest_prometheus-config.yml" << EOF
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

cat >> "${CONFIG}" << EOF
baseDomain: origin-ci-int-aws.dev.rhcloud.com
controlPlane:
  name: master
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- name: worker
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
      zones: ${ZONES_STR}
platform:
  aws:
    region: ${REGION}
    userTags:
      expirationDate: ${expiration_date}
EOF
