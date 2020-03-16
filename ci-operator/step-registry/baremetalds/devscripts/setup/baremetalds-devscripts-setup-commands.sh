#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile

export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export PULL_SECRET_PATH=${cluster_profile}/pull-secret
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"

echo "************ baremetalds devscripts setup command ************"
env | sort

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

echo "-------[ $SHARED_DIR ]"
ls -ll ${SHARED_DIR}

# Fetch packet server IP
IP=$(cat ${SHARED_DIR}/server-ip)
export IP
echo "Packet server IP is ${IP}"

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

# Prepare configuration and run dev-scripts 
scp $SSHOPTS ${PULL_SECRET_PATH} root@$IP:pull-secret

timeout -s 9 175m ssh $SSHOPTS root@$IP bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -ex

#### For debug only, to be removed ####################################
curl https://github.com/derekhiggins.keys >> /root/.ssh/authorized_keys
curl https://github.com/andfasano.keys >> /root/.ssh/authorized_keys
curl https://github.com/russellb.keys >> /root/.ssh/authorized_keys
curl https://github.com/stbenjam.keys >> /root/.ssh/authorized_keys
curl https://github.com/honza.keys >> /root/.ssh/authorized_keys
#######################################################################

yum install -y git

mkdir -p /tmp/artifacts

if [ ! -e dev-scripts ] ; then
  git clone https://github.com/openshift-metal3/dev-scripts.git
fi
cd dev-scripts

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" > /root/dev-scripts/config_root.sh
set -x

curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.4/linux/oc.tar.gz | tar -C /usr/bin -xzf -

echo "export OPENSHIFT_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/dev-scripts/config_root.sh
echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> /root/dev-scripts/config_root.sh
echo "export OPENSHIFT_CI=true" >> /root/dev-scripts/config_root.sh
echo "export MIRROR_IMAGES=true" >> /root/dev-scripts/config_root.sh

echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> /root/.bashrc

if [ ! -e /opt/dev-scripts/pool ] ; then
  mkdir -p /opt/dev-scripts/pool
  mount -t tmpfs -o size=100G tmpfs /opt/dev-scripts/pool
fi

timeout -s 9 105m make

EOF







