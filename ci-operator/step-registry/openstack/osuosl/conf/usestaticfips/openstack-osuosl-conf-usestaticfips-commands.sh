#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

(
	# When debugging, we don't care about pipe failures and other errors
	set +o nounset; set +o errexit; set +o pipefail; set -o xtrace
	openstack floating ip list --long --format value
) || true

export OS_CLIENT_CONFIG_FILE=/etc/openstack/clouds.yaml

echo "LEASED_RESOURCE=${LEASED_RESOURCE}"
case ${LEASED_RESOURCE} in
"openstack-osuosl-00")
	export LB_FIP="GROUP1_LB_FIP"
	export APPS_FIP="GROUP1_APPS_FIP"
	;;
"openstack-osuosl-01")
	export LB_FIP="GROUP2_LB_FIP"
	export APPS_FIP="GROUP2_APPS_FIP"
	;;
"*")
	echo "Error: Unknown LEASED_RESOURCE"
	exit 1
	;;
esac

openstack floating ip list --tags ${LB_FIP} -f value -c 'Floating IP Address' > ${SHARED_DIR}/LB_FIP_IP
openstack floating ip list --tags ${LB_FIP} -f value -c 'ID' > ${SHARED_DIR}/LB_FIP_UUID
openstack floating ip list --tags ${APPS_FIP} -f value -c 'Floating IP Address' > ${SHARED_DIR}/INGRESS_FIP_IP
openstack floating ip list --tags ${APPS_FIP} -f value -c 'ID' > ${SHARED_DIR}/INGRESS_FIP_UID

(
	# When debugging, we don't care about pipe failures and other errors
	set +o nounset; set +o errexit; set +o pipefail; set -o xtrace
	cat ${SHARED_DIR}/LB_FIP_IP
	cat ${SHARED_DIR}/LB_FIP_UUID
	cat ${SHARED_DIR}/INGRESS_FIP_IP
	cat ${SHARED_DIR}/INGRESS_FIP_UID
) || true
