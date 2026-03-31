#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- Variables ---
typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

# Get the creds from ACMQE CI vault and run the automation on pre-existing HUB
if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    : "------------ Skipping OCP Deploy = ${SKIP_OCP_DEPLOY} ------------"
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

# Update the AWS credentials in options.yaml from cluster profile
if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=
    typeset awsAccKeyToken=

    set +x
    awsAccKeyID="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsAccKeyToken="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    [ -n "${awsAccKeyID}" ] && [ -n "${awsAccKeyToken}" ]

    echo "Updating credentials in ${optionFile}..."
    yq -o json eval . "${optionFile}" |
    jq -c \
          --arg awsAccKeyID "${awsAccKeyID}" \
          --arg awsAccKeyToken "${awsAccKeyToken}" \
        '
          .options.connections.apiKeys.aws|=(
                .awsAccessKeyID=$awsAccKeyID |
                .awsSecretAccessKeyID=$awsAccKeyToken
            )
        ' |
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"
    set -x

    unset awsAccKeyID awsAccKeyToken
fi

# ========== Dynamic vSphere Configuration from CI Lease ==========

# Check if we're running in vSphere environment
if [[ "${CLUSTER_TYPE}" == "vsphere"* ]] && [[ -f "${SHARED_DIR}/vsphere_context.sh" ]]; then
    echo "=========================================="
    echo "Configuring vSphere parameters from lease"
    echo "=========================================="

    # Load vSphere context variables
    source "${SHARED_DIR}/vsphere_context.sh"
    source "${SHARED_DIR}/govc.sh" || true

    # Read CA certificate
    VSPHERE_CA_CERT=""
    if [[ -f "/var/run/vsphere-ibmcloud-ci/vcenter-certificate" ]]; then
        VSPHERE_CA_CERT=$(cat /var/run/vsphere-ibmcloud-ci/vcenter-certificate)
    elif [[ -f "${CLUSTER_PROFILE_DIR}/ca-bundle.pem" ]]; then
        VSPHERE_CA_CERT=$(cat "${CLUSTER_PROFILE_DIR}/ca-bundle.pem")
    fi

    # Read base domain
    BASE_DOMAIN=""
    if [[ -f "${SHARED_DIR}/basedomain.txt" ]]; then
        BASE_DOMAIN=$(cat "${SHARED_DIR}/basedomain.txt")
    fi

    # Display configuration (for debugging)
    echo "vSphere Configuration:"
    echo "  vCenter: ${vsphere_url}"
    echo "  Datacenter: ${vsphere_datacenter}"
    echo "  Datastore: ${vsphere_datastore}"
    echo "  Cluster: ${vsphere_cluster}"
    echo "  Network: ${vsphere_portgroup}"
    echo "  Resource Pool: ${vsphere_resource_pool}"
    echo "  Base Domain: ${BASE_DOMAIN}"

    # Build jq filter for vSphere vmware connection configuration
    set +x  # Disable tracing for password handling
    JQ_FILTER='
      .options.connections.vmware = {
        name: "opp-vmware-conn-auto",
        namespace: "default",
        provider: "VMware vSphere"
      }
    '

    # Add vcenter server
    if [[ -n "${vsphere_url:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.vcenterServer = \"${vsphere_url}\""
    fi

    # Add credentials
    if [[ -n "${GOVC_USERNAME:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.username = \"${GOVC_USERNAME}\""
    fi

    if [[ -n "${GOVC_PASSWORD:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.password = \"${GOVC_PASSWORD}\""
    fi

    # Add CA certificate
    if [[ -n "${VSPHERE_CA_CERT}" ]]; then
        # Escape newlines for jq
        VSPHERE_CA_CERT_ESCAPED=$(echo "${VSPHERE_CA_CERT}" | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.cacertificate = \"${VSPHERE_CA_CERT_ESCAPED}\""
    fi

    # Add vSphere infrastructure details
    if [[ -n "${vsphere_cluster:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.vmClusterName = \"${vsphere_cluster}\""
    fi

    if [[ -n "${vsphere_datacenter:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.datacenter = \"${vsphere_datacenter}\""
    fi

    if [[ -n "${vsphere_datastore:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.datastore = \"${vsphere_datastore}\""
    fi

    # Static configurations (can be overridden by env vars)
    JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.vSphereDiskType = \"thin\""

    VSPHERE_FOLDER="${VSPHERE_FOLDER:-/Datacenter/vm/ci-clusters}"
    JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.vSphereFolder = \"${VSPHERE_FOLDER}\""

    if [[ -n "${vsphere_resource_pool:-}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.vSphereResourcePool = \"${vsphere_resource_pool}\""
    fi

    if [[ -n "${BASE_DOMAIN}" ]]; then
        JQ_FILTER="${JQ_FILTER} | .options.connections.vmware.baseDnsDomain = \"${BASE_DOMAIN}\""
    fi

    # Apply the configuration
    echo "Injecting vSphere configuration into options.yaml..."
    yq -o json eval . "${optionFile}" | \
    jq "${JQ_FILTER}" | \
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"

    set -x  # Re-enable tracing

    echo "✅ vSphere connection configuration completed"

    # ========== VIP Configuration (if specified) ==========
    if [[ -n "${VSPHERE_API_VIP:-}" ]] || [[ -n "${VSPHERE_INGRESS_VIP:-}" ]]; then
        echo "Configuring custom VIPs for managed cluster..."

        VIP_FILTER='.'
        if [[ -n "${VSPHERE_API_VIP:-}" ]]; then
            echo "  API VIP: ${VSPHERE_API_VIP}"
            VIP_FILTER="${VIP_FILTER} | .options.clusters.vsphere.apiVIP=\"${VSPHERE_API_VIP}\""
        fi

        if [[ -n "${VSPHERE_INGRESS_VIP:-}" ]]; then
            echo "  Ingress VIP: ${VSPHERE_INGRESS_VIP}"
            VIP_FILTER="${VIP_FILTER} | .options.clusters.vsphere.ingressVIP=\"${VSPHERE_INGRESS_VIP}\""
        fi

        if [[ -n "${vsphere_portgroup:-}" ]]; then
            echo "  Network: ${vsphere_portgroup}"
            VIP_FILTER="${VIP_FILTER} | .options.clusters.vsphere.network=\"${vsphere_portgroup}\""
        fi

        yq -o json eval . "${optionFile}" | \
        jq "${VIP_FILTER}" | \
        yq -p json -o yaml eval . > "${optionFile}.tmp"
        mv -f "${optionFile}.tmp" "${optionFile}"

        # Save VIP info for later steps
        cat > "${SHARED_DIR}/vsphere-spoke-vips.txt" <<EOF
VSPHERE_API_VIP=${VSPHERE_API_VIP:-auto}
VSPHERE_INGRESS_VIP=${VSPHERE_INGRESS_VIP:-auto}
VSPHERE_NETWORK=${vsphere_portgroup:-auto}
EOF
        echo "✅ VIP configuration completed"
    else
        echo "No custom VIPs specified, vSphere will auto-assign"
    fi

    # Save configuration summary
    cat > "${SHARED_DIR}/vsphere-config-summary.txt" <<EOF
vSphere Configuration Summary:
==============================
vCenter: ${vsphere_url}
Datacenter: ${vsphere_datacenter}
Datastore: ${vsphere_datastore}
Cluster: ${vsphere_cluster}
Network: ${vsphere_portgroup}
Resource Pool: ${vsphere_resource_pool}
Base Domain: ${BASE_DOMAIN}
Disk Type: thin
Folder: ${VSPHERE_FOLDER}
API VIP: ${VSPHERE_API_VIP:-auto-assigned}
Ingress VIP: ${VSPHERE_INGRESS_VIP:-auto-assigned}
EOF

    cat "${SHARED_DIR}/vsphere-config-summary.txt"

else
    echo "Not a vSphere environment or vsphere_context.sh not found, skipping vSphere configuration"
fi

# ========== END vSphere Configuration ==========

: "Executing CLC interop commands..."
set +x
export CYPRESS_OPTIONS_HUB_PASSWORD=
CYPRESS_OPTIONS_HUB_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
set -x

CYPRESS_BASE_URL="$(oc whoami --show-console)" \
CYPRESS_HUB_API_URL="$(oc whoami --show-server)" \
CYPRESS_CLC_OCP_IMAGE_VERSION="$(cat "${secretsDir}/clc/ocp_image_version")" \
CLOUD_PROVIDERS="$(cat "${secretsDir}/clc/ocp_cloud_providers")" \
bash +x ./execute_clc_interop_commands.sh || :

unset CYPRESS_OPTIONS_HUB_PASSWORD

: "Copying artifacts..."
cp -r reports "${ARTIFACT_DIR}/"

# Copy configuration summary to artifacts for debugging
if [[ -f "${SHARED_DIR}/vsphere-config-summary.txt" ]]; then
    cp "${SHARED_DIR}/vsphere-config-summary.txt" "${ARTIFACT_DIR}/"
fi

true
