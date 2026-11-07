#!/bin/bash
set -euo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT
script="$(dirname "$0")/../ci-operator/step-registry/rosa/cluster/wait-ready/cluster/rosa-cluster-wait-ready-cluster-commands.sh"
mkdir -p "${test_dir}/bin"
export PATH="${test_dir}/bin:${PATH}"

cat > "${test_dir}/bin/rosa" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "$1" in
  describe) cat "${FIXTURE}" ;;
  logs) echo 'dial tcp: lookup api.fixture.example.invalid: no such host' ;;
  *) exit 99 ;;
esac
MOCK
cat > "${test_dir}/bin/aws" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${AWS_CALLS}"
[[ "$*" == 'sts get-caller-identity' ]]
exit 1
MOCK
cat > "${test_dir}/bin/dig" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${DIG_CALLS}"
[[ "$1" == +time=2 && "$2" == +tries=1 ]]
if [[ "${SCENARIO}" == failed-probes ]]; then exit 9; fi
if [[ "${SCENARIO}" == failed-authoritative && "$3" == @* ]]; then exit 9; fi
if [[ "${SCENARIO}" == hanging-probe && "$3" == api.fixture.example.invalid ]]; then sleep 30; fi
if [[ "$3" == NS ]]; then echo 'ns.example.invalid.'; fi
MOCK
chmod +x "${test_dir}/bin/"*

cat > "${test_dir}/failure-path.sh" <<'HARNESS'
set -euo pipefail
log() { printf '%s\n' "$*"; }
capture_classic_resources() { :; }
HARNESS
awk '
  /^if \[\[ "\$FAILED_INSTALL" == "yes" \]\]; then$/ { copying = 1 }
  copying { print }
  copying && /^fi$/ { exit }
' "${script}" >> "${test_dir}/failure-path.sh"
grep -q 'dns-diagnostics.txt' "${test_dir}/failure-path.sh"
grep -q '^  exit 1$' "${test_dir}/failure-path.sh"

export FAILED_INSTALL=yes CLUSTER_ID=synthetic HOSTED_CP=false
for SCENARIO in explicit-url fallback null-url empty-url missing-name missing-domain missing-both explicit-no-zone failed-probes failed-authoritative hanging-probe; do
  export SCENARIO
  export ARTIFACT_DIR="${test_dir}/${SCENARIO}"
  export FIXTURE="${ARTIFACT_DIR}/fixture.json"
  export DIG_CALLS="${ARTIFACT_DIR}/dig.calls" AWS_CALLS="${ARTIFACT_DIR}/aws.calls"
  mkdir -p "${ARTIFACT_DIR}"
  : > "${DIG_CALLS}"
  printf '%s\n' '{"name":"fixture","dns":{"base_domain":"example.invalid"}}' > "${FIXTURE}"
  case "${SCENARIO}" in
    explicit-url) mutation='.api.url = "https://api.explicit.example.invalid:6443"' ;;
    explicit-no-zone) mutation='.api.url = "https://api.explicit.example.invalid:443" | del(.name, .dns)' ;;
    null-url) mutation='.api.url = null' ;;
    empty-url) mutation='.api.url = ""' ;;
    missing-name) mutation='del(.name)' ;;
    missing-domain) mutation='del(.dns.base_domain)' ;;
    missing-both) mutation='del(.name, .dns)' ;;
    *) mutation='.' ;;
  esac
  jq "${mutation}" "${FIXTURE}" > "${FIXTURE}.tmp"
  mv "${FIXTURE}.tmp" "${FIXTURE}"
  result=0
  timeout 20 bash -euo pipefail "${test_dir}/failure-path.sh" > "${ARTIFACT_DIR}/output.log" 2>&1 || result=$?
  if [[ "${result}" != 1 ]]; then
    cat "${ARTIFACT_DIR}/output.log"
    echo "FAIL: ${SCENARIO}: expected install failure (1), got ${result}" >&2
    exit 1
  fi
  diagnostics="${ARTIFACT_DIR}/dns-diagnostics.txt"
  grep -q '=== End DNS Diagnostics ===' "${diagnostics}"
  grep -qx 'sts get-caller-identity' "${AWS_CALLS}"
  case "${SCENARIO}" in
    missing-*)
      test ! -s "${DIG_CALLS}"
      grep -q 'skipping DNS probes' "${diagnostics}"
      ;;
    *)
      expected_host=api.fixture.example.invalid
      expected_zone=fixture.example.invalid
      if [[ "${SCENARIO}" == explicit-* ]]; then expected_host=api.explicit.example.invalid; fi
      if [[ "${SCENARIO}" == explicit-no-zone ]]; then expected_zone=explicit.example.invalid; fi
      grep -qxF "+time=2 +tries=1 ${expected_host}" "${DIG_CALLS}"
      test "$(grep -cxF "+time=2 +tries=1 NS ${expected_zone} +short" "${DIG_CALLS}")" = 2
      if [[ "${SCENARIO}" == failed-probes ]]; then
        test "$(wc -l < "${DIG_CALLS}")" = 3
        grep -q 'No authoritative nameservers found' "${diagnostics}"
      else
        test "$(wc -l < "${DIG_CALLS}")" = 4
        grep -qxF "+time=2 +tries=1 @ns.example.invalid. ${expected_host}" "${DIG_CALLS}"
      fi
      ;;
  esac
  printf 'PASS: %s (strict shell, install exit %s)\n' "${SCENARIO}" "${result}"
done
