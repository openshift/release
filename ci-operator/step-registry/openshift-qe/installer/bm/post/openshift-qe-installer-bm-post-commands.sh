#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x


bastion=$(cat "/secret/address")
mkdir ~/.ssh
cp /secret/jh_priv_ssh_key ~/.ssh/id_rsa
chmod 0600 ~/.ssh/id_rsa

# Clean up JetLag
ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "./clean-resources.sh"

# Clean up Crucible
ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "buildah rm --all; rm -Rfv /opt/crucible* /var/lib/crucible* /etc/sysconfig/crucible  /root/.crucible /etc/profile.d/crucible_completions.sh"
