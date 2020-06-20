#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script is intended to execute the equivalent of upstream ci job
# pull-kubernetes-e2e-gce against aws.

# Execute OpenShift prerequisites
# Disable container security
oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts
oc adm policy add-scc-to-group anyuid system:authenticated system:serviceaccounts
# Mark the master nodes as unschedulable so tests ignore them
oc get nodes -o name -l 'node-role.kubernetes.io/master' | xargs -L1 oc adm cordon
unschedulable="$( ( oc get nodes -o name -l 'node-role.kubernetes.io/master'; ) | wc -l )"

# Configure ssh testing
KUBE_SSH_BASTION="$( oc --insecure-skip-tls-verify get node -l node-role.kubernetes.io/master -o 'jsonpath={.items[0].status.addresses[?(@.type=="ExternalIP")].address}' ):22"
KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export KUBE_SSH_BASTION KUBE_SSH_KEY_PATH
mkdir -p ~/.ssh
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
export KUBE_SSH_USER=core

test_report_dir="${ARTIFACT_DIR}"
mkdir -p "${test_report_dir}"

kube-e2e-tests \
  -num-nodes 4 \
  -ginkgo.noColor \
  '--ginkgo.skip=\[Slow\]|\[Serial\]|\[Disruptive\]|\[Flaky\]|\[Feature:.+\]' \
  -report-dir "${test_report_dir}" \
  -allowed-not-ready-nodes ${unschedulable} \
  2>&1 | tee -a "${test_report_dir}/e2e.log"
