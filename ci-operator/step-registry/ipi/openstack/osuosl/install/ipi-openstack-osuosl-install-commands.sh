#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

dir=/tmp/installer

[ ! -d "${dir}" ] && mkdir "${dir}"

echo "RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST}"

# export OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE=ocp-image-47.83.202102091015-0

if [[ -v OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE ]]; then
	if [[ -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ]]; then
		echo "Old OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
#		export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=registry.ci.openshift.org/ocp-ppc64le/release-ppc64le:4.9
		echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
	else
		echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is empty, unsetting"
		unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
	fi
fi

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

# Sadly, oc is not provided in the image
mkdir -p /tmp/client
URL=https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.6/linux/oc.tar.gz
echo "Downloading ${URL}"
curl "${URL}" | tar --directory=/tmp/client -xzf -
export PATH=/tmp/client:/usr/bin:/usr/local/bin:$PATH
oc version --client

export OS_CLIENT_CONFIG_FILE=/etc/openstack/clouds.yaml

cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

openshift-install version

TF_LOG=trace openshift-install --dir="${dir}" create manifests --log-level=debug &
wait "$!"

(
# When debugging, we don't care about pipe failures and other errors
set +o nounset; set +o errexit; set +o pipefail; set -o xtrace
ls -l "${dir}/"
ls -l "${dir}/manifests/"
) || true

if [ -f "${dir}/manifests/cvo-overrides.yaml" ]
then
    sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"
else
    echo "Warning: file does not exist: ${dir}/manifests/cvo-overrides.yaml"
fi

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  echo "COPYING: ${item} ${dir}/manifests/${manifest##manifest_}"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done < <( find "${SHARED_DIR}" -name "manifest_*.yml" -print0)

TF_LOG=trace openshift-install --dir="${dir}" create ignition-configs --log-level=debug &
wait "$!"

# @TBD should be replaced by ipi-conf-etcd-on-ramfs step but does not work
echo "Modifying master.ign"
cp ${dir}/master.ign ${dir}/master.ign.old
python -c \
    'import json, sys; j = json.load(sys.stdin); j[u"systemd"] = {}; j[u"systemd"][u"units"] = [{u"contents": "[Unit]\nDescription=Mount etcd as a ramdisk\nBefore=local-fs.target\n[Mount]\n What=none\nWhere=/var/lib/etcd\nType=tmpfs\nOptions=size=2G\n[Install]\nWantedBy=local-fs.target", u"enabled": True, u"name":u"var-lib-etcd.mount"}]; json.dump(j, sys.stdout)' \
    < ${dir}/master.ign.old \
    > ${dir}/master.ign.new
cp ${dir}/master.ign.new ${dir}/master.ign

# Regenerate ignition configs
TF_LOG=trace openshift-install --dir="${dir}" create ignition-configs --log-level=debug &
wait "$!"

TF_LOG=trace openshift-install --dir="${dir}" create cluster --log-level=debug 2>&1 | grep --line-buffered -v password &
PID_OPENSHIFT_INSTALL=$!

set +e
wait ${PID_OPENSHIFT_INSTALL}
RC=$?
echo "wait for installer PID ${PID_OPENSHIFT_INSTALL} RC=${RC}"

CID=$(jq --raw-output .cluster_id "${dir}/terraform.tfvars.json")
[ -z "${CID}" ] && exit 1
echo "${CID}" > "${SHARED_DIR}"/CID

if [ ${RC} -gt 0 ]
then
	TF_LOG=trace openshift-install --dir="${dir}" wait-for install-complete --log-level=debug 2>&1 | grep --line-buffered -v password &
	PID_OPENSHIFT_INSTALL=$!
	wait ${PID_OPENSHIFT_INSTALL}
	RC=$?
	echo "second wait for installer PID ${PID_OPENSHIFT_INSTALL} RC=${RC}"
fi

if [ ${RC} -eq 0 ]
then
	touch ${SHARED_DIR}/install_success

	if [[ -f "${SHARED_DIR}/keep_cluster" || -f "${ARTIFACT_DIR}/keep_cluster" ]]
	then
		mkdir "${ARTIFACT_DIR}/auth"
		cp "${dir}/auth/kubeconfig" "${ARTIFACT_DIR}/auth/"
	fi
fi

cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
set -e
sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >"${ARTIFACT_DIR}/.openshift_install.log"
cp \
    --target-directory "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig" \
    "${dir}/metadata.json"
exit "$RC"
