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
  # Capture the exit code that triggered this EXIT/TERM trap before any other
  # command overwrites $? (e.g. killing the ACPI terraform wrapper).
  local install_exit_code=$?
  if [[ -n "${IPI_ACPI_PATCHER_PID:-}" ]]; then
    kill "${IPI_ACPI_PATCHER_PID}" 2>/dev/null || true
    wait "${IPI_ACPI_PATCHER_PID}" 2>/dev/null || true
    unset IPI_ACPI_PATCHER_PID
  fi
  #Save exit code for must-gather to generate junit
  echo "${install_exit_code}" > "${SHARED_DIR}/install-status.txt"
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
	# Bastion tunnel port = lease slice index (last hyphen segment of LEASED_RESOURCE),
	# e.g. libvirt-s390x-2-3 -> 3, libvirt-s390x-oz-2-1 -> 1.
	# Do not use cut -f4 on cluster_domain first: oz leases shift fields so field 4 is the
	# hypervisor id (numeric), which falsely skips the lease-suffix fallback.
	RESOURCE_ID=$(echo "${LEASED_RESOURCE}" | rev | cut -d- -f1 | rev)
	if ! [[ "${RESOURCE_ID}" =~ ^[0-9]+$ ]]; then
		# Legacy *.ci domains sometimes encoded the slice in cluster_domain field 4.
		RESOURCE_ID=$(echo "${CLUSTER_DOMAIN}" | cut -d- -f4)
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
# xsltproc for the s390x ACPI terraform workaround, unpack Rocky libxml2/libxslt (+deps) RPMs into
# /tmp and prepend PATH/LD_LIBRARY_PATH.
# - ocp/4.15+ libvirt-installer is EL9-based (GLIBC 2.34+) → Rocky 9 RPMs
# - ocp/4.14 libvirt-installer is older (GLIBC < 2.34) → Rocky 9 binaries fail; use Rocky 8
# CentOS Stream "Packages/" pages are no longer plain indexes; Rocky letter buckets expose href="*.rpm".
function ipi_el_pick_latest_rpm() {
	local pkg="$1"
	local html="$2"
	local arch="$3"
	echo "${html}" | grep -oE "href=\"${pkg}-[0-9][^\"]*\\.${arch}\\.rpm\"" | sed 's/href="//;s/"$//' \
		| grep -Ev -- '-(devel|static)' | LC_ALL=C sort -V | tail -n1
}

# True when the installer image can run EL9 (Rocky 9) userspace binaries.
function ipi_host_has_glibc_2_34() {
	grep -aob 'GLIBC_2\.34' /lib64/libc.so.6 >/dev/null 2>&1 || \
		grep -aob 'GLIBC_2\.34' /usr/lib64/libc.so.6 >/dev/null 2>&1
}

# EL9 libvirt-installer image has rpm2cpio but often no cpio(1); unpack newc cpio from rpm2cpio stdout.
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
	local arch xml_base xsl_base xml_html xsl_html base_html tmpd root xml_rpm xsl_rpm curl_bin wget_bin unpack_py label
	local xz_rpm gcrypt_rpm gpgerr_rpm
	# libvirt-installer sets PATH=/bin; common tools live under /usr/bin.
	export PATH="/usr/bin:/bin:${PATH:-}"

	command -v rpm2cpio >/dev/null 2>&1 || { echo "ERROR: rpm2cpio not found" >&2; return 1; }
	command -v mktemp >/dev/null 2>&1 || { echo "ERROR: mktemp not found" >&2; return 1; }
	if ! command -v cpio >/dev/null 2>&1; then
		command -v python3 >/dev/null 2>&1 || {
			echo "ERROR: cpio and python3 both missing; cannot unpack libxslt RPMs" >&2
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

	# Prefer RPMs that match host glibc. ocp/4.14 libvirt-installer lacks GLIBC_2.34 so
	# Rocky 9 xsltproc fails with "version GLIBC_2.34 not found"; Rocky 8 works there.
	# 4.15+ images have newer glibc and use Rocky 9 (same as the installer base).
	local -a mirror_rows=()
	local rocky8_rows=(
		"rocky8|https://download.rockylinux.org/pub/rocky/8/BaseOS/${arch}/os/Packages|https://download.rockylinux.org/pub/rocky/8/AppStream/${arch}/os/Packages"
		"rocky8-dl|https://dl.rockylinux.org/pub/rocky/8/BaseOS/${arch}/os/Packages|https://dl.rockylinux.org/pub/rocky/8/AppStream/${arch}/os/Packages"
	)
	local rocky9_rows=(
		"rocky9|https://download.rockylinux.org/pub/rocky/9/BaseOS/${arch}/os/Packages|https://download.rockylinux.org/pub/rocky/9/AppStream/${arch}/os/Packages"
		"rocky9-dl|https://dl.rockylinux.org/pub/rocky/9/BaseOS/${arch}/os/Packages|https://dl.rockylinux.org/pub/rocky/9/AppStream/${arch}/os/Packages"
	)
	if ipi_host_has_glibc_2_34; then
		echo "INFO: Attempting to install xsltproc for ${arch} (unpack: ${unpack_mode}, glibc>=2.34 → Rocky 9 then 8)" >&2
		mirror_rows+=("${rocky9_rows[@]}" "${rocky8_rows[@]}")
	else
		echo "INFO: Attempting to install xsltproc for ${arch} (unpack: ${unpack_mode}, glibc<2.34 → Rocky 8 then 9)" >&2
		mirror_rows+=("${rocky8_rows[@]}" "${rocky9_rows[@]}")
	fi

	ipi_fetch_index() {
		local url="$1"
		if [[ -n "${curl_bin}" ]]; then
			"${curl_bin}" -fsSL --connect-timeout 30 --retry 3 "${url}" 2>/dev/null
		else
			"${wget_bin}" -q -O - --timeout=30 --tries=3 "${url}" 2>/dev/null
		fi
	}

	ipi_download_rpm() {
		local url="$1"
		local out="$2"
		if [[ -n "${curl_bin}" ]]; then
			"${curl_bin}" -fsSL --connect-timeout 30 --retry 3 -o "${out}" "${url}" 2>/dev/null
		else
			"${wget_bin}" -q --timeout=30 --tries=3 -O "${out}" "${url}" 2>/dev/null
		fi
	}

	for row in "${mirror_rows[@]}"; do
		IFS='|' read -r label xml_base xsl_base <<<"${row}"
		# lettered subdirs under Packages/
		local base_l="${xml_base}/l/"
		local base_x="${xml_base}/x/"
		local app_l="${xsl_base}/l/"
		echo "INFO: Trying mirror set ${label}: base=${xml_base} app=${xsl_base}" >&2

		# Fresh download dir per mirror so Rocky 8/9 RPMs with different NEVRAs do not collide.
		rm -rf "${tmpd}/rpms"
		mkdir -p "${tmpd}/rpms"

		base_html="$(ipi_fetch_index "${base_l}")" || {
			echo "WARN: ${label}: failed to fetch BaseOS Packages/l/ index" >&2
			continue
		}
		local base_x_html
		base_x_html="$(ipi_fetch_index "${base_x}")" || {
			echo "WARN: ${label}: failed to fetch BaseOS Packages/x/ index" >&2
			continue
		}
		xsl_html="$(ipi_fetch_index "${app_l}")" || {
			echo "WARN: ${label}: failed to fetch AppStream Packages/l/ index" >&2
			continue
		}

		xml_rpm="$(ipi_el_pick_latest_rpm libxml2 "${base_html}" "${arch}")"
		xsl_rpm="$(ipi_el_pick_latest_rpm libxslt "${xsl_html}" "${arch}")"
		xz_rpm="$(ipi_el_pick_latest_rpm xz-libs "${base_x_html}" "${arch}")"
		gcrypt_rpm="$(ipi_el_pick_latest_rpm libgcrypt "${base_html}" "${arch}")"
		gpgerr_rpm="$(ipi_el_pick_latest_rpm libgpg-error "${base_html}" "${arch}")"

		if [[ -z "${xml_rpm}" || -z "${xsl_rpm}" ]]; then
			echo "WARN: ${label}: could not parse libxml2/libxslt ${arch} RPM names from indexes" >&2
			continue
		fi

		echo "INFO: ${label}: picked ${xml_rpm}, ${xsl_rpm}, ${xz_rpm:-none}, ${gcrypt_rpm:-none}, ${gpgerr_rpm:-none}" >&2

		local -a downloads=(
			"${base_l}${xml_rpm}|${tmpd}/rpms/${xml_rpm}"
			"${app_l}${xsl_rpm}|${tmpd}/rpms/${xsl_rpm}"
		)
		[[ -n "${xz_rpm}" ]] && downloads+=("${base_x}${xz_rpm}|${tmpd}/rpms/${xz_rpm}")
		[[ -n "${gcrypt_rpm}" ]] && downloads+=("${base_l}${gcrypt_rpm}|${tmpd}/rpms/${gcrypt_rpm}")
		[[ -n "${gpgerr_rpm}" ]] && downloads+=("${base_l}${gpgerr_rpm}|${tmpd}/rpms/${gpgerr_rpm}")

		download_success=true
		for spec in "${downloads[@]}"; do
			IFS='|' read -r url dest <<<"${spec}"
			if ! ipi_download_rpm "${url}" "${dest}"; then
				echo "WARN: Failed to download ${url}" >&2
				download_success=false
				break
			fi
		done
		if [[ "${download_success}" != "true" ]]; then
			continue
		fi

		echo "INFO: Extracting RPM packages" >&2
		local -a rpm_files=("${tmpd}/rpms/${xml_rpm}" "${tmpd}/rpms/${xsl_rpm}")
		[[ -n "${xz_rpm}" ]] && rpm_files+=("${tmpd}/rpms/${xz_rpm}")
		[[ -n "${gcrypt_rpm}" ]] && rpm_files+=("${tmpd}/rpms/${gcrypt_rpm}")
		[[ -n "${gpgerr_rpm}" ]] && rpm_files+=("${tmpd}/rpms/${gpgerr_rpm}")
		extract_ok=true
		for rpmfile in "${rpm_files[@]}"; do
			if ! ipi_extract_rpm_contents "${rpmfile}" "${root}" "${unpack_py}"; then
				echo "WARN: Failed to extract ${rpmfile}" >&2
				extract_ok=false
				break
			fi
		done

		if [[ "${extract_ok}" == "true" ]]; then
			echo "INFO: RPM extraction successful" >&2
			export PATH="${root}/usr/bin:${PATH:-}"
			export LD_LIBRARY_PATH="${root}/usr/lib64:${root}/lib64:${LD_LIBRARY_PATH:-}"
			hash -r 2>/dev/null || true

			if xsltproc --version >/dev/null 2>&1; then
				echo "INFO: xsltproc successfully installed and verified (${label})" >&2
				rm -rf "${tmpd}"
				return 0
			fi
			echo "WARN: xsltproc extracted but not functional (glibc/shared libs mismatch?)" >&2
			if command -v ldd >/dev/null 2>&1 && [[ -x "${root}/usr/bin/xsltproc" ]]; then
				echo "WARN: ldd ${root}/usr/bin/xsltproc:" >&2
				ldd "${root}/usr/bin/xsltproc" >&2 || true
			fi
			# Drop broken extract from PATH so a hashed lookup cannot fake success later.
			export PATH="/usr/bin:/bin"
			unset LD_LIBRARY_PATH
			hash -r 2>/dev/null || true
		else
			echo "WARN: Failed to extract RPM packages" >&2
		fi

		rm -rf "${root}"
		mkdir -p "${root}"
	done

	echo "ERROR: All mirror attempts failed (tried Rocky 8 and 9; host glibc must match RPM generation)" >&2
	export PATH="/usr/bin:/bin"
	unset LD_LIBRARY_PATH
	hash -r 2>/dev/null || true
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

function collect_control_plane_logs() {
	local DIR=$1
	local ID=$2
	local cluster_name cluster_domain hostname FROM TO

	[[ -f "${DIR}/terraform.tfvars.json" ]] || return 0
	cluster_domain=$(sed -n -r -e 's,^ *"cluster_domain": "([^"]*).*$,\1,p' "${DIR}/terraform.tfvars.json")
	if [[ -z "${cluster_domain}" ]]; then
		echo "collect_control_plane: could not determine cluster_domain"
		return 0
	fi
	if [[ -f "${DIR}/metadata.json" ]]; then
		cluster_name=$(sed -n -r -e 's/.*"clusterName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${DIR}/metadata.json" | head -n1)
	fi
	if [[ -z "${cluster_name:-}" && -f "${SHARED_DIR}/install-config.yaml" ]]; then
		if command -v yq-v4 >/dev/null 2>&1; then
			cluster_name=$(yq-v4 -oy '.metadata.name' "${SHARED_DIR}/install-config.yaml")
		else
			cluster_name=$(yq eval -o=y '.metadata.name' "${SHARED_DIR}/install-config.yaml")
		fi
	fi
	if [[ -z "${cluster_name:-}" ]]; then
		echo "collect_control_plane: could not determine cluster name"
		return 0
	fi

	set +e
	for ((i=0; i<${MASTER_REPLICAS}; i++)); do
		hostname="${cluster_name}-master-${i}.${cluster_domain}"
		echo "collect_control_plane: ssh ${hostname}:${BASTION_SSH_PORTS[${RESOURCE_ID}]}"
		mock-nss.sh ssh \
			-o 'ConnectTimeout=5' \
			-o 'StrictHostKeyChecking=no' \
			-i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
			-l core \
			-p "${BASTION_SSH_PORTS[${RESOURCE_ID}]}" \
			"${hostname}" \
			/usr/local/bin/installer-gather.sh --id "${ID}"
		if [ $? -eq 0 ]; then
			FROM="/var/home/core/log-bundle-${ID}.tar.gz"
			TO="/logs/artifacts/control-plane-${i}-log-bundle-${ID}.tar.gz"
			echo "collect_control_plane: scp ${hostname}:${BASTION_SSH_PORTS[${RESOURCE_ID}]}"
			mock-nss.sh scp \
				-o 'ConnectTimeout=5' \
				-o 'StrictHostKeyChecking=no' \
				-i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
				-P "${BASTION_SSH_PORTS[${RESOURCE_ID}]}" \
				"core@${hostname}:${FROM}" "${TO}"
		fi
	done
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
# drops the real binary, before the first init) to patch $(pwd) before each init/apply.
#
# Wrap must be race-safe: wait for a complete ELF binary, cp -a to terraform.real, write the
# shell wrapper to a temp file with +x, then mv -f over terraform. A naive mv+cat left a
# non-executable path and failed create with "fork/exec .../terraform: permission denied".

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
if [[ "${WORKER_REPLICAS}" != "0" && -f "${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml" ]]; then
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value[domainMemory] ${WORKER_MEMORY}
  # Bump the libvirt workers disk to to 30GB
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value.volume[volumeSize] ${WORKER_DISK}
fi

# Opt-in: point machine-api volumes at an existing libvirt pool (e.g. UPI multiarch-ci-pool on /home)
# instead of the per-cluster pool openshift-install would create under /var/lib/libvirt/openshift-images.
if [[ -n "${LIBVIRT_POOL_NAME:-}" ]]; then
	echo "Setting machine volume poolName to ${LIBVIRT_POOL_NAME}"
	for ((i=0; i<${MASTER_REPLICAS}; i++))
	do
		yq write --inplace "${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml" spec.providerSpec.value.volume[poolName] "${LIBVIRT_POOL_NAME}"
	done
	if [[ "${WORKER_REPLICAS}" != "0" && -f "${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml" ]]; then
		yq write --inplace "${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml" spec.template.spec.providerSpec.value.volume[poolName] "${LIBVIRT_POOL_NAME}"
	fi
fi

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
# The CI image runs as UID 1000, so prefer unpacking EL9 RPMs (Rocky 9 indexes); package managers only work as root.
# Prefer xsltproc --version over command -v: a broken unpack can leave a non-runnable binary on PATH.
if [[ "${ARCH:-}" == "s390x" && "${IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH:-}" == "true" ]]; then
	if ! xsltproc --version >/dev/null 2>&1; then
		set +e
		ipi_install_xsltproc_user_local_stream9
		if ! xsltproc --version >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
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
	if ! xsltproc --version >/dev/null 2>&1; then
		echo "ERROR: xsltproc is required when IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH=true but could not be installed (non-root image: unpack libxml2/libxslt RPMs or run as root)." >&2
		exit 1
	fi
fi

# Ensure an existing shared pool is present when LIBVIRT_POOL_NAME is set (VPN OZ / UPI multiarch-ci-pool).
# openshift-install otherwise creates a new dir pool under /var/lib/libvirt/openshift-images/<id> on root.
if [[ -n "${LIBVIRT_POOL_NAME:-}" ]]; then
	LIBVIRT_IMAGE_PATH="${LIBVIRT_IMAGE_PATH:-/home/libvirt/openshift-images}"
	if [[ -z "${LEASED_RESOURCE:-}" || ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
		echo "ERROR: LIBVIRT_POOL_NAME=${LIBVIRT_POOL_NAME} requires LEASED_RESOURCE and ${CLUSTER_PROFILE_DIR}/leases" >&2
		exit 1
	fi
	if command -v yq-v4 >/dev/null 2>&1; then
		POOL_HOST="$(yq-v4 -oy ".[\"${LEASED_RESOURCE}\"].hostname" "${CLUSTER_PROFILE_DIR}/leases")"
	else
		POOL_HOST="$(yq eval -o=y ".[\"${LEASED_RESOURCE}\"].hostname" "${CLUSTER_PROFILE_DIR}/leases")"
	fi
	if [[ -z "${POOL_HOST}" ]]; then
		echo "ERROR: could not resolve hypervisor hostname for pool ${LIBVIRT_POOL_NAME}" >&2
		exit 1
	fi
	POOL_VIRSH="mock-nss.sh virsh --connect qemu+tcp://${POOL_HOST}/system"
	echo "Ensuring libvirt pool ${LIBVIRT_POOL_NAME} exists on ${POOL_HOST} (target ${LIBVIRT_IMAGE_PATH})"
	# Match UPI: looser grep on pool-list (avoid --name; older libvirt + pipefail can miss existing pools).
	set +e
	pool_list_all="$(${POOL_VIRSH} pool-list --all 2>/dev/null)"
	pool_list_rc=$?
	set -e
	if [[ ${pool_list_rc} -eq 0 ]] && echo "${pool_list_all}" | grep -q "${LIBVIRT_POOL_NAME}"; then
		echo "Storage pool ${LIBVIRT_POOL_NAME} already exists. Skipping create."
	else
		echo "Creating storage pool ${LIBVIRT_POOL_NAME}..."
		set +e
		define_out="$(${POOL_VIRSH} pool-define-as --name "${LIBVIRT_POOL_NAME}" --type dir --target "${LIBVIRT_IMAGE_PATH}" 2>&1)"
		define_rc=$?
		set -e
		if [[ ${define_rc} -ne 0 ]]; then
			if echo "${define_out}" | grep -qiE 'already exists|pool .* exists'; then
				echo "Storage pool ${LIBVIRT_POOL_NAME} already exists (define raced). Continuing."
			else
				echo "${define_out}" >&2
				exit "${define_rc}"
			fi
		else
			${POOL_VIRSH} pool-autostart "${LIBVIRT_POOL_NAME}" || true
		fi
	fi
	# Active pools appear in pool-list (without --all); start if inactive.
	if ! ${POOL_VIRSH} pool-list 2>/dev/null | grep -q "${LIBVIRT_POOL_NAME}"; then
		echo "Starting storage pool ${LIBVIRT_POOL_NAME}..."
		${POOL_VIRSH} pool-start "${LIBVIRT_POOL_NAME}" || true
	fi
fi

NEED_ACPI_PATCH="false"
if [[ "${ARCH:-}" == "s390x" && "${IPI_LIBVIRT_S390X_ACPI_XSLT_PATCH:-}" == "true" ]]; then
	NEED_ACPI_PATCH="true"
fi
NEED_POOL_PATCH="false"
if [[ -n "${LIBVIRT_POOL_NAME:-}" ]]; then
	NEED_POOL_PATCH="true"
fi

# CI workarounds: wrap terraform before first init (unpackAndInit has no poller gap).
# - s390x ACPI: inject xml.xslt on libvirt_domain.
# - LIBVIRT_POOL_NAME: drop installer-created libvirt_pool and use the existing shared pool.
if [[ "${NEED_ACPI_PATCH}" == "true" || "${NEED_POOL_PATCH}" == "true" ]]; then
	xsl="${dir}/s390x-strip-acpi.xsl"
	if [[ "${NEED_ACPI_PATCH}" == "true" ]]; then
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
	fi
	patch_tf="${dir}/ipi-libvirt-patch-terraform-tf.sh"
	cat > "${patch_tf}" <<'PATCH_EOF'
#!/bin/bash
set -euo pipefail
work="${1:?}"
xsl="${2:-}"
pool_name="${3:-}"
[[ -d "${work}" ]] || exit 0
while IFS= read -r -d '' tf; do
	if [[ -n "${pool_name}" ]]; then
		# Remove resource "libvirt_pool" "storage_pool" { ... } (installer hardcoded path on root FS).
		if grep -q 'resource "libvirt_pool" "storage_pool"' "${tf}" 2>/dev/null; then
			awk '
				BEGIN { skip=0; depth=0 }
				/resource "libvirt_pool" "storage_pool"/ { skip=1; depth=0 }
				{
					if (skip) {
						for (i=1; i<=length($0); i++) {
							c=substr($0,i,1)
							if (c=="{") depth++
							if (c=="}") {
								depth--
								if (depth<=0) { skip=0; next }
							}
						}
						next
					}
					print
				}
			' "${tf}" > "${tf}.ipi_drop_pool.$$" && mv "${tf}.ipi_drop_pool.$$" "${tf}"
		fi
		# Point volumes/ignition/outputs at the shared pool name.
		if grep -qE 'libvirt_pool\.storage_pool\.name|pool[[:space:]]*=' "${tf}" 2>/dev/null; then
			sed "s|libvirt_pool\.storage_pool\.name|\"${pool_name}\"|g" "${tf}" > "${tf}.ipi_pool_ref.$$" && mv "${tf}.ipi_pool_ref.$$" "${tf}"
		fi
	fi
	if [[ -n "${xsl}" && -f "${xsl}" ]]; then
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
	fi
done < <(find "${work}" -name '*.tf' -print0 2>/dev/null)
PATCH_EOF
	chmod +x "${patch_tf}"
	(
		set +o errexit
		tfbin="${dir}/terraform/bin/terraform"
		deadline=$((SECONDS + 7200))
		# Wait for installer to unpack terraform, then wrap before the first init.
		# Avoid the previous race: mv + cat >tfbin left a non-executable path (or a
		# non-executable .real copied mid-unpack) so openshift-install hit
		# "fork/exec .../terraform: permission denied".
		while [[ ! -d "${dir}/terraform/bin" ]]; do
			if (( SECONDS >= deadline )); then
				echo "WARNING: terraform wrap timed out waiting for ${dir}/terraform/bin" >&2
				exit 0
			fi
			sleep 0.05
		done
		# Wait until the terraform binary is fully written. Prefer ELF+stable size so we
		# do not wrap a partial unpack; chmod +x ourselves (installer may race chmod vs exec).
		while true; do
			if (( SECONDS >= deadline )); then
				echo "WARNING: terraform wrap timed out waiting for ${tfbin}" >&2
				exit 0
			fi
			if [[ -f "${tfbin}" && -s "${tfbin}" ]]; then
				# Skip if we already wrapped (idempotent / late rewrite).
				if head -c 64 "${tfbin}" 2>/dev/null | grep -q 'ipi-libvirt-terraform-wrap'; then
					exit 0
				fi
				magic="$(head -c 4 "${tfbin}" 2>/dev/null || true)"
				if [[ "${magic}" == $'\x7fELF' ]]; then
					sz1=$(wc -c <"${tfbin}" 2>/dev/null || echo 0)
					sleep 0.02
					sz2=$(wc -c <"${tfbin}" 2>/dev/null || echo 0)
					magic2="$(head -c 4 "${tfbin}" 2>/dev/null || true)"
					if [[ "${sz1}" == "${sz2}" && "${sz1}" -gt 0 && "${magic2}" == $'\x7fELF' ]]; then
						chmod +x "${tfbin}" 2>/dev/null || true
						break
					fi
				fi
			fi
			sleep 0.001 2>/dev/null || sleep 0
		done
		if [[ -f "${tfbin}.real" ]]; then
			exit 0
		fi
		xsl_arg=""
		if [[ "${NEED_ACPI_PATCH}" == "true" ]]; then
			xsl_arg="${xsl}"
		fi
		pool_arg="${LIBVIRT_POOL_NAME:-}"
		# Keep original path executable until the wrapper is ready, then atomically replace.
		if ! cp -a "${tfbin}" "${tfbin}.real" 2>/dev/null; then
			echo "WARNING: terraform wrap could not copy ${tfbin} -> ${tfbin}.real" >&2
			exit 0
		fi
		chmod +x "${tfbin}.real" 2>/dev/null || true
		wrap_tmp="${tfbin}.wrap.$$"
		cat >"${wrap_tmp}" <<EOF
#!/bin/bash
# ipi-libvirt-terraform-wrap: patch .tf before init/plan/apply, then run real terraform.
set -euo pipefail
REAL="${tfbin}.real"
PATCH="${patch_tf}"
XSL="${xsl_arg}"
POOL="${pool_arg}"
chmod +x "\${REAL}" 2>/dev/null || true
if [[ "\${1:-}" == "init" || "\${1:-}" == "plan" || "\${1:-}" == "apply" ]]; then
	bash "\${PATCH}" "\$(pwd)" "\${XSL}" "\${POOL}"
fi
exec "\${REAL}" "\$@"
EOF
		chmod +x "${wrap_tmp}"
		if ! mv -f "${wrap_tmp}" "${tfbin}"; then
			echo "WARNING: terraform wrap atomic replace failed; restoring ${tfbin}" >&2
			mv -f "${tfbin}.real" "${tfbin}" 2>/dev/null || true
			rm -f "${wrap_tmp}"
			exit 0
		fi
		chmod +x "${tfbin}" "${tfbin}.real" 2>/dev/null || true
		echo "INFO: wrapped terraform ${tfbin} -> ${tfbin}.real (acpi=${NEED_ACPI_PATCH} pool=${pool_arg:-none})"
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
	collect_control_plane_logs "${dir}" 1
fi

if [ ${ret} -gt 0 ]
then
	# Only wait-for when create progressed far enough to produce a kubeconfig.
	# Otherwise (e.g. terraform permission denied / init failure) this burns ~40m on API EOF.
	if [[ -f "${dir}/auth/kubeconfig" ]]; then
		# Cluster may still be initializing past create's default timeout.
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
			collect_control_plane_logs "${dir}" 2
		fi
	else
		echo "Skipping wait-for install-complete: ${dir}/auth/kubeconfig missing (create did not progress)"
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
  # Persist worker ignition for day-2 virsh workers (WORKER_REPLICAS=0 hybrid path).
  # libvirt-installer PATH may be /bin-only in the next step; save here while oc works.
  export PATH="/usr/bin:/bin:${PATH:-}"
  if env KUBECONFIG="${dir}/auth/kubeconfig" oc -n openshift-machine-api extract secret/worker-user-data --keys=userData --to=- > "${SHARED_DIR}/worker.ign" 2>/dev/null \
    || env KUBECONFIG="${dir}/auth/kubeconfig" oc -n openshift-machine-api extract secret/worker-user-data-managed --keys=userData --to=- > "${SHARED_DIR}/worker.ign" 2>/dev/null; then
    if [[ -s "${SHARED_DIR}/worker.ign" ]]; then
      echo "Saved worker ignition to ${SHARED_DIR}/worker.ign ($(wc -c < "${SHARED_DIR}/worker.ign") bytes)"
    else
      echo "WARNING: worker ignition extract produced an empty file"
      rm -f "${SHARED_DIR}/worker.ign"
    fi
  else
    echo "WARNING: could not extract worker-user-data(-managed) for SHARED_DIR/worker.ign"
    rm -f "${SHARED_DIR}/worker.ign"
  fi
fi

exit "${ret}"
