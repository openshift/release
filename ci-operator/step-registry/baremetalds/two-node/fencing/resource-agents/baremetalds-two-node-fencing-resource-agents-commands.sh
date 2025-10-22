#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds fencing resource agent build command ************"

echo "pulling repo:$RESOURCE_AGENT_REPO ref:$RESOURCE_AGENT_REPO_REF"

git clone "$RESOURCE_AGENT_REPO"
cd resource-agents && git checkout "$RESOURCE_AGENT_REPO_REF"

autoreconf --install --force    # only the 1st time
./configure                     # only the 1st time
RPM_VERSION=4.11
make rpm VERSION="$RPM_VERSION"

scp "${SSHOPTS[@]}" ./x86_64/resource-agents-$RPM_VERSION-1.el9.x86_64.rpm "root@${IP}:/tmp/"

    # shellcheck disable=SC2087
        ssh "${SSHOPTS[@]}" "root@${IP}" bash -ux << EOF
set -o pipefail

mapfile -t IP_ARRAY < <(oc get nodes -o json | jq -r '[.items[0], .items[1]] | .[].status.addresses[] | select(.type=="InternalIP") | .address')

# Assign the array elements to individual variables
IP_NODE0=\${IP_ARRAY[0]}
IP_NODE1=\${IP_ARRAY[1]}

scp "core@\$IP_NODE0" "/tmp/resource-agents-$RPM_VERSION-1.el9.x86_64.rpm" /tmp/
ssh "core@\$IP_NODE0" sudo rpm-ostree -C override replace /tmp/resource-agents-$RPM_VERSION-1.el9.x86_64.rpm
ssh "core@\$IP_NODE0" sudo systemctl reboot
sleep 500
scp "core@\$IP_NODE1" "/tmp/resource-agents-$RPM_VERSION-1.el9.x86_64.rpm" /tmp/
ssh "core@\$IP_NODE1" sudo rpm-ostree -C override replace /tmp/resource-agents-$RPM_VERSION-1.el9.x86_64.rpm
ssh "core@\$IP_NODE1" sudo systemctl reboot
sleep 500


ssh "core@\$IP_NODE0" sudo pcs status --full
ssh "core@\$IP_NODE0" sudo podman exec etcd etcdctl member list -w table

ssh "core@\$IP_NODE1" sudo pcs status --full
ssh "core@\$IP_NODE1" sudo podman exec etcd etcdctl member list -w table

EOF
