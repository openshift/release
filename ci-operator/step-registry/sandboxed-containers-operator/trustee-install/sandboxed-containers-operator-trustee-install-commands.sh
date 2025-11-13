#!/bin/bash

# trustee install
# Installs and configures the Trustee Operator for Confidential Containers
# Can run standalone or as part of sandboxed-containers-operator-pre chain
#
# Usage:
#   ./sandboxed-containers-operator-trustee-install-commands.sh
#
# Environment variables (all optional):
#   INSTALL_TRUSTEE             - Enable/disable trustee installation (default: false)
#   TRUSTEE_CATALOG_SOURCE_NAME - Catalog source name (default: from osc-config or "redhat-operators")
#   TRUSTEE_NAMESPACE           - Trustee operator namespace (default: "trustee-operator-system")
#   TRUSTEE_URL_USE_HTTP        - Use HTTP instead of HTTPS (default: false)
#   TRUSTEE_URL_USE_NODEPORT    - Use nodePort instead of route (default: false)
#   TRUSTEE_INSECURE_HTTP       - Enable insecure HTTP in KBS (default: false)
#   TRUSTEE_TESTING             - Use permissive policy (default: false)
#   TRUSTEE_ORG                 - Certificate organization (default: "Red Hat OpenShift")
#   TRUSTEE_CN                  - Certificate common name (default: "kbs-trustee-operator-system")
#   KBSCONFIG_OUTPUT_FILE       - KbsConfig YAML output file (default: "kbsconfig.yaml")
#   KBS_SERVICE_TYPE            - KBS service type (default: "NodePort")
#   KBS_DEPLOYMENT_TYPE         - KBS deployment type (default: "AllInOneDeployment")
#   KBS_SECRET_RESOURCES        - Comma-separated secret resources (default: "kbsres1,cosign-public-key,security-policy,attestation-token")
#   KBS_ENABLE_TDX              - Enable TDX configuration (default: "false")
#   SHARED_DIR                  - Directory for outputs (default: current directory)
#
# Example:
#   INSTALL_TRUSTEE=true TRUSTEE_TESTING=true ./sandboxed-containers-operator-trustee-install-commands.sh

set -euo pipefail

# Check if trustee installation is enabled
INSTALL_TRUSTEE="${INSTALL_TRUSTEE:-false}"
if [[ "${INSTALL_TRUSTEE}" != "true" ]]; then
    echo "=== Trustee installation is disabled (INSTALL_TRUSTEE=${INSTALL_TRUSTEE}) ==="
    echo "Set INSTALL_TRUSTEE=true to enable trustee installation"
    echo "Skipping trustee installation..."
    exit 0
fi

echo "=== Trustee installation is enabled (INSTALL_TRUSTEE=${INSTALL_TRUSTEE}) ==="

# Configuration options
# Set TRUSTEE_URL_USE_HTTP=true to use HTTP instead of HTTPS for Trustee URL (insecure - for testing only)
TRUSTEE_URL_USE_HTTP="${TRUSTEE_URL_USE_HTTP:-false}"
# Set TRUSTEE_URL_USE_NODEPORT=true to use nodeIP:nodePort instead of route hostname
TRUSTEE_URL_USE_NODEPORT="${TRUSTEE_URL_USE_NODEPORT:-false}"
# Set TRUSTEE_INSECURE_HTTP=true to enable insecure HTTP in KBS config (default: false)
TRUSTEE_INSECURE_HTTP="${TRUSTEE_INSECURE_HTTP:-false}"
# Set TRUSTEE_TESTING=true to use permissive resource policy for development/testing (default: false)
TRUSTEE_TESTING="${TRUSTEE_TESTING:-false}"
# Set TRUSTEE_ORG to customize the Organization (O) value in certificates (default: "Red Hat OpenShift")
TRUSTEE_ORG="${TRUSTEE_ORG:-Red Hat OpenShift}"
# Set TRUSTEE_CN to customize the Common Name (CN) value in certificates (default: "kbs-trustee-operator-system")
TRUSTEE_CN="${TRUSTEE_CN:-kbs-trustee-operator-system}"
# Set TRUSTEE_CATALOG_SOURCE_NAME to specify the catalog source for operator subscription
# If not set, try to read from osc-config ConfigMap, otherwise default to "redhat-operators"
if [ -z "${TRUSTEE_CATALOG_SOURCE_NAME:-}" ]; then
    # Try to get catalog source name from osc-config ConfigMap created by env-cm step
    OSC_CONFIG_CATALOG=$(oc get configmap osc-config -n default '-o=jsonpath={.data.catalogsourcename}' 2>/dev/null || echo "")
    if [ -n "$OSC_CONFIG_CATALOG" ]; then
        TRUSTEE_CATALOG_SOURCE_NAME="$OSC_CONFIG_CATALOG"
        echo "Using catalog source from osc-config: ${TRUSTEE_CATALOG_SOURCE_NAME}"
    else
        TRUSTEE_CATALOG_SOURCE_NAME="redhat-operators"
        echo "Using default catalog source: ${TRUSTEE_CATALOG_SOURCE_NAME}"
    fi
else
    echo "Using TRUSTEE_CATALOG_SOURCE_NAME environment variable: ${TRUSTEE_CATALOG_SOURCE_NAME}"
fi

# KbsConfig configuration variables
TRUSTEE_NAMESPACE="${TRUSTEE_NAMESPACE:-trustee-operator-system}"
KBSCONFIG_OUTPUT_FILE="${KBSCONFIG_OUTPUT_FILE:-kbsconfig.yaml}"
KBS_SERVICE_TYPE="${KBS_SERVICE_TYPE:-NodePort}"
KBS_DEPLOYMENT_TYPE="${KBS_DEPLOYMENT_TYPE:-AllInOneDeployment}"
KBS_SECRET_RESOURCES="${KBS_SECRET_RESOURCES:-kbsres1,cosign-public-key,security-policy,attestation-token}"
KBS_ENABLE_TDX="${KBS_ENABLE_TDX:-false}"

# Function to wait for an operator subscription and CSV to finish installation
# Parameters:
#   $1: subscription_name - Name of the subscription
#   $2: namespace - Namespace where the subscription exists
#   $3: max_attempts - Maximum number of attempts (default: 60)
#   $4: sleep_seconds - Seconds to sleep between attempts (default: 10)
# Returns: 0 if successful, 1 if failed
# Example:
#   wait_for_operator_subscription "trustee-operator" "trustee-operator-system"
#   wait_for_operator_subscription "my-operator" "my-namespace" 120 5
wait_for_operator_subscription() {
    local subscription_name="$1"
    local namespace="$2"
    local max_attempts="${3:-60}"
    local sleep_seconds="${4:-10}"

    if [ -z "$subscription_name" ] || [ -z "$namespace" ]; then
        echo "Error: subscription_name and namespace are required parameters"
        return 1
    fi

    # Wait for subscription to reach AtLatestKnown state
    echo "Waiting for subscription '${subscription_name}' to be ready (state: AtLatestKnown)..."
    local subscription_ready=false

    for i in $(seq 1 "$max_attempts"); do
        local subscription_state=""

        subscription_state=$(oc get subscription "${subscription_name}" -n "${namespace}" '-o=jsonpath={.status.state}' 2>/dev/null )
        if [[ "$subscription_state" == "AtLatestKnown" ]]; then
            subscription_ready=true
            echo "Subscription is ready (state: AtLatestKnown)"
            break
        fi
        echo "Waiting for subscription to be ready... (attempt $i/$max_attempts, current state: ${subscription_state:-unknown})"
        sleep "$sleep_seconds"
    done

    if [ "$subscription_ready" = false ]; then
        echo "Warning: Subscription '${subscription_name}' did not reach AtLatestKnown state after $((max_attempts * sleep_seconds)) seconds"
        echo "Please check the subscription status with: oc get subscription ${subscription_name} -n ${namespace} -o yaml"
        return 1
    fi

    # Get the CSV name from the subscription
    local csv_name=""
    csv_name=$(oc get subscription "${subscription_name}" -n "${namespace}" '-o=jsonpath={.status.installedCSV}' 2>/dev/null )

    if [ -z "$csv_name" ]; then
        echo "Warning: Could not get installedCSV from subscription '${subscription_name}'"
        echo "Please check the subscription status with: oc get subscription ${subscription_name} -n ${namespace} -o yaml"
        return 1
    fi

    # Wait for the operator CSV to be installed
    local installed=false

    for i in $(seq 1 "$max_attempts"); do
        # Check if CSV (ClusterServiceVersion) is in Succeeded phase with InstallSucceeded reason
        local csv_status
        csv_status=$(oc get csv "${csv_name}" -n "${namespace}" '-o=jsonpath={.status.phase}{.status.reason}' 2>/dev/null )
        if [[ "$csv_status" == "SucceededInstallSucceeded" ]]; then
            installed=true
            echo "CSV '${csv_name}' finished!"
            break
        fi
        echo "Waiting for CSV ... (attempt $i/$max_attempts, current status: ${csv_status:-unknown})"
        sleep "$sleep_seconds"
    done

    if [ "$installed" = false ]; then
        echo "Warning: CSV '${csv_name}' did not finish after $((max_attempts * sleep_seconds)) seconds"
        echo "Please check the subscription status with: oc get subscription ${subscription_name} -n ${namespace}"
        echo "And check the CSV status with: oc get csv ${csv_name} -n ${namespace} -o yaml"
        return 1
    fi

    return 0
}

# Function to subscribe to the Trustee Operator
# Parameters:
#   $1: catalog_source - Name of the catalog source (default: TRUSTEE_CATALOG_SOURCE_NAME or "redhat-operators")
#   $2: source_namespace - Namespace of the catalog source (default: "openshift-marketplace")
#   $3: channel - Subscription channel (default: "stable")
# Example:
#   subscribe_to_trustee_operator                                    # Use TRUSTEE_CATALOG_SOURCE_NAME or default
#   subscribe_to_trustee_operator "certified-operators"              # Override catalog source
#   subscribe_to_trustee_operator "my-catalog" "openshift-marketplace" "stable"
subscribe_to_trustee_operator() {
    local catalog_source="${1:-${TRUSTEE_CATALOG_SOURCE_NAME}}"
    local source_namespace="${2:-openshift-marketplace}"
    local channel="${3:-stable}"
    local operator_namespace="trustee-operator-system"

    echo "=== Subscribing to Trustee Operator ==="
    echo "Catalog Source: ${catalog_source}"
    echo "Source Namespace: ${source_namespace}"
    echo "Channel: ${channel}"
    echo "Operator Namespace: ${operator_namespace}"

    # Create the namespace if it doesn't exist
    if ! resource_exists "namespace" "${operator_namespace}"; then
        echo "Creating namespace '${operator_namespace}'..."
        oc create namespace "${operator_namespace}"
    else
        echo "Namespace '${operator_namespace}' already exists"
    fi

    # Create OperatorGroup if it doesn't exist
    if ! resource_exists "operatorgroup" "trustee-operator-group" "${operator_namespace}"; then
        echo "Creating OperatorGroup 'trustee-operator-group'..."
        cat > trustee-operatorgroup.yaml << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: trustee-operator-system
  namespace: ${operator_namespace}
spec:
  targetNamespaces:
  - ${operator_namespace}
EOF
        oc apply -f trustee-operatorgroup.yaml
        echo "Created OperatorGroup"
    else
        echo "OperatorGroup 'trustee-operator-group' already exists"
    fi

    # Create Subscription if it doesn't exist
    if ! resource_exists "subscription" "trustee-operator" "${operator_namespace}"; then
        echo "Creating Subscription 'trustee-operator'..."
        cat > trustee-subscription.yaml << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trustee-operator
  namespace: ${operator_namespace}
spec:
  channel: ${channel}
  name: trustee-operator
  source: ${catalog_source}
  sourceNamespace: ${source_namespace}
  installPlanApproval: Automatic
EOF
        oc apply -f trustee-subscription.yaml
        echo "Creating Subscription"
    else
        echo "Subscription 'trustee-operator' already exists"
    fi

    # Wait for subscription and CSV to finish
    if ! wait_for_operator_subscription "trustee-operator" "${operator_namespace}"; then
        echo "Failed to complete trustee-operator subscription"
        return 1
    fi

    echo ""

    echo "=== Trustee Operator subscription completed ==="
}


# Function to create authentication secret for KBS
create_authentication_secret() {
    echo "Creating authentication secret..."
    if resource_exists "secret" "kbs-auth-public-key"; then
        echo "Secret 'kbs-auth-public-key' already exists"
    else
        echo "Generating authentication keys..."
        # Generate private key using ed25519 algorithm
        openssl genpkey -algorithm ed25519 > privateKey

        # Generate public key from private key
        openssl pkey -in privateKey -pubout -out publicKey

        # Create the secret with public key
        oc create secret generic kbs-auth-public-key --from-file=publicKey -n trustee-operator-system

        echo "Created kbs-auth-public-key secret"
    fi
}

# Function to create kbs-config ConfigMap
create_kbs_config_cm() {
    echo "Creating kbs-config ConfigMap..."
    cat > kbs-config-cm.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kbs-config-cm
  namespace: trustee-operator-system
data:
  kbs-config.toml: |
    [http_server]
    sockets = ["0.0.0.0:8080"]
    insecure_http = ${TRUSTEE_INSECURE_HTTP}

    [admin]
    insecure_api = true
    auth_public_key = "/etc/auth-secret/publicKey"

    [attestation_token]
    insecure_key = true
    attestation_token_type = "CoCo"

    [attestation_service]
    type = "coco_as_builtin"
    work_dir = "/opt/confidential-containers/attestation-service"
    policy_engine = "opa"

      [attestation_service.attestation_token_broker]
      type = "Ear"
      policy_dir = "/opt/confidential-containers/attestation-service/policies"

      [attestation_service.attestation_token_config]
      duration_min = 5

      [attestation_service.rvps_config]
      type = "BuiltIn"

        [attestation_service.rvps_config.storage]
        type = "LocalJson"
        file_path = "/opt/confidential-containers/rvps/reference-values/reference-values.json"

    [[plugins]]
    name = "resource"
    type = "LocalFs"
    dir_path = "/opt/confidential-containers/kbs/repository"

    [policy_engine]
    policy_path = "/opt/confidential-containers/opa/policy.rego"
EOF
}

# Function to create RVPS reference values ConfigMap
create_rvps_configmap() {
    echo "Creating RVPS reference values ConfigMap..."
    cat > rvps-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rvps-reference-values
  namespace: trustee-operator-system
data:
  reference-values.json: |
    [
    ]
EOF
# internal docs suitable for testing with the kbs-client
#   reference-values.json: |
#    [
#      {
#        "name": "svn",
#        "expiration": "2027-01-01T00:00:00Z",
#        "value" : 1
#      },
#      {
#        "name": "major_version",
#        "expiration": "2027-01-01T00:00:00Z",
#        "value" : 1
#      },
#      {
#        "name": "minimum_minor_version",
#        "expiration": "2027-01-01T00:00:00Z",
#        "value" : 4
#      }
#    ]
#}

# Function to create KBS resource secret
# Parameters:
#   $1: secret_name - Name of the secret to create
#   $@: key=value pairs - Secret data as key=value pairs
# Example: create_kbs_resource_secret "kbsres1" "key1=res1val1" "key2=res1val2"
create_kbs_resource_secret() {
    local secret_name="$1"
    shift
    local secret_data=("$@")

    echo "Creating KBS resource secret '${secret_name}'..."
    if resource_exists "secret" "${secret_name}"; then
        echo "Secret '${secret_name}' already exists"
    else
        echo "Creating new secret '${secret_name}'..."

        # Build the oc create secret command with from-literal arguments
        local cmd="oc create secret generic ${secret_name}"
        for item in "${secret_data[@]}"; do
            cmd="${cmd} --from-literal ${item}"
        done
        cmd="${cmd} -n trustee-operator-system"

        eval "${cmd}"
        echo "Created ${secret_name} secret"
    fi
}

# Function to create resource policy ConfigMap
# Parameters:
#   $1: filename - Name of the YAML file to create
#   $2: default_allow - "true" or "false" to set default allow policy
#   $3+: allow_rules - (optional) Array of allow rules to add when default_allow is false
# Example:
#   create_resource_policy_cm "resource-policy.yaml" "false" 'input["submods"]["cpu"]["ear.status"] == "affirming"'
#   create_resource_policy_cm "trustee-resource-policy-dev.yaml" "true"
create_resource_policy_cm() {
    local filename="$1"
    local default_allow="$2"
    shift 2
    local allow_rules=("$@")

    echo "Creating resource policy ConfigMap..."

    if [[ "${default_allow}" == "true" ]]; then
        echo "Using permissive resource policy (default allow = true)..."
        # Permissive policy for development/testing
        # WARNING: This allows all resource requests - use only for testing!
        cat > "${filename}" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-policy
  namespace: trustee-operator-system
data:
  policy.rego:
    package policy
    default allow = true
EOF
    else
        echo "Using restrictive resource policy (default allow = false)..."
        cat > "${filename}" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-policy
  namespace: trustee-operator-system
data:
  policy.rego: |
    package policy
    default allow = false
EOF
        # Add allow rules if provided
        if [ ${#allow_rules[@]} -gt 0 ]; then
            for rule in "${allow_rules[@]}"; do
                cat >> "${filename}" << EOF
    allow {
      ${rule}
    }
EOF
            done
        fi
    fi
}

# Function to create attestation token secret
# Parameters:
#   $1: cn - Common Name (CN) for the certificate subject
#   $2: org - Organization (O) for the certificate subject (default: TRUSTEE_ORG)
# Example:
#   create_attestation_token_secret "my-service-name" "My Organization"
#   create_attestation_token_secret "${TRUSTEE_CN}" "${TRUSTEE_ORG}"  # Uses config variables
create_attestation_token_secret() {
    local cn="$1"
    local org="${2:-${TRUSTEE_ORG}}"

    echo "Creating attestation token secret..."
    if resource_exists "secret" "attestation-token"; then
        echo "Secret 'attestation-token' already exists"
    else
        echo "Generating attestation token key and certificate..."
        # Generate private elliptic curve SSL key
        openssl ecparam -name prime256v1 -genkey -noout -out token.key

        # Generate self-signed SSL/TLS certificate
        openssl req -new -x509 -key token.key -out token.crt -days 365 \
            -subj "/CN=${cn}/O=${org}"

        # Create the secret
        oc create secret generic attestation-token \
            --from-file=token.crt \
            --from-file=token.key \
            -n trustee-operator-system

        echo "Created attestation-token secret"
    fi
}

# Function to create attestation policy ConfigMap
create_attestation_policy_cm() {
    # does not match internal docs
    echo "Creating attestation policy ConfigMap..."
    cat > attestation-policy.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: attestation-policy
  namespace: trustee-operator-system
data:
  default.rego: |
    package policy

    import rego.v1
    default executables := 33
    default hardware := 97
    default configuration := 36

    ##### Azure vTPM SNP
    executables := 3 if {
      input.azsnpvtpm.tpm.pcr03 in data.reference.pcr03
      input.azsnpvtpm.tpm.pcr08 in data.reference.pcr08
      input.azsnpvtpm.tpm.pcr09 in data.reference.pcr09
      input.azsnpvtpm.tpm.pcr11 in data.reference.pcr11
      input.azsnpvtpm.tpm.pcr12 in data.reference.pcr12
    }

    hardware := 0 if {
      input.azsnpvtpm
    }

    configuration := 0 if {
      input.azsnpvtpm
    }

    ##### Azure vTPM TDX
    executables := 3 if {
      input.aztdxvtpm.tpm.pcr03 in data.reference.pcr03
      input.aztdxvtpm.tpm.pcr08 in data.reference.pcr08
      input.aztdxvtpm.tpm.pcr09 in data.reference.pcr09
      input.aztdxvtpm.tpm.pcr11 in data.reference.pcr11
      input.aztdxvtpm.tpm.pcr12 in data.reference.pcr12
    }

    hardware := 0 if {
      input.aztdxvtpm
    }

    configuration := 0 if {
      input.aztdxvtpm
    }
EOF
}


# Function to create security policy configuration file
# Parameters:
#   $1: filename - Name of the JSON file to create
#   $2: default_type - Default policy type (e.g., "insecureAcceptAnything", "reject")
#   $3+: transport_configs - Optional transport configurations in format "registry|type|keyPath"
# Example:
#   create_security_policy "security-policy-config.json" "insecureAcceptAnything" \
#       "ghcr.io/confidential-containers/test-container-image-rs|sigstoreSigned|kbs:///default/cosign-public-key/test"
create_security_policy() {
    local filename="$1"
    local default_type="$2"
    shift 2
    local transport_configs=("$@")

    echo "Creating security policy configuration..."
   cat >> "${filename}" << EOF
{
    "default": [
        {
        "type": "${default_type}"
        }
    ],
EOF
    # Check if transport configurations are provided
    if [ ${#transport_configs[@]} -eq 0 ]; then
        # No transports - create empty transports object and end file
        cat >> "${filename}" << EOF
    "transports": {}
}

EOF
    else
        # Start the JSON file with default policy and docker transports
        cat >> "${filename}" << EOF
    "transports": {
        "docker": {
EOF
        # Add transport configurations
        local first=true
        for config in "${transport_configs[@]}"; do
            # Parse config: registry|type|keyPath
            IFS='|' read -r registry type keyPath <<< "${config}"

            # Add comma before next entry (except for first entry)
            if [ "$first" = false ]; then
                echo "," >> "${filename}"
            fi
            first=false

            # Add the transport configuration
            cat >> "${filename}" << EOF
            "${registry}": [
                {
                    "type": "${type}",
                    "keyPath": "${keyPath}"
                }
            ]
EOF
        done

        # Close the JSON structure
        cat >> "${filename}" << 'EOF'

        }
    }
}
EOF
    fi
}

# Function to create initdata.toml configuration file
# Parameters:
#   $1: trustee_url - The Trustee/KBS service URL
#   $2: kbs_cert - The KBS certificate (optional, empty string to skip cert)
#   $3: output_file - Output filename (default: "initdata.toml")
# Returns: 0 if successful, 1 if failed
# Example:
#   create_initdata_config "${TRUSTEE_URL}" "${KBS_CERT}"
#   create_initdata_config "${TRUSTEE_URL}" "" "my-initdata.toml"  # without cert
create_initdata_config() {
    local trustee_url="$1"
    local kbs_cert="$2"
    local output_file="${3:-initdata.toml}"

    if [ -z "$trustee_url" ]; then
        echo "Error: trustee_url is required"
        return 1
    fi

    echo "Creating initdata configuration file: ${output_file}"

    # Create the base configuration with or without cert
    if [ -n "$kbs_cert" ]; then
        # Include certificate in configuration
        cat > "${output_file}" << EOF
algorithm = "sha384"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]

url = '${trustee_url}'

[token_configs.kbs]
url = '${trustee_url}'
cert = """
${kbs_cert}
"""
'''

"cdh.toml" = '''
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = 'cc_kbc'
url = '${trustee_url}'
kbs_cert = """
${kbs_cert}
"""
'''
EOF
    else
        # Configuration without certificate
        cat > "${output_file}" << EOF
algorithm = "sha384"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]

url = '${trustee_url}'

[token_configs.kbs]
url = '${trustee_url}'
'''

"cdh.toml" = '''
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = 'cc_kbc'
url = '${trustee_url}'
'''
EOF
    fi

    # Add the policy.rego section (common to both cases)
    cat >> "${output_file}" << 'EOF'

"policy.rego" = '''
package agent_policy

default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default ExecProcessRequest := false
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := false
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SetPolicyRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := true
'''
EOF

    echo "Created initdata configuration: ${output_file}"
    return 0
}

# Function to create patch script for peer-pods-cm ConfigMap
# Parameters:
#   $1: initdata_string - The INITDATA string to embed in the script
#   $2: output_file - Output filename (default: "patch_peer_pods_cm.sh")
#   $3: namespace - Target namespace (default: "openshift-sandboxed-containers-operator")
# Returns: 0 if successful, 1 if failed
# Example:
#   create_patch_peer_pods_cm_script "${INITDATA_STRING}"
#   create_patch_peer_pods_cm_script "${INITDATA_STRING}" "my-patch.sh" "my-namespace"
create_patch_peer_pods_cm_script() {
    local initdata_string="$1"
    local output_file="${2:-patch_peer_pods_cm.sh}"
    local namespace="${3:-openshift-sandboxed-containers-operator}"

    if [ -z "$initdata_string" ]; then
        echo "Error: initdata_string is required"
        return 1
    fi

    echo "Creating patch script for peer-pods-cm: ${output_file}"

    cat > "${output_file}" << EOF
#!/bin/bash

# Script to patch peer-pods-cm ConfigMap with INITDATA_STRING
# Generated by trustee_configure.sh

set -euo pipefail

echo "=== Patching peer-pods-cm with INITDATA_STRING ==="

# INITDATA_STRING was generated on the trustee cluster
INITDATA_STRING=${initdata_string}
echo "Loaded INITDATA_STRING (length: \${#INITDATA_STRING})"

# Check if peer-pods-cm ConfigMap exists
if ! oc get configmap peer-pods-cm -n ${namespace} >/dev/null 2>&1; then
    echo "Error: peer-pods-cm ConfigMap not found!"
    echo "Please create the ConfigMap first"
    exit 1
fi

# Patch the ConfigMap
echo "Patching peer-pods-cm ConfigMap with INITDATA..."
oc patch configmap peer-pods-cm -n ${namespace} \\
    --type merge -p "{\\"data\\":{\\"INITDATA\\":\\"\${INITDATA_STRING}\\"}}"

echo "Successfully patched peer-pods-cm ConfigMap with INITDATA"
echo "ConfigMap peer-pods-cm now contains the updated INITDATA configuration"
EOF

    chmod +x "${output_file}"
    echo "Created executable patch script: ${output_file}"
    return 0
}

# Function to create and apply RVPS ConfigMap update with PCR8 hash
# Parameters:
#   $1: initdata_file - Path to initdata.toml file for hash calculation
#   $2: namespace - Namespace for the ConfigMap (default: "trustee-operator-system")
#   $3: output_file - Output YAML filename (default: "rvps-configmap-update.yaml")
#   $4: pcr03_value - PCR03 hash value (optional)
#   $5: pcr09_value - PCR09 hash value (optional)
#   $6: pcr11_value - PCR11 hash value (optional)
#   $7: pcr12_value - PCR12 hash value (optional)
# Returns: 0 if successful, 1 if failed
# Example:
#   create_rvps_configmap_update "initdata.toml"
#   create_rvps_configmap_update "initdata.toml" "trustee-operator-system" "rvps.yaml"
create_rvps_configmap_update() {
    local initdata_file="${1:-initdata.toml}"
    local namespace="${2:-trustee-operator-system}"
    local output_file="${3:-rvps-configmap-update.yaml}"
    local pcr03_value="${4:-3d458cfe55cc03ea1f443f1562beec8df51c75e14a9fcf9a7234a13f198e7969}"
    local pcr09_value="${5:-22e306eac888c8393203858a8b4b7b8f36f3d1434fc4dd044e6b20c6fa43c4d9}"
    local pcr11_value="${6:-53e58bd6ebb6103c18fd19093cb1bcd0a9235685ad642a6d0981ce8314f5e81d}"
    local pcr12_value="${7:-0000000000000000000000000000000000000000000000000000000000000000}"

    if [ ! -f "$initdata_file" ]; then
        echo "Error: initdata file '${initdata_file}' not found"
        return 1
    fi

    echo "Calculating PCR8 hash for RVPS reference values..."

    # Step 1: Calculate SHA-256 hash of initdata file
    local hash=""
    hash=$(sha256sum "${initdata_file}" | cut -d' ' -f1)
    echo "${initdata_file} SHA-256 hash: $hash"

    # Step 2: Set initial PCR value (32 bytes of 0s)
    local initial_pcr=0000000000000000000000000000000000000000000000000000000000000000

    # Step 3: Calculate PCR8 hash by combining initial_pcr and hash
    local pcr08_value=""
    pcr08_value=$(echo -n "$initial_pcr$hash" | xxd -r -p | sha256sum | cut -d' ' -f1)
    echo "PCR8_HASH for RVPS: $pcr08_value"

    # Create RVPS ConfigMap update with the calculated PCR8 hash
    echo "Creating RVPS reference values update with PCR8 hash..."
    cat > "${output_file}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rvps-reference-values
  namespace: ${namespace}
data:
  reference-values.json: |
    [
     {
        "name": "pcr03",
        "expiration": "2025-12-12T00:00:00Z",
        "hash-value": [
          {
                "alg": "sha256",
                "value": "${pcr03_value}"
          }
        ]
     },
     {
        "name": "pcr08",
        "expiration": "2025-12-12T00:00:00Z",
        "hash-value": [
          {
                "alg": "sha256",
                "value": "${pcr08_value}"
          }
        ]
     },
     {
        "name": "pcr09",
        "expiration": "2025-12-12T00:00:00Z",
        "hash-value": [
          {
                "alg": "sha256",
                "value": "${pcr09_value}"
          }
        ]
     },
     {
        "name": "pcr11",
        "expiration": "2025-12-12T00:00:00Z",
        "hash-value": [
          {
                "alg": "sha256",
                "value": "${pcr11_value}"
          }
        ]
     },
     {
        "name": "pcr12",
        "expiration": "2025-12-12T00:00:00Z",
        "hash-value": [
          {
                "alg": "sha256",
                "value": "${pcr12_value}"
          }
        ]
     }
    ]
EOF

    # Apply the updated RVPS ConfigMap
    oc apply -f "${output_file}"
    echo "Updated RVPS reference values with PCR8 hash: $pcr08_value"

    return 0
}

# Function to create KbsConfig custom resource YAML
# Parameters:
#   $1: namespace - Namespace for the KbsConfig (default: "trustee-operator-system")
#   $2: output_file - Output YAML filename (default: "kbsconfig.yaml")
#   $3: service_type - Service type (default: "NodePort", options: NodePort, ClusterIP, LoadBalancer)
#   $4: deployment_type - Deployment type (default: "AllInOneDeployment")
#   $5: secret_resources - Comma-separated list of secret resources (default: "kbsres1,cosign-public-key,security-policy,attestation-token")
#   $6: enable_tdx - Enable TDX config (default: "false")
# Returns: 0 if successful, 1 if failed
# Example:
#   create_kbsconfig_yaml
#   create_kbsconfig_yaml "trustee-operator-system" "kbsconfig.yaml" "ClusterIP"
#   create_kbsconfig_yaml "trustee-operator-system" "kbsconfig.yaml" "NodePort" "AllInOneDeployment" "kbsres1,cosign-public-key"
create_kbsconfig_yaml() {
    local namespace="${1:-trustee-operator-system}"
    local output_file="${2:-kbsconfig.yaml}"
    local service_type="${3:-NodePort}"
    local deployment_type="${4:-AllInOneDeployment}"
    local secret_resources="${5:-kbsres1,cosign-public-key,security-policy,attestation-token}"
    local enable_tdx="${6:-false}"

    echo "Creating KbsConfig custom resource YAML: ${output_file}"

    # Convert comma-separated list to JSON array format
    local secret_resources_json=""
    secret_resources_json="${secret_resources//,/\",\"}"
    secret_resources_json="[\"${secret_resources_json}\"]"

    cat > "${output_file}" << EOF
apiVersion: confidentialcontainers.org/v1alpha1
kind: KbsConfig
metadata:
  labels:
    app.kubernetes.io/name: kbsconfig
    app.kubernetes.io/instance: kbsconfig
    app.kubernetes.io/part-of: trustee-operator
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/created-by: trustee-operator
  name: kbsconfig
  namespace: ${namespace}
spec:
  kbsConfigMapName: kbs-config-cm
  kbsRvpsRefValuesConfigMapName: rvps-reference-values
  kbsAttestationPolicyConfigMapName: attestation-policy # optional
  kbsResourcePolicyConfigMapName: resource-policy
  kbsHttpsKeySecretName: kbs-https-key
  kbsHttpsCertSecretName: kbs-https-certificate
  kbsAuthSecretName: kbs-auth-public-key
  kbsSecretResources: ${secret_resources_json}
  kbsServiceType: ${service_type}
  kbsDeploymentType: ${deployment_type}
EOF

    # Add TDX config if enabled
    if [[ "${enable_tdx}" == "true" ]]; then
        cat >> "${output_file}" << 'EOF'
# Intel TDX configuration
tdxConfigSpec:
  kbsTdxConfigMapName: tdx-config
EOF
    else
        cat >> "${output_file}" << 'EOF'
# Uncomment the following lines if using Intel TDX:
# tdxConfigSpec:
#   kbsTdxConfigMapName: tdx-config
EOF
    fi

    echo "Created KbsConfig YAML: ${output_file}"
    return 0
}

# Function to get the KBS route hostname
# Parameters:
#   $1: max_attempts - Maximum number of attempts to get the route (default: 10)
#   $2: sleep_seconds - Seconds to sleep between attempts (default: 2)
# Returns: Route hostname via echo
# Example:
#   ROUTE_HOST=$(get_route_host)
#   ROUTE_HOST=$(get_route_host 20 3)  # 20 attempts, 3 seconds between attempts
get_route_host() {
    local max_attempts="${1:-10}"
    local sleep_seconds="${2:-2}"
    local route_host=""

    for i in $(seq 1 "$max_attempts"); do
        route_host=$(oc get route kbs-service -n trustee-operator-system '-o=jsonpath={.spec.host}' 2>/dev/null || echo "")
        if [ -n "$route_host" ]; then
            break
        fi
        echo "Waiting for route to be available... (attempt $i/$max_attempts)" >&2
        sleep "$sleep_seconds"
    done

    if [ -z "$route_host" ]; then
        echo "Warning: Could not get route hostname, using default" >&2
        route_host="kbs-service-trustee-operator-system.apps.cluster.local"
    fi

    echo "$route_host"
}

# Function to check if a Kubernetes resource exists
# Parameters:
#   $1: resource_type - Type of resource (secret, configmap, deployment, etc.)
#   $2: resource_name - Name of the resource
#   $3: namespace - Namespace to check (default: trustee-operator-system)
# Returns: 0 if exists, 1 if not exists
# Example:
#   if resource_exists "secret" "kbs-auth-public-key"; then
#       echo "Secret exists"
#   fi
#   if resource_exists "configmap" "my-config" "default"; then
#       echo "ConfigMap exists in default namespace"
#   fi
resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-trustee-operator-system}"

    if oc get "${resource_type}" "${resource_name}" -n "${namespace}" >/dev/null 2>&1; then
        return 0  # exists
    else
        return 1  # does not exist
    fi
}

# Function to create HTTPS certificate secret for KBS service
# Parameters:
#   $1: route_host - Route hostname for Subject Alternative Name
#   $2: cn - Common Name (CN) for the certificate subject
#   $3: org - Organization (O) for the certificate subject (default: TRUSTEE_ORG)
#   $4: key_file - Filename for the private key (default: tls.key)
#   $5: cert_file - Filename for the certificate (default: tls.crt)
# Example:
#   create_https_certificate_secret "kbs-service.apps.cluster.local" "my-service-name" "My Organization"
#   create_https_certificate_secret "${ROUTE_HOST}" "${TRUSTEE_CN}" "${TRUSTEE_ORG}"  # Uses config variables
#   create_https_certificate_secret "${ROUTE_HOST}" "${TRUSTEE_CN}" "" "my-key.key" "my-cert.crt"  # Uses TRUSTEE_ORG with custom files
create_https_certificate_secret() {
    local route_host="$1"
    local cn="$2"
    local org="${3:-${TRUSTEE_ORG}}"
    local key_file="${4:-tls.key}"
    local cert_file="${5:-tls.crt}"

    echo "Creating HTTPS certificate secret for KBS service..."
    if resource_exists "secret" "kbs-https-certificate"; then
        echo "Secret 'kbs-https-certificate' already exists"
    else
        echo "Generating HTTPS certificate for KBS service..."
        echo "Generating certificate for hostname: $route_host"

        # Generate private SSL/TLS key and certificate for HTTPS
        openssl req -x509 -nodes -days 365 \
            -newkey rsa:2048 \
            -keyout "${key_file}" \
            -out "${cert_file}" \
            -subj "/CN=${cn}/O=${org}" \
            -addext "subjectAltName=DNS:${route_host}"

        # Create the secret with the certificate
        oc create secret generic kbs-https-certificate \
            --from-file="${cert_file}" \
            -n trustee-operator-system

        # Create the secret with the private key
        oc create secret generic kbs-https-key \
            --from-file="${key_file}" \
            -n trustee-operator-system

        echo "Created kbs-https-certificate secret"
    fi
}

# create an ingress & route
# route will be named kbs-service-xxxx
# host:80 will be redirected to kbs-service:8080
create_ingress_to_kbs_service() {
    echo "Creating ingress to KBS service..."
    DOMAIN=$(oc get ingress.config/cluster '-o=jsonpath={.spec.domain}')
    HOST="kbs-service-trustee-operator-system.${DOMAIN}"

    cat > ingress-to-kbs-service.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kbs-service
spec:
  rules:
  - host: ${HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kbs-service # Must match the Service name
            port:
              number: 8080 # Must match the Service port
EOF
}

echo "=== Configuring Trustee for Confidential Containers ==="
echo "TRUSTEE_URL_USE_HTTP: ${TRUSTEE_URL_USE_HTTP}"
echo "TRUSTEE_URL_USE_NODEPORT: ${TRUSTEE_URL_USE_NODEPORT}"
echo "TRUSTEE_INSECURE_HTTP: ${TRUSTEE_INSECURE_HTTP}"
echo "TRUSTEE_TESTING: ${TRUSTEE_TESTING}"
echo "TRUSTEE_ORG: ${TRUSTEE_ORG}"
echo "TRUSTEE_CN: ${TRUSTEE_CN}"
echo "TRUSTEE_CATALOG_SOURCE_NAME: ${TRUSTEE_CATALOG_SOURCE_NAME}"

# Configure Trustee Operator
echo "=== Installing & Configuring Trustee Operator ==="

# Create trustee-operator-system namespace if it doesn't exist
echo "Ensuring trustee-operator-system namespace exists..."
if resource_exists "namespace" "trustee-operator-system"; then
    echo "Namespace 'trustee-operator-system' already exists"
else
    echo "Creating namespace 'trustee-operator-system'..."
    oc create namespace trustee-operator-system
fi

# Check if trustee operator is subscribed, if not subscribe to it
echo "Checking for trustee operator subscription..."
if resource_exists "subscription" "trustee-operator" "trustee-operator-system"; then
    echo "Trustee operator subscription already exists"
else
    echo "Trustee operator not subscribed, subscribing now..."
    subscribe_to_trustee_operator "${TRUSTEE_CATALOG_SOURCE_NAME}"
fi

# Create edge route for KBS service (with TLS termination)
echo "Creating edge route for KBS service..."
if resource_exists "route" "kbs-service"; then
    echo "Route 'kbs-service' already exists"
else
    echo "Creating new edge route 'kbs-service'..."
    oc create route edge --service=kbs-service --port=kbs-port -n trustee-operator-system
fi

# Create authentication secret for KBS
create_authentication_secret

# Create kbs-config ConfigMap
create_kbs_config_cm
oc apply -f kbs-config-cm.yaml

create_rvps_configmap
oc apply -f rvps-configmap.yaml

# Create KBS resource secret (example secret for clients)
create_kbs_resource_secret "kbsres1" "key1=res1val1" "key2=res1val2"

# Create resource policy ConfigMap
if [[ "${TRUSTEE_TESTING}" == "true" ]]; then
    RESOURCE_POLICY_FILE="trustee-resource-policy-dev.yaml"
    create_resource_policy_cm "${RESOURCE_POLICY_FILE}" "true"
else
    RESOURCE_POLICY_FILE="resource-policy.yaml"
    create_resource_policy_cm "${RESOURCE_POLICY_FILE}" "false" 'input["submods"]["cpu"]["ear.status"] == "affirming"'
fi

echo "Applying resource policy ConfigMap ${RESOURCE_POLICY_FILE}..."
oc apply -f "${RESOURCE_POLICY_FILE}"

# Create attestation token secret
create_attestation_token_secret "${TRUSTEE_CN}" "${TRUSTEE_ORG}"

# Create attestation policy ConfigMap
create_attestation_policy_cm
oc apply -f attestation-policy.yaml

# Create security policy configuration
# Add transport configurations as needed - format: "registry|type|keyPath"
SECURITY_POLICY_FILE="security-policy-config.json"
create_security_policy "${SECURITY_POLICY_FILE}" "insecureAcceptAnything" \
    "ghcr.io/confidential-containers/test-container-image-rs|sigstoreSigned|kbs:///default/cosign-public-key/test"

if resource_exists "secret" "security-policy"; then
    echo "Secret 'security-policy' already exists"
else
    echo "Creating new secret 'security-policy'..."
    oc create secret generic security-policy --from-file=osc="${SECURITY_POLICY_FILE}" -n trustee-operator-system
    echo "Created security-policy secret"
fi

# Create cosign public key secret for container image signature verification
# oc create secret generic cosign-public-key --from-file=test=$L/trustee-cosign-publickey.pem -n $TS
echo "Creating cosign public key secret..."
if resource_exists "secret" "cosign-public-key"; then
    echo "Secret 'cosign-public-key' already exists"
else
    echo "Generating cosign public key for container image signature verification..."
    # Generate a cosign key pair for demonstration
    # In production, you would use your actual cosign public key
    openssl genpkey -algorithm ed25519 > cosign-private.key
    openssl pkey -in cosign-private.key -pubout -out cosign-public.key

    # Create the secret
    oc create secret generic cosign-public-key \
        --from-file=test=cosign-public.key -n trustee-operator-system

    echo "Created cosign-public-key secret"
fi

# Create HTTPS certificate secret for KBS service
ROUTE_HOST=$(get_route_host 10 2)
create_https_certificate_secret "${ROUTE_HOST}" "${TRUSTEE_CN}" "${TRUSTEE_ORG}"

# The service kbs-service does not appear until after KbsConfig is created
# Create KbsConfig custom resource YAML
create_kbsconfig_yaml "${TRUSTEE_NAMESPACE}" "${KBSCONFIG_OUTPUT_FILE}" "${KBS_SERVICE_TYPE}" "${KBS_DEPLOYMENT_TYPE}" "${KBS_SECRET_RESOURCES}" "${KBS_ENABLE_TDX}"

# Apply KbsConfig custom resource
if resource_exists "kbsconfig" "kbsconfig"; then
    echo "KbsConfig 'kbsconfig' already exists, updating..."
else
    echo "Creating new KbsConfig 'kbsconfig'..."
fi
oc apply -f kbsconfig.yaml


# Create optional TDX config map for Intel Trust Domain Extensions
echo "Creating optional TDX config map..."
cat > tdx-config.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: tdx-config
  namespace: trustee-operator-system
data:
  sgx_default_qcnl.conf: |
    # PCCS server address
    PCCS_URL=https://api.trustedservices.intel.com/sgx/certification/v4/
    # To accept insecure HTTPS certificate, set this option to FALSE
    USE_SECURE_CERT=TRUE
EOF

oc apply -f tdx-config.yaml


# Determine TRUSTEE_HOST based on configuration
if [[ "${TRUSTEE_URL_USE_NODEPORT}" == "true" ]]; then
    echo "Using nodeIP:nodePort for Trustee access..."

    # Get worker node IP
    NODE_IP=$(oc get node -o wide | awk '/worker/{print $6}' | tail -1)
    if [ -z "$NODE_IP" ]; then
        echo "Warning: Could not find worker node IP, trying any node..."
        NODE_IP=$(oc get node -o wide | awk 'NR>1{print $6}' | head -1)
    fi

    # Get NodePort from kbs-service
    NODE_PORT=""
    for i in {1..30}; do
        NODE_PORT=$(oc -n trustee-operator-system get service kbs-service '-o=jsonpath={.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        if [ -n "$NODE_PORT" ]; then
            break
        fi
        echo "Waiting for kbs-service NodePort... (attempt $i/30)"
        sleep 10
    done

    if [ -z "$NODE_PORT" ]; then
        echo "Warning: Could not get NodePort from kbs-service"
        NODE_PORT="30000"  # fallback port
    fi

    if [ -z "$NODE_IP" ]; then
        echo "Warning: Could not get node IP"
        NODE_IP="worker-node-ip"  # fallback
    fi

    TRUSTEE_HOST="${NODE_IP}:${NODE_PORT}"
    echo "Using NodePort access - NODE_IP: ${NODE_IP}, NODE_PORT: ${NODE_PORT}"

else
    # Use route-based access (default)
    echo "Waiting for Trustee service route to be available..."
    for i in {1..30}; do
        TRUSTEE_HOST=$(oc get route kbs-service -n trustee-operator-system '-o=jsonpath={.spec.host}' 2>/dev/null || echo "")
        if [ -n "$TRUSTEE_HOST" ]; then
            break
        fi
        echo "Waiting for kbs-service route... (attempt $i/30)"
        sleep 10
    done

    if [ -z "$TRUSTEE_HOST" ]; then
        echo "Warning: Trustee service route not found after waiting. You may need to:"
        echo "1. Deploy the Trustee operator"
        echo "2. Create the KBS service and route manually"
        TRUSTEE_HOST="kbs-service-trustee-operator-system.apps.your-cluster.com"
    fi
fi

# Determine protocol based on configuration
if [[ "${TRUSTEE_URL_USE_HTTP}" == "true" ]]; then
    TRUSTEE_PROTOCOL="http"
    echo "Using HTTP protocol for Trustee (insecure - for testing only)"
else
    TRUSTEE_PROTOCOL="https"
    echo "Using HTTPS protocol for Trustee (secure)"
fi

TRUSTEE_URL="${TRUSTEE_PROTOCOL}://${TRUSTEE_HOST}"
echo "TRUSTEE_URL: \"$TRUSTEE_URL\""

# Export TRUSTEE_URL for use by other scripts
export TRUSTEE_URL
echo "Exported TRUSTEE_URL environment variable"

# Check if we need to include kbs_cert based on insecure_http setting
echo "Checking TRUSTEE_INSECURE_HTTP setting..."

if [[ "${TRUSTEE_INSECURE_HTTP}" == "true" ]]; then
    echo "TRUSTEE_INSECURE_HTTP is true, will NOT include kbs_cert in initdata"
    INCLUDE_KBS_CERT=false
else
    echo "TRUSTEE_INSECURE_HTTP is false, will include kbs_cert in initdata"
    INCLUDE_KBS_CERT=true

    # Get the TLS certificate from the kbs-https-certificate secret
    KBS_CERT=""
    if resource_exists "secret" "kbs-https-certificate"; then
        KBS_CERT=$(oc get secret kbs-https-certificate -n trustee-operator-system '-o=jsonpath={.data.tls\.crt}' | base64 -d)
        echo "Retrieved TLS certificate from kbs-https-certificate secret"
    else
        echo "Warning: kbs-https-certificate secret not found, using placeholder certificate"
        KBS_CERT="-----BEGIN CERTIFICATE-----
MIICertificatePlaceholder
-----END CERTIFICATE-----"
    fi
fi

# Generate INITDATA configuration
echo "Generating INITDATA configuration..."
if [[ "$INCLUDE_KBS_CERT" == "true" ]]; then
    create_initdata_config "${TRUSTEE_URL}" "${KBS_CERT}"
else
    create_initdata_config "${TRUSTEE_URL}" ""
fi

# Convert initdata.toml to base64 for INITDATA
INITDATA_STRING=$(gzip -c initdata.toml | base64 -w0 )
echo "INITDATA generated (length: ${#INITDATA_STRING})"


# Save INITDATA_STRING to SHARED_DIR for use by subsequent steps
if [ -n "${SHARED_DIR:-}" ]; then
    echo "Saving INITDATA_STRING to SHARED_DIR for peer-pods-cm INITDATA..."
    echo "${INITDATA_STRING}" > "${SHARED_DIR}/initdata_string.txt"
    echo "INITDATA_STRING saved to: ${SHARED_DIR}/initdata_string.txt"
else
    echo "SHARED_DIR not set, saving INITDATA_STRING to current directory..."
    echo "${INITDATA_STRING}" > initdata_string.txt
    echo "INITDATA_STRING saved to: initdata_string.txt"
fi

# Create patch script for peer-pods-cm
create_patch_peer_pods_cm_script "${INITDATA_STRING}"
# prow creates peerpods-param-cm and automation creates peer-pods-cm
echo "Use the generated patch script to update peer-pods-cm with its copy of initdata_string.txt"

# Create and apply RVPS ConfigMap update with PCR8 hash
create_rvps_configmap_update "initdata.toml"

echo "=== Trustee configuration completed successfully ==="
echo ""
echo "Created Trustee Operator components:"
echo "- Namespace: trustee-operator-system"
echo "- Subscription: trustee-operator (from catalog: ${TRUSTEE_CATALOG_SOURCE_NAME})"
echo "- Secret: attestation-token (SSL/TLS certificate and key)"
echo "- Secret: kbs-auth-public-key (authentication public key)"
echo "- Secret: kbs-https-certificate (HTTPS certificate for KBS service)"
echo "- Secret: kbs-https-key (HTTPS private key for KBS service)"
echo "- Secret: kbsres1 (example resource secret for clients)"
echo "- Secret: cosign-public-key (container image signature verification)"
echo "- ConfigMap: kbs-config-cm (Trustee service configuration)"
echo "- ConfigMap: rvps-reference-values (Reference Value Provider Service)"
echo "- ConfigMap: attestation-policy (OPA attestation policy)"
echo "- ConfigMap: resource-policy (resource access policy)"
echo "- ConfigMap: tdx-config (Intel TDX configuration - optional)"
echo "- Secret: security-policy (container security policy)"
echo "- KbsConfig: kbsconfig (ties all components together)"
echo "- Route: kbs-service (exposes KBS service externally)"
echo ""
echo "Created Peer Pods components:"
echo "- ConfigMap: peer-pods-cm (in openshift-sandboxed-containers-operator namespace)"
echo "- INITDATA configuration with Trustee host: ${TRUSTEE_HOST}"
echo ""
echo "Generated files:"
echo "- kbs-config-cm.yaml"
echo "- rvps-configmap.yaml"
echo "- attestation-policy.yaml"
echo "- ${RESOURCE_POLICY_FILE}"
echo "- tdx-config.yaml"
echo "- security-policy-config.json"
echo "- kbsconfig.yaml"
echo "- initdata.toml"
echo "- initdata_string.txt"
echo "- patch_peer_pods_cm.sh"

# Cleanup temporary files
rm -f azure_credentials.json token.key token.crt privateKey publicKey tls.key tls.crt security-policy-config.json cosign-private.key cosign-public.key rvps-configmap-update.yaml trustee-resource-policy-dev.yaml trustee-operatorgroup.yaml trustee-subscription.yaml

echo ""
echo "Next steps:"
echo "1. Trustee operator subscription is automatically handled by this script"
echo "   - To use a different catalog: TRUSTEE_CATALOG_SOURCE_NAME='my-catalog' ./trustee_configure.sh"
echo "   - To manually subscribe: subscribe_to_trustee_operator 'my-catalog'"
echo "2. Verify the OpenShift Sandboxed Containers operator is installed"
echo "3. Create a KataConfig to enable confidential containers (this will create the peer-pods-secret automatically)"
echo "4. Update RVPS reference values with actual PCR measurements from your workloads"
echo "5. Test with a confidential workload"
echo ""
echo "Important notes:"
echo "- The peer-pods-secret will be created automatically by the KataConfig installation process"
echo "- The current configuration uses insecure_http=${TRUSTEE_INSECURE_HTTP} - set to false for production TLS"
echo "- RVPS reference values are empty and need to be populated with actual PCR measurements"
echo "- The attestation policy checks PCR values 03, 08, 09, 11, and 12 for Azure vTPM"
echo "- Set TRUSTEE_CATALOG_SOURCE_NAME to specify the catalog source for operator subscription (default: redhat-operators)"
echo "- Set TRUSTEE_URL_USE_HTTP=true to use HTTP instead of HTTPS for Trustee URL (testing only)"
echo "- Set TRUSTEE_URL_USE_NODEPORT=true to use nodeIP:nodePort instead of route hostname"
echo "- Set TRUSTEE_INSECURE_HTTP=true to enable insecure HTTP in KBS config (default: false)"
echo "- Set TRUSTEE_TESTING=true to use permissive resource policy for development/testing (default: false)"
echo ""
echo "Exported environment variables:"
echo "- TRUSTEE_URL: ${TRUSTEE_URL}"
echo "- INITDATA_STRING: Available for use by other scripts (length: ${#INITDATA_STRING})"
