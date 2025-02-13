#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

export HOME=/tmp
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export SSH_PUB_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-publickey
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere-aws/.awscred
export AWS_DEFAULT_REGION=us-east-1

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
installer_dir=/tmp/installer

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p "${installer_dir}/auth"
mkdir -p "${installer_dir}/secrets"
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/install-config.yaml" \
    "${SHARED_DIR}/metadata.json" \
    "${SHARED_DIR}/terraform.tfvars" \
    "${SHARED_DIR}/secrets.auto.tfvars" \
    "${SHARED_DIR}/variables.ps1" \
    "${SHARED_DIR}/bootstrap.ign" \
    "${SHARED_DIR}/worker.ign" \
    "${SHARED_DIR}/master.ign"

cp -t "${installer_dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"

if command -v pwsh &> /dev/null
then
    cp -t "${installer_dir}/secrets" \
        "${SHARED_DIR}/vcenter-creds.xml"
fi

# Copy sample UPI files
cp -rt "${installer_dir}" \
    /var/lib/openshift-install/upi/"${CLUSTER_TYPE}"/*

export KUBECONFIG="${installer_dir}/auth/kubeconfig"

function gather_console_and_bootstrap() {
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/govc.sh"
    unset SSL_CERT_FILE
    unset GOVC_TLS_CA_CERTS
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

    # 4.5 and prior used the terraform.tfstate for gather bootstrap. This causes an error with:
    # state snapshot was created by Terraform v0.12.24, which is newer than current v0.12.20; upgrade to Terraform v0.12.24 or greater to work with this state"
    # move the state temporarily
    mv "${installer_dir}/terraform.tfstate" "${installer_dir}/terraform.tfstate.backup"
    openshift-install --log-level debug --dir="${installer_dir}" gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"
    mv "${installer_dir}/terraform.tfstate.backup" "${installer_dir}/terraform.tfstate"

}

function approve_csrs() {
  # The cluster won't be ready to approve CSR(s) yet anyway
  sleep 30

  echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
  while true; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
    sleep 15
    if [[ -f "/tmp/install-complete" ]]; then
        return 0
    fi
  done
}

function update_image_registry() {
  sleep 30

  echo "$(date -u --rfc-3339=seconds) - Waiting for imageregistry config to be available"
  while true; do
    oc get configs.imageregistry.operator.openshift.io/cluster > /dev/null && break
    sleep 15
  done

  echo "$(date -u --rfc-3339=seconds) - Configuring image registry with emptyDir..."
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

  echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to see that it has work to do..."
  sleep 30

  echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to go available..."
  oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m

  echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry to rollout..."
  oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=30m

  echo "$(date -u --rfc-3339=seconds) - Wait until imageregistry config changes are observed by kube-apiserver..."
  sleep 60

  echo "$(date -u --rfc-3339=seconds) - Waits for kube-apiserver to finish rolling out..."
  oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=30m

  oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=1m
}

function setE2eMirror() {

  oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 98-e2e-registry-mirror
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,dW5xdWFsaWZpZWQtc2VhcmNoLXJlZ2lzdHJpZXMgPSBbInJlZ2lzdHJ5LmFjY2Vzcy5yZWRoYXQuY29tIiwgImRvY2tlci5pbyJdCgpbW3JlZ2lzdHJ5XV0KcHJlZml4ID0gImRvY2tlci5pbyIKbG9jYXRpb24gPSAiZG9ja2VyLmlvIgoKW1tyZWdpc3RyeS5taXJyb3JdXQpsb2NhdGlvbiA9ICJlMmUtY2FjaGUudm1jLWNpLmRldmNsdXN0ZXIub3BlbnNoaWZ0LmNvbTo1MDAwIgo=
        mode: 0544
        overwrite: true
        path: /etc/containers/registries.conf
EOF
echo "Waiting for machineconfig to begin rolling out"
oc wait --for=condition=Updating mcp/worker --timeout=5m

echo "Waiting for machineconfig to finish rolling out"
oc wait --for=condition=Updated mcp/worker --timeout=30m

}

# inject porxy information into haproxy.service if deploying with proxy configuration
if proxy_info="$(cat install-config.yaml | grep -oP 'httpProxy\s*:\s*\K.*')" ; then
  echo "$(date -u --rfc-3339=seconds) - inject proxy env into haproxy service..."
  sed -i "/TimeoutStartSec=0/a Environment=HTTPS_PROXY=${proxy_info}" ./lb/haproxy.service
fi

# update haproxy image of haproxy.service on lb server if deploying cluster in a disconnected network
if [ -f ${SHARED_DIR}/haproxy-router-image ]; then
  echo "$(date -u --rfc-3339=seconds) - replace haproxy image with one in private registry on lb server"
  tgt_haproxy_image=$(head -1 "${SHARED_DIR}/haproxy-router-image")
  registry_auths=$(tail -1 "${SHARED_DIR}/haproxy-router-image")
  src_haproxy_image=$(grep "podman pull" ./lb/haproxy.service | awk -F' ' '{print $3}')
  sed -i "s#${src_haproxy_image}#${tgt_haproxy_image}#" ./lb/haproxy.service
  sed -i "s#/bin/podman pull #/bin/podman pull --creds=${registry_auths} --tls-verify=false #" ./lb/haproxy.service
fi

if [ ${SECURE_BOOT_ENABLED} = "true" ]; then
  sed -i '/guest_id/a\  firmware         = "efi"\n  efi_secure_boot_enabled = "true"' ./vm/main.tf
  sed -i "s/\$secureboot = \$false/\$secureboot = \$true/" ./variables.ps1
fi

if [ "${STORAGE_POLICY_ID}" != "" ]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/govc.sh"
  govc storage.policy.ls "${STORAGE_POLICY_ID}"
  ret="$?"
  if [ $ret -ne 0 ]; then
    echo "ERROR: Can not find storage policy id ${STORAGE_POLICY_ID}"
    exit "$ret"
  fi
  sed -i "/guest_id/a\ storage_policy_id = \"${STORAGE_POLICY_ID}\"" ./vm/main.tf
  sed -i "s/\$storagepolicy = \"\"/\$storagepolicy = \"${STORAGE_POLICY_ID}\"/" ./variables.ps1
fi

date +%s > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

if ! command -v pwsh &> /dev/null
then
  echo "$(date -u --rfc-3339=seconds) - terraform init..."
  terraform init -input=false -no-color &
  wait "$!"
fi

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

if ! command -v pwsh &> /dev/null
then
  echo "$(date -u --rfc-3339=seconds) - terraform apply..."
  terraform apply -auto-approve -no-color &
  wait "$!"
else
  echo "$(date -u --rfc-3339=seconds) - pwsh upi.ps1..."
  NO_COLOR=true pwsh -f powercli/upi.ps1 &
  wait "$!"
fi

echo "$(date -u --rfc-3339=seconds) - removing ignition..."
rm "${SHARED_DIR}/bootstrap.ign" \
    "${SHARED_DIR}/worker.ign" \
    "${SHARED_DIR}/master.ign"

# The terraform state could be larger than the maximum 1mb
# in a secret
if ! command -v pwsh &> /dev/null
then
  tar -Jcf "${SHARED_DIR}/terraform_state.tar.xz" terraform.tfstate
fi

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
  gather_console_and_bootstrap
  sed 's/password: .*/password: REDACTED/' "${installer_dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"
  echo "$(date -u --rfc-3339=seconds) - Copy log-bundle to artifacts directory..."
  cp --verbose "${installer_dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}"
  set -e
  exit "$ret"
fi

## Approving the CSR requests for nodes
approve_csrs &

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."

# When using line-buffering there is a potential issue that the buffer is not filled (or no new line) and this waits forever
# or in our case until the four hour CI timer is up.
openshift-install --dir="${installer_dir}" wait-for install-complete 2>&1 | stdbuf -o0 grep -v password &

set +e
wait "$!"
ret="$?"
set -e


## Configure image registry
update_image_registry

date +%s > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

touch /tmp/install-complete

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${installer_dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

sed 's/password: .*/password: REDACTED/' "${installer_dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

cp -t "${SHARED_DIR}" \
    "${installer_dir}/auth/kubeconfig"

# Maps e2e images on dockerhub to locally hosted mirror
if [[ $JOB_NAME =~ 4.6-e2e-vsphere.* ]]; then
  echo "Remapping dockerhub e2e images to local mirror for 4.6 e2e vSphere jobs"
  setE2eMirror

elif [[ $JOB_NAME =~ .*okd-4.*-e2e-vsphere.* ]]; then
  echo "Remapping dockerhub e2e images to local mirror for OKD e2e vSphere jobs"
  setE2eMirror

  echo "Patching cluster-samples-operator for OKD e2e vSphere jobs"
  oc --type=merge patch configs.samples.operator.openshift.io cluster -p='{"spec":{"samplesRegistry":"e2e-cache.vmc-ci.devcluster.openshift.com:5000"}}' -n openshift-cluster-samples-operator
fi

exit "$ret"
