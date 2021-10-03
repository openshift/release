#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

dir=/tmp/installer

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml

echo "Deprovisioning cluster..."
cp -ar "${SHARED_DIR}/" "${dir}"

ret=0
if [[ -f "${SHARED_DIR}/keep_cluster" ]]
then
	echo "keep_cluster found, not destroying the cluster!"
else
	if [[ ! -f "${SHARED_DIR}/install_success" ]]
	then
	(
		# When debugging, we don't care about pipe failures and other errors
		set +o nounset; set +o errexit; set +o pipefail; set -o xtrace

		# Have the volumes gone from creating -> downloading -> available -> reserved -> in-use ?
		openstack --os-cloud osuosl volume list --format value

		CID=""; [[ -f "${SHARED_DIR}/CID" ]] && CID=$(<"${SHARED_DIR}/CID")
		if [[ -n "${CID}" ]]
		then
			for NAME1 in bootstrap master-0 master-1 master-2
			do
				NAME2="${CID}-${NAME1}"
				openstack --os-cloud osuosl console log show ${NAME2}
			done
		fi
        ) || true
	fi

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
