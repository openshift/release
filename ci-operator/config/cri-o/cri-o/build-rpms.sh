#!/usr/bin/env bash

# EXAMPLE FOR cri-o team, goes into cri-o repo at hack/build-rpms.sh

# This script generates release zips and RPMs into _output/releases.
# tito and other build dependencies are required on the host. We will
# be running `hack/build-cross.sh` under the covers, so we transitively
# consume all of the relevant envars.
source "$(dirname "${BASH_SOURCE}")/lib/init.sh"

os::util::ensure::system_binary_exists rpmbuild
os::util::ensure::system_binary_exists createrepo

os::build::rpm::get_nvra_vars

OS_RPM_SPECFILE="$( find "${OS_ROOT}" -name *.spec )"
OS_RPM_NAME="$( rpmspec -q --qf '%{name}\n' "${OS_RPM_SPECFILE}" | head -1 )"

os::log::info "Building release RPMs for ${OS_RPM_SPECFILE} ..."

rpm_tmp_dir="${BASETMPDIR}/rpm"

# RPM requires the spec file be owned by the invoking user
chown "$(id -u):$(id -g)" "${OS_RPM_SPECFILE}" || true

mkdir -p "${rpm_tmp_dir}/SOURCES"
tar czf "${rpm_tmp_dir}/SOURCES/${OS_RPM_NAME}-${OS_RPM_VERSION}.tar.gz" \
	--owner=0 --group=0 \
	--exclude=_output --exclude=.git --transform "s|^|${OS_RPM_NAME}-${OS_RPM_VERSION}/|rSH" \
	.

rpmbuild -b${srpm} "${OS_RPM_SPECFILE}" \
	--define "skip_dist 1" \
	--define "version ${OS_RPM_VERSION}" --define "release ${OS_RPM_RELEASE}" \
	--define "commit ${OS_GIT_COMMIT}" \
	--define 'dist .el7' --define "_topdir ${rpm_tmp_dir}"

output_directory="$( find "${rpm_tmp_dir}" -type d -path "*/BUILD/${OS_RPM_NAME}-${OS_RPM_VERSION}/_output/local" )"
if [[ -z "${output_directory}" ]]; then
	os::log::fatal 'No _output artifact directory found in rpmbuild artifacts!'
fi

# migrate the rpm artifacts to the output directory, must be clean or move will fail
make clean
mkdir -p "${OS_OUTPUT}"

mv "${output_directory}"/* "${OS_OUTPUT}"

OS_OUTPUT_RPMPATH=_output/releases/rpms
repo_path=${OS_OUTPUT_RPMPATH}

mkdir -p "${OS_OUTPUT_RPMPATH}"
if [[ -n "${OS_BUILD_SRPM-}" ]]; then
	mv -f "${rpm_tmp_dir}"/SRPMS/*src.rpm "${OS_OUTPUT_RPMPATH}"
fi
mv -f "${rpm_tmp_dir}"/RPMS/*/*.rpm "${OS_OUTPUT_RPMPATH}"
fi

mkdir -p "${OS_OUTPUT_RELEASEPATH}"

createrepo "${repo_path}"

echo "[${OS_RPM_NAME}-local-release]
baseurl = file://${repo_path}
gpgcheck = 0
name = Release from Local Source for ${OS_RPM_NAME}
enabled = 1
" > "${repo_path}/local-release.repo"

# DEPRECATED: preserve until jobs migrate to using local-release.repo
cp "${repo_path}/local-release.repo" "${repo_path}/origin-local-release.repo"

os::log::info "Repository file for \`yum\` or \`dnf\` placed at ${repo_path}/local-release.repo
Install it with:
$ mv '${repo_path}/local-release.repo' '/etc/yum.repos.d"
