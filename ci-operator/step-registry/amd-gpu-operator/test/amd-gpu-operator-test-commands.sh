#!/bin/bash
cp /var/run/amd-ci/id_rsa /tmp/id_rsa
chmod 600 /tmp/id_rsa
mkdir -p ~/.ssh
echo "Host ${REMOTE_HOST}" > ~/.ssh/config
echo "  User root" >> ~/.ssh/config
echo "  IdentityFile /tmp/id_rsa" >> ~/.ssh/config
echo "  StrictHostKeyChecking no" >> ~/.ssh/config
echo "  UserKnownHostsFile /dev/null" >> ~/.ssh/config
chmod 600 ~/.ssh/config
echo "Waiting for cluster API to be ready on remote host..."
for i in {1..60}; do
  if ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST} "curl -k -s --connect-timeout 5 https://192.168.122.253:6443/readyz" | grep -q "ok"; then
    echo "Cluster API is ready!"
    break
  fi
  echo "Waiting for API... ($i/60)"
  sleep 10
done
scp -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST}:/root/kubeconfig /tmp/kubeconfig
sed -i 's|https://192.168.122.253:6443|https://127.0.0.1:6443|g' /tmp/kubeconfig
sed -i 's|https://api.sno.example.com:6443|https://127.0.0.1:6443|g' /tmp/kubeconfig
sed -i '/certificate-authority-data:/d' /tmp/kubeconfig
sed -i '/server: https:\/\/127.0.0.1:6443/a\    insecure-skip-tls-verify: true' /tmp/kubeconfig
ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -L 6443:192.168.122.253:6443 root@${REMOTE_HOST} -N -f
sleep 5
export KUBECONFIG=/tmp/kubeconfig
./scripts/test-runner.sh
