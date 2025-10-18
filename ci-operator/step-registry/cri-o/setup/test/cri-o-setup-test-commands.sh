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
    set -xeuo pipefail
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"
    cd "\${SOURCE_DIR}/contrib/test/ci"
    sed -i 's/stdout_callback = debug//g' ansible.cfg
    sed -i "s/ftp.gnu.org/ftpmirror.gnu.org/g" build/parallel.yml
    ansible-playbook setup-main.yml --connection=local -vvv
    sudo rm -rf "\${SOURCE_DIR}"
EOF

currentDate=$(date +'%s')
gcloud compute instances stop ${instance_name} --zone=${ZONE}
disk_name=$(gcloud compute instances describe ${instance_name} --zone=${ZONE} --format='get(disks[0].source)')

gcloud compute images create crio-setup-${currentDate} \
    --source-disk="${disk_name}" \
    --family="crio-setup" \
    --source-disk-zone=${ZONE} \
    --project="openshift-node-devel"
# Delete images older than 2 weeks
images=$(gcloud compute images list --project="openshift-node-devel" --filter="family:crio-setup AND creationTimestamp<$(date -d '2 weeks ago' +%Y-%m-%dT%H:%M:%SZ)" --format="value(name)")
if [ -n "$images" ]; then
    echo "The following images will be deleted:"
    echo "$images"
    echo "$images" | xargs -I '{}' gcloud compute images delete '{}' --project="openshift-node-devel" || true
else
    echo "No images found that were created more than 2 weeks ago."
fi
gcloud compute instances delete ${instance_name} --zone=${ZONE}
