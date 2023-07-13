#!/bin/bash

set -eux

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
INFRA_ID=$(oc get hostedclusters ${CLUSTER_NAME} -n clusters -ojsonpath='{.spec.infraID}')

output=$(/usr/bin/hypershift create bastion aws --aws-creds="${CLUSTER_PROFILE_DIR}/.awscred" --infra-id="${INFRA_ID}" --region="${HYPERSHIFT_AWS_REGION}" --ssh-key-file="${CLUSTER_PROFILE_DIR}/ssh-publickey" >&1)
ip=$(echo "$output" | grep -oE '"publicIP": "([0-9]{1,3}\.){3}[0-9]{1,3}"' | awk -F': ' '{print $2}' | tr -d '"')
echo "Bastion IP: $ip"



#sudo yum install -y squid && sudo systemctl enable --now squid

#"${CLUSTER_PROFILE_DIR}/ssh-publickey"
#"${CLUSTER_PROFILE_DIR}/ssh-privatekey"
#
#aws-provision-bastionhost
#
#
#wget https://snapshots.mitmproxy.org/7.0.2/mitmproxy-7.0.2-linux.tar.gz
#mkdir mitm
#tar zxvf mitmproxy-7.0.2-linux.tar.gz -C mitm
#cd mitm
#nohup ./mitmdump --showhost --ssl-insecure --ignore-hosts quay.io --ignore-hosts registry.redhat.io --ignore-hosts amazonaws.com  > mitm.log  &