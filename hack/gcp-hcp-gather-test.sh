#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gather_script="${repo_root}/ci-operator/step-registry/gcp-hcp/gather/gcp-hcp-gather-commands.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

assert_jq() {
  local expression="$1"
  local file="$2"
  jq -e "${expression}" "${file}" >/dev/null || fail "jq assertion failed: ${expression} (${file})"
}

write_fakes() {
  local bin_dir="$1"

  mkdir -p "${bin_dir}"

  cat >"${bin_dir}/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "gcloud $*" >>"${FAKE_LOG_DIR}/commands.log"

case "$*" in
  "auth login"*) exit 0 ;;
  "auth print-access-token"*) printf '%s\n' 'test-access-token' ;;
  "projects describe"*) printf '%s\n' "123456789" ;;
  "asset search-all-resources"*)
    if [[ "${FAKE_QUARANTINE_CUSTOMER:-false}" == "true" ]]; then
      printf '%s\n' '[{"private_key":"credential-marker"}]'
    elif [[ "${FAKE_LARGE_CUSTOMER:-false}" == "true" ]]; then
      head -c 22020096 /dev/urandom
    else
      printf '%s\n' '[{"name":"//compute.googleapis.com/projects/customer-project/zones/us-central1-a/instances/worker-0"}]'
    fi
    ;;
  "compute instance-groups managed list"*) printf '%s\n' '[{"name":"workers"}]' ;;
  "compute instances list"*) printf '%s\n' '[{"name":"worker-0","status":"RUNNING"}]' ;;
  "compute operations list"*) printf '%s\n' '[{"name":"operation-0","status":"DONE"}]' ;;
  "logging read"*) printf '%s\n' '[{"severity":"ERROR","textPayload":"worker startup failed"}]' ;;
  *) echo "unexpected gcloud invocation: $*" >&2; exit 2 ;;
esac
FAKE

  cat >"${bin_dir}/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "kubectl $*" >>"${FAKE_LOG_DIR}/commands.log"

args=" $* "
if [[ "${args}" == *" get namespaces "* && "${args}" == *" -o json "* ]]; then
  cat <<'JSON'
{"apiVersion":"v1","items":[
  {"metadata":{"name":"argocd"}},
  {"metadata":{"name":"app-target"}},
  {"metadata":{"name":"tracking-ns","annotations":{"argocd.argoproj.io/tracking-id":"app:/Namespace:tracking-ns"}}},
  {"metadata":{"name":"configsync-ns","annotations":{"config.k8s.io/owning-inventory":"config-management-system_inventory"}}},
  {"metadata":{"name":"owner-ns","ownerReferences":[{"apiVersion":"v1","kind":"ConfigMap","name":"owner","uid":"1"}]}},
  {"metadata":{"name":"hcp-labeled","labels":{"hypershift.openshift.io/hosted-control-plane":"true"}}},
  {"metadata":{"name":"hosted-ns"}},
  {"metadata":{"name":"kube-system"}},
  {"metadata":{"name":"default"}}
]}
JSON
elif [[ "${args}" == *" get applications.argoproj.io "* ]]; then
  cat <<'JSON'
{"apiVersion":"argoproj.io/v1alpha1","items":[
  {"metadata":{"name":"local","namespace":"argocd"},"spec":{"destination":{"server":"https://kubernetes.default.svc","namespace":"app-target"}},"status":{"resources":[{"namespace":"kube-system"},{"namespace":"default"}]}},
  {"metadata":{"name":"remote","namespace":"stale-namespace"},"spec":{"destination":{"server":"https://remote.example","namespace":"remote-target"}}}
]}
JSON
elif [[ "${args}" == *" get hostedclusters.hypershift.openshift.io "* ]]; then
  printf '%s\n' '{"apiVersion":"hypershift.openshift.io/v1beta1","items":[{"metadata":{"name":"hc","namespace":"hosted-ns"}}]}'
elif [[ "${args}" == *" api-resources "* ]]; then
  printf '%s\n' 'NAME SHORTNAMES APIVERSION NAMESPACED KIND'
  printf '%s\n' 'pods po v1 true Pod'
elif [[ "${args}" == *" get nodes "* || "${args}" == *" get persistentvolumes "* || "${args}" == *" get storageclasses.storage.k8s.io "* || "${args}" == *" get volumeattachments.storage.k8s.io "* ]]; then
  printf '%s\n' '{"apiVersion":"v1","items":[]}'
elif [[ "${args}" == *" get applicationsets.argoproj.io "* || "${args}" == *" get nodepools.hypershift.openshift.io "* || "${args}" == *" get hostedcontrolplanes.hypershift.openshift.io "* || "${args}" == *" get machines.cluster.x-k8s.io "* || "${args}" == *" get machinedeployments.cluster.x-k8s.io "* || "${args}" == *" get gcpmachines.infrastructure.cluster.x-k8s.io "* ]]; then
  printf '%s\n' '{"apiVersion":"v1","items":[]}'
else
  echo "unexpected kubectl invocation: $*" >&2
  exit 2
fi
FAKE

  cat >"${bin_dir}/oc" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "oc $*" >>"${FAKE_LOG_DIR}/commands.log"

dest=""
for arg in "$@"; do
  case "${arg}" in
    --dest-dir=*) dest="${arg#--dest-dir=}" ;;
  esac
done

if [[ " $* " == *" adm inspect namespace/"* ]]; then
  namespace="$(printf '%s\n' "$*" | sed -n 's#.*adm inspect namespace/\([^ ]*\).*#\1#p')"
  mkdir -p "${dest}/core" "${dest}/inspect-output"
  printf '%s\n' 'apiVersion: v1' 'kind: Secret' 'data: {}' >"${dest}/core/secrets.yaml"
  printf 'inspection output for %s\n' "${namespace}" >"${dest}/inspect-output/result.txt"
  if [[ "${namespace}" == "app-target" && "$*" == *"region-kubeconfig"* ]]; then
    printf '%s\n' 'partial output survived' >"${dest}/inspect-output/partial.txt"
    exit 1
  fi
  exit 0
fi

if [[ " $* " == *" get nodes "* ]]; then
  printf '%s\n' 'NAME STATUS' 'worker-0 Ready'
  exit 0
fi

if [[ " $* " == *" adm must-gather "* ]]; then
  mkdir -p "${dest}/quay-io-openshift-release-dev-ocp-v4-0-art-dev-sha256-test"
  printf '%s\n' 'hosted cluster diagnostics' >"${dest}/quay-io-openshift-release-dev-ocp-v4-0-art-dev-sha256-test/gather.log"
  exit 0
fi

echo "unexpected oc invocation: $*" >&2
exit 2
FAKE

  cat >"${bin_dir}/gcphcpctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "gcphcpctl $*" >>"${FAKE_LOG_DIR}/commands.log"
[[ " $* " == *" cluster login "* ]] || exit 2
if [[ "${FAKE_FAIL_HOSTED_LOGIN:-false}" == "true" ]]; then
  exit 1
fi
kubeconfig=""
while (( $# > 0 )); do
  if [[ "$1" == "--kubeconfig" ]]; then
    kubeconfig="$2"
    break
  fi
  shift
done
[[ -n "${kubeconfig}" ]] || exit 2
printf '%s\n' 'apiVersion: v1' 'kind: Config' >"${kubeconfig}"
FAKE

  cat >"${bin_dir}/timeout" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
FAKE

  chmod +x "${bin_dir}"/*
}

seed_shared_dir() {
  local shared_dir="$1"
  mkdir -p "${shared_dir}"
  printf '%s\n' '{}' >"${shared_dir}/wif-cred.json"
  printf '%s\n' 'region-project' >"${shared_dir}/region-project-id"
  printf '%s\n' 'region-cluster' >"${shared_dir}/region-cluster-name"
  printf '%s\n' 'management-project' >"${shared_dir}/mc-project-id"
  printf '%s\n' 'management-cluster' >"${shared_dir}/mc-cluster-name"
  printf '%s\n' 'customer-project' >"${shared_dir}/customer-project-id"
  printf '%s\n' 'e2e-hosted' >"${shared_dir}/hosted-cluster-name"
  printf '%s\n' 'e2e-workers' >"${shared_dir}/nodepool-name"
  printf '%s\n' 'infra-1234' >"${shared_dir}/hosted-cluster-infra-id"
  printf '%s\n' 'https://api.example.test' >"${shared_dir}/api-endpoint"
  printf '%s\n' 'https://oidc.example.test' >"${shared_dir}/oidc-endpoint"
  printf '%s\n' '0123456789abcdef0123456789abcdef01234567' >"${shared_dir}/tested-sha"
}

run_case() {
  local case_name="$1"
  shift
  local case_dir="${test_root}/${case_name}"
  local shared_dir="${case_dir}/shared"
  local artifact_dir="${case_dir}/artifacts"
  local bin_dir="${case_dir}/bin"
  local log_dir="${case_dir}/logs"

  mkdir -p "${artifact_dir}" "${log_dir}"
  seed_shared_dir "${shared_dir}"
  write_fakes "${bin_dir}"

  env \
    PATH="${bin_dir}:${PATH}" \
    SHARED_DIR="${shared_dir}" \
    ARTIFACT_DIR="${artifact_dir}" \
    FAKE_LOG_DIR="${log_dir}" \
    BUILD_ID="123" \
    GCP_REGION="us-central1" \
    "$@" \
    bash "${gather_script}" >"${log_dir}/gather.log" 2>&1

  printf '%s\n' "${case_dir}"
}

test_success_and_partial() {
  local case_dir
  case_dir="$(run_case success)"
  local gather_dir="${case_dir}/artifacts/gather"

  assert_file "${gather_dir}/summary.json"
  assert_file "${gather_dir}/manifest.json"
  jq empty "${gather_dir}/summary.json"
  jq empty "${gather_dir}/manifest.json"

  for archive in region-cluster management-cluster hosted-cluster customer-project; do
    assert_file "${gather_dir}/${archive}.tar.gz"
  done

  assert_jq '.schema_version == 1 and .build_id == "123" and .tested_sha == "0123456789abcdef0123456789abcdef01234567"' "${gather_dir}/summary.json"
  assert_jq '.scopes[] | select(.name == "region-cluster") | .status == "partial"' "${gather_dir}/summary.json"
  assert_jq '.scopes[] | select(.name == "management-cluster") | .status == "success"' "${gather_dir}/summary.json"
  assert_jq '.scopes[] | select(.name == "hosted-cluster") | .status == "success"' "${gather_dir}/summary.json"
  assert_jq '.scopes[] | select(.name == "customer-project") | .status == "success"' "${gather_dir}/summary.json"
  assert_jq 'length == 4 and all(.[]; has("sha256") and has("bytes") and has("chai_readable"))' "${gather_dir}/manifest.json"

  if find "${case_dir}/artifacts" -type f -iname '*kubeconfig*' | grep -q .; then
    fail "kubeconfig leaked into ARTIFACT_DIR"
  fi
  grep -q 'gcphcpctl cluster login e2e-hosted --kubeconfig /' "${case_dir}/logs/commands.log" || fail "gcphcpctl did not use a temporary kubeconfig"
  if grep 'gcphcpctl cluster login' "${case_dir}/logs/commands.log" | grep -q "${case_dir}/artifacts"; then
    fail "hosted cluster login wrote kubeconfig under ARTIFACT_DIR"
  fi

  local extract_dir="${case_dir}/region-extracted"
  mkdir -p "${extract_dir}"
  tar -xzf "${gather_dir}/region-cluster.tar.gz" -C "${extract_dir}"
  local selected
  selected="$(find "${extract_dir}" -name selected-namespaces.txt -print -quit)"
  assert_file "${selected}"
  for namespace in argocd app-target tracking-ns configsync-ns owner-ns hcp-labeled hosted-ns; do
    grep -qx "${namespace}" "${selected}" || fail "namespace not selected: ${namespace}"
  done
  for namespace in default kube-system stale-namespace remote-target; do
    if grep -qx "${namespace}" "${selected}"; then
      fail "namespace selected from incidental or stale metadata: ${namespace}"
    fi
  done
  find "${extract_dir}" -name partial.txt -type f -print -quit | grep -q . || fail "partial inspect output was discarded"
  if find "${extract_dir}" -path '*/core/secrets.yaml' -type f | grep -q .; then
    fail "redacted Secret manifests were packaged"
  fi
  if grep -q 'cluster-info dump' "${case_dir}/logs/commands.log"; then
    fail "kubectl cluster-info dump must not be used"
  fi
}

test_hosted_login_failure_is_isolated() {
  local case_dir
  case_dir="$(run_case hosted-failure FAKE_FAIL_HOSTED_LOGIN=true)"
  local summary="${case_dir}/artifacts/gather/summary.json"

  assert_jq '.scopes[] | select(.name == "hosted-cluster") | .status == "unavailable"' "${summary}"
  assert_jq '[.scopes[] | select(.name != "hosted-cluster") | .status] | all(. != "unavailable")' "${summary}"
  assert_no_file "${case_dir}/artifacts/gather/hosted-cluster.tar.gz"
}

test_size_boundary() {
  local case_dir
  case_dir="$(run_case size-boundary FAKE_LARGE_CUSTOMER=true)"
  local summary="${case_dir}/artifacts/gather/summary.json"

  assert_jq '.scopes[] | select(.name == "customer-project") | .bytes >= 20971520 and .chai_readable == false' "${summary}"
}

test_credential_quarantine() {
  local case_dir
  case_dir="$(run_case quarantine FAKE_QUARANTINE_CUSTOMER=true)"
  local gather_dir="${case_dir}/artifacts/gather"

  assert_file "${gather_dir}/summary.json"
  assert_jq '.scopes[] | select(.name == "customer-project") | .status == "unavailable" and (.errors | index("safety-scan: credential marker detected"))' "${gather_dir}/summary.json"
  assert_no_file "${gather_dir}/customer-project.tar.gz"
}

test_workflow_order() {
  local workflow_file="${repo_root}/ci-operator/step-registry/gcp-hcp/e2e/gcp-hcp-e2e-workflow.yaml"
  local expected_post actual_post
  expected_post=$'    - ref: gcp-hcp-gather\n    - ref: gcp-hcp-cleanup-infrastructure\n    - ref: gcp-hcp-finalize-commit-status'
  actual_post="$(awk '
    /^    post:$/ { in_post = 1; next }
    in_post && /^  documentation:/ { exit }
    in_post { print }
  ' "${workflow_file}")"

  grep -qx '    allow_best_effort_post_steps: true' "${workflow_file}" || fail "workflow must allow every best-effort post step to run"
  [[ "${actual_post}" == "${expected_post}" ]] || fail "unexpected workflow post-step order: ${actual_post}"
}

main() {
  [[ "${1:-all}" == "all" ]] || fail "usage: $0 all"
  [[ -f "${gather_script}" ]] || fail "gather script does not exist: ${gather_script}"
  command -v jq >/dev/null || fail "jq is required"

  test_root="$(mktemp -d)"
  trap 'rm -rf "${test_root}"' EXIT

  test_success_and_partial
  test_hosted_login_failure_is_isolated
  test_size_boundary
  test_credential_quarantine
  test_workflow_order
  echo "PASS: gcp-hcp gather harness"
}

main "$@"
