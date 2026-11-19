#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/ipi/conf/vsphere/check/vcm/ipi-conf-vsphere-check-vcm-commands.sh"
TEST_ROOT=$(mktemp -d)
cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,120p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

# Load the pure helper functions from the command script without running the
# rest of it.  The command script keeps everything above the
# END_RELEASE_CAPABILITY_HELPERS marker free of side effects so the
# release-capability logic can be exercised on its own; failing when the marker
# is missing prevents the test from silently sourcing the whole step.
extract_script_prefix() {
  awk '
    /^# END_RELEASE_CAPABILITY_HELPERS$/ { found = 1; exit }
    { print }
    END { if (!found) exit 1 }
  ' "${COMMAND_SCRIPT}"
}

release_helpers=$(extract_script_prefix) || fail "END_RELEASE_CAPABILITY_HELPERS marker not found in ${COMMAND_SCRIPT}"
# shellcheck source=/dev/null
source <(printf '%s\n' "${release_helpers}")

# The capability helpers read the job's feature-set configuration; keep the
# unit tests independent from whatever the invoking shell happens to export.
unset FEATURE_SET FEATURE_GATES

test_ocp_version_number() {
  assert_eq "$(ocp_version_number '4.13.0-0.nightly-2026-11-09-144742')" 413 "4.13 payload"
  assert_eq "$(ocp_version_number '4.17.5')" 417 "4.17 z-stream"
  assert_eq "$(ocp_version_number '4.18.0-0.nightly-2026-11-10-000000')" 418 "4.18 payload"
  assert_eq "$(ocp_version_number '5.0.0-0.nightly-2026-11-01-000000')" 500 "5.0 payload"
  assert_eq "$(ocp_version_number '')" "" "empty version"
  assert_eq "$(ocp_version_number 'not-a-version')" "" "unparseable version"
}

test_multi_vcenter_support() {
  (
    local version
    unset FEATURE_SET FEATURE_GATES

    for version in 413 414 415 416 417; do
      if multi_vcenter_install_supported "${version}"; then
        fail "OCP ${version} without the feature gate must not be treated as multi-vCenter capable"
      fi
    done
    for version in 418 419 500; do
      if ! multi_vcenter_install_supported "${version}"; then
        fail "OCP ${version} must be treated as multi-vCenter capable"
      fi
    done
    if ! multi_vcenter_install_supported ""; then
      fail "an unknown release must keep the requested limits (fail open)"
    fi

    export FEATURE_SET=TechPreviewNoUpgrade
    if ! multi_vcenter_install_supported 417; then
      fail "OCP 4.17 with TechPreviewNoUpgrade must be treated as multi-vCenter capable"
    fi
    if multi_vcenter_install_supported 416; then
      fail "OCP 4.16 must not opt in through a feature gate it does not have"
    fi

    unset FEATURE_SET
    export FEATURE_SET=CustomNoUpgrade
    if multi_vcenter_install_supported 417; then
      fail "OCP 4.17 with CustomNoUpgrade must require the explicit gate"
    fi
    export FEATURE_GATES='["VSphereMultiVCenters=true"]'
    if ! multi_vcenter_install_supported 417; then
      fail "OCP 4.17 with an explicit VSphereMultiVCenters gate must be treated as multi-vCenter capable"
    fi
    export FEATURE_GATES='["VSphereMultiVCenters=false"]'
    if multi_vcenter_install_supported 417; then
      fail "OCP 4.17 with the gate explicitly disabled must not be treated as multi-vCenter capable"
    fi
  )
}

test_release_version_from_image_reference() {
  assert_eq "$(release_version_from_image_reference 'registry.ci.openshift.org/ocp/release:4.13.0-0.nightly-2026-11-09-144742')" "4.13" "versioned 4.13 tag"
  assert_eq "$(release_version_from_image_reference 'registry.ci.openshift.org/ocp/release:4.18.0-0.nightly-2026-11-10-000000')" "4.18" "versioned 4.18 tag"
  assert_eq "$(release_version_from_image_reference 'registry.apps.build02.example/ci-op-x/release@sha256:abcdef')" "" "digest reference"
  assert_eq "$(release_version_from_image_reference 'registry.ci.openshift.org/ocp/release:latest')" "" "non-version tag"
  assert_eq "$(release_version_from_image_reference '')" "" "empty reference"
}

test_release_lease_limits() {
  assert_eq "$(apply_release_lease_limits 413 3 4 '')" "1 3" "4.13 caps vCenters and pools"
  assert_eq "$(apply_release_lease_limits 417 1 4 '')" "1 3" "4.17 caps pools even when vCenters is already 1"
  assert_eq "$(apply_release_lease_limits 413 3 2 '')" "1 2" "4.13 keeps a smaller pool request"
  assert_eq "$(apply_release_lease_limits 413 3 4 'pool-a pool-b')" "1 4" "explicit pools leave the lease count alone"
  assert_eq "$(apply_release_lease_limits 418 3 4 '')" "3 4" "4.18 keeps the requested limits"
  assert_eq "$(apply_release_lease_limits 500 2 1 '')" "2 1" "5.x keeps the requested limits"
  assert_eq "$(apply_release_lease_limits '' 3 4 '')" "3 4" "unknown release keeps the requested limits"

  (
    export FEATURE_SET=TechPreviewNoUpgrade
    assert_eq "$(apply_release_lease_limits 417 3 4 '')" "3 4" "4.17 with the feature gate keeps the requested limits"
  )
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  # The step only uses jq to read .metadata.version; a minimal stand-in keeps
  # the test independent of whether the shellcheck image ships jq.
  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash

cat | grep -o '"version":"[^"]*"' | sed 's/.*"version":"//; s/"$//' || true
EOF

  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash

case "$*" in
  "get istag release:initial"*)
    if [[ -z "${MOCK_INITIAL_IMAGE:-}" ]]; then
      echo 'Error from server (NotFound): imagestreamtags.image.openshift.io "release:initial" not found' >&2
      exit 1
    fi
    printf '%s\n' "${MOCK_INITIAL_IMAGE}"
    ;;
  "registry login "*)
    exit 0
    ;;
  "adm release info "*)
    if [[ "${MOCK_RELEASE_INFO_FAILS:-}" == "true" ]]; then
      echo 'error: unable to read image: unauthorized: authentication required' >&2
      exit 1
    fi
    image="${@: -2:1}"
    case "${image}" in
      *4.13*)
        printf '{"metadata":{"version":"4.13.0-0.nightly-2026-11-09-144742"}}\n'
        ;;
      *4.18*)
        printf '{"metadata":{"version":"4.18.0-0.nightly-2026-11-10-000000"}}\n'
        ;;
      *)
        printf '{"metadata":{}}\n'
        ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "${mock_dir}"/oc "${mock_dir}"/jq
}

run_release_case() {
  local name="$1" initial_image="$2" latest_image="$3" initial_override="$4" release_info_fails="${5:-}"
  local case_dir="${TEST_ROOT}/${name}"

  mkdir -p "${case_dir}/bin" "${case_dir}/tmp" "${case_dir}/profile" "${case_dir}/state"
  make_mocks "${case_dir}/bin"
  printf '%s' '{"auths":{}}' > "${case_dir}/profile/pull-secret"

  (
    unset FEATURE_SET FEATURE_GATES
    export PATH="${case_dir}/bin:${PATH}"
    export TMPDIR="${case_dir}/tmp"
    export MOCK_INITIAL_IMAGE="${initial_image}"
    export MOCK_RELEASE_INFO_FAILS="${release_info_fails}"
    export NAMESPACE="test-namespace"
    export CLUSTER_PROFILE_DIR="${case_dir}/profile"
    export RELEASE_IMAGE_LATEST_FROM_BUILD_FARM="${latest_image}"
    if [[ -n "${initial_override}" ]]; then
      export RELEASE_IMAGE_INITIAL="${initial_override}"
    else
      unset RELEASE_IMAGE_INITIAL
    fi

    image=$(determine_install_release_image)
    version=$(install_release_version "${image}")
    if [[ -z "${version}" ]]; then
      version=$(release_version_from_image_reference "${image}")
    fi
    ocp_version=$(ocp_version_number "${version}")
    printf 'image=%s\nversion=%s\nocp=%s\nlimits=%s\n' \
      "${image}" "${version}" "${ocp_version}" \
      "$(apply_release_lease_limits "${ocp_version}" 3 4 '')"
  ) > "${case_dir}/output.log" 2>&1 || fail "${name}: release capability resolution failed"
}

test_upgrade_uses_initial_release() {
  local initial_image="registry.ci.openshift.org/ocp/release:4.13.0-0.nightly-2026-11-09-144742"
  local latest_image="registry.ci.openshift.org/ocp/release:4.18.0-0.nightly-2026-11-10-000000"
  local output

  run_release_case upgrade_initial "${initial_image}" "${latest_image}" ""
  output="${TEST_ROOT}/upgrade_initial/output.log"
  assert_contains "${output}" "image=${initial_image}"
  assert_contains "${output}" "version=4.13.0-0.nightly-2026-11-09-144742"
  assert_contains "${output}" "ocp=413"
  assert_contains "${output}" "limits=1 3"
}

test_newer_initial_keeps_multi_vcenter() {
  local initial_image="registry.ci.openshift.org/ocp/release:4.18.0-0.nightly-2026-11-10-000000"
  local latest_image="registry.ci.openshift.org/ocp/release:4.19.0-0.nightly-2026-11-11-000000"
  local output

  run_release_case newer_initial "${initial_image}" "${latest_image}" ""
  output="${TEST_ROOT}/newer_initial/output.log"
  assert_contains "${output}" "image=${initial_image}"
  assert_contains "${output}" "ocp=418"
  assert_contains "${output}" "limits=3 4"
}

test_falls_back_to_latest_when_initial_missing() {
  local latest_image="registry.ci.openshift.org/ocp/release:4.18.0-0.nightly-2026-11-10-000000"
  local output

  run_release_case no_initial "" "${latest_image}" ""
  output="${TEST_ROOT}/no_initial/output.log"
  assert_contains "${output}" "image=${latest_image}"
  assert_contains "${output}" "ocp=418"
  assert_contains "${output}" "limits=3 4"
}

test_upgrade_falls_back_to_image_tag() {
  local initial_image="registry.ci.openshift.org/ocp/release:4.13.0-0.nightly-2026-11-09-144742"
  local latest_image="registry.ci.openshift.org/ocp/release:4.18.0-0.nightly-2026-11-10-000000"
  local output

  run_release_case tag_fallback "${initial_image}" "${latest_image}" "" true
  output="${TEST_ROOT}/tag_fallback/output.log"
  assert_contains "${output}" "image=${initial_image}"
  assert_contains "${output}" "version=4.13"
  assert_contains "${output}" "ocp=413"
  assert_contains "${output}" "limits=1 3"
}

test_explicit_initial_env_wins() {
  local initial_image="registry.ci.openshift.org/ocp/release:4.13.0-0.nightly-2026-11-09-144742"
  local latest_image="registry.ci.openshift.org/ocp/release:4.18.0-0.nightly-2026-11-10-000000"
  local output

  run_release_case explicit_initial "${latest_image}" "${latest_image}" "${initial_image}"
  output="${TEST_ROOT}/explicit_initial/output.log"
  assert_contains "${output}" "image=${initial_image}"
  assert_contains "${output}" "ocp=413"
  assert_contains "${output}" "limits=1 3"
}

test_ocp_version_number
test_release_version_from_image_reference
test_multi_vcenter_support
test_release_lease_limits
test_upgrade_uses_initial_release
test_newer_initial_keeps_multi_vcenter
test_falls_back_to_latest_when_initial_missing
test_upgrade_falls_back_to_image_tag
test_explicit_initial_env_wins

echo "PASS: ipi-conf-vsphere-check-vcm release capability tests"
