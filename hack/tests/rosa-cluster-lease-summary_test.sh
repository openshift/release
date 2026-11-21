#!/bin/bash

# Behavioral tests for the ROSA cluster lease summary accounting.
#
# A cluster whose OCM state is pending/installing/waiting is still being built.
# It is neither broken nor usable capacity, so the controller and health reports
# must count it separately instead of folding it into "healthy". These tests run
# both step scripts against a mocked `oc` and `ocm` on PATH (plus `rosa`, `aws`
# and `sleep` stubs that keep a drifting run away from live cloud tooling) and
# assert the resulting summary lines, including that the lease state transitions
# those runs perform are unchanged.
#
# Unlike the other test in this directory, these cannot mock `jq`: the scripts
# under test drive jq with dozens of non-trivial filters, and the controller
# parses its desired state with `python3`. Both must therefore be real. The CI
# image that runs hack/validate-registry-commands.sh
# (clusters/app.ci/supplemental-ci-images/validation-images/shellcheck) installs
# only make, git, findutils and ShellCheck, so these tests SKIP there and are
# exercised by developers running the validator locally. Adding `jq` and
# `python3` to that image's BuildConfig would switch them on in CI; that image
# is GitOps-managed and shared by every step-registry PR, so it is deliberately
# left to a separate change.

set -o nounset
set -o errexit
set -o pipefail

# Report rather than fail when the host cannot run these tests at all.
missing_tools=()
for required_tool in jq python3; do
  command -v "${required_tool}" > /dev/null 2>&1 || missing_tools+=("${required_tool}")
done
if (( ${#missing_tools[@]} > 0 )); then
  echo "SKIP: rosa cluster lease summary tests require ${missing_tools[*]}, which are not available here." >&2
  echo "SKIP: see the comment at the top of ${BASH_SOURCE[0]} for how to enable them in CI." >&2
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
LEASE_DIR="${REPO_ROOT}/ci-operator/step-registry/rosa/cluster-lease"
CONTROLLER_SCRIPT="${LEASE_DIR}/controller/rosa-cluster-lease-controller-commands.sh"
HEALTH_SCRIPT="${LEASE_DIR}/health/rosa-cluster-lease-health-commands.sh"
TEST_ROOT=$(mktemp -d)

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Dump a file for context on failure. A run that died early may not have written
# it at all, and `sed` on a missing file would abort the assertion under errexit
# before its FAIL message was printed.
dump() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    sed -n '1,240p' "${file}" >&2
  else
    echo "(${file} was never written)" >&2
  fi
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq -- "${expected}" "${file}" 2>/dev/null; then
    dump "${file}"
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  # A missing file would make grep report "not found" and pass vacuously.
  [[ -f "${file}" ]] || fail "expected ${file} to exist"
  if grep -Fq -- "${unexpected}" "${file}" 2>/dev/null; then
    dump "${file}"
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

# Counts matching lines, which equals occurrences for the single-token-per-line
# report entries these tests assert on.
assert_occurrences() {
  local file="$1" expected="$2" count="$3" actual
  actual=$(grep -Fc -- "${expected}" "${file}" 2>/dev/null || true)
  if [[ "${actual}" != "${count}" ]]; then
    dump "${file}"
    fail "expected '${expected}' ${count} time(s) in ${file}, got '${actual}'"
  fi
}

# No fixture in this file should reach the cloud tooling stubbed in make_mocks.
assert_no_unexpected_calls() {
  local case_dir="$1"
  local unexpected="${case_dir}/state/unexpected-calls"
  if [[ -e "${unexpected}" ]]; then
    dump "${unexpected}"
    fail "run reached cloud tooling that these tests do not mock"
  fi
}

# Emit a lease ConfigMap as the controller and health scripts expect to read it.
cluster_cm() {
  local name="$1" status="$2" cluster_id="$3" acquired_at="${4:-}"
  local registered
  # Relative so the fixtures never age into a different code path.
  registered=$(minutes_ago 60)
  jq -n \
    --arg name "${name}" \
    --arg status "${status}" \
    --arg id "${cluster_id}" \
    --arg acquired "${acquired_at}" \
    --arg registered "${registered}" \
    --arg holder "$([[ "${status}" == "in-use" ]] && echo "ci-job" || echo "")" \
    '{
      metadata: {
        name: $name,
        namespace: "rosa-cluster-lease",
        creationTimestamp: $registered,
        labels: {
          "rosa-cluster-lease/managed": "true",
          "rosa-cluster-lease/status": $status,
          "rosa-cluster-lease/type": "classic-sts",
          "rosa-cluster-lease/env": "staging",
          "rosa-cluster-lease/region": "us-east-1",
          "rosa-cluster-lease/version": "4.22"
        },
        annotations: {
          "rosa-cluster-lease/holder": $holder,
          "rosa-cluster-lease/build-id": "",
          "rosa-cluster-lease/acquired-at": $acquired,
          "rosa-cluster-lease/released-at": "",
          "rosa-cluster-lease/registered-at": $registered
        }
      },
      data: {
        "cluster-id": $id,
        "cluster-name": $name,
        "api-url": "https://api.\($name).example.com:6443",
        "region": "us-east-1",
        "version": "4.22.0",
        "ocm-env": "staging"
      }
    }'
}

# Emit the OCM cluster document the scripts query by cluster id.
ocm_cluster() {
  local name="$1" cluster_id="$2" state="$3"
  jq -n \
    --arg name "${name}" \
    --arg id "${cluster_id}" \
    --arg state "${state}" \
    '{
      kind: "Cluster",
      id: $id,
      href: "/api/clusters_mgmt/v1/clusters/\($id)",
      name: $name,
      openshift_version: "4.22.0",
      api: { url: "https://api.\($name).example.com:6443" },
      status: { state: $state }
    }'
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  # Serves lease ConfigMaps from the fixture directory and accepts every
  # mutation, so a run exercises the real control flow without a cluster.
  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash
set -o nounset
set -o pipefail

argv=()
for arg in "$@"; do
  [[ "${arg}" == --kubeconfig=* ]] || argv+=("${arg}")
done
set -- "${argv[@]}"
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/oc-calls"

verb="${1:-}"
[[ $# -eq 0 ]] || shift

case "${verb}" in
  get)
    ;;
  apply|replace)
    cat >> "${MOCK_STATE_DIR}/oc-stdin"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

resource="${1:-}"
[[ $# -eq 0 ]] || shift
case "${resource}" in
  configmap|configmaps|cm)
    ;;
  *)
    printf '%s\n' '{"items":[]}'
    exit 0
    ;;
esac

name=""
selector=""
while (( $# > 0 )); do
  case "$1" in
    -l|--selector)
      selector="${2:-}"
      # A flag with no value would otherwise leave $# unchanged and spin here.
      shift 2 2>/dev/null || break
      ;;
    -n|--namespace|-o|--output)
      shift 2 2>/dev/null || break
      ;;
    -*)
      shift
      ;;
    *)
      name="$1"
      shift
      ;;
  esac
done

if [[ "${name}" == "rosa-cluster-lease-config" ]]; then
  cat "${MOCK_FIXTURE_DIR}/lease-config.json"
  exit 0
fi

if [[ -n "${name}" ]]; then
  jq -e --arg n "${name}" '.items[] | select(.metadata.name == $n)' \
    "${MOCK_FIXTURE_DIR}/clusters.json" || exit 1
  exit 0
fi

status=""
if [[ "${selector}" == *"rosa-cluster-lease/status="* ]]; then
  status="${selector##*rosa-cluster-lease/status=}"
  status="${status%%,*}"
fi

jq --arg s "${status}" '
  if $s == "" then
    .
  else
    {items: [.items[] | select(.metadata.labels["rosa-cluster-lease/status"] == $s)]}
  end
' "${MOCK_FIXTURE_DIR}/clusters.json"
EOF

  # Answers cluster lookups from the fixture directory; an unknown id returns
  # the OCM 404 error document, which the scripts treat as "not-found".
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
set -o nounset

printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-calls"

case "${1:-}" in
  get)
    ;;
  login)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

path="${2:-}"
case "${path}" in
  */credentials)
    # No cluster credentials are served, so the in-cluster RBAC and
    # ClusterPackage probes self-skip. Matched before the cluster-id branch
    # below, which would otherwise read this as a cluster named "credentials".
    printf '%s\n' '{"kind":"Error","id":"404","code":"CLUSTERS-MGMT-404","reason":"Credentials not available"}'
    exit 1
    ;;
  /api/clusters_mgmt/v1/clusters/*)
    id="${path##*/}"
    if [[ -f "${MOCK_FIXTURE_DIR}/ocm-${id}.json" ]]; then
      cat "${MOCK_FIXTURE_DIR}/ocm-${id}.json"
      exit 0
    fi
    printf '%s\n' '{"kind":"Error","id":"404","code":"CLUSTERS-MGMT-404","reason":"Cluster not found"}'
    exit 1
    ;;
esac

printf '%s\n' '{"items":[]}'
EOF

  # The fixtures below never reach the provisioning or decommission phases, so
  # `rosa` and `aws` must not be called. Stub them anyway: without a stub, drift
  # in a fixture or in the scripts would reach the host's real cloud tooling and
  # talk to a live account. The wait loops around those calls also sleep for
  # minutes at a time, so `sleep` is stubbed out to keep a drifting run fast.
  cat > "${mock_dir}/rosa" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/unexpected-calls"
echo "rosa must not be called by these tests: $*" >&2
exit 1
EOF

  cat > "${mock_dir}/aws" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/unexpected-calls"
echo "aws must not be called by these tests: $*" >&2
exit 1
EOF

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

  chmod 0755 "${mock_dir}/oc" "${mock_dir}/ocm" "${mock_dir}/rosa" \
    "${mock_dir}/aws" "${mock_dir}/sleep"
}

# Build a case directory with mocks, credentials and an empty fixture set.
new_case() {
  local case_dir="$1"
  mkdir -p "${case_dir}/state" "${case_dir}/fixtures" "${case_dir}/artifacts" \
    "${case_dir}/profile" "${case_dir}/tmp"
  make_mocks "${case_dir}/bin"
  printf 'fake-ocm-token' > "${case_dir}/profile/ocm-token"
  printf 'fake-kubeconfig' > "${case_dir}/lease-kubeconfig"
  printf '%s\n' '{"items":[]}' > "${case_dir}/fixtures/clusters.json"
}

# Replace the managed ConfigMap list with the supplied ConfigMap documents.
set_clusters() {
  local case_dir="$1"
  shift
  printf '%s\n' "$@" | jq -s '{items: .}' > "${case_dir}/fixtures/clusters.json"
}

set_ocm_cluster() {
  local case_dir="$1" cluster_id="$2" document="$3"
  printf '%s\n' "${document}" > "${case_dir}/fixtures/ocm-${cluster_id}.json"
}

# The controller refuses to reconcile an empty desired state, so every desired
# cluster is listed; that also keeps the decommission phase a no-op.
set_desired() {
  local case_dir="$1"
  shift
  local desired=""
  local name
  for name in "$@"; do
    desired+="- name: ${name}"$'\n'
    desired+="  env: staging"$'\n'
    desired+="  region: us-east-1"$'\n'
    desired+="  type: classic-sts"$'\n'
    desired+="  version: \"4.22\""$'\n'
  done
  jq -n --arg desired "${desired}" '{
    apiVersion: "v1",
    kind: "ConfigMap",
    metadata: {name: "rosa-cluster-lease-config", namespace: "rosa-cluster-lease"},
    data: {"desired-clusters": $desired}
  }' > "${case_dir}/fixtures/lease-config.json"
}

# Every step parameter is pinned, so a change to an in-script default cannot
# silently move these cases onto a different code path. MAX_CLUSTER_AGE_HOURS=0
# disables age-based refresh, which would otherwise make the run depend on the
# day of the week. LC_ALL/LANG/BASH_ENV are pinned because the scripts capture
# stderr into values they parse as JSON: a locale the host does not have
# installed makes bash print a setlocale warning there and every OCM lookup
# then fails.
run_lease_script() {
  local script="$1" case_dir="$2"
  env \
    LC_ALL=C \
    LANG=C \
    BASH_ENV= \
    PATH="${case_dir}/bin:${PATH}" \
    TMPDIR="${case_dir}/tmp" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_FIXTURE_DIR="${case_dir}/fixtures" \
    ARTIFACT_DIR="${case_dir}/artifacts" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    LEASE_HOST_KUBECONFIG="${case_dir}/lease-kubeconfig" \
    LEASE_NAMESPACE=rosa-cluster-lease \
    OCM_LOGIN_ENV=staging \
    STALE_LEASE_HOURS=4 \
    ERROR_REPLACE_HOURS=1 \
    MAX_CLUSTER_AGE_HOURS=0 \
    REFRESH_DAY=6 \
    MAX_REFRESH_PER_RUN=2 \
    DRY_RUN=false \
    bash "${script}" > "${case_dir}/output.log" 2>&1
}

minutes_ago() {
  local minutes="$1"
  date -u -d "-${minutes} minutes" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v"-${minutes}M" '+%Y-%m-%dT%H:%M:%SZ'
}

# The controller must not report a cluster that OCM is still installing as
# healthy, while a cluster that finished installing during the run still is.
test_controller_counts_provisioning_separately() {
  local case_dir="${TEST_ROOT}/controller-summary"
  local report="${case_dir}/artifacts/controller-report.txt"
  new_case "${case_dir}"

  # lease-available exercises the steady-state path that most of the inventory
  # takes; its RBAC and ClusterPackage probes self-skip because the mock serves
  # no cluster credentials, leaving it counted as plain healthy.
  set_clusters "${case_dir}" \
    "$(cluster_cm lease-available available available-id)" \
    "$(cluster_cm lease-ready in-use ready-id "$(minutes_ago 5)")" \
    "$(cluster_cm lease-installing provisioning installing-id)" \
    "$(cluster_cm lease-pending provisioning pending-id)" \
    "$(cluster_cm lease-became-ready provisioning became-ready-id)" \
    "$(cluster_cm lease-gone provisioning gone-id)"
  set_ocm_cluster "${case_dir}" available-id "$(ocm_cluster lease-available available-id ready)"
  set_ocm_cluster "${case_dir}" ready-id "$(ocm_cluster lease-ready ready-id ready)"
  set_ocm_cluster "${case_dir}" installing-id "$(ocm_cluster lease-installing installing-id installing)"
  set_ocm_cluster "${case_dir}" pending-id "$(ocm_cluster lease-pending pending-id pending)"
  set_ocm_cluster "${case_dir}" became-ready-id "$(ocm_cluster lease-became-ready became-ready-id ready)"
  # lease-gone has no OCM fixture, so the lookup returns the 404 document.
  set_desired "${case_dir}" lease-available lease-ready lease-installing lease-pending \
    lease-became-ready lease-gone

  # The log lives under TEST_ROOT, which the EXIT trap removes, so dump it here
  # rather than pointing at a path that will be gone.
  run_lease_script "${CONTROLLER_SCRIPT}" "${case_dir}" \
    || { dump "${case_dir}/output.log"; fail "controller run failed"; }

  assert_contains "${report}" "Summary: 3 healthy, 2 provisioning, 1 unhealthy, 0 recovered"
  assert_contains "${case_dir}/output.log" \
    "Controller reconcile complete: 3 healthy, 2 provisioning, 1 unhealthy, 0 recovered"
  # Before the fix both installing clusters were folded into the healthy count.
  assert_not_contains "${report}" "Summary: 5 healthy"

  # Per-cluster classification is unchanged.
  assert_contains "${report}" "PROVISIONING: lease-installing (OCM: installing)"
  assert_contains "${report}" "PROVISIONING: lease-pending (OCM: pending)"
  assert_contains "${report}" "IN-USE: lease-ready by ci-job (OCM: ready)"
  assert_contains "${report}" "PROVISIONED: lease-became-ready (available)"
  assert_contains "${report}" "STALE PROVISIONING: lease-gone (removed, will reprovision next run)"

  # Lease state transitions still happen: the finished cluster is published as
  # available and the vanished one is dropped from the inventory.
  assert_contains "${case_dir}/state/oc-calls" "patch configmap lease-became-ready"
  assert_contains "${case_dir}/state/oc-calls" "delete configmap lease-gone"
  # A still-installing cluster is left alone for the next reconcile, and so is a
  # steady-state available one.
  assert_not_contains "${case_dir}/state/oc-calls" "patch configmap lease-installing"
  assert_not_contains "${case_dir}/state/oc-calls" "delete configmap lease-installing"
  assert_not_contains "${case_dir}/state/oc-calls" "patch configmap lease-available"
  # Everything desired already exists, so nothing is provisioned.
  assert_not_contains "${report}" "PROVISION: "
  assert_no_unexpected_calls "${case_dir}"
}

# The health step skips health checks for provisioning clusters; the summary
# must say so instead of counting them as healthy.
test_health_counts_provisioning_separately() {
  local case_dir="${TEST_ROOT}/health-summary"
  local report="${case_dir}/artifacts/lease-health-report.txt"
  new_case "${case_dir}"

  set_clusters "${case_dir}" \
    "$(cluster_cm lease-ready in-use ready-id "$(minutes_ago 5)")" \
    "$(cluster_cm lease-stale in-use stale-id "$(minutes_ago 600)")" \
    "$(cluster_cm lease-installing provisioning installing-id)" \
    "$(cluster_cm lease-pending provisioning pending-id)" \
    "$(cluster_cm lease-broken available broken-id)"
  set_ocm_cluster "${case_dir}" ready-id "$(ocm_cluster lease-ready ready-id ready)"
  set_ocm_cluster "${case_dir}" stale-id "$(ocm_cluster lease-stale stale-id ready)"
  set_ocm_cluster "${case_dir}" installing-id "$(ocm_cluster lease-installing installing-id installing)"
  set_ocm_cluster "${case_dir}" pending-id "$(ocm_cluster lease-pending pending-id pending)"
  set_ocm_cluster "${case_dir}" broken-id "$(ocm_cluster lease-broken broken-id error)"

  run_lease_script "${HEALTH_SCRIPT}" "${case_dir}" \
    || { dump "${case_dir}/output.log"; fail "health run failed"; }

  assert_contains "${report}" "Summary: 2 healthy, 2 provisioning, 1 unhealthy, 1 recovered"
  # Before the fix both provisioning clusters were counted as healthy.
  assert_not_contains "${report}" "Summary: 4 healthy"
  assert_contains "${case_dir}/output.log" \
    "Lease health check complete: 2 healthy, 2 provisioning, 1 unhealthy, 1 stale leases recovered"

  # Both provisioning clusters skipped the checks; neither reached a probe.
  assert_occurrences "${report}" "Provisioning (skipped)" 2

  # Stale lease recovery and error marking are unaffected by the count change.
  assert_contains "${report}" "RECOVERED: lease force-released"
  assert_contains "${case_dir}/state/oc-calls" "patch configmap lease-stale"
  assert_contains "${case_dir}/state/oc-calls" "patch configmap lease-broken"
  assert_not_contains "${case_dir}/state/oc-calls" "patch configmap lease-installing"
  assert_no_unexpected_calls "${case_dir}"
}

test_controller_counts_provisioning_separately
test_health_counts_provisioning_separately

echo "PASS: rosa cluster lease summary accounting tests"
