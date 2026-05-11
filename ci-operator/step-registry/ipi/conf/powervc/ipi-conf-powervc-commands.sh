#!/bin/bash

# Strict mode
set -o nounset
set -o errexit
set -o pipefail

# Global constants
readonly POWERVC_TOOL_VERSION="v2.2.0"
readonly YQ_VERSION="v4.49.2"

# Global variables for cleanup
BASTION_CREATED=false
KEYPAIR_CREATED=false

#######################################
# Log an informational message with timestamp
# Arguments:
#   Message to log
#######################################
function log_info() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

#######################################
# Log an error message with timestamp
# Arguments:
#   Message to log
#######################################
function log_error() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#######################################
# Log a warning message with timestamp
# Arguments:
#   Message to log
#######################################
function log_warning() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

#######################################
# Cleanup resources on failure
# Globals:
#   BASTION_CREATED
#   KEYPAIR_CREATED
#   CLUSTER_NAME
#   CLOUD
#######################################
function cleanup_on_exit() {
	local rc="${1:-0}"
	if [[ "${rc}" -eq 0 ]]; then
		return 0
	fi

	log_warning "Cleaning up resources due to failure..."

	if [[ "${BASTION_CREATED}" == "true" ]] && [[ -n "${CLUSTER_NAME:-}" ]] && [[ -n "${CLOUD:-}" ]]; then
		log_info "Attempting to delete bastion instance: ${CLUSTER_NAME}"
		openstack --os-cloud="${CLOUD}" server delete "${CLUSTER_NAME}" 2>/dev/null || log_warning "Failed to delete bastion instance"
	fi

	if [[ "${KEYPAIR_CREATED}" == "true" ]] && [[ -n "${CLUSTER_NAME:-}" ]] && [[ -n "${CLOUD:-}" ]]; then
		log_info "Attempting to delete keypair: ${CLUSTER_NAME}-key"
		openstack --os-cloud="${CLOUD}" keypair delete "${CLUSTER_NAME}-key" 2>/dev/null || log_warning "Failed to delete keypair"
	fi
}

# Set trap for cleanup on non-zero exit
trap 'cleanup_on_exit $?' EXIT

#######################################
# Validate required environment variables
# Globals:
#   ARCH, BRANCH, LEASED_RESOURCE, BASE_DOMAIN, etc.
# Returns:
#   0 on success, exits on failure
#######################################
function validate_environment() {
	log_info "Validating environment variables..."

	local required_vars=(
		"ARCH"
		"BASE_DOMAIN"
		"BASTION_FLAVOR"
		"BASTION_IMAGE_NAME"
		"BRANCH"
		"CLOUD"
		"CLUSTER_FLAVOR"
		"CLUSTER_PROFILE_DIR"
		"COMPUTE_NODE_TYPE"
		"CONTROL_PLANE_REPLICAS"
		"LEASED_RESOURCE"
		"NETWORK_NAME"
		"SERVER_IP"
		"SHARED_DIR"
		"WORKER_REPLICAS"
	)

	local missing_vars=()
	for var in "${required_vars[@]}"; do
		if [[ -z "${!var:-}" ]]; then
			missing_vars+=("${var}")
		fi
	done

	if [[ ${#missing_vars[@]} -gt 0 ]]; then
		log_error "Missing required environment variables: ${missing_vars[*]}"
		exit 1
	fi

	log_info "All required environment variables are set"
}

#######################################
# Install required tools for PowerVC operations
# Downloads and configures PowerVC-Tool, yq, and OpenStack credentials
# Globals:
#   SECRETS_DIR, HOME, PATH
# Returns:
#   0 on success, exits on failure
#######################################
function install_required_tools() {
	log_info "Installing required tools..."

	cd /tmp || {
		log_error "Failed to change directory to /tmp"
		exit 1
	}

	HOME=/tmp
	export HOME

	mkdir -p /tmp/bin || {
		log_error "Failed to create /tmp/bin directory"
		exit 1
	}

	PATH="/tmp/bin:${PATH}"
	export PATH

	# Install PowerVC-Tool
	log_info "Installing PowerVC-Tool version ${POWERVC_TOOL_VERSION}"
	local machine
	machine=$(uname -m)
	if [[ "${machine}" == "x86_64" ]]; then
		machine="amd64"
	fi

	local tool_bin="ocp-ipi-powervc-linux-${machine}"
	local tool_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/${tool_bin}"

	if ! curl --location --fail --silent --show-error --output /tmp/bin/PowerVC-Tool "${tool_url}"; then
		log_error "Failed to download PowerVC-Tool"
		exit 1
	fi
	chmod ugo+x /tmp/bin/PowerVC-Tool

	# Install yq-v4 if not present
	log_info "Checking for yq-v4..."
	local cmd_yq
	cmd_yq="$(command -v yq-v4 2>/dev/null || true)"

	if [[ ! -x "${cmd_yq}" ]]; then
		log_info "Installing yq-v4 version ${YQ_VERSION}"
		local yq_arch
		yq_arch=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
		local yq_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}"

		if ! curl --fail --location --silent --show-error "${yq_url}" -o /tmp/bin/yq-v4; then
			log_error "Failed to download yq-v4 from ${yq_url}"
			exit 1
		fi
		chmod +x /tmp/bin/yq-v4
	else
		log_info "yq-v4 already installed at ${cmd_yq}"
	fi

	# Setup OpenStack configuration
	log_info "Setting up OpenStack credentials..."
	mkdir -p "${HOME}/.config/openstack/" || {
		log_error "Failed to create OpenStack config directory"
		exit 1
	}

	if [[ ! -f "${SECRETS_DIR}/clouds.yaml" ]]; then
		log_error "clouds.yaml not found at ${SECRETS_DIR}/clouds.yaml"
		exit 1
	fi

	if [[ ! -f "${SECRETS_DIR}/ocp-ci-ca.pem" ]]; then
		log_error "ocp-ci-ca.pem not found at ${SECRETS_DIR}/ocp-ci-ca.pem"
		exit 1
	fi

	cp "${SECRETS_DIR}/clouds.yaml" "${HOME}/.config/openstack/" || {
		log_error "Failed to copy clouds.yaml to .config/openstack/"
		exit 1
	}

	cp "${SECRETS_DIR}/clouds.yaml" "${HOME}/" || {
		log_error "Failed to copy clouds.yaml to HOME"
		exit 1
	}

	cp "${SECRETS_DIR}/ocp-ci-ca.pem" "${HOME}/" || {
		log_error "Failed to copy ocp-ci-ca.pem"
		exit 1
	}

	# Verify all required tools are available
	log_info "Verifying installed tools..."
	local tools=("PowerVC-Tool" "jq" "yq-v4" "openstack")
	for tool in "${tools[@]}"; do
		if ! command -v "${tool}" &>/dev/null; then
			log_error "Required tool '${tool}' is not available"
			exit 1
		fi
		log_info "✓ ${tool} is available at $(command -v "${tool}")"
	done

	log_info "All required tools installed successfully"
}

#######################################
# Determine cluster name based on leased resource
# Globals:
#   LEASED_RESOURCE, CLUSTER_NAME_MODIFIER
# Outputs:
#   CLUSTER_NAME
# Returns:
#   0 on success, exits on failure
#######################################
function determine_cluster_name() {
	log_info "Determining cluster name..."

	if [[ -z "${LEASED_RESOURCE}" ]]; then
		log_error "Failed to acquire lease - LEASED_RESOURCE is empty"
		exit 1
	fi

	if [[ -n "${CLUSTER_NAME_MODIFIER:-}" ]]; then
		# Hostname (including BASE_DOMAIN) should be less than 255 bytes
		# CLUSTER_NAME is typically truncated at 21 characters
		case "${LEASED_RESOURCE}" in
			"powervc-1-quota-slice")
				CLUSTER_NAME="p-1-${CLUSTER_NAME_MODIFIER}"
				;;
			*)
				log_warning "Unknown leased resource: ${LEASED_RESOURCE}"
				CLUSTER_NAME="p-${LEASED_RESOURCE}-${CLUSTER_NAME_MODIFIER}"
				;;
		esac
	else
		CLUSTER_NAME="p-${LEASED_RESOURCE}"
	fi

	# Validate cluster name length
	if [[ ${#CLUSTER_NAME} -gt 21 ]]; then
		log_warning "Cluster name '${CLUSTER_NAME}' exceeds 21 characters (${#CLUSTER_NAME}), may be truncated"
	fi

	log_info "Cluster name set to: ${CLUSTER_NAME}"
	export CLUSTER_NAME
}

#######################################
# Verify RHCOS image exists in PowerVC
# Globals:
#   CLOUD
# Outputs:
#   RHCOS_IMAGE_NAME
# Returns:
#   0 on success, exits on failure
#######################################
function verify_rhcos_image() {
	log_info "Verifying RHCOS image availability..."

	# Get RHCOS image information from openshift-install
	log_info "Fetching RHCOS image information for ppc64le architecture..."
	local rhcos_info
	if ! rhcos_info=$(openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.openstack'); then
		log_error "Failed to fetch RHCOS information from openshift-install"
		exit 1
	fi

	local url
	url=$(echo "${rhcos_info}" | jq -r '.formats."qcow2.gz".disk.location')

	if [[ -z "${url}" ]] || [[ "${url}" == "null" ]]; then
		log_error "Could not parse RHCOS image URL from coreos stream"
		exit 1
	fi

	log_info "RHCOS image URL: ${url}"

	local filename="${url##*/}"
	RHCOS_IMAGE_NAME="${filename//.qcow2.gz/}"

	log_info "RHCOS image name: ${RHCOS_IMAGE_NAME}"

	# Verify image exists in PowerVC
	log_info "Checking if ${RHCOS_IMAGE_NAME} exists in PowerVC..."
	if ! openstack --os-cloud="${CLOUD}" image show "${RHCOS_IMAGE_NAME}" --format=shell --column=name &>/dev/null; then
		log_error "RHCOS image '${RHCOS_IMAGE_NAME}' not found in PowerVC cloud '${CLOUD}'"
		log_info "Available RHCOS images:"
		openstack --os-cloud="${CLOUD}" image list --format=value | grep -i rhcos || log_warning "No RHCOS images found"
		exit 1
	fi

	log_info "✓ RHCOS image '${RHCOS_IMAGE_NAME}' verified in PowerVC"
	export RHCOS_IMAGE_NAME
}

#######################################
# Main execution starts here
#######################################
log_info "=== PowerVC IPI Configuration Script Started ==="

# Validate environment
validate_environment

# Display configuration
log_info "Architecture: ${ARCH}"
log_info "Branch: ${BRANCH}"
log_info "Leased Resource: ${LEASED_RESOURCE}"

# Setup secrets directory
export SECRETS_DIR=/var/run/powervc-ipi-cicd-secrets/powervc-creds
if [[ ! -d "${SECRETS_DIR}" ]]; then
	log_error "Secrets directory does not exist: ${SECRETS_DIR}"
	exit 1
fi
log_info "Secrets directory: ${SECRETS_DIR}"
ls -l "${SECRETS_DIR}/" || log_warning "Failed to list secrets directory"

# Determine cluster name
determine_cluster_name

# Install required tools
install_required_tools

# Verify RHCOS image
verify_rhcos_image

#######################################
# Save PowerVC configuration to shared directory
# Globals:
#   SHARED_DIR, CLUSTER_PROFILE_DIR, various config vars
# Returns:
#   0 on success, exits on failure
#######################################
function save_powervc_config() {
	log_info "Saving PowerVC configuration..."

	# Set credentials file
	POWERVC_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.powervccred"
	export POWERVC_SHARED_CREDENTIALS_FILE

	# Create configuration file
	if ! cat > "${SHARED_DIR}/powervc-conf.yaml" << EOF
ARCH: ${ARCH}
BASE_DOMAIN: ${BASE_DOMAIN}
BASTION_FLAVOR: ${BASTION_FLAVOR}
BASTION_IMAGE_NAME: ${BASTION_IMAGE_NAME}
BRANCH: ${BRANCH}
CLOUD: ${CLOUD}
CLUSTER_FLAVOR: ${CLUSTER_FLAVOR}
CLUSTER_NAME: ${CLUSTER_NAME}
COMPUTE_NODE_TYPE: ${COMPUTE_NODE_TYPE}
LEASED_RESOURCE: ${LEASED_RESOURCE}
NETWORK_NAME: ${NETWORK_NAME}
RHCOS_IMAGE_NAME: ${RHCOS_IMAGE_NAME}
SERVER_IP: ${SERVER_IP}
EOF
	then
		log_error "Failed to create powervc-conf.yaml"
		exit 1
	fi

	log_info "✓ PowerVC configuration saved to ${SHARED_DIR}/powervc-conf.yaml"
}

#######################################
# Check PowerVC server connectivity
# Globals:
#   SERVER_IP
# Returns:
#   0 on success, exits on failure
#######################################
function check_powervc_alive() {
	log_info "Checking PowerVC server connectivity..."

	# Workaround: cd to /tmp as clouds.yaml is also there
	cd /tmp/ || {
		log_error "Failed to change directory to /tmp"
		exit 1
	}

	if ! PowerVC-Tool \
		check-alive \
		--serverIP "${SERVER_IP}" \
		--shouldDebug true; then
		log_error "PowerVC server check failed for ${SERVER_IP}"
		exit 1
	fi

	log_info "✓ PowerVC server ${SERVER_IP} is alive"
}

#######################################
# Get subnet ID for the network
# Globals:
#   CLOUD, NETWORK_NAME
# Outputs:
#   SUBNET_ID
# Returns:
#   0 on success, exits on failure
#######################################
function get_subnet_id() {
	log_info "Retrieving subnet ID for network: ${NETWORK_NAME}"

	local subnets_json subnet_id subnet_length
	if ! subnets_json=$(openstack --os-cloud="${CLOUD}" network show "${NETWORK_NAME}" --format json --column subnets); then
		log_error "Failed to query subnets for network '${NETWORK_NAME}'"
		exit 1
	fi

	subnet_length=$(jq -r '.subnets | length' <<< "${subnets_json}")
	subnet_id=$(jq -r '.subnets[0] // empty' <<< "${subnets_json}")
	log_info "subnet_length=${subnet_length}"
	log_info "subnet_id=${subnet_id}"

	if [[ -z "${subnet_id}" ]]; then
		log_error "Failed to retrieve subnet ID for network '${NETWORK_NAME}'"
		exit 1
	fi
	if (( subnet_length > 1 )); then
		log_error "Network '${NETWORK_NAME}' has multiple subnets; expected exactly one"
		exit 1
	fi

	SUBNET_ID="${subnet_id}"
	log_info "Subnet ID: ${SUBNET_ID}"
	export SUBNET_ID
}

#######################################
# Create SSH keypair for cluster
# Globals:
#   CLOUD, CLUSTER_NAME, SECRETS_DIR
# Returns:
#   0 on success, exits on failure
#######################################
function create_ssh_keypair() {
	log_info "Creating SSH keypair: ${CLUSTER_NAME}-key"
	local ssh_public_key="${CLUSTER_PROFILE_DIR}/ssh-publickey"

	# Delete existing keypair if present
	if openstack --os-cloud="${CLOUD}" keypair show "${CLUSTER_NAME}-key" &>/dev/null; then
		log_info "Deleting existing keypair: ${CLUSTER_NAME}-key"
		openstack --os-cloud="${CLOUD}" keypair delete "${CLUSTER_NAME}-key" || log_warning "Failed to delete existing keypair"
	fi

	# Verify SSH public key exists
	if [[ ! -f "${ssh_public_key}" ]]; then
		log_error "SSH public key not found: ${ssh_public_key}"
		exit 1
	fi

	# Create new keypair
	if ! openstack \
		--os-cloud="${CLOUD}" \
		keypair create \
		--public-key "${ssh_public_key}" \
		"${CLUSTER_NAME}-key"; then
		log_error "Failed to create SSH keypair"
		exit 1
	fi

	KEYPAIR_CREATED=true
	log_info "✓ SSH keypair created successfully"
}

#######################################
# Create bastion host
# Globals:
#   CLOUD, CLUSTER_NAME, BASTION_FLAVOR, BASTION_IMAGE_NAME, etc.
# Outputs:
#   VIP_API, VIP_INGRESS
# Returns:
#   0 on success, exits on failure
#######################################
function create_bastion() {
	log_info "Creating bastion host..."
	log_info "  Bastion Name: ${CLUSTER_NAME}"
	log_info "  Flavor: ${BASTION_FLAVOR}"
	log_info "  Image: ${BASTION_IMAGE_NAME}"
	log_info "  Network: ${NETWORK_NAME}"
	log_info "  Cloud: ${CLOUD}"

	if ! PowerVC-Tool \
		create-bastion \
		--cloud "${CLOUD}" \
		--bastionName "${CLUSTER_NAME}" \
		--flavorName "${BASTION_FLAVOR}" \
		--imageName "${BASTION_IMAGE_NAME}" \
		--networkName "${NETWORK_NAME}" \
		--sshKeyName "${CLUSTER_NAME}-key" \
		--domainName "${BASE_DOMAIN}" \
		--enableHAProxy false \
		--serverIP "${SERVER_IP}" \
		--shouldDebug true; then
		log_error "Failed to create bastion host"
		exit 1
	fi

	BASTION_CREATED=true

	# Verify bastion IP file was created
	if [[ ! -f /tmp/bastionIp ]]; then
		log_error "Bastion IP file not found: /tmp/bastionIp"
		exit 1
	fi

	local bastion_ip
	bastion_ip=$(cat /tmp/bastionIp)

	if [[ -z "${bastion_ip}" ]]; then
		log_error "Bastion IP is empty"
		exit 1
	fi

	VIP_API="${bastion_ip}"
	VIP_INGRESS="${bastion_ip}"

	log_info "✓ Bastion host created successfully"
	log_info "  API VIP: ${VIP_API}"
	log_info "  Ingress VIP: ${VIP_INGRESS}"

	export VIP_API
	export VIP_INGRESS
}

# Save PowerVC configuration
save_powervc_config

# Check PowerVC connectivity
check_powervc_alive

# Get subnet ID
get_subnet_id

# Create SSH keypair
create_ssh_keypair

# Create bastion host
create_bastion

#######################################
# Create install-config.yaml
# Globals:
#   SHARED_DIR, CLUSTER_NAME, BASE_DOMAIN, VIP_API, VIP_INGRESS, etc.
# Returns:
#   0 on success, exits on failure
#######################################
function create_install_config() {
	log_info "Creating install-config.yaml..."

	local config="${SHARED_DIR}/install-config.yaml"

	# Verify required files exist
	if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
		log_error "Pull secret not found: ${CLUSTER_PROFILE_DIR}/pull-secret"
		exit 1
	fi

	if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
		log_error "SSH public key not found: ${CLUSTER_PROFILE_DIR}/ssh-publickey"
		exit 1
	fi

	if ! cat > "${config}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: ppc64le
  hyperthreading: Enabled
  name: worker
  platform:
    powervc:
      zones:
        - ${COMPUTE_NODE_TYPE}
  replicas: ${WORKER_REPLICAS}
controlPlane:
  architecture: ppc64le
  hyperthreading: Enabled
  name: master
  platform:
    powervc:
      zones:
        - ${COMPUTE_NODE_TYPE}
  replicas: ${CONTROL_PLANE_REPLICAS}
networking:
  clusterNetwork:
  - cidr: 10.116.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.130.32.0/20
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  powervc:
    loadBalancer:
      type: UserManaged
    apiVIPs:
    - ${VIP_API}
    cloud: ${CLOUD}
    clusterOSImage: ${RHCOS_IMAGE_NAME}
    defaultMachinePlatform:
      type: ${CLUSTER_FLAVOR}
    ingressVIPs:
    - ${VIP_INGRESS}
    controlPlanePort:
      fixedIPs:
        - subnet:
            id: ${SUBNET_ID}
publish: External
credentialsMode: Passthrough
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF
	then
		log_error "Failed to create install-config.yaml"
		exit 1
	fi

	log_info "✓ install-config.yaml created at ${config}"
	export CONFIG="${config}"
}

#######################################
# Create chrony configuration for worker nodes
# Globals:
#   SHARED_DIR
# Returns:
#   0 on success, exits on failure
#######################################
function create_chrony_worker_config() {
	log_info "Creating chrony worker configuration..."

	if ! cat > "${SHARED_DIR}/99-chrony-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-chrony-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,c2VydmVyIGNsb2NrLmNvcnAucmVkaGF0LmNvbSBpYnVyc3QKZHJpZnRmaWxlIC92YXIvbGliL2Nocm9ueS9kcmlmdAptYWtlc3RlcCAxLjAgMwpydGNzeW5jCmxvZ2RpciAvdmFyL2xvZy9jaHJvbnkK
        filesystem: root
        mode: 0644
        overwrite: true
        path: /etc/chrony.conf
EOF
	then
		log_error "Failed to create chrony worker configuration"
		exit 1
	fi

	log_info "✓ Chrony worker configuration created"
}

#######################################
# Create chrony configuration for master nodes
# Globals:
#   SHARED_DIR
# Returns:
#   0 on success, exits on failure
#######################################
function create_chrony_master_config() {
	log_info "Creating chrony master configuration..."

	if ! cat > "${SHARED_DIR}/99-chrony-master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-chrony-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,c2VydmVyIGNsb2NrLmNvcnAucmVkaGF0LmNvbSBpYnVyc3QKZHJpZnRmaWxlIC92YXIvbGliL2Nocm9ueS9kcmlmdAptYWtlc3RlcCAxLjAgMwpydGNzeW5jCmxvZ2RpciAvdmFyL2xvZy9jaHJvbnkK
        filesystem: root
        mode: 420
        overwrite: true
        path: /etc/chrony.conf
EOF
	then
		log_error "Failed to create chrony master configuration"
		exit 1
	fi

	log_info "✓ Chrony master configuration created"
}

#######################################
# Apply optional install-config modifications
# Globals:
#   OPTIONAL_INSTALL_CONFIG_PARMS, CONFIG
# Returns:
#   0 on success
#######################################
function apply_optional_config_modifications() {
	if [[ -z "${OPTIONAL_INSTALL_CONFIG_PARMS:-}" ]]; then
		log_info "No optional install-config parameters to remove"
		return 0
	fi

	log_info "Applying optional install-config modifications..."
	log_info "Parameters to remove: ${OPTIONAL_INSTALL_CONFIG_PARMS}"

	local -a parameters
	read -ra parameters <<< "${OPTIONAL_INSTALL_CONFIG_PARMS}"
	log_info "Number of parameters to remove: ${#parameters[*]}"

	for parameter in "${parameters[@]}"; do
		log_info "Removing parameter: ${parameter}"
		sed -i "/${parameter}:/d" "${CONFIG}"
	done

	log_info "✓ Optional modifications applied"
}

#######################################
# Add feature set to install-config
# Globals:
#   FEATURE_SET, CONFIG
# Returns:
#   0 on success
#######################################
function add_feature_set() {
	if [[ -z "${FEATURE_SET:-}" ]]; then
		log_info "No feature set specified"
		return 0
	fi

	log_info "Adding feature set to install-config.yaml: ${FEATURE_SET}"

	if ! cat >> "${CONFIG}" << EOF
featureSet: ${FEATURE_SET}
EOF
	then
		log_error "Failed to add feature set to install-config.yaml"
		exit 1
	fi

	log_info "✓ Feature set added"
}

#######################################
# Add feature gates to install-config
# Globals:
#   FEATURE_GATES, CONFIG
# Returns:
#   0 on success
# Note:
#   FeatureGates must be a valid YAML list, e.g., ['Feature1=true', 'Feature2=false']
#   Only supported in OpenShift 4.14+
#######################################
function add_feature_gates() {
	if [[ -z "${FEATURE_GATES:-}" ]]; then
		log_info "No feature gates specified"
		return 0
	fi

	log_info "Adding feature gates to install-config.yaml: ${FEATURE_GATES}"

	if ! cat >> "${CONFIG}" << EOF
featureGates: ${FEATURE_GATES}
EOF
	then
		log_error "Failed to add feature gates to install-config.yaml"
		exit 1
	fi

	log_info "✓ Feature gates added"
}

# Create install-config.yaml
create_install_config

# Create chrony configurations
create_chrony_worker_config
create_chrony_master_config

# Apply optional modifications
apply_optional_config_modifications

# Add feature set if specified
add_feature_set

# Add feature gates if specified
add_feature_gates

log_info "=== PowerVC IPI Configuration Script Completed Successfully ==="
