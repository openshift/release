#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${OCM_FVT_JOB_NAME:-}" ]]; then
  echo "ERROR: OCM_FVT_JOB_NAME is required but not set" >&2
  exit 1
fi

JOB_LINK="https://prow.ci.openshift.org/view/gs/test-platform-results-public/"
if [[ -n "${PULL_NUMBER:-}" ]]; then
  JOB_LINK="${JOB_LINK}pr-logs/pull/openshift_release/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  JOB_LINK="${JOB_LINK}logs/${JOB_NAME}/${BUILD_ID}"
fi

# Backplane Hive login (Prow only; Tekton uses vault).
hive_kubeconfig=""
hive_kubeconfig_src=""
backplane_bin_dir=""
backplane_proxy_url=""
if [[ "${OCM_FVT_USE_BACKPLANE:-false}" == "true" ]]; then
  echo "=== OCM backplane login (Hive) ==="
  cred_dir="${OCM_FVT_BACKPLANE_CREDENTIALS_DIR:-/usr/local/rosa-clusters-service-sandbox}"
  # Do not trace credential reads.
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
    echo "(mount Prow secret ci/rosa-clusters-service-sandbox; see longrunning ref)" >&2
    exit 1
  fi
  echo "Using backplane credentials from ${cred_dir} (or env)"

  # Defaults match *-ref.yaml; CLI versions align with rosa-clusters-service build/backplane.py.
  backplane_cluster_id="${OCM_FVT_BACKPLANE_CLUSTER_ID:-1g268u7pp694gj152nj16me4sv615lpv}"
  backplane_ocm_url="${OCM_FVT_BACKPLANE_OCM_URL:-https://api.openshift.com}"
  backplane_proxy_url="${OCM_FVT_BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
  backplane_elevate_reason="${OCM_FVT_BACKPLANE_ELEVATE_REASON:-https://issues.redhat.com/browse/ROSAENG-62717}"
  ocm_ver="${OCM_FVT_OCM_CLI_VERSION:-1.0.15}"
  bp_ver="${OCM_FVT_BACKPLANE_CLI_VERSION:-0.11.0}"
  oc_ver="${OCM_FVT_OC_VERSION:-stable}"

  backplane_bin_dir="$(mktemp -d /tmp/ocm-backplane-bin.XXXXXX)"
  export PATH="${backplane_bin_dir}:${PATH}"

  echo "Installing ocm CLI v${ocm_ver} into ${backplane_bin_dir}"
  curl -sSL --fail --connect-timeout 30 --max-time 300 -o "${backplane_bin_dir}/ocm" \
    "https://github.com/openshift-online/ocm-cli/releases/download/v${ocm_ver}/ocm-linux-amd64"
  chmod 0755 "${backplane_bin_dir}/ocm"

  echo "Installing ocm-backplane CLI v${bp_ver} into ${backplane_bin_dir}"
  bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
  curl -sSL --fail --connect-timeout 30 --max-time 300 -o "${bp_tar}" \
    "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"
  tar -xzf "${bp_tar}" -C "${backplane_bin_dir}" ocm-backplane
  chmod 0755 "${backplane_bin_dir}/ocm-backplane"
  rm -f "${bp_tar}"

  # nested-podman image has no oc.
  echo "Installing oc CLI (${oc_ver}) into ${backplane_bin_dir}"
  oc_tar="$(mktemp /tmp/openshift-client.XXXXXX.tar.gz)"
  curl -sSL --fail --connect-timeout 30 --max-time 600 -o "${oc_tar}" \
    "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${oc_ver}/openshift-client-linux.tar.gz"
  tar -xzf "${oc_tar}" -C "${backplane_bin_dir}" oc
  chmod 0755 "${backplane_bin_dir}/oc"
  rm -f "${oc_tar}"

  mkdir -p "${HOME}/.config/backplane"
  printf '{"proxy-url":"%s"}\n' "${backplane_proxy_url}" > "${HOME}/.config/backplane/config.json"

  # Fixed path for backplane login kubeconfig.
  hive_kubeconfig_src="$(mktemp /tmp/backplane-kubeconfig.XXXXXX)"
  rm -f "${hive_kubeconfig_src}"
  export KUBECONFIG="${hive_kubeconfig_src}"

  # Do not trace ocm login secrets.
  [[ $- == *x* ]] && WAS_TRACING_BP=true || WAS_TRACING_BP=false
  set +x
  ocm login \
    --client-id="${backplane_client_id}" \
    --client-secret="${backplane_client_secret}" \
    --url="${backplane_ocm_url}"
  ocm-backplane login "${backplane_cluster_id}"
  $WAS_TRACING_BP && set -x
  # Verify elevation before kubeconfig dump.
  ocm-backplane elevate "${backplane_elevate_reason}" -- whoami

  if [[ ! -f "${KUBECONFIG}" ]]; then
    echo "ERROR: backplane login did not write kubeconfig at ${KUBECONFIG}" >&2
    exit 1
  fi
  chmod 0600 "${hive_kubeconfig_src}"

  # Elevated kubeconfig for osdfm AAO secret reads.
  hive_kubeconfig="$(mktemp /tmp/hive-kubeconfig.XXXXXX)"
  chmod 0600 "${hive_kubeconfig}"
  [[ $- == *x* ]] && WAS_TRACING_ELEV=true || WAS_TRACING_ELEV=false
  set +x
  if ! ocm-backplane elevate "${backplane_elevate_reason}" -- \
    config view --raw --minify > "${hive_kubeconfig}"; then
    $WAS_TRACING_ELEV && set -x
    echo "ERROR: failed to dump elevated backplane kubeconfig" >&2
    rm -f "${hive_kubeconfig}"
    hive_kubeconfig=""
    exit 1
  fi
  $WAS_TRACING_ELEV && set -x
  if ! grep -q 'backplane-cluster-admin' "${hive_kubeconfig}"; then
    echo "ERROR: elevated kubeconfig missing Impersonate backplane-cluster-admin" >&2
    rm -f "${hive_kubeconfig}"
    hive_kubeconfig=""
    exit 1
  fi

  echo "Elevated backplane kubeconfig ready for cluster ${backplane_cluster_id}"
  echo "================================"
fi

old_umask=$(umask)
umask 077
podman_env_file="$(mktemp /tmp/podman.env.XXXXXX)"
cleanup_ocm_fvt() {
  rm -f "${podman_env_file}" "${hive_kubeconfig:-}" "${hive_kubeconfig_src:-}"
}
trap cleanup_ocm_fvt EXIT
umask "${old_umask}"

{
  echo "AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-cred"
  echo "SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-shared-vpc-credentials"
  echo "JOB_LINK=${JOB_LINK}"
  echo "SLACK_WEBHOOK_URL=$(cat /usr/local/cs-qe-credentials/slack_webhook_url)"
  echo "CONSOLE_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/console_client_secret)"
} > "${podman_env_file}"

if [[ -n "${hive_kubeconfig}" ]]; then
  # Let podman refresh backplane tokens (proxy + CLI on PATH).
  echo "PATH=/usr/local/backplane-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> "${podman_env_file}"
  echo "HOME=/home/ci-user" >> "${podman_env_file}"
  echo "HTTPS_PROXY=${backplane_proxy_url}" >> "${podman_env_file}"
  echo "HTTP_PROXY=${backplane_proxy_url}" >> "${podman_env_file}"
  echo "https_proxy=${backplane_proxy_url}" >> "${podman_env_file}"
  echo "http_proxy=${backplane_proxy_url}" >> "${podman_env_file}"
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

# Simple backplane credential export from cs-qe-credentials.
if [[ "${OCM_FVT_BACKPLANE_CREDS:-false}" == "true" ]]; then
  if [[ -f /usr/local/cs-qe-credentials/backplane_client_id ]]; then
    echo "BACKPLANE_CLIENT_ID=$(cat /usr/local/cs-qe-credentials/backplane_client_id)" >> "${podman_env_file}"
  fi
  if [[ -f /usr/local/cs-qe-credentials/backplane_client_secret ]]; then
    echo "BACKPLANE_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/backplane_client_secret)" >> "${podman_env_file}"
  fi
  echo "HTTPS_PROXY=$(cat /usr/local/cs-qe-credentials/backplane_proxy_url)" >> "${podman_env_file}"
fi

osdfm_qe_creds_dir=/usr/local/osdfm-qe-credentials
aao_kubeconfig_env=()
# AAO kubeconfig: backplane (Prow) or mounted file (Tekton/Jenkins).
if [[ -n "${hive_kubeconfig}" && "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  aao_kubeconfig_env=("-e" "AWS_ACCOUNT_OPERATOR_KUBECONFIG=$(<"${hive_kubeconfig}")")
  $WAS_TRACING && set -x
elif [[ -f "${osdfm_qe_creds_dir}/aws_account_operator_kubeconfig" ]]; then
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  aao_kubeconfig_env=("-e" "AWS_ACCOUNT_OPERATOR_KUBECONFIG=$(<"${osdfm_qe_creds_dir}/aws_account_operator_kubeconfig")")
  $WAS_TRACING && set -x
elif [[ "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  echo "ERROR: osdfm AAO tests need elevated backplane kubeconfig or ${osdfm_qe_creds_dir}/aws_account_operator_kubeconfig" >&2
  exit 1
fi

# Static DR creds; build farm cannot reach Hive (ROSAENG-60596).
dr_aws_creds_env=()
if [[ -f "${osdfm_qe_creds_dir}/aws_dr_cred" ]]; then
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  dr_aws_creds_env=("-e" "DR_AWS_CREDENTIALS=$(<"${osdfm_qe_creds_dir}/aws_dr_cred")")
  $WAS_TRACING && set -x
fi

# ECR mirror list for zero-egress test (@id_76488).
zero_egress_env=()
if [[ "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  ecr_account=""
  ecr_regions=()
  case "${OCM_FVT_OCM_ENV:-}" in
    integration|int)
      ecr_account="816069139099"
      ecr_regions=("us-west-2")
      ;;
    stage|staging)
      ecr_account="122610517469"
      ecr_regions=("us-east-1" "us-west-2")
      ;;
    production|prod) ;; # prod test skips ECR config
    *)
      echo "WARNING: ZERO_EGRESS_ECR_CONFIG not generated for OCM_FVT_OCM_ENV=${OCM_FVT_OCM_ENV:-<empty>}" >&2
      ;;
  esac
  if [[ -n "${ecr_account}" ]]; then
    ecr_replicas=(ocp-mirror-1 ocp-mirror-2 ocp-mirror-3 ocp-mirror-4 ocp-mirror-5
      ocp-mirror-6 ocp-mirror-7 ocp-mirror-8 ocp-mirror-9 ocp-mirror-10 app-sre)
    ecr_cfg="ecr_regions:"
    for ecr_region in "${ecr_regions[@]}"; do
      ecr_cfg+=$'\n'"- region: ${ecr_region}"
      ecr_cfg+=$'\n'"  urls:"
      for ecr_replica in "${ecr_replicas[@]}"; do
        ecr_cfg+=$'\n'"    - ${ecr_account}.dkr.ecr.${ecr_region}.amazonaws.com/${ecr_replica}"
      done
    done
    zero_egress_env=("-e" "ZERO_EGRESS_ECR_CONFIG=${ecr_cfg}")
  fi
fi

cred_sources='source /usr/local/cs-qe-credentials/ocm-tokens'

env -i bash --norc --noprofile -c "
  ${cred_sources}
  env | grep -v '^_='
" >> "${podman_env_file}"

# SREP service account: use backplane client credentials so tests don't depend
# on expiring offline tokens for the SREP role.
if [[ -f /usr/local/cs-qe-credentials/backplane_client_id && -f /usr/local/cs-qe-credentials/backplane_client_secret ]]; then
  [[ $- == *x* ]] && WAS_TRACING_SREP=true || WAS_TRACING_SREP=false
  set +x
  echo "SREP_CLIENT_ID=$(cat /usr/local/cs-qe-credentials/backplane_client_id)" >> "${podman_env_file}"
  echo "SREP_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/backplane_client_secret)" >> "${podman_env_file}"
  $WAS_TRACING_SREP && set -x
fi

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

# ROSAENG-67791: osdfm metrics/alerts query RHOBS (in-cluster prometheus-app-sre PF removed).
if [[ "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  echo "=== RHOBS metrics endpoint (osdfm post-alerts) ==="
  ocm_env_lower="$(echo "${OCM_FVT_OCM_ENV:-integration}" | tr '[:upper:]' '[:lower:]')"
  case "${ocm_env_lower}" in
    production|prod)
      rhobs_oidc_dir="${OCM_FVT_RHOBS_OIDC_DIR:-/usr/local/rhobs-oidc-production}"
      rhobs_metrics_url="${OCM_FVT_PROMETHEUS_URL:-https://us-east-1-0.rhobs.api.openshift.com/api/metrics/v1/hcp}"
      ;;
    *)
      # integration + stage OSDFM metrics land in stage RHOBS hcp tenant (OTEL catchall).
      rhobs_oidc_dir="${OCM_FVT_RHOBS_OIDC_DIR:-/usr/local/rhobs-oidc-staging}"
      rhobs_metrics_url="${OCM_FVT_PROMETHEUS_URL:-https://us-east-1-0.rhobs.api.stage.openshift.com/api/metrics/v1/hcp}"
      ;;
  esac

  if [[ ! -f "${rhobs_oidc_dir}/client_id" || ! -f "${rhobs_oidc_dir}/client_secret" ]]; then
    echo "ERROR: RHOBS OIDC credentials missing under ${rhobs_oidc_dir} (need client_id/client_secret)" >&2
    exit 1
  fi

  [[ $- == *x* ]] && WAS_TRACING_RHOBS=true || WAS_TRACING_RHOBS=false
  set +x
  rhobs_client_id="$(cat "${rhobs_oidc_dir}/client_id")"
  rhobs_client_secret="$(cat "${rhobs_oidc_dir}/client_secret")"
  rhobs_issuer="$(cat "${rhobs_oidc_dir}/oidc_issuer_url" 2>/dev/null || true)"
  if [[ -z "${rhobs_issuer}" ]]; then
    rhobs_issuer="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
  fi
  rhobs_token="$(curl -sf -X POST "${rhobs_issuer}" \
    -d "grant_type=client_credentials" \
    -d "client_id=${rhobs_client_id}" \
    -d "client_secret=${rhobs_client_secret}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")" || {
    $WAS_TRACING_RHOBS && set -x
    echo "ERROR: failed to obtain RHOBS OIDC access token from ${rhobs_issuer}" >&2
    exit 1
  }
  $WAS_TRACING_RHOBS && set -x

  # Mount OIDC creds so ocmci can refresh tokens after SOAK_TIME (SSO TTL ~5m).
  podman_args+=("-v" "${rhobs_oidc_dir}:/usr/local/rhobs-oidc:ro,z")
  echo "OCM_FVT_PROMETHEUS_URL=${rhobs_metrics_url}" >> "${podman_env_file}"
  echo "OCM_FVT_RHOBS_OIDC_DIR=/usr/local/rhobs-oidc" >> "${podman_env_file}"
  # Initial token for spot-check / early queries; container refreshes before PromQL.
  echo "OCM_FVT_PROMETHEUS_TOKEN=${rhobs_token}" >> "${podman_env_file}"
  echo "RHOBS metrics URL: ${rhobs_metrics_url}"
  echo "RHOBS OIDC dir: ${rhobs_oidc_dir} (mounted at /usr/local/rhobs-oidc)"

  # Spot-check PromQL against RHOBS (log truncated body only).
  ns="osd-fleet-manager-${OCM_FVT_OCM_ENV:-integration}"
  set +x
  code="$(curl -sS -o /tmp/rhobs-up.out -w '%{http_code}' --max-time 30 \
    -H "Authorization: Bearer ${rhobs_token}" \
    --get "${rhobs_metrics_url}/api/v1/query" \
    --data-urlencode "query=fleet_manager_cluster_status_count{namespace=\"${ns}\"}" || echo err)"
  $WAS_TRACING_RHOBS && set -x
  echo "RHOBS spot-check HTTP ${code}; body: $(head -c 160 /tmp/rhobs-up.out 2>/dev/null | tr '\n' ' ')"
  rm -f /tmp/rhobs-up.out
  if [[ "${code}" != "200" ]]; then
    echo "ERROR: RHOBS metrics query failed (HTTP ${code})" >&2
    exit 1
  fi
  echo "============================================"
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
# Do not trace secret env expansion.
[[ $- == *x* ]] && WAS_TRACING_RUN=true || WAS_TRACING_RUN=false
set +x
podman run \
  "${podman_args[@]}" \
  "${aao_kubeconfig_env[@]}" \
  "${dr_aws_creds_env[@]}" \
  "${zero_egress_env[@]}" \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest \
  ocmtest "${ocmtest_args[@]}" || exit_code=$?
$WAS_TRACING_RUN && set -x

# Copy merged report.xml (skip per-phase duplicates).
find "${ocm_fvt_output}" -type f -name 'report.xml' -print0 | while IFS= read -r -d '' xml_file; do
  cp "${xml_file}" "${ARTIFACT_DIR}/junit-ocm-fvt-report.xml"
done

# Exit code for post-steps (e.g. stage promotion).
echo "${exit_code}" > "${SHARED_DIR}/ocm-fvt-exit-code" 2>/dev/null || true

exit "${exit_code}"
