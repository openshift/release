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

# Prow-only Hive access (skipped by Tekton/Jenkins).
hive_kubeconfig=""
hive_kubeconfig_src=""
backplane_bin_dir=""
backplane_proxy_url=""
if [[ "${OCM_FVT_USE_BACKPLANE:-false}" == "true" ]]; then
  echo "=== OCM backplane login (Hive) ==="
  cred_dir="${OCM_FVT_BACKPLANE_CREDENTIALS_DIR:-/usr/local/rosa-clusters-service-sandbox}"
  # Disable tracing due to credential handling.
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

  # Defaults match rosa-e2e-ocm-fvt*-ref.yaml.
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
  curl -sSL -o "${backplane_bin_dir}/ocm" \
    "https://github.com/openshift-online/ocm-cli/releases/download/v${ocm_ver}/ocm-linux-amd64"
  chmod 0755 "${backplane_bin_dir}/ocm"

  echo "Installing ocm-backplane CLI v${bp_ver} into ${backplane_bin_dir}"
  bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
  curl -sSL -o "${bp_tar}" \
    "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"
  tar -xzf "${bp_tar}" -C "${backplane_bin_dir}" ocm-backplane
  chmod 0755 "${backplane_bin_dir}/ocm-backplane"
  rm -f "${bp_tar}"

  # nested-podman image has no oc; backplane login/elevate need it.
  echo "Installing oc CLI (${oc_ver}) into ${backplane_bin_dir}"
  oc_tar="$(mktemp /tmp/openshift-client.XXXXXX.tar.gz)"
  curl -sSL -o "${oc_tar}" \
    "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${oc_ver}/openshift-client-linux.tar.gz"
  tar -xzf "${oc_tar}" -C "${backplane_bin_dir}" oc
  chmod 0755 "${backplane_bin_dir}/oc"
  rm -f "${oc_tar}"

  mkdir -p "${HOME}/.config/backplane"
  printf '{"proxy-url":"%s"}\n' "${backplane_proxy_url}" > "${HOME}/.config/backplane/config.json"

  # Pin KUBECONFIG so login writes a known path.
  hive_kubeconfig_src="$(mktemp /tmp/backplane-kubeconfig.XXXXXX)"
  rm -f "${hive_kubeconfig_src}"
  export KUBECONFIG="${hive_kubeconfig_src}"

  # Disable tracing due to client-secret handling.
  [[ $- == *x* ]] && WAS_TRACING_BP=true || WAS_TRACING_BP=false
  set +x
  ocm login \
    --client-id="${backplane_client_id}" \
    --client-secret="${backplane_client_secret}" \
    --url="${backplane_ocm_url}"
  ocm-backplane login "${backplane_cluster_id}"
  $WAS_TRACING_BP && set -x
  # Confirm elevate before dumping Impersonate kubeconfig.
  ocm-backplane elevate "${backplane_elevate_reason}" -- whoami

  if [[ ! -f "${KUBECONFIG}" ]]; then
    echo "ERROR: backplane login did not write kubeconfig at ${KUBECONFIG}" >&2
    exit 1
  fi

  # Elevated Impersonate kubeconfig for AAO (exec uses PATH in container).
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
trap 'rm -f "${podman_env_file}"; rm -f "${hive_kubeconfig:-}" "${hive_kubeconfig_src:-}"' EXIT
umask "${old_umask}"

{
  echo "AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-cred"
  echo "SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-shared-vpc-credentials"
  echo "JOB_LINK=${JOB_LINK}"
  echo "SLACK_WEBHOOK_URL=$(cat /usr/local/cs-qe-credentials/slack_webhook_url)"
  echo "CONSOLE_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/console_client_secret)"
} > "${podman_env_file}"

if [[ -n "${hive_kubeconfig}" ]]; then
  # Proxy + PATH/HOME so container can refresh backplane tokens.
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
# Prow: elevated kubeconfig. Else vault (Tekton/Jenkins).
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

# DR_AWS_CREDENTIALS: static DR AWS creds (farm cannot reach Hive; ROSAENG-60596).
dr_aws_creds_env=()
if [[ -f "${osdfm_qe_creds_dir}/aws_dr_cred" ]]; then
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  dr_aws_creds_env=("-e" "DR_AWS_CREDENTIALS=$(<"${osdfm_qe_creds_dir}/aws_dr_cred")")
  $WAS_TRACING && set -x
fi

# ZERO_EGRESS_ECR_CONFIG for @id_76488 (sync with app-interface ecr account/regions).
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
    production|prod) ;; # test skips
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

# TEMP DEBUG: Prometheus reachability (remove after confirming).
if [[ "${OCM_FVT_SERVICE:-}" == "osdfm" ]]; then
  prom_route="${OCM_FVT_PROMETHEUS_ROUTE:-https://prometheus.app-sre-stage-01.devshift.net}"
  prom_proxy="${HTTPS_PROXY:-${backplane_proxy_url:-http://squid.corp.redhat.com:3128}}"
  echo "=== Prometheus reachability probe (osdfm) ==="
  echo "Direct .svc from build pod:"
  code_svc="$(curl -sS -o /tmp/prom-svc.out -w '%{http_code}' --max-time 5 \
    "http://prometheus-app-sre.openshift-customer-monitoring.svc.cluster.local:9090/api/v1/query?query=up" \
    || echo err)"
  echo "HTTP ${code_svc}; body: $(head -c 80 /tmp/prom-svc.out 2>/dev/null | tr '\n' ' ')"
  echo "Route ${prom_route} via proxy:"
  code_route="$(curl -sS -o /tmp/prom-route.out -w '%{http_code}' --max-time 15 --proxy "${prom_proxy}" \
    "${prom_route}/api/v1/query?query=up" \
    || echo err)"
  echo "HTTP ${code_route}; body: $(head -c 80 /tmp/prom-route.out 2>/dev/null | tr '\n' ' ')"

  # TEMP: AppSRE backplane Prom probe (separate kubeconfig; keep Hive).
  if [[ "${OCM_FVT_USE_BACKPLANE:-false}" == "true" && -n "${backplane_bin_dir}" ]]; then
    appsre_cluster_id="${OCM_FVT_APPSRE_BACKPLANE_CLUSTER_ID:-19mjrthsfn66bm22m574v2v1gt9a8r4q}"
    appsre_kubeconfig="$(mktemp /tmp/appsre-kubeconfig.XXXXXX)"
    rm -f "${appsre_kubeconfig}"
    saved_kubeconfig="${KUBECONFIG:-}"
    export KUBECONFIG="${appsre_kubeconfig}"
    export PATH="${backplane_bin_dir}:${PATH}"
    echo "Backplane login app-sre-stage-01 (${appsre_cluster_id}):"
    if ocm-backplane login "${appsre_cluster_id}"; then
      echo "oc whoami: $(oc whoami 2>&1 || true)"
      echo "get svc prometheus-app-sre:"
      oc -n openshift-customer-monitoring get svc prometheus-app-sre -o name 2>&1 || echo "get svc: failed"
      # Port-forward then PromQL.
      oc -n openshift-customer-monitoring port-forward svc/prometheus-app-sre 19090:9090 >/tmp/prom-pf.log 2>&1 &
      pf_pid=$!
      sleep 3
      code_pf="$(curl -sS -o /tmp/prom-pf.out -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:19090/api/v1/query?query=up" || echo err)"
      echo "port-forward PromQL HTTP ${code_pf}; body: $(head -c 120 /tmp/prom-pf.out 2>/dev/null | tr '\n' ' ')"
      kill "${pf_pid}" 2>/dev/null || true
      wait "${pf_pid}" 2>/dev/null || true
      # Elevate get svc if port-forward PromQL failed.
      if [[ "${code_pf}" != "200" ]]; then
        echo "Retry get svc + port-forward via elevate:"
        ocm-backplane elevate "${backplane_elevate_reason:-https://issues.redhat.com/browse/ROSAENG-62717}" -- \
          -n openshift-customer-monitoring get svc prometheus-app-sre -o name 2>&1 || echo "elevate get svc: failed"
      fi
    else
      echo "Backplane login to app-sre-stage-01 failed"
    fi
    export KUBECONFIG="${saved_kubeconfig}"
    rm -f "${appsre_kubeconfig}"
  else
    echo "Skip app-sre backplane Prom probe (OCM_FVT_USE_BACKPLANE!=true or no backplane bin)"
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
# Disable tracing while expanding secret env args.
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

# Copy merged report.xml only (avoid inflated counts from per-phase XMLs).
find "${ocm_fvt_output}" -type f -name 'report.xml' -print0 | while IFS= read -r -d '' xml_file; do
  cp "${xml_file}" "${ARTIFACT_DIR}/junit-ocm-fvt-report.xml"
done

# Exit code for post steps (e.g. stage promotion).
echo "${exit_code}" > "${SHARED_DIR}/ocm-fvt-exit-code" 2>/dev/null || true

exit "${exit_code}"
