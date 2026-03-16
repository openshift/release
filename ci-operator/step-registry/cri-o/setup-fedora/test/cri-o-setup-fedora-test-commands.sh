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

    # Patch libpathrs.yml to use the official runc build script
    cat > build/libpathrs.yml << 'LIBPATHRS_PATCH'
---
# Clone runc repository to access the build-libpathrs.sh script
- name: clone runc source repo for build script
  git:
    repo: "https://github.com/opencontainers/runc.git"
    dest: "/tmp/runc-libpathrs-build"
    version: "main"
    force: yes

# Make the build script executable
- name: make build script executable
  file:
    path: "/tmp/runc-libpathrs-build/script/build-libpathrs.sh"
    mode: '0755'

# Build and install libpathrs using the runc build script
- name: build libpathrs
  become: yes
  shell: |
    cd /tmp/runc-libpathrs-build
    ./script/build-libpathrs.sh 0.2.4 /usr
  environment:
    PATH: "/usr/local/bin:/usr/bin:/bin"
    CARGO_HOME: "{{ ansible_env.HOME }}/.cargo"

# Clean up libpathrs build artifacts
- name: cleanup libpathrs build artifacts in /tmp
  file:
    path: "/tmp/libpathrs-0.2.4.tar.xz"
    state: absent

# Clean up runc clone used for build script
- name: cleanup runc build script repository
  file:
    path: "/tmp/runc-libpathrs-build"
    state: absent
LIBPATHRS_PATCH

    # Update system-packages.yml to add cargo dependencies for libpathrs build
    sed -i '/- crun-wasm$/a\      # required for building libpathrs from source.\n      - rust\n      - cargo\n      - cargo-c\n      - git\n      - wget\n      - make' system-packages.yml

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
