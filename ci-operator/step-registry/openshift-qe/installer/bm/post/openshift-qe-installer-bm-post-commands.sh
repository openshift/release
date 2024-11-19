#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x


bastion=$(cat "/secret/address")
SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

# Clean up JetLag
ssh ${SSH_ARGS} root@${bastion} "./clean-resources.sh"

# Clean up Crucible
ssh ${SSH_ARGS} root@${bastion} "buildah rm --all; rm -Rfv /opt/crucible* /var/lib/crucible* /etc/sysconfig/crucible  /root/.crucible /etc/profile.d/crucible_completions.sh"
