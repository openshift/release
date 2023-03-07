#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


function check_pod_status() {
    INTERVAL=60
    CNT=10
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
            oc -n "${MAISTRA_NAMESPACE}" get pods "$1"
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
    resources:
      requests:
        memory: 1Gi
        cpu: '2'
        ${RESOURCE_REQUEST:-}
      limits:
        memory: 1Gi
        cpu: '2'
        ${RESOURCE_REQUEST:-}
    volumeMounts:
    - mountPath: /lib/modules
      name: modules
      readOnly: true
    - mountPath: /sys/fs/cgroup
      name: cgroup
      readOnly: true
    - mountPath: /var/lib/docker
      name: varlibdocker
      readOnly: false
  volumes:
  - hostPath:
      path: /lib/modules
      type: Directory
    name: modules
  - hostPath:
      path: /sys/fs/cgroup
      type: Directory
    name: cgroup
  - emptyDir: {}
    name: varlibdocker
EOF
}

create_namespace "${MAISTRA_NAMESPACE}"
create_pod "${MAISTRA_SC_POD}"
create_pod "${MAISTRA_MC_POD}"
check_pod_status "${MAISTRA_SC_POD}"
check_pod_status "${MAISTRA_MC_POD}"

echo "Successfully created maistra istio builder pods"
