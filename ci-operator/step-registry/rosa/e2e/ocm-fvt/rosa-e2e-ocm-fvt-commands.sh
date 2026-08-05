#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${OCM_FVT_JOB_NAME:-}" ]]; then
  echo "ERROR: OCM_FVT_JOB_NAME is required but not set" >&2
  exit 1
fi

JOB_LINK="https://prow.ci.openshift.org/view/gs/test-platform-results/"
if [[ -n "${PULL_NUMBER:-}" ]]; then
  JOB_LINK="${JOB_LINK}pr-logs/pull/openshift_release/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  JOB_LINK="${JOB_LINK}logs/${JOB_NAME}/${BUILD_ID}"
fi

# Prow-only: Hive via ocm-backplane when OCM_FVT_USE_BACKPLANE=true (Jenkins/Tekton skip this).
hive_kubeconfig=""
hive_kubeconfig_src=""
hive_kubeconfig_raw=""
backplane_bin_dir=""
backplane_proxy_url=""
if [[ "${OCM_FVT_USE_BACKPLANE:-false}" == "true" ]]; then
  echo "=== OCM backplane login (Hive) ==="
  # (BACKPLANE_CLIENT_ID/SECRET env, or backplane_client_{id,secret} files).
  cred_dir="${OCM_FVT_BACKPLANE_CREDENTIALS_DIR:-/usr/local/rosa-clusters-service-sandbox}"
  # Disable tracing while reading backplane client credentials.
  [[ $- == *x* ]] && WAS_TRACING_BP=true || WAS_TRACING_BP=false
  set +x
  backplane_client_id="${BACKPLANE_CLIENT_ID:-}"
  backplane_client_secret="${BACKPLANE_CLIENT_SECRET:-}"
  if [[ -z "${backplane_client_id}" && -f "${cred_dir}/backplane_client_id" ]]; then
    backplane_client_id="$(cat "${cred_dir}/backplane_client_id")"
  fi
  if [[ -z "${backplane_client_secret}" && -f "${cred_dir}/backplane_client_secret" ]]; then
    backplane_client_secret="$(cat "${cred_dir}/backplane_client_secret")"
  fi
  $WAS_TRACING_BP && set -x
  if [[ -z "${backplane_client_id}" || -z "${backplane_client_secret}" ]]; then
    echo "ERROR: OCM_FVT_USE_BACKPLANE=true but backplane client credentials are missing" >&2
    echo "Expected BACKPLANE_CLIENT_ID/SECRET env or ${cred_dir}/backplane_client_{id,secret}" >&2
    echo "(CS mounts these from ci/rosa-clusters-service-sandbox)" >&2
    exit 1
  fi
  echo "Using backplane credentials from ${cred_dir} (or env)"

  # Defaults match rosa-e2e-ocm-fvt*-ref.yaml; override via job/workflow env if needed.
  backplane_cluster_id="${OCM_FVT_BACKPLANE_CLUSTER_ID:-1g268u7pp694gj152nj16me4sv615lpv}"
  backplane_ocm_url="${OCM_FVT_BACKPLANE_OCM_URL:-https://api.openshift.com}"
  backplane_proxy_url="${OCM_FVT_BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
  backplane_elevate_reason="${OCM_FVT_BACKPLANE_ELEVATE_REASON:-https://issues.redhat.com/browse/ROSAENG-62717}"

  backplane_bin_dir="$(mktemp -d /tmp/ocm-backplane-bin.XXXXXX)"
  export PATH="${backplane_bin_dir}:${PATH}"

  echo "Installing ocm CLI into ${backplane_bin_dir}"
  curl -sSL -o "${backplane_bin_dir}/ocm" \
    "https://github.com/openshift-online/ocm-cli/releases/download/v1.0.15/ocm-linux-amd64"
  chmod 0755 "${backplane_bin_dir}/ocm"

  echo "Installing ocm-backplane CLI into ${backplane_bin_dir}"
  bp_ver="0.11.0"
  bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
  curl -sSL -o "${bp_tar}" \
    "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"
  tar -xzf "${bp_tar}" -C "${backplane_bin_dir}" ocm-backplane
  chmod 0755 "${backplane_bin_dir}/ocm-backplane"
  rm -f "${bp_tar}"

  # nested-podman image has no oc; ocm-backplane login/elevate invoke it.
  echo "Installing oc CLI into ${backplane_bin_dir}"
  oc_tar="$(mktemp /tmp/openshift-client.XXXXXX.tar.gz)"
  curl -sSL -o "${oc_tar}" \
    "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz"
  tar -xzf "${oc_tar}" -C "${backplane_bin_dir}" oc
  chmod 0755 "${backplane_bin_dir}/oc"
  rm -f "${oc_tar}"

  mkdir -p "${HOME}/.config/backplane"
  printf '{"proxy-url":"%s"}\n' "${backplane_proxy_url}" > "${HOME}/.config/backplane/config.json"

  # Pin kubeconfig path — Prow may set KUBECONFIG elsewhere; sed must read the same file login writes.
  hive_kubeconfig_src="$(mktemp /tmp/backplane-kubeconfig.XXXXXX)"
  rm -f "${hive_kubeconfig_src}"
  export KUBECONFIG="${hive_kubeconfig_src}"

  # Disable tracing due to client-secret handling on ocm login.
  [[ $- == *x* ]] && WAS_TRACING_BP=true || WAS_TRACING_BP=false
  set +x
  ocm login \
    --client-id="${backplane_client_id}" \
    --client-secret="${backplane_client_secret}" \
    --url="${backplane_ocm_url}"
  ocm-backplane login "${backplane_cluster_id}"
  $WAS_TRACING_BP && set -x
  # Warm elevate reason; Impersonate is only on elevate's temp kubeconfig.
  ocm-backplane elevate "${backplane_elevate_reason}" -- whoami

  if [[ ! -f "${KUBECONFIG}" ]]; then
    echo "ERROR: backplane login did not write kubeconfig at ${KUBECONFIG}" >&2
    exit 1
  fi

  # Dump elevate's Impersonate kubeconfig for AAO (do not log contents).
  hive_kubeconfig="$(mktemp /tmp/hive-kubeconfig.XXXXXX)"
  hive_kubeconfig_raw="$(mktemp /tmp/hive-kubeconfig-raw.XXXXXX)"
  chmod 0600 "${hive_kubeconfig}" "${hive_kubeconfig_raw}"
  [[ $- == *x* ]] && WAS_TRACING_ELEV=true || WAS_TRACING_ELEV=false
  set +x
  if ! ocm-backplane elevate "${backplane_elevate_reason}" -- \
    config view --raw --minify > "${hive_kubeconfig_raw}"; then
    $WAS_TRACING_ELEV && set -x
    echo "ERROR: failed to dump elevated backplane kubeconfig" >&2
    rm -f "${hive_kubeconfig_raw}"
    exit 1
  fi
  $WAS_TRACING_ELEV && set -x
  if ! grep -q 'backplane-cluster-admin' "${hive_kubeconfig_raw}"; then
    echo "ERROR: elevated kubeconfig missing Impersonate backplane-cluster-admin" >&2
    rm -f "${hive_kubeconfig_raw}"
    exit 1
  fi

  # Host-path check before container exec rewrite; name only (no secret data).
  if [[ "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
    aao_probe_secret="${OCM_FVT_AAO_PROBE_SECRET:-d4ncjp595tqc73dupto0-account-creds}"
    echo "=== elevated AAO kubeconfig check (name only) ==="
    oc --kubeconfig "${hive_kubeconfig_raw}" --request-timeout=60s \
      get secret "${aao_probe_secret}" -n osd-fleet-manager-aao -o name
    echo "=== end elevated AAO kubeconfig check ==="
  fi

  # Point exec plugins at binaries mounted into the ocmci container.
  sed -E \
    -e 's|command:[[:space:]]*ocm-backplane([[:space:]]*$)|command: /usr/local/backplane-bin/ocm-backplane\1|' \
    -e 's|command:[[:space:]]*ocm([[:space:]]*$)|command: /usr/local/backplane-bin/ocm\1|' \
    "${hive_kubeconfig_raw}" > "${hive_kubeconfig}"
  chmod 0600 "${hive_kubeconfig}"
  rm -f "${hive_kubeconfig_raw}"

  echo "Elevated backplane kubeconfig ready for cluster ${backplane_cluster_id}"
  echo "================================"
fi

old_umask=$(umask)
umask 077
podman_env_file="$(mktemp /tmp/podman.env.XXXXXX)"
trap 'rm -f "${podman_env_file}"; rm -f "${hive_kubeconfig:-}" "${hive_kubeconfig_src:-}" "${hive_kubeconfig_raw:-}"' EXIT
umask "${old_umask}"

{
  echo "AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-cred"
  echo "SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-shared-vpc-credentials"
  echo "JOB_LINK=${JOB_LINK}"
  echo "SLACK_WEBHOOK_URL=$(cat /usr/local/cs-qe-credentials/slack_webhook_url)"
  echo "CONSOLE_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/console_client_secret)"
} > "${podman_env_file}"

if [[ -n "${hive_kubeconfig}" ]]; then
  # Corp proxy + backplane PATH/HOME for Hive/AAO from the farm.
  echo "PATH=/usr/local/backplane-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> "${podman_env_file}"
  echo "HOME=/home/ci-user" >> "${podman_env_file}"
  echo "HTTPS_PROXY=${backplane_proxy_url}" >> "${podman_env_file}"
  echo "HTTP_PROXY=${backplane_proxy_url}" >> "${podman_env_file}"
  echo "https_proxy=${backplane_proxy_url}" >> "${podman_env_file}"
  echo "http_proxy=${backplane_proxy_url}" >> "${podman_env_file}"
fi

if [[ "${OCM_FVT_REPORT_JIRA:-true}" == "true" ]]; then
  echo "ENABLE_JIRA_REPORTING=true" >> "${podman_env_file}"
fi

if [[ -n "${OCM_FVT_OCM_ENV:-}" ]]; then
  echo "OCM_ENV=${OCM_FVT_OCM_ENV}" >> "${podman_env_file}"
fi

if [[ -n "${OCM_FVT_EXTRA_ENVS:-}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    echo "${line}" >> "${podman_env_file}"
  done <<< "${OCM_FVT_EXTRA_ENVS}"
fi

osdfm_qe_creds_dir=/usr/local/osdfm-qe-credentials
aao_kubeconfig_env=()
# Prow: elevated kubeconfig path. Else vault content (Tekton/Jenkins).
if [[ -n "${hive_kubeconfig}" && "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  echo "AWS_ACCOUNT_OPERATOR_KUBECONFIG=/credentials-hive/kubeconfig" >> "${podman_env_file}"
elif [[ -f "${osdfm_qe_creds_dir}/aws_account_operator_kubeconfig" ]]; then
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  aao_kubeconfig_env=("-e" "AWS_ACCOUNT_OPERATOR_KUBECONFIG=$(<"${osdfm_qe_creds_dir}/aws_account_operator_kubeconfig")")
  $WAS_TRACING && set -x
elif [[ "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  echo "ERROR: osdfm AAO tests need elevated backplane kubeconfig or ${osdfm_qe_creds_dir}/aws_account_operator_kubeconfig" >&2
  exit 1
fi

# DR_AWS_CREDENTIALS lets DR-account validation tests (e.g. OSDFM disaster_recovery_test.go,
# oadp_v2_mc_backup_test.go) use a static, single-region AWS credentials file instead of fetching
# per-region creds live from Hive (build farm has no network route to Hive, see ROSAENG-60596).
dr_aws_creds_env=()
if [[ -f "${osdfm_qe_creds_dir}/aws_dr_cred" ]]; then
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  dr_aws_creds_env=("-e" "DR_AWS_CREDENTIALS=$(<"${osdfm_qe_creds_dir}/aws_dr_cred")")
  $WAS_TRACING && set -x
fi

cred_sources='source /usr/local/cs-qe-credentials/ocm-tokens'
if [[ "${OCM_FVT_REPORT_JIRA:-true}" == "true" ]]; then
  cred_sources="${cred_sources}; source /usr/local/cs-qe-credentials/jira-cred"
fi

env -i bash --norc --noprofile -c "
  ${cred_sources}
  env | grep -v '^_='
" >> "${podman_env_file}"

podman_args=(
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson
  --env-file "${podman_env_file}"
  "-v" "/usr/local/cs-qe-credentials:/credentials:ro,z"
)

if [[ -n "${hive_kubeconfig}" ]]; then
  podman_args+=(
    "-v" "${hive_kubeconfig}:/credentials-hive/kubeconfig:ro,z"
    "-v" "${backplane_bin_dir}:/usr/local/backplane-bin:ro,z"
    "-v" "${HOME}/.config:/home/ci-user/.config:ro,z"
  )
fi

if [[ "${OCM_FVT_GCP_CREDS:-false}" == "true" ]]; then
  podman_args+=(
    "-v" "/usr/local/cs-qe-credentials/osd-ccs-admin.json:/home/ci-user/.gcp/osd-ccs-admin.json:ro,z"
  )
fi

ocm_fvt_output="${ARTIFACT_DIR}/ocm-fvt-results"
mkdir -p "${ocm_fvt_output}"
chmod 1777 "${ocm_fvt_output}"
podman_args+=("-v" "${ocm_fvt_output}:/ocm-backend-tests/output:z")
podman_args+=(--rm)

ocmtest_args=(test --service "${OCM_FVT_SERVICE:-cms}" --job "${OCM_FVT_JOB_NAME}")
if [[ "${OCM_FVT_REPORT_JIRA:-true}" == "true" ]]; then
  ocmtest_args+=(--reportJiraTicket)
fi

echo "=== ocmci image digest ==="
podman pull \
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest
podman inspect \
  --format '{{index .RepoDigests 0}}' \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest \
  || echo "WARNING: failed to get ocmci image digest"
echo "=========================="

echo "Running ocmtest: ${ocmtest_args[*]}"
exit_code=0
# Keep xtrace off while secret env args are expanded.
[[ $- == *x* ]] && WAS_TRACING_RUN=true || WAS_TRACING_RUN=false
set +x
podman run \
  "${podman_args[@]}" \
  "${aao_kubeconfig_env[@]}" \
  "${dr_aws_creds_env[@]}" \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest \
  ocmtest "${ocmtest_args[@]}" || exit_code=$?
$WAS_TRACING_RUN && set -x

# Copy only the merged report.xml to avoid inflated test counts from
# per-phase XMLs that include all Ginkgo specs (including skipped).
find "${ocm_fvt_output}" -type f -name 'report.xml' -print0 | while IFS= read -r -d '' xml_file; do
  cp "${xml_file}" "${ARTIFACT_DIR}/junit-ocm-fvt-report.xml"
done

# Record the test result so post steps (e.g. stage promotion) can tell
# whether it is safe to act on this run instead of always running.
echo "${exit_code}" > "${SHARED_DIR}/ocm-fvt-exit-code" 2>/dev/null || true

exit "${exit_code}"
