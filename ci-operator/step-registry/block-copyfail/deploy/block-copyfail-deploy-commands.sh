#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying block-copyfail BPF LSM DaemonSet..."
echo "  Image: ${MITIGATION_LOADER_IMAGE}"

sed "s|image: .*|image: ${MITIGATION_LOADER_IMAGE}|" daemonset.yaml | oc apply -f -

echo "Waiting for DaemonSet rollout..."
oc -n openshift-cve-mitigations rollout status daemonset/kernel-ebpf-lsm-loader --timeout=300s

echo "DaemonSet deployed successfully:"
oc get pods -n openshift-cve-mitigations -o wide

echo "Checking mitigation-loader logs..."
oc logs -n openshift-cve-mitigations -l app=kernel-ebpf-lsm-loader --tail=5
