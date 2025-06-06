#!/bin/bash

# TODO: should use configurable branch instead of 'devel'?
podvm_img_url="https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/devel/config/peerpods/podvm/"
configmap_path="${SHARED_DIR:-$(pwd)}/env-cm.yaml"

# TODO: still needed? 600 seconds will cause the step timeout?
#echo "Giving a 10min stabilization time for AWS fresh 4.18 cluster before applying kataconfig as workaround for KATA-3451"
#sleep 600

if [[ "$TEST_RELEASE_TYPE" == "Pre-GA" ]]; then
  # TODO: implement me.
  echo "Apply catalog source. Not implemented."
  exit 1
fi

cat <<EOF | tee "${configmap_path}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: osc-config
  namespace: default
data:
  catalogsourcename: "${CATALOG_SOURCE_NAME}"
  operatorVer: "${OPERATOR_INDEX_VERSION}"
  channel: "${OPERATOR_UPDATE_CHANNEL}"
  redirectNeeded: "true"
  exists: "true"
  labelSingleNode: "false"
  eligibility: "false"
  eligibleSingleNode: "false"
  enableGPU: "${ENABLEGPU}"
  podvmImageUrl: "${podvm_img_url}"
  runtimeClassName: "${RUNTIMECLASS}"
  enablePeerPods: "${ENABLEPEERPODS}"
  mustgatherimage: "registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:latest"
  workloadImage: "${WORKLOAD_IMAGE}"
  installKataRPM: "${INSTALL_KATA_RPM}"
  workloadToTest: "${WORKLOAD_TO_TEST}"
EOF

oc create -f "${configmap_path}"