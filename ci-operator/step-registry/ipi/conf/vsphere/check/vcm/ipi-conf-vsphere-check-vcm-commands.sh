#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

################################################################################
# This script uses the following parameters from CI jobs.
#
# CLUSTER_PROFILE_NAME - Specifies the profile name.  "vsphere-elastic" uses VMC
#      to assign configurations.
# MULTI_NIC_IPI - Enables the script to create multiple networks in each failure
#      domain.
# VSPHERE_MULTI_NETWORKS - Configures script to create a unique subnet for each
#      failure domain.
# POOL_SELECTOR - Specifies pool selector labels as comma-separated key=value
#      pairs (e.g., "vcf=true,region=us-east").
# RESERVE_EXTRA_NETWORK - Requests an additional network that won't be attached
#      to cluster nodes. Reserved networks are saved to reserved_networks.json
#      for later use (e.g., remote worker installation).
# MIN_VCENTERS - Requires the lease's pools to span at least this many distinct
#      vCenters (min-vcenters lease support, SPLAT-2993).  Only valid with the
#      POOL_COUNT single-lease path; must not exceed POOL_COUNT or MAX_VCENTERS.
# MAX_VCENTERS - Caps the number of distinct vCenters a lease may span.  It is
#      reduced to 1 when the release being installed predates multi-vCenter
#      install-config support (see below).
################################################################################

################################################################################
# Installer release capabilities
#
# install-config.yaml only accepts more than one platform.vsphere.vcenters
# entry from OCP 4.18 on, where VSphereMultiVCenters is enabled by default.
# Installers for 4.13 - 4.16 cap the list at one item outright.  OCP 4.17
# allows a longer list only when the job enables the VSphereMultiVCenters
# feature gate (through TechPreviewNoUpgrade or CustomNoUpgrade), which the
# zonal workflows do not do.  A lease spanning several vCenters therefore makes
# the initial installation fail before an upgrade can even be exercised.
#
# Upgrade jobs install the release referenced by release:initial before
# upgrading, so the bound must follow the *initial* release rather than the
# release being upgraded to.  The image resolution below mirrors what
# ipi-conf-vsphere-vcm and ipi-install-install-stableinitial do.
################################################################################

MULTI_VCENTER_MIN_OCP_VERSION=418
# OCP 4.17 is the first release with the VSphereMultiVCenters feature gate.
MULTI_VCENTER_FEATURE_GATE_VERSION=417

# A single vCenter exposes three failure-domain pools in the VMC fleet, so a
# lease capped to one vCenter can only satisfy three pools.  This matches the
# MAX_VCENTERS=1/POOL_COUNT=3 combination that the older-release zonal jobs use.
SINGLE_VCENTER_MAX_POOLS=3

# Echo the release image that the initial installation will use.
function determine_install_release_image() {
  local release_image_initial="${RELEASE_IMAGE_INITIAL:-}"

  if [[ -z "${release_image_initial}" ]]; then
    release_image_initial=$(oc get istag "release:initial" -n "${NAMESPACE}" \
      -o jsonpath='{.tag.from.name}' 2>/dev/null || true)
  fi

  if [[ -z "${release_image_initial}" ]]; then
    release_image_initial="${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM:-}"
  fi

  printf '%s\n' "${release_image_initial}"
}

# Echo the payload version (.metadata.version) for a release image.  The
# cluster profile pull secret is used directly; build-farm registry
# credentials are merged in the same way ipi-conf-vsphere-vcm does it.
function install_release_version() {
  local release_image="${1:-}"
  local work_dir=""
  local version=""

  if [[ -z "${release_image}" || ! -f "${CLUSTER_PROFILE_DIR:-}/pull-secret" ]]; then
    return 0
  fi

  work_dir=$(mktemp -d)
  cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${work_dir}/pull-secret"
  oc registry login --to "${work_dir}/pull-secret" &>/dev/null || true
  # A failed lookup must not abort the step: the requested limits are kept when
  # the version is unknown.
  version=$(oc adm release info \
    --registry-config "${work_dir}/pull-secret" \
    "${release_image}" --output=json 2>/dev/null |
    jq -r '.metadata.version // empty' 2>/dev/null || true)
  rm -rf "${work_dir}"

  printf '%s\n' "${version}"
}

# Echo the release version embedded in an image tag, e.g.
# registry/repo:4.13.0-0.nightly -> 4.13.  Used when the payload metadata
# cannot be read; digest references and non-version tags echo nothing.
function release_version_from_image_reference() {
  local release_image="${1:-}"
  local tag=""

  case "${release_image}" in
    *@sha256:*)
      return 0
      ;;
  esac

  tag="${release_image##*:}"
  if [[ "${tag}" =~ ^([0-9]+)\.([0-9]{1,2})(\.|-|$) ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# Echo <major>*100+<minor> for a payload version, e.g. 4.13.0-0.nightly -> 413.
# Echoes nothing when the version cannot be parsed.
function ocp_version_number() {
  local version="${1:-}"
  local major_version=""
  local minor_version=""

  major_version=$(echo "${version}" | cut -d. -f1)
  minor_version=$(echo "${version}" | cut -d. -f2)
  if [[ ! "${major_version}" =~ ^[0-9]+$ || ! "${minor_version}" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  echo $((10#${major_version} * 100 + 10#${minor_version}))
}

# Returns success when the job enables the VSphereMultiVCenters feature gate,
# which is how pre-4.18 releases opt into multi-vCenter install-config.
function multi_vcenter_feature_gate_enabled() {
  case "${FEATURE_SET:-}" in
    TechPreviewNoUpgrade)
      return 0
      ;;
    CustomNoUpgrade)
      [[ "${FEATURE_GATES:-}" == *VSphereMultiVCenters* && "${FEATURE_GATES:-}" != *VSphereMultiVCenters=false* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns success when the release accepts multiple platform.vsphere.vcenters
# entries.  An unknown version is treated as supported so a registry outage
# does not force newer jobs onto the single-vCenter path.
function multi_vcenter_install_supported() {
  local ocp_version="${1:-}"

  if [[ ! "${ocp_version}" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if (( 10#${ocp_version} >= MULTI_VCENTER_MIN_OCP_VERSION )); then
    return 0
  fi

  if (( 10#${ocp_version} >= MULTI_VCENTER_FEATURE_GATE_VERSION )); then
    multi_vcenter_feature_gate_enabled
    return
  fi

  return 1
}

# Echo "<max_vcenters> <pool_count>" with the lease limits adjusted to the
# release's multi-vCenter capability.
function apply_release_lease_limits() {
  local ocp_version="${1:-}"
  local max_vcenters="$2"
  local pool_count="$3"
  local pools="$4"

  if multi_vcenter_install_supported "${ocp_version}"; then
    printf '%s %s\n' "${max_vcenters}" "${pool_count}"
    return 0
  fi

  if (( 10#${max_vcenters} > 1 )); then
    max_vcenters=1
  fi

  # When POOLS lists explicit pools, each pool gets its own lease, so there is
  # no single-lease pool count to trim.
  if [[ -z "${pools}" ]] && (( 10#${pool_count} > SINGLE_VCENTER_MAX_POOLS )); then
    pool_count=${SINGLE_VCENTER_MAX_POOLS}
  fi

  printf '%s %s\n' "${max_vcenters}" "${pool_count}"
}

# Keep this marker directly above the first statement that has side effects:
# hack/tests/ipi-conf-vsphere-check-vcm-commands_test.sh sources this file up to
# the marker to exercise the release-capability helpers on their own.
# END_RELEASE_CAPABILITY_HELPERS

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "using legacy sibling of this step"
  exit 0
fi

function log() {
  echo "$(date -u --rfc-3339=seconds) - " + "$1"
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

log "POOLS: ${POOLS}"
log "POOL_COUNT: ${POOL_COUNT}"
log "MAX_VCENTERS: ${MAX_VCENTERS}"
log "MIN_VCENTERS: ${MIN_VCENTERS}"

# Make sure POOLS and POOL_COUNT are not both configured
if [[ "${POOL_COUNT}" != "1" && "${POOLS}" != "" ]]; then
  echo "Cannot set both POOL_COUNT and POOLS"
  exit 1
fi

# MIN_VCENTERS, POOL_COUNT and MAX_VCENTERS are compared arithmetically below
# and written into the lease spec; reject anything but non-negative integers
# here so a misconfigured value fails with a clear message instead of a cryptic
# bash or API-server error.  0 keeps its "disabled" meaning for MIN_VCENTERS.
for NUMERIC_VAR in MIN_VCENTERS POOL_COUNT MAX_VCENTERS; do
  if ! [[ "${!NUMERIC_VAR}" =~ ^[0-9]+$ ]]; then
    echo "${NUMERIC_VAR} must be a non-negative integer, got '${!NUMERIC_VAR}'"
    exit 1
  fi
done

# Apply the capability of the release that will actually be installed.  In an
# upgrade job that is the initial release, not the release being upgraded to.
install_release_image=$(determine_install_release_image)
INSTALL_RELEASE_VERSION=$(install_release_version "${install_release_image}")
if [[ -z "${INSTALL_RELEASE_VERSION}" ]]; then
  INSTALL_RELEASE_VERSION=$(release_version_from_image_reference "${install_release_image}")
fi
INSTALL_RELEASE_OCP_VERSION=$(ocp_version_number "${INSTALL_RELEASE_VERSION}")

requested_max_vcenters=${MAX_VCENTERS}
requested_pool_count=${POOL_COUNT}
read -r MAX_VCENTERS POOL_COUNT <<<"$(apply_release_lease_limits \
  "${INSTALL_RELEASE_OCP_VERSION}" "${MAX_VCENTERS}" "${POOL_COUNT}" "${POOLS}")"

MAX_VCENTERS_CLAMPED="false"
if [[ -z "${INSTALL_RELEASE_OCP_VERSION}" ]]; then
  log "WARNING: unable to determine the release being installed; keeping MAX_VCENTERS=${MAX_VCENTERS} and POOL_COUNT=${POOL_COUNT}"
elif multi_vcenter_install_supported "${INSTALL_RELEASE_OCP_VERSION}"; then
  log "release ${INSTALL_RELEASE_VERSION} supports multiple vCenters; keeping MAX_VCENTERS=${MAX_VCENTERS} and POOL_COUNT=${POOL_COUNT}"
else
  MAX_VCENTERS_CLAMPED="true"
  log "release ${INSTALL_RELEASE_VERSION} (OCP ${INSTALL_RELEASE_OCP_VERSION}) does not support multiple vCenters; using MAX_VCENTERS=${MAX_VCENTERS} and POOL_COUNT=${POOL_COUNT} (requested ${requested_max_vcenters} and ${requested_pool_count})"
fi

# MIN_VCENTERS requires the single-lease (POOL_COUNT) path and must respect the
# same bounds VCM enforces on spec.min-vcenters: it cannot exceed the number of
# pools requested or the vCenters cap.
if [[ "${MIN_VCENTERS}" != "0" ]]; then
  if [[ "${POOLS}" != "" ]]; then
    echo "MIN_VCENTERS cannot be used with POOLS; it requires the single-lease POOL_COUNT path"
    exit 1
  fi
  if [[ "${MAX_VCENTERS_CLAMPED}" == "true" ]]; then
    echo "MIN_VCENTERS (${MIN_VCENTERS}) requires multiple vCenters, but release ${INSTALL_RELEASE_VERSION} (OCP ${INSTALL_RELEASE_OCP_VERSION}) does not support them; MAX_VCENTERS is capped at 1"
    exit 1
  fi
  if (( 10#${MIN_VCENTERS} > 10#${POOL_COUNT} )); then
    echo "MIN_VCENTERS (${MIN_VCENTERS}) must not exceed POOL_COUNT (${POOL_COUNT})"
    exit 1
  fi
  if (( 10#${MIN_VCENTERS} > 10#${MAX_VCENTERS} )); then
    echo "MIN_VCENTERS (${MIN_VCENTERS}) must not exceed MAX_VCENTERS (${MAX_VCENTERS})"
    exit 1
  fi
fi

export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate

# only used in zonal and vsphere environments with
# multiple datacenters
declare vsphere_url
declare VCENTER_AUTH_PATH
declare PORTGROUP_RETVAL
declare LEASES


declare SINGLE_TENANT_LEASE_JOB_SAFE_NAMES
# shellcheck source=/dev/null
source "/var/run/vault/vsphere-ibmcloud-config/multi-capable-workflows.sh"

LEASES=()

DEFAULT_NETWORK_TYPE=${DEFAULT_NETWORK_TYPE:-"multi-tenant"}
for job_safe_name in ${SINGLE_TENANT_LEASE_JOB_SAFE_NAMES}; do
  job_safe_name=$(echo "${job_safe_name}" | tr -d '[:space:]\r')
  if [[ "${JOB_NAME_SAFE}" == "${job_safe_name}"* ]]; then
    log "job ${JOB_NAME_SAFE} requires a single-tenant lease. will request a single-tenant network if there is no override in the job yaml."
    DEFAULT_NETWORK_TYPE="single-tenant"
    break
  fi
done

NETWORK_TYPE=${NETWORK_TYPE:-${DEFAULT_NETWORK_TYPE}}

log "job will run with network type ${NETWORK_TYPE}"

function networkToSubnetsJson() {
  local NETWORK_CACHE_PATH=$1
  local NETWORK_RESOURCE=$2

  TMPSUBNETSJSON="/tmp/subnets-${NETWORK_RESOURCE}.json"

  jq -r '.[.spec.primaryRouterHostname] = .[.spec.vlanId] |
  .[.spec.primaryRouterHostname][.spec.vlanId] = .spec |
  .[.spec.primaryRouterHostname][.spec.vlanId].dnsServer = .spec.nameservers[0] |
  .[.spec.primaryRouterHostname][.spec.vlanId].mask = .spec.netmask |
  .[.spec.primaryRouterHostname][.spec.vlanId].StartIPv6Address= .spec.startIPv6Address |
  .[.spec.primaryRouterHostname][.spec.vlanId].CidrIPv6 = .spec.cidrIPv6' "${NETWORK_CACHE_PATH}" > "${TMPSUBNETSJSON}"


  if [ -f "${SHARED_DIR}/subnets.json" ]; then
    if [[ "${VSPHERE_MULTI_NETWORKS:-}" == "true" ]]; then
      jq -s '.[0] * .[1]' "${TMPSUBNETSJSON}" "${SHARED_DIR}/subnets.json" > /tmp/tmpfile && mv /tmp/tmpfile "${SHARED_DIR}/subnets.json"
    else
      jq -s '.[0] * .[1]' "${TMPSUBNETSJSON}" "${SHARED_DIR}/subnets.json"
    fi
  else
    cp "${TMPSUBNETSJSON}" "${SHARED_DIR}/subnets.json"
  fi
}

function getPortGroup() {
  NETWORK_INDEX=$1
  log "Getting portgroup for networks[${NETWORK_INDEX}]"
  NETWORK_PATH=$(jq -r ".status.topology.networks[$NETWORK_INDEX]" < /tmp/lease.json)

  # We may have more than one network in the lease.  We'll need to find the owner that matches current
  NETWORK_RESOURCES=$(jq -r '.metadata.ownerReferences[] | select(.kind=="Network") | .name' < /tmp/lease.json)
  for RESOURCE in ${NETWORK_RESOURCES}; do
    log "Checking network resource ${RESOURCE}"
    NETWORK_CACHE_PATH="${SHARED_DIR}/NETWORK_${RESOURCE}.json"

    if [ ! -f "$NETWORK_CACHE_PATH" ]; then
      log "Caching network resource ${RESOURCE}"
      oc get networks.vspherecapacitymanager.splat.io -n vsphere-infra-helpers --kubeconfig "${SA_KUBECONFIG}" "${RESOURCE}" -o json > "${NETWORK_CACHE_PATH}"
    fi

    networkToSubnetsJson "${NETWORK_CACHE_PATH}" "${RESOURCE}"
  done

  PORTGROUP_RETVAL=$(echo "$NETWORK_PATH" | cut -d '/' -f 4)
}

log "add jq plugin for converting json to yaml"
# this snippet enables jq to convert json to yaml
cat > ~/.jq <<EOF
def yamlify2:
    (objects | to_entries | (map(.key | length) | max + 2) as \$w |
        .[] | (.value | type) as \$type |
        if \$type == "array" then
            "\(.key):", (.value | yamlify2)
        elif \$type == "object" then
            "\(.key):", "    \(.value | yamlify2)"
        else
            "\(.key):\(" " * (.key | \$w - length))\(.value)"
        end
    )
    // (arrays | select(length > 0)[] | [yamlify2] |
        "  - \(.[0])", "    \(.[1:][])"
    )
    // .
    ;
EOF

function getTypeInHeirarchy() {
  local DATATYPE=$1
  local LEVEL=$2

  FOUND=0
  while [[ $FOUND == 0 ]]; do
    PARENTREF=$(jq --compact-output -r '.[] | select (.Name=="parent").Val' <<< "$LEVEL")
    echo "$PARENTREF"
    if [[ ${PARENTREF} == "null" ]]; then
      log "unable to find ${DATATYPE}"
      return 1
    fi
    TEMPTYPE=$(jq -r .Type <<< "${PARENTREF}")
    log "type ${TEMPTYPE}"
    LEVEL=$(govc object.collect -json "${TEMPTYPE}":"$(jq --compact-output -r .Value <<< "${PARENTREF}")")
    if [[ ${TEMPTYPE} == "${DATATYPE}" ]]; then
      LEVEL_NAME=$(jq -r '.[] | select(.Name == "name") | .Val' <<< "${LEVEL}")
      FOUND=1
    fi
  done

  return 0
}

DVS_PATH="${SHARED_DIR}/dvs.json"
dvsJSON="{}"

# getDVSInfo build a map of JSON data for a specific network path
function getDVSInfo() {
  local NETWORK=$1

  if [[ $(jq -r '.["'"${NETWORK}"'"]' <<< "${dvsJSON}") != "null" ]]; then
    return
  fi
  log "gathering clusters and UUIDs associated with ${NETWORK}"

  dvsJSON=$(jq -r '. += {"'"${NETWORK}"'": {}}' <<< "${dvsJSON}")

  govc ls -json -t DistributedVirtualPortgroup "${NETWORK}" > /tmp/dvs.json
  elements=$(jq length /tmp/dvs.json)
  DVS_idx=0
  while [[ $DVS_idx -lt ${elements} ]]; do
    log "DVS: ${DVS_idx}"

    parentDVS=$(jq --compact-output -r .elements[${DVS_idx}].Object.Config.DistributedVirtualSwitch /tmp/dvs.json)
    UUID_FORMATTED=$(govc object.collect -json "$(jq -r .Type <<< "${parentDVS}")":"$(jq -r .Value <<< "${parentDVS}")" | jq -r '.[] | select(.Name=="uuid") | .Val')

    # determine the cluster where this dvs instance resides
    HOSTS=$(jq -r '.elements['${DVS_idx}'].Object.Host | .[].Value' /tmp/dvs.json)
    for HOST in ${HOSTS}; do
      _HOST=$(govc object.collect -json HostSystem:"${HOST}")

      getTypeInHeirarchy "ClusterComputeResource" "${_HOST}"
      # shellcheck disable=SC2181
      if [ "$?" -ne 0 ];then
        log "could not determine the compute cluster resource for ${NETWORK}"
        exit 1
      fi
      local CLUSTER=${LEVEL_NAME}

      getTypeInHeirarchy "Datacenter" "${_HOST}"
      # shellcheck disable=SC2181
      if [ "$?" -ne 0 ];then
        log "could not determine the datacenter resource for ${NETWORK}"
        exit 1
      fi

      log "found in cluster ${CLUSTER} with UUID ${UUID_FORMATTED}"
      dvsJSON2=$(jq -r '.["'"${NETWORK}"'"] += {"datacenter":"'"${LEVEL_NAME}"'","cluster":{"'"${CLUSTER}"'": "'"${UUID_FORMATTED}"'"}}' <<< "${dvsJSON}")
      dvsJSON=$(echo "${dvsJSON} ${dvsJSON2}" | jq -s '.[0] * .[1]')
    done
    DVS_idx=$((DVS_idx + 1))
   done

  echo "$dvsJSON" > "${DVS_PATH}"
}

SA_KUBECONFIG=${SA_KUBECONFIG:-/var/run/vault/vsphere-ibmcloud-ci/vsphere-capacity-manager-kubeconfig}

if [[ ${JOB_NAME_SAFE} =~ "-upi" ]]; then
   IPI=0
   log "determined this is a UPI job"
else
   IPI=1
   log "determined this is an IPI job"
fi

# It seems we have some private jobs that are not using this flag.  We'll have to see how to sync up with those tests
# to try to use the MULTI_NIC_IPI flag for doing multiple nics.
if [[ -n "${MULTI_NIC_IPI}" ]]; then
  echo "multi-nic is enabled, an additional NIC will be attached to nodes"
fi

# Generate labels for reference back to job
PROW_JOB_TYPE="$(echo ${JOB_SPEC} | jq -r '.type')"
PROW_JOB="$(echo ${JOB_SPEC} | jq -r '.job')"
PROW_BUILD_ID="$(echo ${JOB_SPEC} | jq -r '.buildid')"
PROW_GS_BUCKET="$(echo ${JOB_SPEC} | jq -r '.decoration_config.gcs_configuration.bucket')"
JOB_URL_PREFIX="$(echo ${JOB_SPEC} | jq -r '.decoration_config.gcs_configuration.job_url_prefix // empty')"
if [[ "${JOB_URL_PREFIX}" == "" ]]; then
  JOB_URL_PREFIX="https://prow.ci.openshift.org/view/"
fi

# The following will only be present for presubmits
GIT_ORG="$(echo ${JOB_SPEC} | jq -r '.refs.org')"
GIT_REPO="$(echo ${JOB_SPEC} | jq -r '.refs.repo')"
GIT_PR="$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')"

LEASE_ANNOTATIONS="prow-job-type: \"${PROW_JOB_TYPE}\"
    prow-job-name: \"${PROW_JOB}\"
    prow-build-id: \"${PROW_BUILD_ID}\"
    prow-gs-bucket: \"${PROW_GS_BUCKET}\"
    prow-url-prefix: \"${JOB_URL_PREFIX}\""
if [[ "${PROW_JOB_TYPE}" == "presubmit" ]]; then
  LEASE_ANNOTATIONS="${LEASE_ANNOTATIONS}
    git-org: \"${GIT_ORG}\"
    git-repo: \"${GIT_REPO}\"
    git-pr: \"${GIT_PR}\""
fi

# Handle POOL_SELECTOR if provided (parse once and use for all leases)
# Supports multiple key=value pairs separated by commas, e.g., "vcf=true,region=us-east"
poolSelector=""
if [ -n "${POOL_SELECTOR:-}" ]; then
  # Split by comma and process each key=value pair
  IFS=',' read -ra selector_pairs <<< "${POOL_SELECTOR}"

  poolSelector="poolSelector:"
  for pair in "${selector_pairs[@]}"; do
    # Trim whitespace from pair
    pair=$(echo "${pair}" | xargs)

    # Parse each pair in format "key=value"
    if [[ "${pair}" =~ ^([^=]+)=([^=]+)$ ]]; then
      selector_key="${BASH_REMATCH[1]}"
      selector_value="${BASH_REMATCH[2]}"
      poolSelector="${poolSelector}
    ${selector_key}: \"${selector_value}\""
      log "setting poolSelector with ${selector_key}=${selector_value}"
    else
      log "ERROR: Each POOL_SELECTOR pair must be in format 'key=value', got: ${pair}"
      exit 1
    fi
  done
fi

if [[ -n "${VSPHERE_BASTION_LEASED_RESOURCE:-}" ]]; then
  log "creating bastion lease resource ${VSPHERE_BASTION_LEASED_RESOURCE}"

  # shellcheck disable=SC1078
  LEASES+=("$(echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: \"${LEASED_RESOURCE}-\"
  namespace: \"vsphere-infra-helpers\"
  annotations:
    ${LEASE_ANNOTATIONS}
  labels:
    vsphere-capacity-manager.splat-team.io/lease-namespace: \"${NAMESPACE}\"
    boskos-lease-id: \"${LEASED_RESOURCE}\"
    boskos-lease-group: \"${LEASED_RESOURCE}\"
    job-name: \"${JOB_NAME_SAFE}\"
    VSPHERE_BASTION_LEASED_RESOURCE: \"${VSPHERE_BASTION_LEASED_RESOURCE}\"
spec:
  vcpus: 0
  memory: 0
  network-type: \"${NETWORK_TYPE}\"
  requiresPool: \"${VSPHERE_BASTION_LEASED_RESOURCE}\"
  ${poolSelector}
  networks: 1
  vcenters: ${MAX_VCENTERS}" | oc create --kubeconfig "${SA_KUBECONFIG}" -o json -f - | jq -r '.metadata.name')")
fi

POOLS=${POOLS:-}
IFS=" " read -r -a pools <<< "${POOLS}"

# Jobs are now using vault to provide dynamic overrides of configs.  Jobs can still provide their core counts as an
# override; however, we will calculate based on vault config if not provided.
SPEC_CONFIG="/var/run/vault/vsphere-ibmcloud-config/vm-specs.json"
if [[ "${OPENSHIFT_REQUIRED_CORES}" -eq "" ]]; then
  # add cores for control plane
  OPENSHIFT_REQUIRED_CORES=$(( CONTROL_PLANE_REPLICAS * $(jq -r '.spec.controlplane.cpus' ${SPEC_CONFIG}) ))
  # add cores for compute
  OPENSHIFT_REQUIRED_CORES=$(( OPENSHIFT_REQUIRED_CORES + ( COMPUTE_NODE_REPLICAS * $(jq -r '.spec.compute.cpus' ${SPEC_CONFIG}) ) ))
  # add cores for bootstrap.  currently bootstrap is configured like a control plane vm.
  OPENSHIFT_REQUIRED_CORES=$(( OPENSHIFT_REQUIRED_CORES + $(jq -r '.spec.controlplane.cpus' ${SPEC_CONFIG}) ))
fi

if [[ "${OPENSHIFT_REQUIRED_MEMORY}" -eq "" ]]; then
  # add memory for control plane
  OPENSHIFT_REQUIRED_MEMORY=$(( CONTROL_PLANE_REPLICAS * $(jq -r '.spec.controlplane.memoryMB' ${SPEC_CONFIG}) ))
  # add memory for compute
  OPENSHIFT_REQUIRED_MEMORY=$(( OPENSHIFT_REQUIRED_MEMORY + ( COMPUTE_NODE_REPLICAS * $(jq -r '.spec.compute.memoryMB' ${SPEC_CONFIG}) ) ))
  # add memory for bootstrap.  currently bootstrap is configured like a control plane vm.
  OPENSHIFT_REQUIRED_MEMORY=$(( OPENSHIFT_REQUIRED_MEMORY + $(jq -r '.spec.controlplane.memoryMB' ${SPEC_CONFIG}) ))

  # Vault has memory in MB due to install-config using MB, but leases uses GB
  OPENSHIFT_REQUIRED_MEMORY=$(( OPENSHIFT_REQUIRED_MEMORY / 1024 ))
fi

OPENSHIFT_REQUIRED_CORES=${OPENSHIFT_REQUIRED_CORES:-24}
OPENSHIFT_REQUIRED_MEMORY=${OPENSHIFT_REQUIRED_MEMORY:-96}

if [[ ${#pools[@]} -eq 0 ]]; then
  pools[0]="unspecified"
else
  # if we have multiple pools, attempt to spread the load evenly between the pools
  OPENSHIFT_REQUIRED_CORES=$((OPENSHIFT_REQUIRED_CORES / ${#pools[@]}))
  OPENSHIFT_REQUIRED_MEMORY=$((OPENSHIFT_REQUIRED_MEMORY / ${#pools[@]}))
fi

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

# create a lease for each pool
POOL_INDEX=0
for POOL in "${pools[@]}"; do
  log "creating lease for pool ${POOL}"
  requiredPool=""
  if [ "$POOL" != "unspecified" ]; then
    requiredPool="required-pool: $POOL"
    log "setting required pool ${requiredPool}"
  fi

  networks_number=1
  # Base vs private ci jobs use different flags to represent multi nic.  If either is set, increase number to 2 networks.
  # Future change will change this to be an integer and allow jobs to pass in the number of networks to acquire.
  if [[ "${MULTI_NIC_IPI:-}" == "true" ]]; then
    networks_number=2
  fi

  # RESERVE_EXTRA_NETWORK requests an additional network that won't be attached to nodes.
  # Useful for remote worker installations that need a separate network.
  if [[ "${RESERVE_EXTRA_NETWORK:-}" == "true" ]]; then
    networks_number=2
  fi

  # For this flag, we need to make sure each FD has a unique name so it gets a unique subnet.
  unique_name=""
  if [[ "${VSPHERE_MULTI_NETWORKS:-}" == "true" ]]; then
    unique_name="-${POOL_INDEX}"
    POOL_INDEX=$((POOL_INDEX + 1))
  fi

  # shellcheck disable=SC1078
  lease_json=$(echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: \"${LEASED_RESOURCE}-\"
  namespace: \"vsphere-infra-helpers\"
  annotations:
    ${LEASE_ANNOTATIONS}
  labels:
    cluster-id: \"${cluster_name}\"
    vsphere-capacity-manager.splat-team.io/lease-namespace: \"${NAMESPACE}\"
    boskos-lease-id: \"${LEASED_RESOURCE}${unique_name}\"
    boskos-lease-group: \"${LEASED_RESOURCE}\"
    job-name: \"${JOB_NAME_SAFE}\"
spec:
  vcpus: ${OPENSHIFT_REQUIRED_CORES}
  memory: ${OPENSHIFT_REQUIRED_MEMORY}
  network-type: \"${NETWORK_TYPE}\"
  pools: ${POOL_COUNT}
  min-vcenters: ${MIN_VCENTERS}
  ${requiredPool}
  ${poolSelector}
  networks: $networks_number
  vcenters: ${MAX_VCENTERS}" | oc create --kubeconfig "${SA_KUBECONFIG}" -o json -f -)

  # An API server serving a VCM CRD that predates min-vcenters (SPLAT-2993)
  # silently prunes the field instead of rejecting the lease.  Detect that here
  # so a job requiring a multi-vCenter lease fails loudly instead of running on
  # fewer vCenters than intended.
  if [[ "${MIN_VCENTERS}" != "0" ]] && [[ "$(jq -r '.spec["min-vcenters"] // empty' <<<"${lease_json}")" == "" ]]; then
    log "ERROR: lease was created without the requested min-vcenters (${MIN_VCENTERS})"
    log "The VCM CRD in vsphere-infra-helpers does not support min-vcenters (SPLAT-2993)."
    log "Deploy the updated vsphere-capacity-manager before running jobs that set MIN_VCENTERS."
    exit 1
  fi

  LEASES+=("$(jq -r '.metadata.name' <<<"${lease_json}")")
done

log "waiting for lease $(printf '%s ' "${LEASES[@]}") to be fulfilled..."
n=0
until [ "$n" -ge 5 ]
do
  if [ "${#LEASES[@]}" -eq "1" ]; then
    # shellcheck disable=SC2046
    if oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o json | jq -e '.status?'; then
      break
    fi
  else
    # shellcheck disable=SC2046
    if oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o json | jq -e '.items[].status?'; then
      break
    fi
  fi

  n=$((n+1))
  sleep 15
done

if [ "$n" -ge 5 ]; then
  log "status was never available for lease, exit 1"
  # shellcheck disable=SC2046
  oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o yaml
  exit 1
fi

LEASE_WAIT_TIMEOUT_SECONDS=$((120 * 60))
LEASE_WAIT_POLL_INTERVAL=15
elapsed=0
while true; do
  # shellcheck disable=SC2046
  lease_phases=$(oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o json | jq -r 'if has("items") then .items[].status.phase else .status.phase end')

  if grep -q "^Failed$" <<< "${lease_phases}"; then
    log "ERROR: lease entered Failed phase, the requested configuration is invalid or cannot be fulfilled"
    # shellcheck disable=SC2046
    oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o yaml
    exit 1
  fi

  if [[ -z "$(grep -v '^Fulfilled$' <<< "${lease_phases}")" ]]; then
    log "all leases fulfilled"
    break
  fi

  if [[ ${elapsed} -ge ${LEASE_WAIT_TIMEOUT_SECONDS} ]]; then
    log "ERROR: timed out waiting for lease $(printf '%s ' "${LEASES[@]}") to be fulfilled"
    exit 1
  fi

  sleep ${LEASE_WAIT_POLL_INTERVAL}
  elapsed=$((elapsed + LEASE_WAIT_POLL_INTERVAL))
done

declare -A vcenter_portgroups
declare -A vcenter_reserved_portgroups

# reconcile leases
log "Extracting portgroups from leases..."
for LEASE in "${LEASES[@]}"; do
  log "getting lease ${LEASE}"
  oc get leases.vspherecapacitymanager.splat.io -n vsphere-infra-helpers --kubeconfig "${SA_KUBECONFIG}" "${LEASE}" -o json > /tmp/lease.json
  VCENTER=$(jq -r '.status.name' < /tmp/lease.json )

  log "got lease ${LEASE}"

  # We need to iterate through each network
  networkCount=$(jq '.status.topology.networks | length' < /tmp/lease.json)
  log "Network count: ${networkCount}"

  bastion_leased_resource=$(jq .metadata.labels.VSPHERE_BASTION_LEASED_RESOURCE < /tmp/lease.json)

  if [ "${bastion_leased_resource}" != "null" ]; then
    getPortGroup 0
    portgroup_name=${PORTGROUP_RETVAL}
    log "setting bastion portgroup ${portgroup_name} in vsphere_context.sh"

    cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export vsphere_bastion_portgroup="${portgroup_name}"
EOF

  else
    for ((i = 0; i < ${networkCount}; i++)); do
      getPortGroup $i
      portgroup_name=${PORTGROUP_RETVAL}

      # If RESERVE_EXTRA_NETWORK is enabled, only use the first network for installation
      # Additional networks are reserved for later use (e.g., remote workers)
      if [[ "${RESERVE_EXTRA_NETWORK:-}" == "true" ]] && [[ $i -gt 0 ]]; then
        log "Reserving network ${portgroup_name} for later use (not adding to platform spec)"
        previousReservedValue=""
        if [[ -n "${vcenter_reserved_portgroups[$VCENTER]:-}" ]]; then
          previousReservedValue="${vcenter_reserved_portgroups[$VCENTER]},"
        fi
        vcenter_reserved_portgroups[$VCENTER]="${previousReservedValue}${portgroup_name}"
      else
        previousValue=""
        if [[ -n "${vcenter_portgroups[$VCENTER]:-}" ]]; then
          previousValue="${vcenter_portgroups[$VCENTER]},"
        fi
        vcenter_portgroups[$VCENTER]="${previousValue}${portgroup_name}"
      fi
    done
  fi

  # When pools > 1, each pool's portgroup is in status.poolInfo[N].topology.networks[0]
  # rather than the top-level status.topology.networks. Populate vcenter_portgroups
  # for each additional pool so the platformSpec loop can find them by pool name.
  pool_info_count=$(jq '.status.poolInfo | length' < /tmp/lease.json)
  if [[ "${pool_info_count}" != "null" && "${pool_info_count}" -gt 1 ]]; then
    log "Multi-pool lease detected (${pool_info_count} pools) — extracting per-pool portgroups from poolInfo"
    for ((pi = 0; pi < pool_info_count; pi++)); do
      pi_pool_name=$(jq -r ".status.poolInfo[${pi}].name" < /tmp/lease.json)
      pi_network_path=$(jq -r ".status.poolInfo[${pi}].topology.networks[0]" < /tmp/lease.json)
      pi_portgroup=$(echo "${pi_network_path}" | cut -d '/' -f 4)
      log "Pool ${pi_pool_name}: portgroup ${pi_portgroup}"
      vcenter_portgroups[${pi_pool_name}]="${pi_portgroup}"
    done
  fi

  cp /tmp/lease.json "${SHARED_DIR}/LEASE_$LEASE.json"
done

# debug, confirm correct subnets.json
cat "${SHARED_DIR}/subnets.json"

declare -A pool_usernames
declare -A pool_passwords

# shellcheck disable=SC2089
platformSpec='{"vcenters": [],"failureDomains": []}'

# Track the number of unique vCenters to enforce MAX_VCENTERS limit
vcenter_count=0

log "building local variables and failure domains"

# Iterate through each lease and generate the failure domain and vcenters information
for _leaseJSON in "${SHARED_DIR}"/LEASE*; do
  # Skip the LEASE_single copy to avoid double-processing — the original named file
  # is iterated separately and covers the same content.
  if [[ ${_leaseJSON} =~ "single" ]]; then
    continue
  fi

  PRIMARY_LEASED_CPUS=$(jq -r .spec.vcpus < "${_leaseJSON}")
  if [[ ${PRIMARY_LEASED_CPUS} != "null" ]]; then
    log "storing primary lease as LEASE_single"
    cp "${_leaseJSON}" "${SHARED_DIR}"/LEASE_single.json
  fi

  # Determine how many pools are in this lease.  When pools > 1, VCM returns all
  # pools in status.poolInfo[].  When pools == 1, fall back to status.name.
  #
  # This threshold must stay in sync with the "-gt 1" check used above when
  # populating vcenter_portgroups: that loop only keys the map by pool name
  # for leases spanning more than one pool, falling back to keying by the
  # lease's vcenter (status.name) for a single-pool lease. If this branch
  # used ">0" instead, a single-pool lease (poolInfo length 1) would look up
  # vcenter_portgroups by pool name even though it was only ever keyed by
  # vcenter, crashing with "unbound variable" under set -o nounset whenever
  # the pool name doesn't happen to equal the vcenter name.
  lease_pool_count=$(jq '.status.poolInfo | length' < "${_leaseJSON}")
  if [[ "${lease_pool_count}" == "null" || "${lease_pool_count}" -eq 0 ]]; then
    lease_pool_count=0
  fi

  if [[ ${lease_pool_count} -gt 1 ]]; then
    log "Multi-pool lease: processing ${lease_pool_count} pool(s) from poolInfo"
    pool_names=()
    for ((lpi = 0; lpi < lease_pool_count; lpi++)); do
      pool_names+=("$(jq -r ".status.poolInfo[${lpi}].name" < "${_leaseJSON}")")
    done
  else
    log "Single-pool lease: processing pool from status.name"
    pool_names=("$(jq -r .status.name < "${_leaseJSON}")")
  fi

  for RESOURCE_POOL in "${pool_names[@]}"; do
    log "building local variables and platform spec for pool ${RESOURCE_POOL}"
    oc get pools.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers "${RESOURCE_POOL}" -o json > /tmp/pool.json
  VCENTER_AUTH_PATH=$(jq -r '.metadata.annotations["ci-auth-path"]' < /tmp/pool.json)

  declare vcenter_usernames
  declare vcenter_passwords

  # shellcheck source=/dev/null
  source "${VCENTER_AUTH_PATH}"
  account_loc=$((RANDOM % 4))
  VCENTER=$(jq -r '.spec.server' < /tmp/pool.json)
  vsphere_user="${vcenter_usernames[$account_loc]}"
  vsphere_password="${vcenter_passwords[$account_loc]}"
  pool_usernames[$VCENTER]=${vsphere_user}
  pool_passwords[$VCENTER]=${vsphere_password}

  shortName=$(jq -r '.spec.shortName' < /tmp/pool.json)
  server=$(jq -r '.spec.server' < /tmp/pool.json)
  region=$(jq -r '.spec.region' < /tmp/pool.json)
  zone=$(jq -r '.spec.zone' < /tmp/pool.json)
  cluster=$(jq -r '.spec.topology.computeCluster' < /tmp/pool.json)
  datacenter=$(jq -r '.spec.topology.datacenter' < /tmp/pool.json)
  datastore=$(jq -r '.spec.topology.datastore' < /tmp/pool.json)

  # Populate network from our map.  Add quotes around the comma for json creation below
  network="${vcenter_portgroups[$RESOURCE_POOL]/,/\",\"}"
  if [ $IPI -eq 0 ]; then
    resource_pool=${cluster}/Resources/${NAMESPACE}-${UNIQUE_HASH}
  else
    resource_pool=${cluster}/Resources/ipi-ci-clusters
  fi

  # prevent duplicate failure domains if in the event we have a network-only lease in addition to the primary lease
  add_failure_domain=0
  failure_domain_count=$(echo "${platformSpec}" | jq '.failureDomains | length')
  if [[ $failure_domain_count == 0 ]]; then
    add_failure_domain=1
  elif [ -z "$(echo "${platformSpec}" | jq -e --arg NAME "$shortName" '.failureDomains[] | select(.name == $NAME) | length == 0')" ]; then
    add_failure_domain=1
  fi

  # poolName carries VCM's own status.poolInfo[].name verbatim (or status.name
  # for a single-pool lease) so consumers can look up this failure domain's
  # govc_<pool>.sh by the same string VCM used to create it. VCM lowercases
  # the datacenter/cluster segments when composing that name (e.g. datacenter
  # "wldn-120-DC" becomes "wldn-120-dc" in the pool name), but topology.datacenter
  # below keeps the original case, so reconstructing the pool name from
  # server+datacenter+cluster is not reliable.
  if [[ $add_failure_domain == 1 ]] ; then
    platformSpec=$(echo "${platformSpec}" | jq -r '.failureDomains += [{"server": "'"${server}"'", "name": "'"${shortName}"'", "poolName": "'"${RESOURCE_POOL}"'", "zone": "'"${zone}"'", "region": "'"${region}"'", "server": "'"${server}"'", "topology": {"resourcePool": "'"${resource_pool}"'", "computeCluster": "'"${cluster}"'", "datacenter": "'"${datacenter}"'", "datastore": "'"${datastore}"'", "networks": ["'"${network}"'"]}}]')
  fi

  # Add / Update vCenter list
  if echo "${platformSpec}" | jq -e --arg VCENTER "$VCENTER" '.vcenters[] | select(.server == $VCENTER) | length > 0' ; then
    # Check and make sure the datacenter doesn't already exist in the vcenter definition
    if ! echo "${platformSpec}" | jq -e --arg VCENTER "$VCENTER" --arg DC "$datacenter" '.vcenters[] | select(.server == $VCENTER) | any(.datacenters[]; . == $DC)' ; then
      log "Adding additional datacenter to vcenter ${VCENTER}"
      platformSpec=$(echo "${platformSpec}" | jq -r --arg VCENTER "$VCENTER" --arg DC "$datacenter" '(.vcenters[] | select(.server == $VCENTER)) |= (.datacenters[.datacenters | length] |= .+ $DC)')
    fi
  else
    # Check if we've reached the maximum number of vCenters - this validates VCM honored the limit
    if [[ ${vcenter_count} -ge ${MAX_VCENTERS} ]]; then
      log "ERROR: VCM returned more vCenters than requested maximum (${MAX_VCENTERS})"
      log "Attempted to add vCenter: ${VCENTER}"
      log "Current vCenters already in configuration:"
      echo "${platformSpec}" | jq -r '.vcenters[].server'
      log "This indicates VCM did not honor the spec.vcenters limit in the lease request"
      exit 1
    fi
    log "Adding vcenter ${VCENTER} to config (${vcenter_count}/${MAX_VCENTERS})"
    platformSpec=$(echo "${platformSpec}" | jq -r '.vcenters += [{"server": "'"${VCENTER}"'", "user": "'"${pool_usernames[$VCENTER]}"'", "password": "'"${pool_passwords[$VCENTER]}"'", "datacenters": ["'"${datacenter}"'"]}]')
    vcenter_count=$((vcenter_count + 1))
  fi

    cp /tmp/pool.json "${SHARED_DIR}"/POOL_"${RESOURCE_POOL}".json
  done  # end for RESOURCE_POOL
done  # end for _leaseJSON

log "Successfully configured ${vcenter_count} vCenter(s) (max allowed: ${MAX_VCENTERS})"

# For legacy spec, the below will merge the following json to the existing json.
if [ -n "${POPULATE_LEGACY_SPEC}" ]; then
  platformSpec='{"vcenter": "'"${server}"'", "username": "'"${vsphere_user}"'", "password": "'"${vsphere_password}"'", "defaultDatastore": "'"$(basename "${datastore}")"'" ,"network": "'"$(basename "${network}")"'" , "cluster": "'"$(basename "${cluster}")"'", "datacenter": "'"$(basename "${datacenter}")"'"}'
fi

# For most CI jobs, a single lease and single pool will be used. We'll initialize govc.sh and
# vsphere_context.sh with the first lease we find. multi-zone and multi-vcenter will need to
# parse topology, credentials, etc from $SHARED_DIR.

IFS=' ' read -ra NETWORK_RESOURCE <<< "$(jq -r '.metadata.ownerReferences[] | select(.kind=="Network") | .name' < "${SHARED_DIR}"/LEASE_single.json)"
cp "${SHARED_DIR}/NETWORK_${NETWORK_RESOURCE[0]}.json" "${SHARED_DIR}"/NETWORK_single.json

# Seed govc.sh from the pool backing failureDomains[0].  status.envVars is VCM's
# deprecated top-level field and holds the LAST pool's values, which can belong
# to a different vCenter than failureDomains[0]; a consumer that keeps govc.sh's
# credentials while targeting another failure domain's server would then fail
# login.  Each pool's own values are in status.envVarsMap.
primary_fd_server=$(echo "${platformSpec}" | jq -r '.failureDomains[0].server')
primary_fd_cluster=$(echo "${platformSpec}" | jq -r '.failureDomains[0].topology.computeCluster')
primary_pool_name=""
for _leaseJSON in "${SHARED_DIR}"/LEASE*; do
  if [[ ${_leaseJSON} =~ "single" ]]; then
    continue
  fi
  _pool_count=$(jq -r '.status.poolInfo | length' < "${_leaseJSON}")
  if [[ "${_pool_count}" == "null" || "${_pool_count}" -eq 0 ]]; then
    continue
  fi
  for ((_pi = 0; _pi < _pool_count; _pi++)); do
    _pool_server=$(jq -r ".status.poolInfo[${_pi}].server" < "${_leaseJSON}")
    _pool_cluster=$(jq -r ".status.poolInfo[${_pi}].topology.computeCluster" < "${_leaseJSON}")
    if [[ "${_pool_server}" == "${primary_fd_server}" && "${_pool_cluster}" == "${primary_fd_cluster}" ]]; then
      primary_pool_name=$(jq -r ".status.poolInfo[${_pi}].name" < "${_leaseJSON}")
      break 2
    fi
  done
done

if [[ -n "${primary_pool_name}" ]]; then
  log "Seeding govc.sh from pool ${primary_pool_name} (failureDomains[0])"
  jq -r ".status.envVarsMap.\"${primary_pool_name}\"" < "${_leaseJSON}" > /tmp/envvars
  # failureDomains[0] already carries this pool's computed resource pool
  resource_pool=$(echo "${platformSpec}" | jq -r '.failureDomains[0].topology.resourcePool')
else
  # Legacy single-pool leases have no poolInfo; their top-level status.envVars
  # is the pool's own value and safe to seed from.
  log "No poolInfo entry matches failureDomains[0], seeding govc.sh from status.envVars"
  jq -r '.status.envVars' "${SHARED_DIR}"/LEASE_single.json > /tmp/envvars
fi

# shellcheck source=/dev/null
source /tmp/envvars


if [[ -z "${GOVC_URL}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - vcm failed to provide environment variables, exiting"
  exit 1
fi

# An empty credential lookup would otherwise surface later as an opaque govc
# login failure in whichever step consumes govc.sh.
if [[ -z "${pool_usernames[${GOVC_URL}]:-}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - no credentials found for vCenter ${GOVC_URL}, exiting"
  exit 1
fi

log "Creating govc.sh file..."
cat >>"${SHARED_DIR}/govc.sh" <<EOF
$(cat /tmp/envvars)
export LEASE_PATH=${SHARED_DIR}/LEASE_single.json
export NETWORK_PATH=${SHARED_DIR}/NETWORK_single.json
export GOVC_INSECURE=1
export vsphere_resource_pool=${resource_pool}
export GOVC_RESOURCE_POOL=${resource_pool}
export cloud_where_run=IBM
export GOVC_USERNAME="${pool_usernames[${GOVC_URL}]}"
export GOVC_PASSWORD='${pool_passwords[${GOVC_URL}]}'
export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate
export SSL_CERT_FILE=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate
EOF

log "Creating vsphere_context.sh file..."
cp "${SHARED_DIR}/govc.sh" "${SHARED_DIR}/vsphere_context.sh"

log "Creating individual govc files for each pool..."
for _leaseJSON in "${SHARED_DIR}"/LEASE*; do
  # Skip the LEASE_single copy — the original named lease file covers the same content
  if [[ ${_leaseJSON} =~ "single" ]]; then
    continue
  fi

  # Get the number of pools in this lease's poolInfo array
  pool_count=$(jq -r '.status.poolInfo | length' < "${_leaseJSON}")

  if [[ "${pool_count}" == "null" || "${pool_count}" -eq 0 ]]; then
    log "No poolInfo found in ${_leaseJSON}, skipping"
    continue
  fi

  log "Processing ${pool_count} pool(s) from lease $(basename ${_leaseJSON})"

  # Iterate through each pool in the poolInfo array
  for ((pool_idx = 0; pool_idx < pool_count; pool_idx++)); do
    # Get the pool name from poolInfo
    pool_name=$(jq -r ".status.poolInfo[${pool_idx}].name" < "${_leaseJSON}")

    log "Processing pool: ${pool_name}"

    # Get envVars for this specific pool from envVarsMap using the pool name as key
    jq -r ".status.envVarsMap.\"${pool_name}\"" < "${_leaseJSON}" > /tmp/envvars_pool

    # Get topology info from poolInfo
    vcenter_cluster=$(jq -r ".status.poolInfo[${pool_idx}].topology.computeCluster" < "${_leaseJSON}")

    # Source the envVars to get vsphere_url and other variables
    # shellcheck source=/dev/null
    source /tmp/envvars_pool

    # Build resource pool path
    if [ $IPI -eq 0 ]; then
      vcenter_resource_pool=${vcenter_cluster}/Resources/${NAMESPACE}-${UNIQUE_HASH}
    else
      vcenter_resource_pool=${vcenter_cluster}/Resources/ipi-ci-clusters
    fi

    # Create a sanitized filename from the pool name
    # Pool names look like: vcenter-1.ci.ibmc.devcluster.openshift.com-cidatacenter-2-cicluster-3
    pool_filename=$(echo "${pool_name}" | tr '.' '_' | tr ':' '_')

    log "Creating govc_${pool_filename}.sh for pool ${pool_name}"
    cat >"${SHARED_DIR}/govc_${pool_filename}.sh" <<EOF
$(cat /tmp/envvars_pool)
export LEASE_PATH=${_leaseJSON}
export POOL_NAME=${pool_name}
export GOVC_INSECURE=1
export vsphere_resource_pool=${vcenter_resource_pool}
export GOVC_RESOURCE_POOL=${vcenter_resource_pool}
export cloud_where_run=IBM
export GOVC_USERNAME="${pool_usernames[${vsphere_url}]}"
export GOVC_PASSWORD='${pool_passwords[${vsphere_url}]}'
export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate
export SSL_CERT_FILE=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate
EOF
  done
done

# 1. Get the OpaqueNetwork (NSX-T port group) which is listed in LEASED_RESOURCE.
# 2. Select the virtual machines attached to network
# 3. list the path to the virtual machine via the managed object reference
# 4. skip the templates with ova
# 5. Power off and delete the virtual machine

# disable error checking in this section
# randomly delete may fail, this shouldn't cause an immediate issue
# but should eventually be cleaned up.

set +e
for LEASE in "${LEASES[@]}"; do
  jq -r '.status.envVars' > /tmp/envvars < "$SHARED_DIR/LEASE_$LEASE.json"

  declare vsphere_portgroup
  declare vsphere_datacenter

  # shellcheck source=/dev/null
  source /tmp/envvars

  export GOVC_USERNAME="${pool_usernames[$vsphere_url]}"
  export GOVC_PASSWORD="${pool_passwords[$vsphere_url]}"
  export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate

  echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${vsphere_portgroup} in DC ${vsphere_datacenter} and destroy"
  govc ls -json "${vsphere_portgroup}" |
  jq '.elements[]?.Object.Vm[]?.Value' |
  xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |
  jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |
  xargs -I {} --no-run-if-empty govc vm.destroy {}
done
set -e

for LEASE in "${SHARED_DIR}"/LEASE*; do
  if [[ $LEASE =~ "single" ]]; then
    continue
  fi

  # A lease can cover multiple pools (POOL_COUNT path) and each pool has its own
  # portgroup, so DVS info must be gathered per pool from poolInfo/envVarsMap.
  # Leases without poolInfo (legacy single-pool leases) fall back to the
  # top-level status fields.
  dvs_pool_count=$(jq -r '.status.poolInfo | length' "${LEASE}")
  if [[ "${dvs_pool_count}" != "null" && "${dvs_pool_count}" -gt 0 ]]; then
    for ((dvs_pool_idx = 0; dvs_pool_idx < dvs_pool_count; dvs_pool_idx++)); do
      dvs_pool_name=$(jq -r ".status.poolInfo[${dvs_pool_idx}].name" "${LEASE}")
      jq -r ".status.envVarsMap.\"${dvs_pool_name}\"" "${LEASE}" > /tmp/envvars

      # shellcheck source=/dev/null
      source /tmp/envvars

      log "checking ${LEASE} pool ${dvs_pool_name} and ${GOVC_NETWORK} for DVS UUID"

      export GOVC_USERNAME="${pool_usernames[$vsphere_url]}"
      export GOVC_PASSWORD="${pool_passwords[$vsphere_url]}"

      getDVSInfo "/${GOVC_DATACENTER}/network/${GOVC_NETWORK}"
    done
  else
    jq -r .status.envVars "${LEASE}" > /tmp/envvars

    # shellcheck source=/dev/null
    source /tmp/envvars

    log "checking ${LEASE} and ${GOVC_NETWORK} for DVS UUID"

    export GOVC_USERNAME="${pool_usernames[$vsphere_url]}"
    export GOVC_PASSWORD="${pool_passwords[$vsphere_url]}"

    getDVSInfo "/${GOVC_DATACENTER}/network/${GOVC_NETWORK}"
  fi
done

log "writing the platform spec"
echo "$platformSpec" > "${SHARED_DIR}"/platform.json
# poolName is internal bookkeeping (see failureDomains above) and is not part
# of the installer's VSphereFailureDomain schema, so strip it before this gets
# spliced into install-config.yaml's platform.vsphere section.
echo "$platformSpec" | jq -r 'del(.failureDomains[]?.poolName)' | jq -r yamlify2 | sed --expression='s/^/    /g' > "${SHARED_DIR}"/platform.yaml

# Save reserved networks for later use
if [[ "${RESERVE_EXTRA_NETWORK:-}" == "true" ]]; then
  log "Saving reserved networks to reserved_networks.json"
  reserved_spec='{}'
  for VCENTER in "${!vcenter_reserved_portgroups[@]}"; do
    networks="${vcenter_reserved_portgroups[$VCENTER]}"
    reserved_spec=$(echo "$reserved_spec" | jq -r --arg vcenter "$VCENTER" --arg networks "$networks" '.[$vcenter] = $networks')
  done
  echo "$reserved_spec" > "${SHARED_DIR}"/reserved_networks.json
  log "Reserved networks: $(cat "${SHARED_DIR}"/reserved_networks.json)"
fi