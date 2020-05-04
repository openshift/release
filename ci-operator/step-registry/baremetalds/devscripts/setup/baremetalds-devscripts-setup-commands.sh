#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts setup command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
${HOME}/fix_uid.sh

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

# Fetch packet server IP
IP=$(cat ${SHARED_DIR}/server-ip)

SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey"

# Checkout dev-scripts and make
for x in $(seq 10) ; do
    test $x == 10 && exit 1
    ssh $SSHOPTS root@$IP hostname && break
    sleep 10
done

# Get dev-scripts logs
finished()
{
  set +e

  # Get dev-scripts logs
  echo "dev-scripts setup completed, fetching logs"
  ssh $SSHOPTS root@$IP tar -czf - /root/dev-scripts/logs | tar -C ${ARTIFACT_DIR} -xzf -
  sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' ${ARTIFACT_DIR}/root/dev-scripts/logs/*
}
trap finished EXIT TERM

# Copy dev-scripts source from current directory to the remote server
tar -czf - . | ssh $SSHOPTS root@$IP "cat > /root/dev-scripts.tar.gz"

# Prepare configuration and run dev-scripts
scp $SSHOPTS ${CLUSTER_PROFILE_DIR}/pull-secret root@$IP:pull-secret

if [[ -e ${SHARED_DIR}/dev-scripts-additional-config ]]
then
  scp $SSHOPTS ${SHARED_DIR}/dev-scripts-additional-config root@$IP:dev-scripts-additional-config
fi

timeout -s 9 175m ssh $SSHOPTS root@$IP bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -ex

yum install -y git

mkdir -p /tmp/artifacts

mkdir dev-scripts
tar -xzvf dev-scripts.tar.gz -C /root/dev-scripts
chown -R root:root dev-scripts

cd dev-scripts

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" > /root/dev-scripts/config_root.sh
set -x

curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.4/linux/oc.tar.gz | tar -C /usr/bin -xzf -

echo "export OPENSHIFT_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/dev-scripts/config_root.sh
echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> /root/dev-scripts/config_root.sh
echo "export OPENSHIFT_CI=true" >> /root/dev-scripts/config_root.sh
echo "export MIRROR_IMAGES=true" >> /root/dev-scripts/config_root.sh
echo "export NUM_WORKERS=2" >> /root/dev-scripts/config_root.sh

if [[ -e /root/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
fi

echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> /root/.bashrc

#timeout -s 9 105m make

EOF







