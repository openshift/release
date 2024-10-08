#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

# Download the kube-burner-ocp tarball


current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

# The measurable run
iteration_multiplier=$(($ITERATION_MULTIPLIER_ENV))
export ITERATIONS=$(($iteration_multiplier*$current_worker_count))

./kube-burner-ocp network-policy --iterations ${ITERATIONS} --pods-per-namespace ${PODS_PER_NAMESPACE} --netpol-per-namespace ${NETPOL_PER_NAMESPACE} --local-pods ${LOCAL_PODS} --single-ports ${SINGLE_PORTS} --port-ranges ${PORT_RANGES} --remotes-namespaces ${REMOTE_NAMESPACES} --remotes-pods ${REMOTE_PODS} --cidrs ${CIDR}

