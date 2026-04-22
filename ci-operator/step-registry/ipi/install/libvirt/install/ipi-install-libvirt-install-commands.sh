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

# libvirt-installer runs as non-root (UID 1000); microdnf/yum cannot install packages. When we need
# xsltproc for the s390x ACPI terraform workaround, unpack CentOS Stream 9 libxml2/libxslt RPMs
# (same major userspace as the image) into /tmp and prepend PATH/LD_LIBRARY_PATH.
function ipi_stream9_pick_latest_rpm() {
	local pkg="$1"
	local html="$2"
	echo "${html}" | grep -oE "href=\"${pkg}-[0-9][^\"]*\\.rpm\"" | sed 's/href="//;s/"$//' \
		| grep -Ev -- '-(devel|static)' | LC_ALL=C sort -V | tail -n1
}

# Stream 9 libvirt-installer image has rpm2cpio but often no cpio(1); unpack newc cpio from rpm2cpio stdout.
function ipi_write_newc_cpio_unpack_py() {
	local out="$1"
	cat >"${out}" <<'PY'
import os, stat, sys

ALIGN = lambda n: (n + 3) & ~3


def readn(f, n):
	b = f.read(n)
	if len(b) != n:
		raise EOFError("expected %d bytes, got %d" % (n, len(b)))
	return b


def main(root):
	f = sys.stdin.buffer
	while True:
		magic = f.read(6)
		if not magic:
			return
		if magic != b"070701":
			raise SystemExit("cpiounpack: bad magic %r" % (magic,))
		rest = readn(f, 104).decode("ascii")
		nums = [int(rest[i : i + 8], 16) for i in range(0, 104, 8)]
		(
			_inode,
			mode,
			_uid,
			_gid,
			_nlink,
			_mtime,
			filesize,
			_devmaj,
			_devmin,
			_rdevmaj,
			_rdevmin,
			namesize,
			_chksum,
		) = nums
		namebuf = readn(f, namesize)
		name = namebuf.split(b"\x00", 1)[0]
		if name == b"TRAILER!!!":
			return
		pad = ALIGN(110 + namesize) - (110 + namesize)
		if pad:
			readn(f, pad)
		data = readn(f, filesize) if filesize else b""
		pad2 = ALIGN(filesize) - filesize
		if pad2:
			readn(f, pad2)
		rel = name.decode("utf-8", "surrogateescape").lstrip("./")
		if not rel or rel.startswith("../"):
			continue
		path = os.path.join(root, rel.replace("/", os.sep))
		if stat.S_ISDIR(mode):
			os.makedirs(path, exist_ok=True)
		elif stat.S_ISREG(mode):
			os.makedirs(os.path.dirname(path), exist_ok=True)
			with open(path, "wb") as outf:
				outf.write(data)
			os.chmod(path, mode & 0o7777)
		elif stat.S_ISLNK(mode):
			os.makedirs(os.path.dirname(path), exist_ok=True)
			tgt = data.split(b"\x00", 1)[0].decode("utf-8", "surrogateescape")
			if os.path.lexists(path):
				os.unlink(path)
			os.symlink(tgt, path)


if __name__ == "__main__":
	main(sys.argv[1])
PY
}

function ipi_extract_rpm_contents() {
	local rpm="$1"
	local dest="$2"
	local unpack_py="$3"
	if command -v cpio >/dev/null 2>&1; then
		( cd "${dest}" && rpm2cpio "${rpm}" | cpio -idm 2>/dev/null ) || return 1
	else
		rpm2cpio "${rpm}" | python3 "${unpack_py}" "${dest}" || return 1
	fi
	return 0
}

function ipi_install_xsltproc_user_local_stream9() {
	local arch base html tmpd root xml_rpm xsl_rpm curl_bin wget_bin unpack_py
	# libvirt-installer sets PATH=/bin; common tools live under /usr/bin.
	export PATH="/usr/bin:/bin:${PATH:-}"

	command -v rpm2cpio >/dev/null 2>&1 || { echo "ERROR: rpm2cpio not found" >&2; return 1; }
	command -v mktemp >/dev/null 2>&1 || { echo "ERROR: mktemp not found" >&2; return 1; }
	if ! command -v cpio >/dev/null 2>&1; then
		command -v python3 >/dev/null 2>&1 || {
			echo "ERROR: cpio and python3 both missing; cannot unpack Stream 9 libxslt RPMs" >&2
			return 1
		}
	fi

	curl_bin="$(command -v curl 2>/dev/null || true)"
	if [[ -z "${curl_bin}" && -x /usr/bin/curl ]]; then
		curl_bin=/usr/bin/curl
	fi
	wget_bin="$(command -v wget 2>/dev/null || true)"
	if [[ -z "${wget_bin}" && -x /usr/bin/wget ]]; then
		wget_bin=/usr/bin/wget
	fi

	if [[ -z "${curl_bin}" && -z "${wget_bin}" ]]; then
		echo "ERROR: Neither curl nor wget found" >&2
		return 1
	fi

	arch="$(uname -m)"
	tmpd="$(mktemp -d)"
	unpack_py="${tmpd}/ipi-newc-unpack.py"
	if ! command -v cpio >/dev/null 2>&1; then
		ipi_write_newc_cpio_unpack_py "${unpack_py}"
	fi
	root="/tmp/ipi-libxslt-extract-$$"
	mkdir -p "${root}"

	local unpack_mode=python3
	command -v cpio >/dev/null 2>&1 && unpack_mode=cpio
	echo "INFO: Attempting to install xsltproc for ${arch} (unpack: ${unpack_mode})" >&2

	for base in \
			"https://mirror.stream.centos.org/9-stream/BaseOS/${arch}/os/Packages/" \
			"https://vault.centos.org/9-stream/BaseOS/${arch}/os/Packages/" \
			"http://mirror.stream.centos.org/9-stream/BaseOS/${arch}/os/Packages/"
	do
		echo "INFO: Trying mirror: ${base}" >&2

		if [[ -n "${curl_bin}" ]]; then
			html="$("${curl_bin}" -fsSL --connect-timeout 30 --retry 3 "${base}" 2>/dev/null)" || {
				echo "WARN: Failed to fetch from ${base} with curl" >&2
				continue
			}
		else
			html="$("${wget_bin}" -q -O - --timeout=30 --tries=3 "${base}" 2>/dev/null)" || {
				echo "WARN: Failed to fetch from ${base} with wget" >&2
				continue
			}
		fi

		xml_rpm="$(ipi_stream9_pick_latest_rpm libxml2 "${html}")"
		xsl_rpm="$(ipi_stream9_pick_latest_rpm libxslt "${html}")"

		if [[ -z "${xml_rpm}" || -z "${xsl_rpm}" ]]; then
			echo "WARN: Could not find RPM packages in ${base}" >&2
			continue
		fi

		echo "INFO: Found packages: ${xml_rpm}, ${xsl_rpm}" >&2

		download_success=true
		if [[ -n "${curl_bin}" ]]; then
			"${curl_bin}" -fsSL --connect-timeout 30 --retry 3 -o "${tmpd}/${xml_rpm}" "${base}${xml_rpm}" 2>/dev/null || {
				echo "WARN: Failed to download ${xml_rpm}" >&2
				download_success=false
			}
			if [[ "${download_success}" == "true" ]]; then
				"${curl_bin}" -fsSL --connect-timeout 30 --retry 3 -o "${tmpd}/${xsl_rpm}" "${base}${xsl_rpm}" 2>/dev/null || {
					echo "WARN: Failed to download ${xsl_rpm}" >&2
					download_success=false
				}
			fi
		else
			"${wget_bin}" -q --timeout=30 --tries=3 -O "${tmpd}/${xml_rpm}" "${base}${xml_rpm}" 2>/dev/null || {
				echo "WARN: Failed to download ${xml_rpm}" >&2
				download_success=false
			}
			if [[ "${download_success}" == "true" ]]; then
				"${wget_bin}" -q --timeout=30 --tries=3 -O "${tmpd}/${xsl_rpm}" "${base}${xsl_rpm}" 2>/dev/null || {
					echo "WARN: Failed to download ${xsl_rpm}" >&2
					download_success=false
				}
			fi
		fi

		if [[ "${download_success}" != "true" ]]; then
			continue
		fi

		echo "INFO: Extracting RPM packages" >&2

		if ipi_extract_rpm_contents "${tmpd}/${xml_rpm}" "${root}" "${unpack_py}" &&
			ipi_extract_rpm_contents "${tmpd}/${xsl_rpm}" "${root}" "${unpack_py}"
		then
			echo "INFO: RPM extraction successful" >&2
			export PATH="${root}/usr/bin:${PATH:-}"
			export LD_LIBRARY_PATH="${root}/usr/lib64:${LD_LIBRARY_PATH:-}"

			if xsltproc --version >/dev/null 2>&1; then
				echo "INFO: xsltproc successfully installed and verified" >&2
				rm -rf "${tmpd}"
				return 0
			fi
			echo "WARN: xsltproc extracted but not functional (missing shared libs?)" >&2
		else
			echo "WARN: Failed to extract RPM packages" >&2
		fi

		rm -rf "${root}"
		mkdir -p "${root}"
	done

	echo "ERROR: All mirror attempts failed" >&2
	rm -rf "${tmpd}" "${root}"
	return 1
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
# The CI image runs as UID 1000, so prefer unpacking Stream 9 RPMs; package managers only work as root.
if [[ "${ARCH:-}" == "s390x" && "${IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH:-}" == "true" ]]; then
	if ! command -v xsltproc >/dev/null 2>&1; then
		set +e
		ipi_install_xsltproc_user_local_stream9
		if ! command -v xsltproc >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
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
		fi
		set -e
	fi
	if ! command -v xsltproc >/dev/null 2>&1; then
		echo "ERROR: xsltproc is required when IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH=true but could not be installed (non-root image: unpack libxml2/libxslt RPMs or run as root)." >&2
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
