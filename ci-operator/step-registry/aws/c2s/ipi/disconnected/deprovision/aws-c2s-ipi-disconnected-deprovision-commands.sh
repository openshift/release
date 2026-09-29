#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Tear down a disconnected AWS C2S/SC2S cluster.
#
# C2S/SC2S secret regions are emulated in CI: the cluster's AWS API calls are
# intercepted through the bastion proxy, and they authenticate with short-lived
# credentials minted by the SHIFT provider (CAP for C2S, GEOAxIS for SC2S).
#
#   >= 4.12: destroy in the emulated environment, the same way the cluster was
#            installed. openshift-install gained in-environment destroy for the
#            us-iso/us-isob partitions in 4.13 (openshift/installer#7427,
#            OCPBUGS-17809), backported to 4.12 (#7474, OCPBUGS-18646), so 4.12 is
#            the earliest release that supports it. Install reads its credentials
#            from ${SHARED_DIR}/aws_temp_creds (see ipi-install-install-aws) which
#            the in-cluster cap-token-refresh CronJob keeps current; that snapshot
#            is stale by teardown and nothing refreshes our pod, so we re-mint a
#            fresh credential from the provider, then run "destroy cluster" with
#            the exact same env install used (aws_temp_creds + additional_trust_
#            bundle + proxy) and the region left untouched.
#
#   <= 4.11: the installer cannot destroy against the emulated endpoints, so fall
#            back to the historical workaround: rewrite the region in
#            metadata.json to the commercial source_region and destroy there
#            directly with the long-lived backing-account credentials
#            (${CLUSTER_PROFILE_DIR}/.awscred), no proxy.

# Returns 0 (true) if $1 >= $2. Same helper as aws-c2s-init-token-service.
function version_ge() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

REGION="${LEASED_RESOURCE}"

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit 0
fi

function save_logs() {
  if [[ -f /tmp/installer/.openshift_install.log ]]; then
    echo "Copying the installer log to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}" || true
  fi
}
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT

echo "Copying the installation artifacts to the installer's asset directory..."
cp -ar "${SHARED_DIR}" /tmp/installer

# Resolve the installer binary and read its version to pick the destroy strategy.
export INSTALLER_BINARY="openshift-install"
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "Extracting installer from ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
fi
echo "=============== openshift-install version =============="
${INSTALLER_BINARY} version
ocp_version=$(${INSTALLER_BINARY} version | awk '/^openshift-install /{print $2; exit}' | cut -d. -f1,2)
echo "OCP version: ${ocp_version}"

# Re-mint a fresh temporary credential from the SHIFT provider (CAP for C2S,
# GEOAxIS for SC2S) into ${SHARED_DIR}/aws_temp_creds. This is exactly part 1 of
# aws-c2s-init-token-service; every input comes from the cluster profile, so it
# is safe to repeat at teardown. The request must traverse the bastion proxy to
# reach the emulator, which is still up (the bastion is torn down later, by
# aws-deprovision-stacks).
function refresh_temp_creds() {
  local agency="SHIFT"
  local shift_project_setting="${CLUSTER_PROFILE_DIR}/shift_project_setting.json"
  local shift_project_name shift_ca_file
  local temp_cred_provider_endpoint temp_cred_provider_role
  local cred_provider_name temp_cred_request_url

  shift_project_name=$(jq -r ".\"${REGION}\".project_name" "${shift_project_setting}")
  shift_ca_file="${SHARED_DIR}/shift-ca-chain.cert.pem"
  cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" > "${shift_ca_file}"

  temp_cred_provider_endpoint=$(jq -r ".\"${REGION}\".temporary_credential_endpoint" "${shift_project_setting}")
  temp_cred_provider_role=$(jq -r ".\"${REGION}\".cross_account_role" "${shift_project_setting}")
  jq -r ".\"${REGION}\".cert" "${shift_project_setting}" | base64 -d > "${SHARED_DIR}/temp_cred_provider_cert.pem"
  jq -r ".\"${REGION}\".private_key" "${shift_project_setting}" | base64 -d > "${SHARED_DIR}/temp_cred_provider_private_key.pem"

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
  temp_cred_file=$(mktemp)

  # The credential request must originate inside the emulator, so route it
  # through the proxy.
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"

  set +o errexit
  while { [[ -z "${key_id}" || "${key_id}" == "null" || -z "${key_sec}" || "${key_sec}" == "null" ]]; } && [[ "${try}" -lt "${retries}" ]]; do
    echo "trying to get credential from ${cred_provider_name} endpoint $((try + 1))/${retries}"
    http_code=$(curl -sS -o "${temp_cred_file}" -w "%{http_code}" "${temp_cred_request_url}" \
      --cert "${SHARED_DIR}/temp_cred_provider_cert.pem" \
      --cacert "${shift_ca_file}" \
      --key "${SHARED_DIR}/temp_cred_provider_private_key.pem")
    curl_rc=$?
    key_id=$(jq -j .Credentials.AccessKeyId "${temp_cred_file}" 2>/dev/null)
    key_sec=$(jq -j .Credentials.SecretAccessKey "${temp_cred_file}" 2>/dev/null)
    if [[ -z "${key_id}" || "${key_id}" == "null" || -z "${key_sec}" || "${key_sec}" == "null" ]]; then
      # Redact any credential field values before logging the response body.
      echo "failed to get credential from ${cred_provider_name} endpoint (curl exit code: ${curl_rc}, HTTP status code: ${http_code})"
      echo "response payload content (credential values redacted):"
      sed -E 's/("(AccessKeyId|SecretAccessKey|SessionToken|Token)"[[:space:]]*:[[:space:]]*")[^"]*/\1[redacted]/g' "${temp_cred_file}"
      try=$((try + 1))
      sleep 60
    fi
  done
  set -o errexit

  # unset-proxy.sh is intentionally NOT sourced: the destroy that follows also
  # needs the proxy to reach the emulated AWS API.

  if [[ -z "${key_id}" || "${key_id}" == "null" || -z "${key_sec}" || "${key_sec}" == "null" ]]; then
    echo "ERROR: could not get AWS credential from ${cred_provider_name} after ${retries} attempts."
    return 1
  fi

  cat > "${SHARED_DIR}/aws_temp_creds" <<EOF
[default]
aws_access_key_id     = ${key_id}
aws_secret_access_key = ${key_sec}
EOF
}

if version_ge "${ocp_version}" "4.12"; then
  # ---- in-environment destroy (>= 4.12) ----
  echo "Destroying in the emulated C2S/SC2S environment (OCP ${ocp_version})."
  refresh_temp_creds
  export AWS_SHARED_CREDENTIALS_FILE="${SHARED_DIR}/aws_temp_creds"
  # Trust the emulator's TLS with the same bundle the installer used to create
  # the cluster.
  export AWS_CA_BUNDLE="${SHARED_DIR}/additional_trust_bundle"
else
  # ---- legacy destroy via commercial source_region (<= 4.11) ----
  echo "Destroying via the commercial source region (OCP ${ocp_version})."
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  sed -i "s/${REGION}/${source_region}/" "/tmp/installer/metadata.json"
fi

echo "Running the installer's 'destroy cluster' command..."
OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"; export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT
${INSTALLER_BINARY} --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

if [[ -s /tmp/installer/quota.json ]]; then
  cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

exit "${ret}"
