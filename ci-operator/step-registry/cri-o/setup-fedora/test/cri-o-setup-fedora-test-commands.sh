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

    # Update system-packages.yml to replace libpathrs-devel with build dependencies
    sed -i '/# required for building runc with libpathrs support\./d' system-packages.yml
    sed -i 's/      - libpathrs-devel/      # required for building libpathrs from source.\n      - rust\n      - cargo\n      - cargo-c\n      - git/' system-packages.yml

    # Create build/libpathrs.yml
    cat > build/libpathrs.yml << 'LIBPATHRS_EOF'
---
- name: clone libpathrs source repo
  git:
    repo: "https://github.com/cyphar/libpathrs.git"
    dest: "/tmp/libpathrs"
    version: "main"
    force: yes

- name: build libpathrs
  shell: cargo cbuild --release
  args:
    chdir: "/tmp/libpathrs"
  environment:
    PATH: "{{ ansible_env.HOME }}/.cargo/bin:{{ ansible_env.PATH }}"

- name: install libpathrs
  shell: cargo cinstall --release --prefix=/usr --libdir=/usr/lib64
  args:
    chdir: "/tmp/libpathrs"
  environment:
    PATH: "{{ ansible_env.HOME }}/.cargo/bin:{{ ansible_env.PATH }}"

- name: cleanup libpathrs source
  file:
    path: "/tmp/libpathrs"
    state: absent
LIBPATHRS_EOF

    # Update setup.yml to add libpathrs build step before runc
    sed -i '/- name: clone build and install runc/i\- name: build and install libpathrs\n  include_tasks: "build/libpathrs.yml"\n  when: ansible_distribution in ['"'"'Fedora'"'"']\n' setup.yml

    ansible-playbook setup-main.yml --connection=local -vvv
    ANSIBLE_EXIT_CODE=\$?
    sudo rm -rf "\${SOURCE_DIR}"
    exit \${ANSIBLE_EXIT_CODE}
EOF

if [ $? -ne 0 ]; then
    echo "ERROR: Ansible playbook failed, not creating base image"
    exit 1
fi

echo "Ansible playbook succeeded, creating base image..."
currentDate=$(date +'%s')
gcloud compute instances stop ${instance_name} --zone=${ZONE}
disk_name=$(gcloud compute instances describe ${instance_name} --zone=${ZONE} --format='get(disks[0].source)')

gcloud compute images create crio-setup-fedora-${currentDate} \
    --source-disk="${disk_name}" \
    --family="crio-setup-fedora" \
    --source-disk-zone=${ZONE} \
    --project="openshift-node-devel"
# Delete images older than 2 weeks
images=$(gcloud compute images list --project="openshift-node-devel" --filter="family:crio-setup-fedora AND creationTimestamp<$(date -d '2 weeks ago' +%Y-%m-%dT%H:%M:%SZ)" --format="value(name)")
if [ -n "$images" ]; then
    echo "The following images will be deleted:"
    echo "$images"
    echo "$images" | xargs -I '{}' gcloud compute images delete '{}' --project="openshift-node-devel" || true
else
    echo "No images found that were created more than 2 weeks ago."
fi
gcloud compute instances delete ${instance_name} --zone=${ZONE}
