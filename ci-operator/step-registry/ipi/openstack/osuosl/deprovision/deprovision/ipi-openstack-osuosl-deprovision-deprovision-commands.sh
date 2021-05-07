#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

dir=/tmp/installer

(
# When debugging, we don't care about pipe failures and other errors
set +o nounset; set +o errexit; set +o pipefail; set -o xtrace
echo "SHARED_DIR=${SHARED_DIR}"
echo "ARTIFACT_DIR=${ARTIFACT_DIR}"
mount | grep "$(basename ${SHARED_DIR})"
[ -n "${SHARED_DIR}" ] && ls -l "${SHARED_DIR}/"
[ -n "${ARTIFACT_DIR}" ] && ls -l "${ARTIFACT_DIR}/"
[ -n "${dir}" ] && ls -l "${dir}/"
) || true

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml

echo "Deprovisioning cluster..."
cp -ar "${SHARED_DIR}/" "${dir}"

ret=0
if [[ -f "${SHARED_DIR}/keep_cluster" ]]
then
	echo "keep_cluster found, not destroying the cluster!"
else
	if [[ ! -s "${dir}/metadata.json" ]]; then
		echo "Skipping destroy cluster: ${dir}/metadata.json not found."
	else
		openshift-install --dir "${dir}" destroy cluster &

		set +e
		wait "$!"
		ret="$?"
		set -e
	fi
fi

cp -ar "${dir}/" "${ARTIFACT_DIR}"

exit "${ret}"
