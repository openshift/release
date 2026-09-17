#!/bin/bash

configmap_path="${SHARED_DIR:-$(pwd)}/env-cm.yaml"

# TODO: still needed? 600 seconds will cause the step timeout?
#echo "Giving a 10min stabilization time for AWS fresh 4.18 cluster before applying kataconfig as workaround for KATA-3451"
#sleep 600

cat <<EOF | tee "${configmap_path}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: osc-config
  namespace: default
data:
  catalogsourcename: "${CATALOG_SOURCE_NAME}"
  operatorVer: ""
  channel: "${OPERATOR_UPDATE_CHANNEL}"
  redirectNeeded: "false"
  exists: "true"
  labelSingleNode: "false"
  eligibility: "false"
  eligibleSingleNode: "false"
  enableGPU: "${ENABLEGPU}"
  podvmImageUrl: "${PODVM_IMAGE_URL}"
  runtimeClassName: "${RUNTIMECLASS}"
  trusteeUrl: "${TRUSTEE_URL}"
  INITDATA: "${INITDATA}"
  enablePeerPods: "${ENABLEPEERPODS}"
  mustgatherimage: "${MUST_GATHER_IMAGE}"
  workloadImage: "${WORKLOAD_IMAGE}"
  installKataRPM: "false"
  workloadToTest: "${WORKLOAD_TO_TEST}"
EOF

oc create -f "${configmap_path}"
