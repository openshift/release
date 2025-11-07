#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

case ${KUBECONFIG_ORIGIN} in
  (bastion)
    SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
    bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
    LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
    LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)

    if [ -z "${KUBECONFIG_PATH}" ]; then
        scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig ${SHARED_DIR}/kubeconfig
    else
        scp -q ${SSH_ARGS} root@${bastion}:/$KUBECONFIG_PATH/kubeconfig ${SHARED_DIR}/kubeconfig
    fi

    # Create proxy configuration for private VLAN deployments
    if [[ ${PUBLIC_VLAN} == "false" ]]; then
      cat > ${SHARED_DIR}/proxy-conf.sh << 'PROXY_EOF'
#!/bin/bash

cleanup_ssh() {
  # Kill the SOCKS proxy running on the jumphost
  ssh ${SSH_ARGS} root@${jumphost} "pkill -f 'ssh root@${bastion} -fNT -D'" 2>/dev/null || true
  # Kill local SSH processes
  pkill ssh
}

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

# Generate a random port between 10000-65535 for SOCKS proxy
SOCKS_PORT=$((RANDOM % 55536 + 10000))

# Step 1: Start SOCKS proxy on jumphost connecting to bastion (runs in background on jumphost)
ssh ${SSH_ARGS} root@${jumphost} "ssh root@${bastion} -fNT -D 0.0.0.0:${SOCKS_PORT}" &

# Step 2: Forward the SOCKS proxy from jumphost back to CI host
ssh ${SSH_ARGS} root@${jumphost} -fNT -L ${SOCKS_PORT}:localhost:${SOCKS_PORT}

# Give SSH tunnels a moment to establish
sleep 3

# Configure proxy settings for oc commands
export KUBECONFIG=${SHARED_DIR}/kubeconfig
export https_proxy=socks5://localhost:${SOCKS_PORT}
export http_proxy=socks5://localhost:${SOCKS_PORT}

# Configure oc to use the proxy
oc --kubeconfig=${SHARED_DIR}/kubeconfig config set-cluster "$(oc config current-context)" --proxy-url=socks5://localhost:${SOCKS_PORT}

trap 'cleanup_ssh' EXIT
PROXY_EOF
    fi
    ;;

(vault)
    if [ -z "${VAULT_ENV_PATH}" ]; then
        echo "VAULT_ENV_PATH must be set when KUBECONFIG_ORIGIN=vault"
        exit 1
    fi

    # Function to fetch a secret with retries
    fetch_from_vault() {
        local path="$1"
        local dest="$2"
        local retries=3
        local count=0
        local delay=5

        until [ $count -ge $retries ]; do
            if vault kv get -field=value "$path" > "$dest" 2>/dev/null; then
                return 0
            fi
            echo "Failed to fetch $path from Vault, retrying in $delay seconds..."
            count=$((count+1))
            sleep $delay
        done

        echo "ERROR: Unable to fetch $path from Vault after $retries attempts."
        return 1
    }

    for tgtFile in kube{admin-password,config}; do
        srcFile="${tgtFile}${KCFG_SRC_SFX:+--${KCFG_SRC_SFX}}"
        fetch_from_vault "${VAULT_ENV_PATH}/${srcFile}" "${SHARED_DIR}/${tgtFile}"

        # Optional minimal kubeconfig for CI workflows
        [ "${tgtFile}" = kubeconfig ] && cp "${SHARED_DIR}/${tgtFile}" "${SHARED_DIR}/${tgtFile}-minimal"
    done

    export KUBECONFIG="${SHARED_DIR}/kubeconfig"

    ;;

  (*)
    echo "Unsupported KUBECONFIG_ORIGIN='${KUBECONFIG_ORIGIN}'"
    exit 1
    ;;
esac

exit 0
