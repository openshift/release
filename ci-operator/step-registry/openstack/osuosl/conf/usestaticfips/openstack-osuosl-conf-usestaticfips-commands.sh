#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

(
# When debugging, we don't care about pipe failures and other errors
set +o errexit; set +o pipefail; set -o xtrace
ls -l ${CLUSTER_PROFILE_DIR}/
ls -l /etc/openstack/
openstack floating ip list --long -f value
)

export OS_CLIENT_CONFIG_FILE=/etc/openstack/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)

echo "CLUSTER_NAME=${CLUSTER_NAME}"
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
"openstack-osuosl-02")
	export LB_FIP="GROUP3_LB_FIP"
	export APPS_FIP="GROUP3_APPS_FIP"
	# @HACK
	export LB_FIP="GROUP1_LB_FIP"
	export APPS_FIP="GROUP1_APPS_FIP"
	;;
"openstack-osuosl-03")
	export LB_FIP="GROUP4_LB_FIP"
	export APPS_FIP="GROUP4_APPS_FIP"
	# @HACK
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
set +o errexit; set +o pipefail; set -o xtrace
cat ${SHARED_DIR}/LB_FIP_IP
cat ${SHARED_DIR}/LB_FIP_UUID
cat ${SHARED_DIR}/INGRESS_FIP_IP
cat ${SHARED_DIR}/INGRESS_FIP_UID
)
