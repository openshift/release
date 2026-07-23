#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
tag_category_name="${CLUSTER_NAME}-usertags-category"

echo "print addition_tags lists: ${USER_TAGS}"
if [[ -z "$(govc tags.category.ls | grep ${tag_category_name})" ]]; then
    govc tags.category.create -m ${tag_category_name}
fi    
printf '%s' "${USER_TAGS:-}" | while read -r tag
do    
    tag_id=$(govc tags.create -c ${tag_category_name} ${tag})
    echo "${tag},'${tag_id}'" >> ${SHARED_DIR}/tags_lists
done;

echo "print tags in tags_lists"
cat ${SHARED_DIR}/tags_lists

