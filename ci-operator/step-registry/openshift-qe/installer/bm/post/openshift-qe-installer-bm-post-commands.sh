#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x


bastion=$(cat "/secret/address")

# Clean up JetLag
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "./clean-resources.sh"

# Clean up Crucible
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "buildah rm --all; rm -Rfv /opt/crucible* /var/lib/crucible* /etc/sysconfig/crucible  /root/.crucible /etc/profile.d/crucible_completions.sh"
