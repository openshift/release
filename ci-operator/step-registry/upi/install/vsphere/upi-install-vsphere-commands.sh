#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export SSH_PUB_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-publickey
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_DEFAULT_REGION=us-east-1

tfvars_path=/var/run/secrets/ci.openshift.io/cluster-profile/vmc.secret.auto.tfvars
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
installer_dir=/tmp/installer

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p "${installer_dir}/auth"
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/install-config.yaml" \
    "${SHARED_DIR}/metadata.json" \
    "${SHARED_DIR}/terraform.tfvars" \
    "${SHARED_DIR}/bootstrap.ign" \
    "${SHARED_DIR}/worker.ign" \
    "${SHARED_DIR}/master.ign"

cp -t "${installer_dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"

# Copy sample UPI files
cp -rt "${installer_dir}" \
    /var/lib/openshift-install/upi/"${CLUSTER_TYPE}"/*

# Copy secrets to terraform path
cp -t "${installer_dir}" \
    ${tfvars_path}

export KUBECONFIG="${installer_dir}/auth/kubeconfig"

function gather_bootstrap_and_fail() {
    set +e
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/govc.sh"
    # list all the virtual machines in the folder/rp
    clustervms=$(govc ls "/${GOVC_DATACENTER}/vm/${cluster_name}")
    GATHER_BOOTSTRAP_ARGS=()
    for ipath in $clustervms; do
      # split on /
      # shellcheck disable=SC2162
      IFS=/ read -a ipath_array <<< "$ipath";
      hostname=${ipath_array[-1]}

      # create png of the current console to determine if a virtual machine has a problem
      echo "$(date -u --rfc-3339=seconds) - capture console image"
      govc vm.console -vm.ipath="$ipath" -capture "${ARTIFACT_DIR}/${hostname}.png"

      # based on the virtual machine name create variable for each
      # with ip addresses as the value
      # wait 1 minute for an ip address to become available

      # shellcheck disable=SC2140
      declare "${hostname//-/_}_ip"="$(govc vm.ip -wait=1m -vm.ipath="$ipath" | awk -F',' '{print $1}')"
    done

    GATHER_BOOTSTRAP_ARGS+=('--bootstrap' "${bootstrap_0_ip}")
    GATHER_BOOTSTRAP_ARGS+=('--master' "${control_plane_0_ip}" '--master' "${control_plane_1_ip}" '--master' "${control_plane_2_ip}")

    set -e
    openshift-install --dir=/tmp/artifacts/installer gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"

  return 1
}

function approve_csrs() {
  # The cluster won't be ready to approve CSR(s) yet anyway
  sleep 30

  echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
  while true; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
    sleep 15
  done
}

function update_image_registry() {
  sleep 30

  echo "$(date -u --rfc-3339=seconds) - Waiting for imageregistry config to be available"
  while true; do
    oc get configs.imageregistry.operator.openshift.io/cluster > /dev/null && break
    sleep 15
  done

  echo "$(date -u --rfc-3339=seconds) - Patching image registry configuration..."
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
}

echo "$(date -u --rfc-3339=seconds) - terraform init..."
terraform init -input=false -no-color &
wait "$!"

echo "$(date -u --rfc-3339=seconds) - terraform apply..."
terraform apply -auto-approve -no-color &
wait "$!"

# The terraform state could be larger than the maximum 1mb
# in a secret
tar -Jcf "${SHARED_DIR}/terraform_state.tar.xz" terraform.tfstate

# To ease debugging of ip address use
cluster_domain=$(<"${SHARED_DIR}"/clusterdomain.txt)
host -t A "api.${cluster_domain}"

## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
openshift-install --dir="${installer_dir}" wait-for bootstrap-complete &

set +e
wait "$!"
ret="$?"
set -e

if [ $ret -ne 0 ]; then
  set +e
  # Attempt to gather bootstrap logs.
  echo "$(date -u --rfc-3339=seconds) - Bootstrap failed, attempting to gather bootstrap logs..."
  gather_bootstrap_and_fail
  sed 's/password: .*/password: REDACTED/' "${installer_dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"
  cp log-bundle-*.tar.gz "${ARTIFACT_DIR}"
  set -e
  exit "$ret"
fi

## Approving the CSR requests for nodes
approve_csrs &

## Configure image registry
update_image_registry &

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."
openshift-install --dir="${installer_dir}" wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

set +e
wait "$!"
ret="$?"
set -e

sed 's/password: .*/password: REDACTED/' "${installer_dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

cp -t "${SHARED_DIR}" \
    "${installer_dir}/auth/kubeconfig"

popd
