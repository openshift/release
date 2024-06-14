#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
tag_category_name="${CLUSTER_NAME}-usertags-category"

if [[ -n "$(govc tags.category.ls | grep "${tag_category_name}")" ]];then
    echo "tag category tag_category_name found, will delete after remove tags"
else
    echo "tag category tag_category_name not found.skip deprovision"
    exit 0
fi

printf '%s' "${USER_TAGS:-}" | while read -r tag
do
    if [[ -n "$(govc tags.ls -c "${tag_category_name}" | grep "${tag}")" ]];then
        govc tags.rm -c ${tag_category_name} ${tag}
        echo "${tag} removed successful"
    fi
done;

govc tags.category.rm ${tag_category_name}
