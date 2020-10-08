#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ -f "${SHARED_DIR}/install_success" ]
then
	CID=$(<"${SHARED_DIR}"/CID)
	[ -z "${CID}" ] && exit 1

	INGRESS_PORT=$(openstack --os-cloud osuosl port list --format value -c Name | awk '/'${CID}'-ingress-port/ {print}')
	INGRESS_FIP_UID=$(<"${SHARED_DIR}"/INGRESS_FIP_UID)

	openstack --os-cloud osuosl floating ip set --port ${INGRESS_PORT} ${INGRESS_FIP_UID}

	exit 0
else
	exit 1
fi
