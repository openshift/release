#!/bin/bash

# TODO: should use configurable branch instead of 'devel'?
podvm_img_url="https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/devel/config/peerpods/podvm/"
configmap_path="${SHARED_DIR:-$(pwd)}/env-cm.yaml"

# TODO: still needed? 600 seconds will cause the step timeout?
#echo "Giving a 10min stabilization time for AWS fresh 4.18 cluster before applying kataconfig as workaround for KATA-3451"
#sleep 600

create_catsrc() {
  local catsrc_name="$1"
  local catsrc_version="$2"
  local catsrc_image="$3"
  local catsrc_path="${SHARED_DIR:-$(pwd)}/catsrc_${catsrc_name}.yaml"

  echo "Create a custom catalogsource named ${catsrc_name} for internal builds"

  cat<<-EOF | tee "${catsrc_path}"
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: "${catsrc_name}"
    namespace: openshift-marketplace
  spec:
    displayName: QE
    image: "${catsrc_image}:${catsrc_version}"
    publisher: QE
    sourceType: grpc
EOF

  oc apply -f "${catsrc_path}"
}

mirror_konflux() {
  local mirror_path="${SHARED_DIR:-$(pwd)}/mirror_konflux.yaml"

  echo "Create mirror for konflux images"

cat<<EOF | tee "${mirror_path}"
---
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: osc-registry
spec:
  imageTagMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-monitor
      source: registry.redhat.io/openshift-sandboxed-containers/osc-monitor-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-caa
      source: registry.redhat.io/openshift-sandboxed-containers/osc-cloud-api-adaptor-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-caa-webhook
      source: registry.redhat.io/openshift-sandboxed-containers/osc-cloud-api-adaptor-webhook-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-builder
      source: registry.redhat.io/openshift-sandboxed-containers/osc-podvm-builder-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload
      source: registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-operator
      source: registry.redhat.io/openshift-sandboxed-containers/osc-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-must-gather
      source: registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-operator-bundle
      source: registry.redhat.io/openshift-sandboxed-containers/osc-operator-bundle
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: osc-registry
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-monitor
      source: registry.redhat.io/openshift-sandboxed-containers/osc-monitor-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-caa
      source: registry.redhat.io/openshift-sandboxed-containers/osc-cloud-api-adaptor-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-caa-webhook
      source: registry.redhat.io/openshift-sandboxed-containers/osc-cloud-api-adaptor-webhook-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-builder
      source: registry.redhat.io/openshift-sandboxed-containers/osc-podvm-builder-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload
      source: registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-operator
      source: registry.redhat.io/openshift-sandboxed-containers/osc-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-must-gather
      source: registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/osc-operator-bundle
      source: registry.redhat.io/openshift-sandboxed-containers/osc-operator-bundle
---
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: trustee-registry
spec:
  imageTagMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee
      source: registry.redhat.io/confidential-compute-attestation-tech-preview
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9-operator
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: trustee-registry
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee
      source: registry.redhat.io/confidential-compute-attestation-tech-preview
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9-operator
EOF

  oc apply -f "${mirror_path}"
}

if [[ "$TEST_RELEASE_TYPE" == "Pre-GA" ]]; then
  mirror_konflux
  create_catsrc "${CATALOG_SOURCE_NAME}" "${OPERATOR_INDEX_VERSION}" "${OPERATOR_INDEX_IMAGE}"
  create_catsrc "${TRUSTEE_CATALOG_SOURCE_NAME}" "${TRUSTEE_INDEX_VERSION}" "${TRUSTEE_INDEX_IMAGE}"
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
  trusteeCatalogSourcename: "${TRUSTEE_CATALOG_SOURCE_NAME}"
  trusteeUrl: "${TRUSTEE_URL}"
  enablePeerPods: "${ENABLEPEERPODS}"
  mustgatherimage: "${MUST_GATHER_IMAGE}"
  workloadImage: "${WORKLOAD_IMAGE}"
  installKataRPM: "${INSTALL_KATA_RPM}"
  workloadToTest: "${WORKLOAD_TO_TEST}"
EOF

oc create -f "${configmap_path}"
