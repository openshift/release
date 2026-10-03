#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck disable=SC1090
source "$LEASE_PROXY_CLIENT_SH"
install_lease_handle=''

function acquire_install_lease() {
  if ! lease__install_lease_eligible; then
      return 0
  fi

  install_lease_handle=$(lease__acquire --type="${CLUSTER_PROFILE_SET_NAME}--${CLUSTER_PROFILE_NAME}--install-quota-slice" --scope=step)
  printf 'Install lease acquired at %s: %s\n' "$(date "+%F %X")" "$(lease__cat --handle="$install_lease_handle" --format=csv)"
}

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

acquire_install_lease || true

function on_exit() {
    lease__release --handle="$install_lease_handle" || true
    save_logs
}

function save_logs() {
    echo "Copying the Installer logs and metadata to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'on_exit' EXIT TERM

export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
  echo "Setting AWS credential with minimal permision for installer"
  export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
else
  export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
fi

export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
if [ -f "${SHARED_DIR}/gcp_min_permissions.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the minimum permissions testing on GCP..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/gcp_min_permissions.json"
elif [ -f "${SHARED_DIR}/user_tags_sa.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the userTags testing on GCP..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/user_tags_sa.json"
elif [ -f "${SHARED_DIR}/xpn_min_perm_passthrough.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_min_perm_passthrough.json"
elif [ -f "${SHARED_DIR}/xpn_min_perm_cco_manual.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC with CCO in Manual mode..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_min_perm_cco_manual.json"
elif [ -f "${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC using BYO hosted zone..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json"
fi
export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

if [[ "${CLUSTER_TYPE}" == "ibmcloud"* ]]; then
  if [ -f "${SHARED_DIR}/ibmcloud-min-permission-api-key" ]; then
    IC_API_KEY="$(< "${SHARED_DIR}/ibmcloud-min-permission-api-key")"
  else
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  fi
  export IC_API_KEY
fi
if [[ "${CLUSTER_TYPE}" == "vsphere"* ]]; then
    cp /var/run/vsphere-ibmcloud-ci/vcenter-certificate /tmp/ca-bundle.pem
    if [ -f "${SHARED_DIR}/additional_ca_cert.pem" ]; then
      echo "additional CA bundle found, appending it to the bundle from vault"
      echo -n $'\n' >> /tmp/ca-bundle.pem
      cat "${SHARED_DIR}/additional_ca_cert.pem" >> /tmp/ca-bundle.pem
    fi
    export SSL_CERT_FILE=/tmp/ca-bundle.pem
fi

echo ${SHARED_DIR}/metadata.json
if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
    echo "Setting AZURE credential with minimal permissions for installer"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure_minimal_permission
elif [[ -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
    echo "Setting AZURE credential with Contributor role only for installer"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure-sp-contributor.json
fi

if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
  export AZURE_AUTH_LOCATION=$SHARED_DIR/osServicePrincipal.json
  if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
  fi
fi

echo "Copying the installation artifacts to the Installer's asset directory..."
cp -ar "${SHARED_DIR}" /tmp/installer

export INSTALLER_BINARY="openshift-install"
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
        echo "Extracting installer from ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
        oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --command=openshift-install --to="/tmp" || exit 1
        export INSTALLER_BINARY="/tmp/openshift-install"
fi
echo "=============== openshift-install version =============="
${INSTALLER_BINARY} version
if ! ocp_version=$(${INSTALLER_BINARY} version 2>/dev/null | awk 'NR==1{print $2}') || [[ -z "${ocp_version}" ]]; then
  echo "Unable to determine the installer version" >&2
  exit 1
fi

function version_ge() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

# Re-mint a fresh temporary credential from the SHIFT provider (CAP for C2S,
# GEOAxIS for SC2S). The snapshot in ${SHARED_DIR}/aws_temp_creds is stale by
# teardown; only the in-cluster CronJob refreshes it during the run. All
# ephemeral material is written to /tmp — nothing here needs to outlive this step.
function refresh_temp_creds() {
  local agency="SHIFT"
  local shift_project_setting="${CLUSTER_PROFILE_DIR}/shift_project_setting.json"
  local shift_project_name
  local temp_cred_provider_endpoint temp_cred_provider_role
  local cred_provider_name temp_cred_request_url
  local shift_ca_file cert_file key_file

  shift_ca_file=$(mktemp /tmp/shift-ca-XXXXXX.pem)
  cert_file=$(mktemp /tmp/shift-cert-XXXXXX.pem)
  key_file=$(mktemp /tmp/shift-key-XXXXXX.pem)

  cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" > "${shift_ca_file}"
  shift_project_name=$(jq -r ".\"${LEASED_RESOURCE}\".project_name" "${shift_project_setting}")
  temp_cred_provider_endpoint=$(jq -r ".\"${LEASED_RESOURCE}\".temporary_credential_endpoint" "${shift_project_setting}")
  temp_cred_provider_role=$(jq -r ".\"${LEASED_RESOURCE}\".cross_account_role" "${shift_project_setting}")

  # Disable tracing around key material extraction.
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  jq -r ".\"${LEASED_RESOURCE}\".cert" "${shift_project_setting}" | base64 -d > "${cert_file}"
  jq -r ".\"${LEASED_RESOURCE}\".private_key" "${shift_project_setting}" | base64 -d > "${key_file}"
  ${WAS_TRACING} && set -x || true

  if [[ "${CLUSTER_TYPE}" == "aws-c2s" ]]; then
    cred_provider_name="CAP"
    temp_cred_request_url="${temp_cred_provider_endpoint}?agency=${agency}&mission=${shift_project_name}&role=${temp_cred_provider_role}"
  else
    cred_provider_name="GEOAxIS"
    temp_cred_request_url="${temp_cred_provider_endpoint}?agency=${agency}&accountName=${shift_project_name}&roleName=${temp_cred_provider_role}"
  fi

  local key_id="" key_sec="" http_code="" curl_rc=""
  local try=0 retries=5
  local temp_cred_file
  temp_cred_file=$(mktemp /tmp/shift-resp-XXXXXX.json)

  # Credential request must traverse the bastion proxy to reach the emulator.
  # proxy-conf.sh is intentionally not unset afterward — destroy also needs the
  # proxy to reach the emulated AWS API.
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"

  set +o errexit
  while { [[ -z "${key_id}" || "${key_id}" == "null" || -z "${key_sec}" || "${key_sec}" == "null" ]]; } && [[ "${try}" -lt "${retries}" ]]; do
    echo "trying to get credential from ${cred_provider_name} endpoint $((try + 1))/${retries}"
    http_code=$(curl -sS -o "${temp_cred_file}" -w "%{http_code}" "${temp_cred_request_url}" \
      --cert "${cert_file}" \
      --cacert "${shift_ca_file}" \
      --key "${key_file}")
    curl_rc=$?
    key_id=$(jq -j .Credentials.AccessKeyId "${temp_cred_file}" 2>/dev/null)
    key_sec=$(jq -j .Credentials.SecretAccessKey "${temp_cred_file}" 2>/dev/null)
    if [[ -z "${key_id}" || "${key_id}" == "null" || -z "${key_sec}" || "${key_sec}" == "null" ]]; then
      echo "failed to get credential from ${cred_provider_name} endpoint (curl exit code: ${curl_rc}, HTTP status code: ${http_code})"
      echo "response payload content (credential values redacted):"
      sed -E 's/("(AccessKeyId|SecretAccessKey|SessionToken|Token)"[[:space:]]*:[[:space:]]*")[^"]*/\1[redacted]/g' "${temp_cred_file}"
      try=$((try + 1))
      sleep 60
    fi
  done
  set -o errexit

  if [[ -z "${key_id}" || "${key_id}" == "null" || -z "${key_sec}" || "${key_sec}" == "null" ]]; then
    echo "ERROR: could not get AWS credential from ${cred_provider_name} after ${retries} attempts."
    return 1
  fi

  set +x
  cat > /tmp/aws_temp_creds <<EOF
[default]
aws_access_key_id     = ${key_id}
aws_secret_access_key = ${key_sec}
EOF
  ${WAS_TRACING} && set -x || true
}

if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  if version_ge "${ocp_version}" "4.23"; then
    # In-environment destroy for 4.23+ (and 5.0+): re-mint a fresh credential
    # from the SHIFT provider (stale by teardown) and destroy through the proxy.
    echo "C2S/SC2S: installer ${ocp_version} >= 4.23; refreshing credentials and destroying in-environment (region: ${LEASED_RESOURCE})"
    refresh_temp_creds
    export AWS_SHARED_CREDENTIALS_FILE="/tmp/aws_temp_creds"
    export AWS_CA_BUNDLE="${SHARED_DIR}/additional_trust_bundle"
  else
    # Installers < 4.23: fall back to rewriting the iso region in metadata.json
    # to source_region (us-east-1) and destroying in commercial AWS directly.
    echo "C2S/SC2S: installer ${ocp_version} < 4.23; falling back to source-region destroy"
    curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq && chmod +x /tmp/jq
    source_region=$(/tmp/jq -r ".\"${LEASED_RESOURCE}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
    sed -i "s/${LEASED_RESOURCE}/${source_region}/" "/tmp/installer/metadata.json"
  fi
fi

# TODO: remove once BZ#1926093 is done and backported
if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
  echo "Destroy bootstrap ..."
  set +e
  ${INSTALLER_BINARY} --dir /tmp/installer destroy bootstrap
  set -e
fi

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
    if version_ge "${ocp_version}" "4.23"; then
      # proxy-conf.sh already sourced inside refresh_temp_creds(); no-op here.
      echo "C2S/SC2S: bastion proxy already set for in-environment destroy"
    else
      echo "proxy-conf.sh detected, but not required by C2S/SC2S while destroying cluster (< 4.23), skip proxy setting"
    fi
  elif [[ "${CLUSTER_TYPE}" = "azure4" ]]; then
    # when bastion host is provisioned in cluster resource group, once the bastion is destroyed in the destroy process,
    # the running destroy process would be interrupted and failed. E.g: azure-ipi-public-to-private jobs.
    echo "proxy-conf.sh detected, but not required by azure4 clusters while destroying cluster, skip proxy setting"
  else
    echo "Private cluster setting proxy"
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
fi

if [[ "${CLUSTER_TYPE}" == "nutanix" ]]; then
  if [[ -f "${CLUSTER_PROFILE_DIR}/prismcentral.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/prismcentral.pem"
  fi
fi

echo "Running the Installer's 'destroy cluster' command..."
OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"; export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT
${INSTALLER_BINARY} --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

if [[ -s /tmp/installer/quota.json ]]; then
        cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

exit "$ret"
