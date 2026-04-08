#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

fips_config=$(yq-go r ${SHARED_DIR}/install-config.yaml 'fips')
if [[ "${fips_config}" != "true" ]]; then
    echo "fips is not enabled in install-config.yaml, skip the post check..."
    exit 0
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

check_result=0
node_lists=$(oc get nodes -ojson | jq -r '.items[].metadata.name' | xargs)
for node in $node_lists; do
    result=""
    echo "**********Check fips on node ${node}**********"
    result=$(oc debug node/${node} -n openshift-infra -- chroot /host fips-mode-setup --check)
    if [[ "${result}" == "FIPS mode is enabled." ]]; then
        echo "Check passed on node ${node}"
    else
        echo "Check failed on node ${node}"
        oc debug node/${node} -n openshift-infra -- chroot /host fips-mode-setup --check
        oc debug node/${node} -n openshift-infra -- chroot /host grep -i fips /proc/cmdline
        check_result=1
    fi
done

echo "Exit with ${check_result}"
exit ${check_result}
