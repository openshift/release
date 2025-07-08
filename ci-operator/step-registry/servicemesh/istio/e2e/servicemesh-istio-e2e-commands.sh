#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


function check_pod_status() {
    INTERVAL=60
    CNT=15
    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            pod_name=$(echo "${i}" | awk '{print $1}')
            pod_phase=$(echo "${i}" | awk '{print $3}')
            if [[ "${pod_phase}" == "Running" ]]; then
                READY=true
            else
                echo "Waiting for Pod ${pod_name} to be ready"
                READY=false
            fi
        done <<< "$(oc -n "${MAISTRA_NAMESPACE}" get pods "$1" --no-headers)"

        if [[ "${READY}" == "true" ]]; then
            echo "Pod $1 has successfully been deployed"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Pod $1 did not successfully deploy"
            oc -n "${MAISTRA_NAMESPACE}" describe pods "$1"
            return 1
        fi
    done
}

function create_namespace() {
  oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/audit: "privileged"
    pod-security.kubernetes.io/enforce: "privileged"
    pod-security.kubernetes.io/warn: "privileged"
EOF

  echo "Created \"$1\" Namespace"
}

function create_pod() {
  oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: ${MAISTRA_NAMESPACE}
  annotations:
    cpu-load-balancing.crio.io: "disable"
    cpu-quota.crio.io: "disable"
    ${ANNOTATIONS:-}
spec:
  containers:
  - name: testpmd
    command: ["sleep", "99999"]
    image: ${MAISTRA_BUILDER_IMAGE}
    securityContext:
      capabilities:
        add: ["IPC_LOCK","SYS_ADMIN"]
      privileged: true
      runAsUser: 0
    env:
    - name: BUILD_WITH_CONTAINER
      value: "${BUILD_WITH_CONTAINER:-}"
    - name: INTEGRATION_TEST_FLAGS
      value: "${INTEGRATION_TEST_FLAGS:-}"
    - name: DOCKER_REGISTRY_MIRRORS
      value: "${DOCKER_REGISTRY_MIRRORS:-}"
    - name: CI
      value: "${CI:-}"
    - name: ARTIFACTS
      value: "${ARTIFACT_DIR:-}"
    - name: JOB_NAME
      value: "${JOB_NAME:-}"
    - name: JOB_TYPE
      value: "${JOB_TYPE:-}"
    - name: BUILD_ID
      value: "${BUILD_ID:-}"
    - name: PROW_JOB_ID
      value: "${PROW_JOB_ID:-}"
    - name: REPO_OWNER
      value: "${REPO_OWNER:-}"
    - name: REPO_NAME
      value: "${REPO_NAME:-}"
    - name: PULL_BASE_REF
      value: "${PULL_BASE_REF:-}"
    - name: PULL_BASE_SHA
      value: "${PULL_BASE_SHA:-}"
    - name: PULL_REFS
      value: "${PULL_REFS:-}"
    - name: PULL_NUMBER
      value: "${PULL_NUMBER:-}"
    - name: PULL_PULL_SHA
      value: "${PULL_PULL_SHA:-}"
    - name: PULL_HEAD_REF
      value: "${PULL_HEAD_REF:-}"
    volumeMounts:
    - mountPath: /lib/modules
      name: modules
      readOnly: true
    - mountPath: /var/lib/docker
      name: varlibdocker
      readOnly: false
  volumes:
  - hostPath:
      path: /lib/modules
      type: Directory
    name: modules
  - emptyDir: {}
    name: varlibdocker
EOF
}

create_namespace "${MAISTRA_NAMESPACE}"
create_pod "${MAISTRA_SC_POD}"
check_pod_status "${MAISTRA_SC_POD}"
# create ARTIFACT_DIR
oc exec -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -c testpmd -- mkdir -p "${ARTIFACT_DIR}"

echo "Successfully created maistra istio builder pods"
