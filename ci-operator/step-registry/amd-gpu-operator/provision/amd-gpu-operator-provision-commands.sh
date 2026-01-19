#!/bin/bash
set -x
cp /var/run/amd-ci/id_rsa /tmp/id_rsa
chmod 600 /tmp/id_rsa
mkdir -p ~/.ssh
echo "Host ${REMOTE_HOST}" > ~/.ssh/config
echo "  User root" >> ~/.ssh/config
echo "  IdentityFile /tmp/id_rsa" >> ~/.ssh/config
echo "  StrictHostKeyChecking no" >> ~/.ssh/config
echo "  UserKnownHostsFile /dev/null" >> ~/.ssh/config
chmod 600 ~/.ssh/config
ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST} "echo 'Host *' >> /etc/ssh/ssh_config && echo '  StrictHostKeyChecking no' >> /etc/ssh/ssh_config && echo '  UserKnownHostsFile /dev/null' >> /etc/ssh/ssh_config && echo '#!/bin/sh' > /bin/sudo && echo 'exec \"\$@\"' >> /bin/sudo && chmod 755 /bin/sudo"
scp -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/id_rsa root@${REMOTE_HOST}:~/.ssh/id_rsa
ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST} "chmod 600 ~/.ssh/id_rsa && ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub && chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true && grep -qF \"\$(cat ~/.ssh/id_rsa.pub)\" ~/.ssh/authorized_keys 2>/dev/null || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
export PULL_SECRET_PATH=/var/run/amd-ci/pull-secret
export SSH_KEY_PATH=/tmp/id_rsa
make sno-deploy

