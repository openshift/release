#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

typeset -i workerCount=0
workerCount=$(
  oc get nodes \
    -l node-role.kubernetes.io/worker= \
    -o jsonpath-as-json='{.items[*].metadata.name}' |
  jq 'length'
)

{
  oc create -f - --dry-run=client -o json --save-config |
  jq \
    --arg ns "${FA__SCALE__NAMESPACE}" \
    --arg name "${FA__SCALE__CLUSTER_NAME}" \
    --arg clientCpu "${FA__SCALE__CLIENT_CPU}" \
    --arg clientMem "${FA__SCALE__CLIENT_MEMORY}" \
    --arg storageCpu "${FA__SCALE__STORAGE_CPU}" \
    --arg storageMem "${FA__SCALE__STORAGE_MEMORY}" \
    --argjson quorum "$(( workerCount >= 3 ? 1 : 0 ))" \
    '
      .metadata.name = $name |
      .metadata.namespace = $ns |
      .spec.daemon.roles[0].resources = { cpu: $clientCpu, memory: $clientMem } |
      .spec.daemon.roles[1].resources = { cpu: $storageCpu, memory: $storageMem } |
      if $quorum == 0 then del(.spec.quorum) else . end
    '
} 0<<'SKELETON' | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata: {}
spec:
  license:
    accept: true
    license: data-management
  quorum:
    autoAssign: true
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    nsdDevicesConfig:
      localDevicePaths:
      - devicePath: /dev/disk/by-id/*
        deviceType: generic
    clusterProfile:
      controlSetxattrImmutableSELinux: "yes"
      enforceFilesetQuotaOnRoot: "yes"
      ignorePrefetchLUNCount: "yes"
      initPrefetchBuffers: "128"
      maxblocksize: "16M"
      prefetchPct: "25"
      prefetchTimeout: "30"
    roles:
    - name: client
      resources: {}
    - name: storage
      resources: {}
SKELETON

oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  cluster/"${FA__SCALE__CLUSTER_NAME}" \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout="${FA__SCALE__CLUSTER_READY_TIMEOUT}"

true
