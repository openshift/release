#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

workerCount=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

cat > /tmp/cluster-skeleton.yaml <<'SKELETON'
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata: {}
spec:
  license:
    accept: true
    license: data-management
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
    roles: []
SKELETON

yq -o json /tmp/cluster-skeleton.yaml | \
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
      .spec.daemon.roles = [
        { name: "client", resources: { cpu: $clientCpu, memory: $clientMem } },
        { name: "storage", resources: { cpu: $storageCpu, memory: $storageMem } }
      ] |
      if $quorum == 1 then .spec.quorum = { autoAssign: true } else . end
    ' | \
  oc create --dry-run=client -o json --save-config -f - | \
  oc apply -f -

oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  cluster/"${FA__SCALE__CLUSTER_NAME}" \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout="${FA__SCALE__CLUSTER_READY_TIMEOUT}"

true
