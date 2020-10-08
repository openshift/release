#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

set +e

function check_ip_resolves() {
  lookup=$(nslookup $2)
  if [[ $? -eq 0 ]]; then
    if [[ ${lookup} =~ $1 ]]; then
      echo $2 resolves to $1
      return 0
    fi
  fi
  echo $2 does not resolv to $1
  return 1
}

(
# When debugging, we don't care about pipe failures and other errors
set +o nounset; set +o errexit; set +o pipefail; set -o xtrace
echo "SHARED_DIR=${SHARED_DIR}"
echo "ARTIFACT_DIR=${ARTIFACT_DIR}"
mount | grep "$(basename ${SHARED_DIR})"
[ -n "${SHARED_DIR}" ] && ls -l "${SHARED_DIR}/"
[ -n "${ARTIFACT_DIR}" ] && ls -l "${ARTIFACT_DIR}/"
) || true

LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)
INGRESS_FIP_IP=$(<"${SHARED_DIR}"/INGRESS_FIP_IP)

echo "LEASED_RESOURCE=${LEASED_RESOURCE}"
case ${LEASED_RESOURCE} in
"openstack-osuosl-00"|"openstack-osuosl-01")
	export CLUSTER_NAME=${LEASED_RESOURCE}
	;;
"*")
	echo "Error: Unknown LEASED_RESOURCE"
	exit 1
	;;
esac

SLEEP_TIME=${WAIT_TIME}
COUNT=$(seq ${TRY_COUNT})

declare -A ipmap
ipmap["api"]=${LB_FIP_IP}
ipmap["ingress.apps"]=${INGRESS_FIP_IP}

for key in "${!ipmap[@]}"
do
    NAME=${key}
    IP=${ipmap[${key}]}
    for TRY in ${COUNT}
    do
        sleep ${SLEEP_TIME}
        echo Attempt ${TRY} to verify we can resolve ${NAME}.${CLUSTER_NAME}.${BASE_DOMAIN}
        check_ip_resolves "${IP}" "${NAME}.${CLUSTER_NAME}.${BASE_DOMAIN}"
        if [[ "$?" -eq "0" ]] ; then
            echo ${NAME}.${CLUSTER_NAME}.${BASE_DOMAIN} resolves correctly to ${IP}
            EXIT_CODE=0
            break
        fi
        EXIT_CODE=1
    done
    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo "FAILED: After ${TRY_COUNT} tries, ${NAME}.${CLUSTER_NAME}.${BASE_DOMAIN} did not resolve to ${IP}"
        exit ${EXIT_CODE}
    fi
done
