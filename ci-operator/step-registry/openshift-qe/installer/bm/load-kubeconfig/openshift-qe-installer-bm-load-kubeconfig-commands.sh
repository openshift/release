#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

case ${KUBECONFIG_ORIGIN} in
  (bastion)
    SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
    bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
    LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
    LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)

    if [ -z "${KUBECONFIG_PATH}" ]; then
        scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig ${SHARED_DIR}/kubeconfig
    else
        scp -q ${SSH_ARGS} root@${bastion}:/$KUBECONFIG_PATH/kubeconfig ${SHARED_DIR}/kubeconfig
    fi
    ;;
  (vault)
    typeset e=

    for e in kube{admin-password,config}; do
        [ -r "${CLUSTER_PROFILE_DIR}/${e}" ] && cp "${CLUSTER_PROFILE_DIR}/${e}" "${SHARED_DIR}/"
        [ "${e}" = kubeconfig ] && cp "${CLUSTER_PROFILE_DIR}/${e}" "${SHARED_DIR}/${e}-minimal"
    done
    ;;
  (*)
    echo "Unsupported setting \`KUBECONFIG_ORIGIN=${KUBECONFIG_ORIGIN@Q}\`."
    ;;
esac
