#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ agent iso-no-registry create cluster command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# ESI nodes are all using the same IP with different ports (which is forwarded to 8213)
function getExtraVal(){
    EXTRAFILE=$SHARED_DIR/cir-extra
    if [ ! -f "$EXTRAFILE" ] || [ "$(stat -c %s "$EXTRAFILE")" -lt 2 ] ; then
        echo "$2"
        return
    fi
    jq -r --arg default "$2" ".$1 // \$default" "$EXTRAFILE"
}

PROXYPORT="$(getExtraVal ofcir_port_proxy 8213)"

finished()
{
  retval=$?

  set +o pipefail
  set +o errexit

  echo "Fetching kubeconfig, other credentials..."
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeconfig" "${SHARED_DIR}/" || true
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeadmin-password" "${SHARED_DIR}/" || true

  if [ -f "${SHARED_DIR}/kubeconfig" ]; then
    echo "Adding proxy-url in kubeconfig"
    sed -i "/- cluster/ a\    proxy-url: http://$IP:$PROXYPORT/" "${SHARED_DIR}"/kubeconfig
  fi

  echo "Fetching logs from agent_create_cluster"
  ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /root/dev-scripts/logs | tar -C "${ARTIFACT_DIR}" -xzf -
  # Use '/auths/ s/.*/' instead of 's/.*auths.*/' to avoid regex backtracking on long lines
  sed -i '
    /auths/ s/.*/*** PULL_SECRET ***/;
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${ARTIFACT_DIR}"/root/dev-scripts/logs/* 2>/dev/null || true

  # Save exit code for must-gather to generate junit
  status_file=${ARTIFACT_DIR}/root/dev-scripts/logs/installer-status.txt
  if [ -f "$status_file" ]; then
    cp "$status_file" "${SHARED_DIR}/install-status.txt"
  else
    echo "$retval" > "${SHARED_DIR}/install-status.txt"
  fi
}
trap finished EXIT TERM

# Run agent_create_cluster on the remote host
# Use '/auths/ s/.*/' instead of 's/.*auths.*/' to avoid regex backtracking on long log lines
timeout -s 9 165m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e '/auths/ s/.*/*** PULL_SECRET ***/'
set -xeuo pipefail

cd /root/dev-scripts

set +e
timeout -s 9 150m make agent_create_cluster
rv=$?

# squid needs to be restarted after network changes
podman restart --time 1 external-squid || true

# Add extra CI specific rules to the libvirt zone
sudo firewall-cmd --add-port=8213/tcp --zone=libvirt

exit $rv
EOF

# Copy dev-scripts variables to be shared with the test step
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh

set +x
echo "export DS_OPENSHIFT_VERSION=$(openshift_version)" >> /tmp/ds-vars.conf
echo "export DS_REGISTRY=$LOCAL_REGISTRY_DNS_NAME:$LOCAL_REGISTRY_PORT" >> /tmp/ds-vars.conf
echo "export DS_WORKING_DIR=$WORKING_DIR" >> /tmp/ds-vars.conf
echo "export DS_IP_STACK=$IP_STACK" >> /tmp/ds-vars.conf
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/tmp/ds-vars.conf" "${SHARED_DIR}/"

# Add required configurations ci-chat-bot needs
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > /tmp/console.url
EOF

# Save console URL in `console.url` file so that ci-chat-bot could report success
scp "${SSHOPTS[@]}" "root@${IP}:/tmp/console.url" "${SHARED_DIR}/"
