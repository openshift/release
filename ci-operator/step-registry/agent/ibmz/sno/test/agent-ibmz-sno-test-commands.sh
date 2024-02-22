#!/bin/bash

set -ex

# Session variables
httpd_vsi_ip=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-ip")
export httpd_vsi_ip
ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/httpd-vsi-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}

-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}
ssh_options=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=60' -i "$tmp_ssh_key")

# Verifying the SNO cluster status
echo "$(date) Checking the SNO status"
ssh "${ssh_options[@]}" root@$httpd_vsi_ip "oc wait no --all --for=condition=Ready=true --timeout=30m --kubeconfig /var/www/html/$CLUSTER_NAME/auth/kubeconfig"
echo "$(date) SNO cluster is ready"

# Verifying the SNO cluster operators status
echo "$(date) Verifying the cluster operators status"
ssh "${ssh_options[@]}" root@$httpd_vsi_ip "oc wait --all=true co --for=condition=Available=True --timeout=30m --kubeconfig /var/www/html/$CLUSTER_NAME/auth/kubeconfig"
echo "$(date) All cluster operators are ready"
