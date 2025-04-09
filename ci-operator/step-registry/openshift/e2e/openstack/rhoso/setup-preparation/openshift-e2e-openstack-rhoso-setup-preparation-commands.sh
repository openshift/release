#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
SHARED_DIR=/tmp/secret

echo Running on ${LEASED_RESOURCE}
echo "${USER:-default}:x:$(id -u):$(id -g):Default User:$HOME:/sbin/nologin" >> /etc/passwd
PROXY_USER=$(cat /var/run/cluster-secrets/openstack-rhoso/proxy-user)
cp /var/run/cluster-secrets/openstack-rhoso/proxy-private-key /tmp/id_rsa-proxy
chmod 0600 /tmp/id_rsa-proxy
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no \
  -i /tmp/id_rsa-proxy \
  ${PROXY_USER}@${LEASED_RESOURCE}:~/kubeconfig $SHARED_DIR/rhoso_kubeconfig \
  || (echo "ABORTING! Selected RHOSO cloud is not ready to be used."; exit 130)
KUBECONFIG=$SHARED_DIR/rhoso_kubeconfig
oc get -n openstack openstackversions.core.openstack.org controlplane
