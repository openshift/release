#!/usr/bin/env bash

set -ex

DEFAULT_ORG="openstack-k8s-operators"

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo "${JOB_SPEC}" | jq -r '.refs.repo')
REF_ORG=$(echo "${JOB_SPEC}" | jq -r '.refs.org')

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$DEFAULT_ORG" ]]; then
    echo "Not a ${DEFAULT_ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[0].org')
    if [[ "$EXTRA_REF_ORG" != "$DEFAULT_ORG" ]]; then
      echo "Failing since this step supports only ${DEFAULT_ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi

# custom per project ENV variables
# shellcheck source=/dev/null
if [ -f /go/src/github.com/"${DEFAULT_ORG}"/"${BASE_OP}"/.prow_ci.env ]; then
  source /go/src/github.com/"${DEFAULT_ORG}"/"${BASE_OP}"/.prow_ci.env
fi

HIVE_KUBECONFIG=${KUBECONFIG}

# Getting info from jobs's namespace
set +x
unset KUBECONFIG

OCP_API_USER=$(oc whoami | cut -d ":" -f4)
OCP_API_TOKEN=$(oc whoami -t)
CI_REGISTRY=$(oc get is pipeline -o json | jq -r .status.publicDockerImageRepository | cut -d "/" -f1)

# Back to hive's ephemeral cluster
export KUBECONFIG=${HIVE_KUBECONFIG}

# Get one master node to run debug pod
MASTER_NODE=$(oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}')
if [[ -z $MASTER_NODE ]]; then
    echo "Error: Can't find a master node"
    exit 1
fi

# Run operator scan
REPORT_FILE="/tmp/fips-check-operator-scan.log"

# Registry login
oc -n "${NS_FIPS_CHECK}" --request-timeout=60s debug node/"${MASTER_NODE}" -T -- chroot /host /usr/bin/bash -c "mkdir -p /tmp/auth; XDG_RUNTIME_DIR=/tmp/auth podman login ${CI_REGISTRY} -u ${OCP_API_USER} -p ${OCP_API_TOKEN}"
# Sleep to wait previous pod destruction
sleep 60
# Run operator scan
set -x
oc -n "${NS_FIPS_CHECK}" --request-timeout=300s debug node/"${MASTER_NODE}" -T -- chroot /host /usr/bin/bash -c "podman run --authfile /var/lib/kubelet/config.json --privileged -i -v /:/myroot -v /tmp/auth:/root/auth -e XDG_RUNTIME_DIR=/root/auth registry.ci.openshift.org/ci/check-payload:latest scan operator --spec ${OPERATOR_IMG} --output-file ${REPORT_FILE}" || true
sleep 30
REPORT_OUT=$(oc -n "${NS_FIPS_CHECK}" --request-timeout=300s debug node/"${MASTER_NODE}" -- chroot /host bash -c "cat ${REPORT_FILE}" || true)
REPORT_RES=$(echo "${REPORT_OUT}" | grep -E 'Failure Report|Successful run with warnings|Warning Report' || true)

# Save content in artifact dir
echo $REPORT_OUT > "${ARTIFACT_DIR}/fips-check-operator-scan.log"

# Fail only if flag is set to true
if [[ -n $REPORT_RES && $FAIL_FIPS_CHECK = true ]];then
  exit 1
fi
