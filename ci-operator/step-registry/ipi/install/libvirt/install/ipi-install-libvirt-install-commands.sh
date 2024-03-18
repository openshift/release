#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
}

function prepare_next_steps() {
  #Save exit code for must-gather to generate junit
  echo "$?" > "${SHARED_DIR}/install-status.txt"
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
}

function init_bootstrap() {
	local DIR=$1
	local CLUSTER_DOMAIN
	declare -g BOOTSTRAP_HOSTNAME
	declare -g RESOURCE_ID
	declare -ag BASTION_SSH_PORTS

	while [ ! -f "${DIR}/terraform.tfvars.json" ]
	do
		echo "init_bootstrap: waiting for ${DIR}/terraform.tfvars.json"
		sleep 3m
	done
	CLUSTER_DOMAIN=$(sed -n -r -e 's,^ *"cluster_domain": "([^"]*).*$,\1,p' "${DIR}/terraform.tfvars.json")
	BOOTSTRAP_HOSTNAME="bootstrap.${CLUSTER_DOMAIN}"
	RESOURCE_ID=$(echo "${CLUSTER_DOMAIN}" | cut -d- -f4)
	BASTION_SSH_PORTS=( 1033 1043 1053 1063 1073 1083 )
}

function init_worker() {

  local DIR=$1
  cat >> ${DIR}/manifests/99-sysctl-worker.yaml << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-sysctl-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          # kernel.sched_migration_cost_ns=25000
          source: data:text/plain;charset=utf-8;base64,a2VybmVsLnNjaGVkX21pZ3JhdGlvbl9jb3N0X25zID0gMjUwMDA=
        filesystem: root
        mode: 0644
        overwrite: true
        path: /etc/sysctl.conf
EOF

}

function collect_bootstrap() {
	local ID=$1
	local FROM
	local TO

	echo "collect_bootstrap: ssh ${BOOTSTRAP_HOSTNAME}:${BASTION_SSH_PORTS[${RESOURCE_ID}]}"
	set +e
	mock-nss.sh ssh \
		-o 'ConnectTimeout=1' \
		-o 'StrictHostKeyChecking=no' \
		-i ${CLUSTER_PROFILE_DIR}/ssh-privatekey \
		-l core \
		-p ${BASTION_SSH_PORTS[${RESOURCE_ID}]} \
		${BOOTSTRAP_HOSTNAME} \
		/usr/local/bin/installer-gather.sh --id ${ID}
	if [ $? -eq 0 ]
	then
		FROM="/var/home/core/log-bundle-${ID}.tar.gz"
		TO="/logs/artifacts/bootstrap-log-bundle-${ID}.tar.gz"
		echo "collect_bootstrap: scp ${BOOTSTRAP_HOSTNAME}:${BASTION_SSH_PORTS[${RESOURCE_ID}]}"
		mock-nss.sh scp \
			-o 'ConnectTimeout=1' \
			-o 'StrictHostKeyChecking=no' \
			-i ${CLUSTER_PROFILE_DIR}/ssh-privatekey \
			-P ${BASTION_SSH_PORTS[${RESOURCE_ID}]} \
			core@${BOOTSTRAP_HOSTNAME}:${FROM} ${TO}
	fi
	set -e
}

trap 'prepare_next_steps' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp
export KUBECONFIG=${HOME}/.kube/config

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

# Increase log verbosity and ensure it gets saved
export TF_LOG=DEBUG
export TF_LOG_PATH=${ARTIFACT_DIR}/terraform.log

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

echo "Creating manifest"
mock-nss.sh openshift-install create manifests --dir=${dir}
sed -i '/^  channel:/d' ${dir}/manifests/cvo-overrides.yaml

# Bump the libvirt masters memory to 16GB
export TF_VAR_libvirt_master_memory=${MASTER_MEMORY}
ls ${dir}/openshift
for ((i=0; i<${MASTER_REPLICAS}; i++))
do
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml spec.providerSpec.value[domainMemory] ${MASTER_MEMORY}
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml spec.providerSpec.value.volume[volumeSize] ${MASTER_DISK}
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml spec.providerSpec.value[domainVcpu] 6
done
# Bump the libvirt workers memory to 16GB
yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value[domainMemory] ${WORKER_MEMORY}
# Bump the libvirt workers disk to to 30GB
yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value.volume[volumeSize] ${WORKER_DISK}

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" -name "manifest_*.yml" -print0)

if [[ "${NODE_TUNING}" == "true" ]]; then
  init_worker ${dir}
fi

echo "Installing cluster"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

[ -z "${GATHER_BOOTSTRAP_LOGS+x}" ] && GATHER_BOOTSTRAP_LOGS=false
echo "GATHER_BOOTSTRAP_LOGS=${GATHER_BOOTSTRAP_LOGS}"
if ${GATHER_BOOTSTRAP_LOGS}
then
	declare -gx OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP
	OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP=1
else
	declare -g OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP
	OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP=""
fi

RCFILE=$(mktemp)
{
	set +e
	mock-nss.sh openshift-install create cluster --dir="${dir}" --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
	# We need to save the individual return codes for the pipes
	printf "RC0=%s\nRC1=%s\n" "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" > ${RCFILE};
} &
openshift_install="$!"

init_bootstrap ${dir}

wait "${openshift_install}"

# shellcheck source=/dev/null
source ${RCFILE}
echo "RC0=${RC0}"
echo "RC1=${RC1}"
rm ${RCFILE}
ret=${RC0}

if [ ${ret} -gt 0 ] || [ -n "${OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP}" ]
then
	collect_bootstrap 1
fi

if [ ${ret} -gt 0 ]
then
	# Add a step to wait for installation to complete, in case the cluster takes longer to create than the default time of 30 minutes.
	RCFILE=$(mktemp)
	{
		set +e
		mock-nss.sh openshift-install --dir=${dir} --log-level=debug wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
		# We need to save the individual return codes for the pipes
		printf "RC0=%s\nRC1=%s\n" "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" > ${RCFILE}
	} &
	wait "$!"

	# shellcheck source=/dev/null
	source ${RCFILE}
	echo "RC0=${RC0}"
	echo "RC1=${RC1}"
	rm ${RCFILE}
	ret=${RC0}

	if [ ${ret} -gt 0 ] || [ -n "${OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP}" ]
	then
		collect_bootstrap 2
	fi
fi

if [ -n "${OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP}" ]
then
	{
		set +e
		mock-nss.sh openshift-install --dir=${dir} --log-level=debug destroy bootstrap
		echo "destroy bootstrap: RC=$?"
	}
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "${ret}"
