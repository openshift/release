#!/bin/bash
set -o nounset
set -o errexit
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x ${SHARED_DIR}/login_script.sh
${SHARED_DIR}/login_script.sh

instance_name=$(<"${SHARED_DIR}/gcp-instance-ids.txt")

timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"
    cd "\${SOURCE_DIR}/contrib/test/ci"
    ansible-playbook setup-main.yml --connection=local -vvv
EOF

currentDate=$(date +'%s')
gcloud compute instances stop ${instance_name} --zone=${ZONE}
gcloud compute images create "crio-setup-${currentDate}" --source-image-family="crio-setup" --source-image-project="${PROJECT_ID}" --family="crio-setup" --project="openshift-node-devel"
# Delete images older than 2 weeks
images=$(gcloud compute images list --project="openshift-node-devel" --filter="family:crio-setup AND creationTimestamp<$(date -d '2 weeks ago' +%Y-%m-%dT%H:%M:%SZ)" --format="value(name)")
if [ -n "$images" ]; then
	echo "$images" | xargs -I '{}' gcloud compute images delete '{}'
else
	echo "No images found that were created more than 2 weeks ago."
fi
