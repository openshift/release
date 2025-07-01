#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

CONFIG=${SHARED_DIR}/install-config.yaml
if [ ! -f "${CONFIG}" ] ; then
  echo "No install-config.yaml found, exit now"
  exit 1
fi


# case "${OCP_ARCH}" in
# amd64)
#     ARCH="x86_64"
#     ;;
# arm64)
#     ARCH="aarch64"
#     ;;
# *)
#     echo "${OCP_ARCH} is not supported, exit now"
#     exit 1
# esac

# default_ami=$(openshift-install coreos print-stream-json | jq -r --arg a $ARCH --arg r $REGION '.architectures[$a].images.aws.regions[$r].image')
# echo "AMI (default, \"openshift-install coreos print-stream-json\"): ${default_ami}"

function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

control_plane_ami=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" "Name=tag:Name,Values=*master*" --output json | jq -r '.Reservations[].Instances[].ImageId' | sort | uniq)
compute_ami=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" "Name=tag:Name,Values=*worker*" --output json | jq -r '.Reservations[].Instances[].ImageId' | sort | uniq)
echo "AMI used by cluster: controlPlane: [${control_plane_ami}], compute: [${compute_ami}]"

ret=0

ic_platform_ami=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.amiID')
ic_control_plane_ami=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.amiID')
ic_compute_ami=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.amiID')
echo "AMI in install-config: platform: [${ic_platform_ami}], controlPlane: [${ic_control_plane_ami}], compute: [${ic_compute_ami}]"

if test -f "${SHARED_DIR}/proxy-conf.sh" 
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi
# https://issues.redhat.com/browse/OCPBUGS-57348 Cluster manages bootimages despite explicit bootimages in installconfig
machineset_ami=$(oc get machineset.machine.openshift.io -n openshift-machine-api -A -ojson | jq -r '.items[] | .spec.template.spec.providerSpec.value.ami.id' | sort | uniq)
controlplanemachineset_ami=$(oc get controlplanemachineset.machine.openshift.io -n openshift-machine-api -A -ojson | jq -r '.items[] | .spec.template."machines_v1beta1_machine_openshift_io".spec.providerSpec.value.ami.id')
echo "AMI in MachineSet: [${machineset_ami}], CPMS AMI: [${controlplanemachineset_ami}]"

expected_control_plane_ami=""
expected_compute_ami=""

if ! is_empty "$ic_platform_ami"; then
    echo "platform.aws.defaultMachinePlatform.amiID was found: ${ic_platform_ami}"
    expected_control_plane_ami="${ic_platform_ami}"
    expected_compute_ami="${ic_platform_ami}"
fi

if ! is_empty "$ic_control_plane_ami"; then
    echo "controlPlane.platform.aws.amiID was found: ${ic_control_plane_ami}"
    expected_control_plane_ami="${ic_control_plane_ami}"
fi

if ! is_empty "$ic_compute_ami"; then
    echo "compute[0].platform.aws.amiID was found: ${ic_compute_ami}"
    expected_compute_ami="${ic_compute_ami}"
fi

if [[ ${expected_control_plane_ami} != "" ]]; then
    if [[ "${control_plane_ami}" != "${expected_control_plane_ami}" ]] || [[ "${controlplanemachineset_ami}" != "${expected_control_plane_ami}" ]]; then
        echo "FAIL: Control plane AMI mismatch: cluster: ${control_plane_ami}, CPMS: ${controlplanemachineset_ami}, expect: ${expected_control_plane_ami}"
        ret=$((ret+1))
    else
        echo "PASS: Control plane AMI."
    fi
else
    echo "SKIP: No AMI was configured for control plane nodes"
fi

if [[ ${expected_compute_ami} != "" ]]; then
    if [[ "${compute_ami}" != "${expected_compute_ami}" ]] || [[ "${machineset_ami}" != "${expected_compute_ami}" ]]; then
        echo "FAIL: Compute AMI mismatch: cluster: ${compute_ami}, machineset: ${machineset_ami}, expect: ${expected_compute_ami}"
        ret=$((ret+1))
    else
        echo "PASS: Compute AMI."
    fi
else
    echo "SKIP: No AMI was configured for compute nodes"
fi

exit $ret
