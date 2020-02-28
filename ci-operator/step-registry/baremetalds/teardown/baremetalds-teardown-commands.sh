#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export PACKETCRD_PATH=${cluster_profile}/.packetcrd
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}

echo "************ baremetalds teardown command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

#        finished()
#        {
#            set +e
#
#            if [ -n "$IP" ] ; then
#                echo "Getting logs"
#                ssh $SSHOPTS root@$IP tar -czf - /root/dev-scripts/logs | tar -C /tmp/artifacts -xzf -
#                sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' /tmp/artifacts/root/dev-scripts/logs/*
#            fi
#
#            echo "Deprovisioning cluster ..."
#            cd /tmp/artifacts/terraform
#            terraform init
#            for r in {1..5}; do terraform destroy -auto-approve && break ; done
#            touch /tmp/shared/exit
#        }
#        trap finished EXIT TERM




