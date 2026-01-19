#!/bin/bash
cp /var/run/amd-ci/id_rsa /tmp/id_rsa
chmod 600 /tmp/id_rsa
mkdir -p ~/.ssh

# Create SSH config matching working local setup
cat > ~/.ssh/config <<'SSH_CONFIG'
Host ${REMOTE_HOST}
    User root
    IdentityFile /tmp/id_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ConnectTimeout 30
    ServerAliveInterval 10
    ServerAliveCountMax 3
    BatchMode yes
SSH_CONFIG
sed -i "s/\${REMOTE_HOST}/${REMOTE_HOST}/g" ~/.ssh/config
chmod 600 ~/.ssh/config

export PULL_SECRET_PATH=/var/run/amd-ci/pull-secret
export SSH_KEY_PATH=/tmp/id_rsa
make sno-delete

