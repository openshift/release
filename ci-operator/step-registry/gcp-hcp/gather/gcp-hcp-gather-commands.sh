#!/usr/bin/env bash
set -uo pipefail

umask 077

readonly GATHER_ROOT="${ARTIFACT_DIR}/gather"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
readonly STARTED_AT
readonly TEXT_FILE_MAX_BYTES="${GATHER_TEXT_MAX_BYTES:-5242880}"
readonly CHAI_MAX_BYTES="${GATHER_CHAI_MAX_BYTES:-20971520}"
readonly GCP_REGION_VALUE="${GCP_REGION:-us-central1}"

mkdir -p "${GATHER_ROOT}"
temp_root="$(mktemp -d)"
cleanup_temp_files() {
  rm -rf "${temp_root}"
  find "${GATHER_ROOT}" -maxdepth 1 -type f -name '.*.tmp' -delete
}
trap cleanup_temp_files EXIT

read_shared() {
  local name="$1"
  if [[ -s "${SHARED_DIR}/${name}" ]]; then
    tr -d '\r\n' <"${SHARED_DIR}/${name}"
  fi
}

record_error() {
  local scope_dir="$1"
  local collector="$2"
  local exit_code="$3"
  local timed_out="false"
  [[ "${exit_code}" == "124" ]] && timed_out="true"
  printf '%s: exit=%s timeout=%s\n' "${collector}" "${exit_code}" "${timed_out}" >>"${scope_dir}/.errors"
  touch "${scope_dir}/.partial"
}

run_capture() {
  local scope_dir="$1"
  local collector="$2"
  local output_file="$3"
  local duration="$4"
  shift 4

  mkdir -p "$(dirname "${output_file}")"
  timeout "${duration}" "$@" >"${output_file}" 2>"${output_file}.stderr"
  local exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "${collector}" "${exit_code}"
  fi
  return 0
}

inspect_namespace() {
  local kubeconfig="$1"
  local scope_dir="$2"
  local namespace="$3"
  local output="${scope_dir}/inspect/${namespace}"

  timeout 45s oc \
    --kubeconfig="${kubeconfig}" \
    --request-timeout=30s \
    adm inspect "namespace/${namespace}" \
    --since=3h \
    --dest-dir="${output}" \
    >"${scope_dir}/inspect-${namespace}.log" 2>&1
  local exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "inspect/${namespace}" "${exit_code}"
  fi
  return 0
}

write_connect_kubeconfig() {
  local path="$1"
  local endpoint="$2"
  local token="$3"
  cat >"${path}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://${endpoint}
  name: target
contexts:
- context:
    cluster: target
    user: gcp-user
  name: target
current-context: target
users:
- name: gcp-user
  user:
    token: ${token}
EOF
}

collect_gke() {
  local kubeconfig="$1"
  local scope_dir="$2"
  local namespaces_json="${scope_dir}/cluster/namespaces.json"
  local candidates="${scope_dir}/candidate-namespaces.txt"
  local application_candidates="${scope_dir}/application-namespaces.txt"
  local supplemental_candidates="${scope_dir}/supplemental-namespaces.txt"
  local existing="${scope_dir}/existing-namespaces.txt"
  local selected="${scope_dir}/selected-namespaces.txt"
  local output exit_code namespace kind safe_kind pid
  local -a inspect_pids=()

  mkdir -p "${scope_dir}/cluster" "${scope_dir}/custom-resources" "${scope_dir}/inspect"
  : >"${candidates}"
  : >"${application_candidates}"
  : >"${supplemental_candidates}"

  output="${scope_dir}/cluster/api-resources.txt"
  run_capture "${scope_dir}" "api-resources" "${output}" 30s \
    kubectl --kubeconfig="${kubeconfig}" api-resources

  output="${namespaces_json}"
  timeout 30s kubectl --kubeconfig="${kubeconfig}" get namespaces -o json >"${output}" 2>"${output}.stderr"
  exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "namespaces" "${exit_code}"
    touch "${scope_dir}/.unavailable"
    return 0
  fi

  if ! jq -r '.items[].metadata.name // empty' "${namespaces_json}" | sort -u >"${existing}"; then
    record_error "${scope_dir}" "namespaces-json" 1
    touch "${scope_dir}/.unavailable"
    return 0
  fi
  if ! jq -r '
    .items[]
    | select(
        .metadata.annotations["argocd.argoproj.io/tracking-id"] != null
        or .metadata.annotations["config.k8s.io/owning-inventory"] != null
        or ((.metadata.ownerReferences // []) | length) > 0
        or .metadata.labels["hypershift.openshift.io/hosted-control-plane"] == "true"
      )
    | .metadata.name
  ' "${namespaces_json}" >>"${supplemental_candidates}"; then
    record_error "${scope_dir}" "namespace-metadata" 1
  fi

  output="${scope_dir}/custom-resources/applications.argoproj.io.json"
  timeout 30s kubectl --kubeconfig="${kubeconfig}" get applications.argoproj.io --all-namespaces -o json >"${output}" 2>"${output}.stderr"
  exit_code=$?
  if (( exit_code == 0 )); then
    if ! jq -r '
      .items[]
      | select(
          .spec.destination.server == "https://kubernetes.default.svc"
          or .spec.destination.name == "in-cluster"
        )
      | .metadata.namespace
    ' "${output}" >>"${supplemental_candidates}"; then
      record_error "${scope_dir}" "applications-json" 1
    fi
    if ! jq -r '
      .items[]
      | select(
          .spec.destination.server == "https://kubernetes.default.svc"
          or .spec.destination.name == "in-cluster"
        )
      | .spec.destination.namespace // empty
    ' "${output}" >>"${application_candidates}"; then
      record_error "${scope_dir}" "application-destinations-json" 1
    fi
  else
    record_error "${scope_dir}" "applications.argoproj.io" "${exit_code}"
  fi

  output="${scope_dir}/custom-resources/hostedclusters.hypershift.openshift.io.json"
  timeout 30s kubectl --kubeconfig="${kubeconfig}" get hostedclusters.hypershift.openshift.io --all-namespaces -o json >"${output}" 2>"${output}.stderr"
  exit_code=$?
  if (( exit_code == 0 )); then
    if ! jq -r '.items[].metadata.namespace // empty' "${output}" >>"${supplemental_candidates}"; then
      record_error "${scope_dir}" "hostedclusters-json" 1
    fi
  else
    record_error "${scope_dir}" "hostedclusters.hypershift.openshift.io" "${exit_code}"
  fi

  cat "${application_candidates}" >>"${candidates}"
  grep -Ev '^(default|kube-system)$' "${supplemental_candidates}" >>"${candidates}" || true
  sort -u "${candidates}" -o "${candidates}"
  comm -12 "${existing}" "${candidates}" >"${selected}"

  while IFS= read -r namespace; do
    [[ -n "${namespace}" ]] || continue
    inspect_namespace "${kubeconfig}" "${scope_dir}" "${namespace}" &
    inspect_pids+=("$!")
    if (( ${#inspect_pids[@]} == 4 )); then
      for pid in "${inspect_pids[@]}"; do
        wait "${pid}"
      done
      inspect_pids=()
    fi
  done <"${selected}"
  for pid in "${inspect_pids[@]}"; do
    wait "${pid}"
  done

  for kind in \
    applicationsets.argoproj.io \
    nodepools.hypershift.openshift.io \
    hostedcontrolplanes.hypershift.openshift.io \
    machines.cluster.x-k8s.io \
    machinedeployments.cluster.x-k8s.io \
    gcpmachines.infrastructure.cluster.x-k8s.io; do
    safe_kind="${kind//\//_}"
    run_capture "${scope_dir}" "${kind}" "${scope_dir}/custom-resources/${safe_kind}.json" 30s \
      kubectl --kubeconfig="${kubeconfig}" get "${kind}" --all-namespaces -o json
  done

  run_capture "${scope_dir}" "nodes" "${scope_dir}/cluster/nodes.json" 30s \
    kubectl --kubeconfig="${kubeconfig}" get nodes -o json
  run_capture "${scope_dir}" "persistentvolumes" "${scope_dir}/cluster/persistentvolumes.json" 30s \
    kubectl --kubeconfig="${kubeconfig}" get persistentvolumes -o json
  run_capture "${scope_dir}" "storageclasses" "${scope_dir}/cluster/storageclasses.json" 30s \
    kubectl --kubeconfig="${kubeconfig}" get storageclasses.storage.k8s.io -o json
  run_capture "${scope_dir}" "volumeattachments" "${scope_dir}/cluster/volumeattachments.json" 30s \
    kubectl --kubeconfig="${kubeconfig}" get volumeattachments.storage.k8s.io -o json

  find "${scope_dir}" -type f -path '*/core/secrets.yaml' -delete
}

collect_gke_bounded() {
  local name="$1"
  local kubeconfig="$2"
  local scope_dir="$3"
  timeout 240s bash -c 'set -uo pipefail; collect_gke "$@"' _ "${kubeconfig}" "${scope_dir}"
  local exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "${name}" "${exit_code}"
  fi
}

collect_hosted_cluster() {
  local scope_dir="$1"
  local hosted_cluster="$2"
  local customer_project="$3"
  local hosted_kubeconfig="$4"
  local exit_code

  mkdir -p "${scope_dir}"
  if [[ -z "${hosted_cluster}" || -z "${customer_project}" || -z "${GCPHCPCTL_API_ENDPOINT:-}" || -z "${GCPHCPCTL_OIDC_ENDPOINT:-}" ]]; then
    printf '%s\n' 'metadata: exit=1 timeout=false' >>"${scope_dir}/.errors"
    touch "${scope_dir}/.unavailable"
    return 0
  fi

  timeout 60s gcphcpctl cluster login "${hosted_cluster}" --kubeconfig "${hosted_kubeconfig}" \
    >"${scope_dir}/login.log" 2>&1
  exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "gcphcpctl-login" "${exit_code}"
    touch "${scope_dir}/.unavailable"
    return 0
  fi

  timeout 30s oc --kubeconfig="${hosted_kubeconfig}" --request-timeout=20s get nodes \
    >"${scope_dir}/nodes.txt" 2>"${scope_dir}/nodes.stderr"
  exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "hosted-nodes" "${exit_code}"
    touch "${scope_dir}/.unavailable"
    return 0
  fi

  timeout 480s oc adm must-gather \
    --kubeconfig="${hosted_kubeconfig}" \
    --dest-dir="${scope_dir}/must-gather" \
    >"${scope_dir}/must-gather.log" 2>&1
  exit_code=$?
  if (( exit_code != 0 )); then
    record_error "${scope_dir}" "must-gather" "${exit_code}"
  fi
}

collect_customer_project() {
  local scope_dir="$1"
  local customer_project="$2"
  mkdir -p "${scope_dir}"

  if [[ -z "${customer_project}" ]]; then
    printf '%s\n' 'customer-project: exit=1 timeout=false' >>"${scope_dir}/.errors"
    touch "${scope_dir}/.unavailable"
    return 0
  fi

  # Keep customer-project output diagnostic but bounded to structured fields.
  # In particular, do not archive instance metadata or arbitrary log payloads.
  run_capture "${scope_dir}" "cloud-asset" "${scope_dir}/assets.json" 90s \
    gcloud asset search-all-resources --scope="projects/${customer_project}" \
      --format='json(name,assetType,project,location,displayName,state,createTime,updateTime)'
  run_capture "${scope_dir}" "managed-instance-groups" "${scope_dir}/managed-instance-groups.json" 60s \
    gcloud compute instance-groups managed list --project="${customer_project}" \
      --format='json(name,zone,region,status,targetSize,currentActions,instanceTemplate,versions,baseInstanceName)'
  run_capture "${scope_dir}" "instances" "${scope_dir}/instances.json" 60s \
    gcloud compute instances list --project="${customer_project}" \
      --format='json(name,id,zone,status,machineType,creationTimestamp,lastStartTimestamp,lastStopTimestamp,cpuPlatform,networkInterfaces,disks,scheduling)'
  run_capture "${scope_dir}" "compute-operations" "${scope_dir}/compute-operations.json" 60s \
    gcloud compute operations list --project="${customer_project}" --limit=200 \
      --format='json(name,operationType,status,statusMessage,error,targetLink,zone,region,startTime,endTime,httpErrorStatusCode,httpErrorMessage,progress)'
  run_capture "${scope_dir}" "worker-logs" "${scope_dir}/worker-logs.json" 90s \
    gcloud logging read 'logName:"cloudaudit.googleapis.com" AND (resource.type="gce_instance" OR protoPayload.resourceName=~"/(instances|instanceGroupManagers)/")' \
      --project="${customer_project}" --freshness=3h --limit=500 \
      --format='json(timestamp,severity,logName,resource,operation,protoPayload.methodName,protoPayload.resourceName,protoPayload.status,errorGroups,insertId)'
}

cap_text_files() {
  local scope_dir="$1"
  local file size capped
  while IFS= read -r -d '' file; do
    grep -Iq . "${file}" || continue
    size="$(wc -c <"${file}" | tr -d ' ')"
    if (( size > TEXT_FILE_MAX_BYTES )); then
      capped="${file}.capped"
      tail -c "${TEXT_FILE_MAX_BYTES}" "${file}" >"${capped}"
      mv "${capped}" "${file}"
    fi
  done < <(find "${scope_dir}" -type f -print0)
}

scope_is_safe() {
  local scope_dir="$1"
  grep -raqiE -- \
    '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|(^|[^[:alnum:]_])(private_key|access_token|refresh_token|client_secret)["[:space:]]*[:=]|authorization["[:space:]]*:[[:space:]]*bearer[[:space:]]+|(^|[^[:alnum:]_-])ya29\.[[:alnum:]_.-]+|(^|[^[:alnum:]_-])eyJ[[:alnum:]_-]{10,}\.[[:alnum:]_-]{10,}\.[[:alnum:]_-]{10,}' \
    "${scope_dir}"
  local exit_code=$?
  if (( exit_code == 1 )); then
    return 0
  fi
  return 1
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  else
    shasum -a 256 "${file}" | awk '{print $1}'
  fi
}

finalize_scope() {
  local name="$1"
  local scope_dir="$2"
  local record_file="$3"
  local status="success"
  local archive_path="${GATHER_ROOT}/${name}.tar.gz"
  local archive_temp
  local archive_publish_temp="${GATHER_ROOT}/.${name}.tar.gz.tmp"
  local archive_json="null"
  local bytes=0
  local digest=""
  local chai_readable="false"
  local errors_json='[]'
  local scope_parent scope_base

  if [[ -f "${scope_dir}/.errors" ]]; then
    errors_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "${scope_dir}/.errors")"
  fi
  [[ -f "${scope_dir}/.partial" ]] && status="partial"
  [[ -f "${scope_dir}/.unavailable" ]] && status="unavailable"

  rm -f "${scope_dir}/.errors" "${scope_dir}/.partial" "${scope_dir}/.unavailable"
  find "${scope_dir}" -type f -path '*/core/secrets.yaml' -delete
  cap_text_files "${scope_dir}"

  if [[ "${status}" != "unavailable" ]] && ! scope_is_safe "${scope_dir}"; then
    status="unavailable"
    errors_json="$(jq -c '. + ["safety-scan: credential marker detected"]' <<<"${errors_json}")"
  fi

  if [[ "${status}" != "unavailable" ]]; then
    find "${scope_dir}" \( -type f -o -type d \) -exec touch -t 198001010000 {} +
    scope_parent="$(dirname "${scope_dir}")"
    scope_base="$(basename "${scope_dir}")"
    archive_temp="${scope_parent}/.${name}.tar.gz"
    if (
      cd "${scope_parent}" || exit 1
      find "${scope_base}" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | tar --null -T - -cf -
    ) | gzip -n >"${archive_temp}"; then
      if cp "${archive_temp}" "${archive_publish_temp}" && mv "${archive_publish_temp}" "${archive_path}"; then
        bytes="$(wc -c <"${archive_path}" | tr -d ' ')"
        digest="$(sha256_file "${archive_path}")"
        archive_json="gather/${name}.tar.gz"
        if (( bytes < CHAI_MAX_BYTES )); then
          chai_readable="true"
        fi
      else
        rm -f "${archive_publish_temp}" "${archive_path}"
        status="unavailable"
        errors_json="$(jq -c '. + ["archive-publish: exit=1 timeout=false"]' <<<"${errors_json}")"
      fi
    else
      rm -f "${archive_path}"
      status="unavailable"
      errors_json="$(jq -c '. + ["archive: exit=1 timeout=false"]' <<<"${errors_json}")"
    fi
  fi

  if [[ "${status}" == "unavailable" ]]; then
    rm -f "${archive_path}"
  fi

  jq -n \
    --arg name "${name}" \
    --arg status "${status}" \
    --argjson archive "$(if [[ "${archive_json}" == "null" ]]; then printf 'null'; else jq -Rn --arg value "${archive_json}" '$value'; fi)" \
    --argjson bytes "${bytes}" \
    --arg sha256 "${digest}" \
    --argjson chai_readable "${chai_readable}" \
    --argjson errors "${errors_json}" \
    '{name: $name, status: $status, archive: $archive, bytes: $bytes, sha256: $sha256, chai_readable: $chai_readable, errors: $errors}' \
    >"${record_file}"
}

export GATHER_ROOT TEXT_FILE_MAX_BYTES CHAI_MAX_BYTES
export -f collect_gke inspect_namespace record_error run_capture
export -f cap_text_files scope_is_safe sha256_file finalize_scope

region_project="$(read_shared region-project-id)"
region_cluster="$(read_shared region-cluster-name)"
mc_project="$(read_shared mc-project-id)"
mc_cluster="$(read_shared mc-cluster-name)"
customer_project="$(read_shared customer-project-id)"
hosted_cluster="$(read_shared hosted-cluster-name)"
tested_sha="$(read_shared gcp-hcp-tested-sha)"
[[ -n "${tested_sha}" ]] || tested_sha="${PULL_PULL_SHA:-${PULL_BASE_SHA:-}}"

export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"
GCPHCPCTL_API_ENDPOINT="$(read_shared api-endpoint)"
GCPHCPCTL_OIDC_ENDPOINT="$(read_shared oidc-endpoint)"
export GCPHCPCTL_API_ENDPOINT GCPHCPCTL_OIDC_ENDPOINT
export GCPHCPCTL_PROJECT="${customer_project}"

region_dir="${temp_root}/region-cluster"
management_dir="${temp_root}/management-cluster"
hosted_dir="${temp_root}/hosted-cluster"
customer_dir="${temp_root}/customer-project"
mkdir -p "${region_dir}" "${management_dir}" "${hosted_dir}" "${customer_dir}"

auth_ok=true
auth_exit=0
if [[ ! -s "${SHARED_DIR}/wif-cred.json" ]]; then
  auth_ok=false
  auth_exit=1
else
  timeout 30s gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet >/dev/null 2>&1
  auth_exit=$?
  (( auth_exit == 0 )) || auth_ok=false
fi

region_kubeconfig="$(mktemp "${temp_root}/region-kubeconfig.XXXXXX")"
management_kubeconfig="$(mktemp "${temp_root}/management-kubeconfig.XXXXXX")"
hosted_kubeconfig="$(mktemp "${temp_root}/hosted-kubeconfig.XXXXXX")"

if [[ "${auth_ok}" == "true" && -n "${region_project}" ]]; then
  region_project_number="$(timeout 30s gcloud projects describe "${region_project}" --format='value(projectNumber)' 2>/dev/null)"
  project_lookup_exit=$?
  access_token="$(timeout 30s gcloud auth print-access-token 2>/dev/null)"
  access_token_exit=$?

  if (( project_lookup_exit == 0 && access_token_exit == 0 )) && \
    [[ -n "${region_project_number}" && -n "${access_token}" && -n "${region_cluster}" ]]; then
    write_connect_kubeconfig "${region_kubeconfig}" \
      "${GCP_REGION_VALUE}-connectgateway.googleapis.com/v1/projects/${region_project_number}/locations/${GCP_REGION_VALUE}/gkeMemberships/${region_cluster}" \
      "${access_token}"
    collect_gke_bounded "region-cluster" "${region_kubeconfig}" "${region_dir}" &
    region_pid=$!
  else
    if (( project_lookup_exit != 0 )); then
      record_error "${region_dir}" "fleet-project-lookup" "${project_lookup_exit}"
    elif (( access_token_exit != 0 )); then
      record_error "${region_dir}" "access-token" "${access_token_exit}"
    else
      record_error "${region_dir}" "region-metadata" 1
    fi
    touch "${region_dir}/.unavailable"
    region_pid=""
  fi

  if (( project_lookup_exit == 0 && access_token_exit == 0 )) && \
    [[ -n "${region_project_number}" && -n "${access_token}" && -n "${mc_project}" && -n "${mc_cluster}" ]]; then
    write_connect_kubeconfig "${management_kubeconfig}" \
      "${GCP_REGION_VALUE}-connectgateway.googleapis.com/v1/projects/${region_project_number}/locations/${GCP_REGION_VALUE}/gkeMemberships/${mc_cluster}" \
      "${access_token}"
    collect_gke_bounded "management-cluster" "${management_kubeconfig}" "${management_dir}" &
    management_pid=$!
  else
    if (( project_lookup_exit != 0 )); then
      record_error "${management_dir}" "fleet-project-lookup" "${project_lookup_exit}"
    elif (( access_token_exit != 0 )); then
      record_error "${management_dir}" "access-token" "${access_token_exit}"
    else
      record_error "${management_dir}" "management-metadata" 1
    fi
    touch "${management_dir}/.unavailable"
    management_pid=""
  fi
else
  if [[ "${auth_ok}" == "true" ]]; then
    record_error "${region_dir}" "region-project-metadata" 1
    record_error "${management_dir}" "region-project-metadata" 1
  else
    record_error "${region_dir}" "gcloud-auth" "${auth_exit}"
    record_error "${management_dir}" "gcloud-auth" "${auth_exit}"
  fi
  touch "${region_dir}/.unavailable" "${management_dir}/.unavailable"
  region_pid=""
  management_pid=""
fi

collect_hosted_cluster "${hosted_dir}" "${hosted_cluster}" "${customer_project}" "${hosted_kubeconfig}" &
hosted_pid=$!

if [[ "${auth_ok}" == "true" ]]; then
  collect_customer_project "${customer_dir}" "${customer_project}" &
  customer_pid=$!
else
  record_error "${customer_dir}" "gcloud-auth" "${auth_exit}"
  touch "${customer_dir}/.unavailable"
  customer_pid=""
fi

for pid in "${region_pid}" "${management_pid}" "${hosted_pid}" "${customer_pid}"; do
  [[ -n "${pid}" ]] && wait "${pid}"
done

finalize_scope_bounded() {
  local name="$1"
  local scope_dir="$2"
  local record="$3"

  timeout 180s bash -c 'set -uo pipefail; finalize_scope "$@"' _ \
    "${name}" "${scope_dir}" "${record}"
  local finalize_exit=$?
  if (( finalize_exit != 0 )); then
    rm -f "${GATHER_ROOT}/${name}.tar.gz" "${GATHER_ROOT}/.${name}.tar.gz.tmp"
    jq -n \
      --arg name "${name}" \
      --arg error "finalize: exit=${finalize_exit} timeout=$([[ "${finalize_exit}" == "124" ]] && printf true || printf false)" \
      '{name: $name, status: "unavailable", archive: null, bytes: 0, sha256: "", chai_readable: false, errors: [$error]}' \
      >"${record}"
  fi
  return 0
}

scope_records=()
finalize_pids=()
for name in region-cluster management-cluster hosted-cluster customer-project; do
  record="${temp_root}/${name}.json"
  scope_records+=("${record}")
  finalize_scope_bounded "${name}" "${temp_root}/${name}" "${record}" &
  finalize_pids+=("$!")
done
for pid in "${finalize_pids[@]}"; do
  wait "${pid}"
done

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq -s \
  --arg build_id "${BUILD_ID:-}" \
  --arg tested_sha "${tested_sha}" \
  --arg started_at "${STARTED_AT}" \
  --arg finished_at "${finished_at}" \
  '{schema_version: 1, build_id: $build_id, tested_sha: $tested_sha, started_at: $started_at, finished_at: $finished_at, scopes: .}' \
  "${scope_records[@]}" >"${GATHER_ROOT}/summary.json.tmp"
mv "${GATHER_ROOT}/summary.json.tmp" "${GATHER_ROOT}/summary.json"

jq '[.scopes[] | select(.archive != null) | {name, archive, bytes, sha256, chai_readable, status}]' \
  "${GATHER_ROOT}/summary.json" >"${GATHER_ROOT}/manifest.json.tmp"
mv "${GATHER_ROOT}/manifest.json.tmp" "${GATHER_ROOT}/manifest.json"

echo "GCP HCP diagnostics written to ${GATHER_ROOT}"
