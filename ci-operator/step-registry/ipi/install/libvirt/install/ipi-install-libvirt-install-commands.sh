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
  if [[ -n "${IPI_ACPI_PATCHER_PID:-}" ]]; then
    kill "${IPI_ACPI_PATCHER_PID}" 2>/dev/null || true
    wait "${IPI_ACPI_PATCHER_PID}" 2>/dev/null || true
    unset IPI_ACPI_PATCHER_PID
  fi
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
	BASTION_SSH_PORTS=( 1033 1043 1053 1063 1073 1083 )
	# Pick bastion tunnel port by lease slice index. *.ci domains use hyphen-separated
	# segments (field 4 is the slice id). *.phc-cicd.cis.ibm.net merges "3.phc-..." into
	# field 4; use the last segment of LEASED_RESOURCE (e.g. libvirt-s390x-2-3 -> 3).
	RESOURCE_ID=$(echo "${CLUSTER_DOMAIN}" | cut -d- -f4)
	if ! [[ "${RESOURCE_ID}" =~ ^[0-9]+$ ]]; then
		RESOURCE_ID=$(echo "${LEASED_RESOURCE}" | rev | cut -d- -f1 | rev)
	fi
	if ! [[ "${RESOURCE_ID}" =~ ^[0-9]+$ ]]; then
		RESOURCE_ID=0
	fi
	if [ "${RESOURCE_ID}" -ge "${#BASTION_SSH_PORTS[@]}" ]; then
		RESOURCE_ID=0
	fi
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

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

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

# s390x + newer QEMU (e.g. default machine s390-ccw-virtio-rhel9.6.0): libvirt rejects domains that
# request ACPI, but openshift-install's terraform-provider-libvirt always enables ACPI in the
# default domain XML (domain_def.go). The provider supports xml.xslt on libvirt_domain.
# unpackAndInit() writes modules and runs terraform init in the same Go routine with no gap, so a
# parallel poller cannot patch .tf in time. We wrap ${dir}/terraform/bin/terraform (after UnpackTerraform
# drops the real binary, before the first init) to patch $(pwd) before each init/apply (fragile).

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
# For ppc64le s2s leases, generate Infra ID truncates the cluster name, which also removes the lease identifier.
# To ensure the lease name is preserved for post-cleanup, this workaround replaces the new truncated value with the original lease value.
if [[ "${LEASED_RESOURCE}" == *ppc64le* ]]; then
	pattern="$(echo "$LEASED_RESOURCE" | sed 's/-[^-]*$/-/')[a-zA-Z0-9]{5}"
	find "$dir" -type f -exec sed -i -E "s/${pattern}/${LEASED_RESOURCE}/g" {} +
fi

# terraform-provider-libvirt shells out to xsltproc when xml.xslt is set; libvirt-installer image
# may not ship it. Install before openshift-install runs terraform (s390x ACPI workaround only).
if [[ "${ARCH:-}" == "s390x" && "${IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH:-}" == "true" ]]; then
	if ! command -v xsltproc >/dev/null 2>&1; then
		set +e
		if command -v microdnf >/dev/null 2>&1; then
			microdnf install -y libxslt
		elif command -v dnf >/dev/null 2>&1; then
			dnf install -y libxslt
		elif command -v yum >/dev/null 2>&1; then
			yum install -y libxslt
		elif command -v apt-get >/dev/null 2>&1; then
			export DEBIAN_FRONTEND=noninteractive
			apt-get update && apt-get install -y xsltproc
		fi
		set -e
	fi
	if ! command -v xsltproc >/dev/null 2>&1; then
		echo "ERROR: xsltproc is required when IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH=true but could not be installed." >&2
		exit 1
	fi
fi

# CI workaround: inject xml.xslt before terraform init (see comment above).
if [[ "${ARCH:-}" == "s390x" && "${IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH:-}" == "true" ]]; then
	xsl="${dir}/s390x-strip-acpi.xsl"
	cat > "${xsl}" <<'XSL_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="xml" encoding="UTF-8" indent="yes"/>
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>
  <xsl:template match="acpi"/>
</xsl:stylesheet>
XSL_EOF
	patch_tf="${dir}/ipi-libvirt-s390x-patch-libvirt-domain-tf.sh"
	cat > "${patch_tf}" <<'PATCH_EOF'
#!/bin/bash
set -euo pipefail
work="${1:?}"
xsl="${2:?}"
[[ -d "${work}" ]] || exit 0
while IFS= read -r -d '' tf; do
	if grep -q 'ipi-ci-s390x-strip-acpi' "${tf}" 2>/dev/null; then
		continue
	fi
	if ! grep -q 'resource "libvirt_domain"' "${tf}" 2>/dev/null; then
		continue
	fi
	awk -v xsl="${xsl}" '
		/resource "libvirt_domain"/ {
			print
			print "  # ipi-ci-s390x-strip-acpi: XSLT strips ACPI for RHEL 9 QEMU s390-ccw-virtio-rhel9.*"
			print "  xml {"
			print "    xslt = file(\"" xsl "\")"
			print "  }"
			next
		}
		{ print }
	' "${tf}" > "${tf}.ipi_acpi_xslt.$$" && mv "${tf}.ipi_acpi_xslt.$$" "${tf}"
done < <(find "${work}" -name '*.tf' -print0 2>/dev/null)
PATCH_EOF
	chmod +x "${patch_tf}"
	(
		set +o errexit
		tfbin="${dir}/terraform/bin/terraform"
		deadline=$((SECONDS + 7200))
		# Wait for installer to create terraform bundle, then wrap before the first terraform init.
		while [[ ! -d "${dir}/terraform/bin" ]]; do
			if (( SECONDS >= deadline )); then exit 0; fi
			sleep 0.05
		done
		while [[ ! -f "${tfbin}" || ! -s "${tfbin}" ]]; do
			if (( SECONDS >= deadline )); then exit 0; fi
			sleep 0.001 2>/dev/null || sleep 0
		done
		if [[ -f "${tfbin}.real" ]]; then
			exit 0
		fi
		if ! mv "${tfbin}" "${tfbin}.real" 2>/dev/null; then
			exit 0
		fi
		cat >"${tfbin}" <<EOF
#!/bin/bash
set -euo pipefail
REAL="${tfbin}.real"
PATCH="${patch_tf}"
XSL="${xsl}"
if [[ "\${ARCH:-}" == "s390x" && "\${IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH:-}" == "true" ]]; then
	if [[ "\$1" == "init" || "\$1" == "plan" || "\$1" == "apply" ]]; then
		bash "\${PATCH}" "\$(pwd)" "\${XSL}"
	fi
fi
exec "\${REAL}" "\$@"
EOF
		chmod +x "${tfbin}"
	) &
	IPI_ACPI_PATCHER_PID=$!
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
