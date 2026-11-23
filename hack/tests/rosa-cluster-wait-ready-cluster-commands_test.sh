#!/bin/bash

# Offline regression tests for the DNS diagnostics of the
# rosa-cluster-wait-ready-cluster step. Every external command the step calls is
# mocked, so the tests never contact OCM, AWS, a management cluster or a resolver.
# The only file read outside the per-case temporary directory is the host's
# /etc/resolv.conf, and the step only tests whether it is readable: its contents must
# never reach an artifact. Every hostname and address used below is a reserved
# documentation value.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster/wait-ready/cluster/rosa-cluster-wait-ready-cluster-commands.sh"
TEST_ROOT=$(mktemp -d)
cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  [[ -f "${file}" ]] || fail "expected file ${file} to exist"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,240p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  [[ -f "${file}" ]] || fail "expected file ${file} to exist"
  if grep -Fq -- "${unexpected}" "${file}"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file $1 to exist"
}

assert_file_absent() {
  [[ ! -e "$1" ]] || fail "did not expect file $1 to exist"
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_no_secrets() {
  local file="$1"
  assert_not_contains "${file}" 'MOCK_OCM_TOKEN_SECRET'
  assert_not_contains "${file}" 'MOCK_AWS_SECRET_KEY'
  # The step masks AWS account identifiers everywhere it echoes cluster output.
  assert_not_contains "${file}" '123456789012'
}

# A snapshot is a new public artifact, so it must not carry the identifier of the
# cluster it describes: the artifact directory it is written into already says which
# step run produced it.
assert_no_cluster_identifier() {
  local file="$1"
  assert_not_contains "${file}" 'mock-cluster-id'
  assert_contains "${file}" 'no identifier is published here'
}

# These files are published as public CI artifacts, so they must carry no resolver
# infrastructure: neither the address of a resolver nor any part of a resolver
# configuration. 192.0.2.10 stands in for the resolver addresses that appear in dig's
# own output and in the Go resolver errors of the install log.
assert_no_resolver_details() {
  local file="$1"
  [[ -f "${file}" ]] || fail "expected file ${file} to exist"
  # The prefix, not the whole address, so that a fragment left by a truncation that
  # ran before redaction is caught too.
  assert_not_contains "${file}" '192.0.2'
  # An IPv6 resolver address, bracketed or bare, must go the same way.
  assert_not_contains "${file}" '2001:db8'
  # Values that merely look like an IPv6 address must survive: a probe is useless
  # without the time dig recorded for it.
  if grep -Fq ';; WHEN:' "${file}" && ! grep -Fq '16:16:33' "${file}"; then
    fail "expected dig's WHEN timestamp to survive redaction in ${file}"
  fi
  if grep -Eq '^[[:space:]]*(nameserver|search|options)[[:space:]]' "${file}"; then
    grep -nE '^[[:space:]]*(nameserver|search|options)[[:space:]]' "${file}" >&2
    fail "did not expect resolver configuration lines in ${file}"
  fi
  if grep -Eq '^;;.*([0-9]{1,3}\.){3}[0-9]{1,3}' "${file}"; then
    grep -nE '^;;.*([0-9]{1,3}\.){3}[0-9]{1,3}' "${file}" >&2
    fail "did not expect a resolver address in dig's comment lines in ${file}"
  fi
}

# Print the lines of one '=== <section> ===' block of an artifact.
section_of() {
  local file="$1" start="$2" end="$3"
  sed -n "/^=== ${start}/,/^=== ${end}/p" "${file}" | sed '1d;$d'
}

# Labels that let a reader tell where and when a probe ran, and keep a successful
# lookup from being read as evidence about the client that originally failed.
assert_probe_origin_labels() {
  local file="$1"
  assert_contains "${file}" "Probe origin: the ci-operator step pod running this step on the CI build farm."
  assert_contains "${file}" "Probe time:"
  assert_contains "${file}" "It is not the resolver used by the ROSA management cluster or by"
  assert_contains "${file}" "does not make it the same resolver."
  # Presence of a resolver configuration is labelled; its contents are never published.
  assert_contains "${file}" "Probe resolver configuration:"
  assert_contains "${file}" "It is not evidence of what the original client resolved, and it"
  assert_contains "${file}" "does not establish when any record was created, changed or propagated."
  assert_no_resolver_details "${file}"
}

# The Route 53 section is an observation of one viewpoint at one time, and a reader has
# to be able to tell that from the artifact alone.
assert_route53_section_labels() {
  local file="$1"
  assert_contains "${file}" "=== Route 53 evidence (as seen from this CI job) ==="
  assert_contains "${file}" "Read at:"
  assert_contains "${file}" "Read by: rosa-cluster-wait-ready-cluster, in a ci-operator step pod, after the"
  assert_contains "${file}" "Viewpoint: the AWS account this job already holds credentials for."
  assert_contains "${file}" "at the time above, not that it does not exist."
  assert_contains "${file}" "No history: the API returns current state only"
  assert_contains "${file}" "Published fields: only the states and counts below."
  # Every value the section can print is named in the legend, so a reader never has to
  # guess what a state means or whether it could have been something else.
  assert_contains "${file}" "Zone states:"
  assert_contains "${file}" "Zone visibility:"
  assert_contains "${file}" "Record states:"
  assert_contains "${file}" "Topologies:"
  assert_contains "${file}" "Delegation verdict: match | mismatch | not-delegated | not-comparable |"
}

# A reported field and the state line that follows it.
assert_route53_record() {
  local file="$1" label="$2" expected="$3"
  local actual
  actual=$(grep -A1 -Fx -- "${label}" "${file}" | sed -n '2p' || true)
  if [[ "${actual}" != "  ${expected}" ]]; then
    fail "under '${label}' expected '  ${expected}', got '${actual}'"
  fi
}

# Nothing the AWS API returned may be published: not a response body, not a record
# value, not a nameserver name, not a hosted-zone identifier and not an error message.
assert_no_route53_response_content() {
  local file="$1" forbidden
  for forbidden in \
    'ResourceRecordSets' 'HostedZones' '"Value"' 'IsTruncated' 'AliasTarget' \
    'awsdns' 'hostmaster.example' '198.51.100' 'mock-nlb' 'MOCKTYPE' \
    'ZCHILD' 'ZPARENT' 'ZADJACENT' 'ZPRIVATE' 'ZGRANDPARENT' 'ZELB' 'hostedzone' \
    'ZT1' 'ZT5' 'example.net'; do
    assert_not_contains "${file}" "${forbidden}"
  done
}

# Every Route 53 read must be time-bounded and ask for a bounded number of items, only
# this run's own cluster zone and its ancestors may be queried, and the job's
# credentials must be used exactly as they are. ${2} is the number of reads the scenario
# is expected to make, so this cannot pass by there being none.
assert_route53_reads_are_bounded() {
  local case_dir="$1" expected_reads="$2" line allowed
  shift 2
  local -a allowed_zones=("$@")
  local -i reads=0 cli_timeout
  assert_file_exists "${case_dir}/state/aws-arguments"
  # Taken from the step rather than restated here, so the two cannot drift apart.
  cli_timeout=$(sed -nE 's/^ROUTE53_CLI_TIMEOUT=([0-9]+)$/\1/p' "${COMMAND_SCRIPT}")
  (( cli_timeout > 0 )) || fail "could not read ROUTE53_CLI_TIMEOUT from the step"
  while IFS= read -r line; do
    if [[ "${line}" == *"configure"* || "${line}" == *"assume-role"* ]]; then
      fail "the step must not change or assume credentials: ${line}"
    fi
    [[ "${line}" == *route53* ]] || continue
    reads=$(( reads + 1 ))
    [[ "${line}" == *"--max-items"* ]] \
      || fail "unbounded Route 53 read: ${line}"
    grep -Fq -- "${cli_timeout} aws ${line}" "${case_dir}/state/timeout-arguments" \
      || fail "Route 53 read was not time-bounded: ${line}"
    if [[ "${line}" == *"--dns-name"* ]]; then
      local matched=false
      for allowed in ${allowed_zones+"${allowed_zones[@]}"}; do
        [[ " ${line} " == *" --dns-name ${allowed} "* ]] || continue
        matched=true
        break
      done
      [[ "${matched}" == true ]] \
        || fail "Route 53 zone lookup left this run's own zone: ${line}"
    fi
  done < "${case_dir}/state/aws-arguments"
  (( reads == expected_reads )) \
    || fail "expected ${expected_reads} Route 53 reads, saw ${reads}"
  # This section runs after the step has already failed, so it spends the ref's
  # grace_period, which the install log, the cluster description and the DNS probes
  # need as well. Bound what this part of it can cost when every call hangs.
  (( reads * cli_timeout <= 120 )) \
    || fail "worst case ${reads} reads x ${cli_timeout}s exceeds the diagnostics budget"
}

# Every DNS probe must be time-bounded, and it must have gone through the mocked dig
# unless the scenario made the bounding timeout itself fire first.
assert_probe_is_bounded_and_mocked() {
  local case_dir="$1" expected_host="$2" dig_runs="${3:-true}"
  assert_contains "${case_dir}/state/timeout-arguments" "10 dig +time=2 +tries=1 ${expected_host}"
  if [[ "${dig_runs}" == "true" ]]; then
    assert_contains "${case_dir}/state/dig-arguments" "+time=2 +tries=1 ${expected_host}"
  else
    assert_file_absent "${case_dir}/state/dig-arguments"
  fi
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  cat > "${mock_dir}/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/timeout-arguments"
if [[ "${MOCK_SCENARIO}" == "dns_probe_timeout" && "$*" == *dig* ]]; then
  exit 124
fi
if [[ "${MOCK_SCENARIO}" == "dns_zone_timeout" && "$*" == *route53* ]]; then
  exit 124
fi
while [[ "${1:-}" == -* || "${1:-}" =~ ^[0-9]+[smhd]?$ ]]; do
  shift
done
exec "$@"
EOF

  cat > "${mock_dir}/dig" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/dig-arguments"
if [[ "${MOCK_SCENARIO}" == "dns_probe_failure" ]]; then
  echo "dig: couldn't get address for the configured resolver" >&2
  exit 9
fi
if [[ "$*" == *" NS "* ]]; then
  if [[ "${MOCK_SCENARIO}" == "dns_full" ]]; then
    # dig names the resolver it could not reach before printing any answer, so the
    # step must take the answer and not the diagnostic line.
    echo ";; communications error to 192.0.2.10#53: timed out"
    echo "ns-mock.example.com."
  fi
  exit 0
fi
cat <<'ANSWER'
; <<>> DiG 9.16.23-RH <<>> mock
;; UDP setup with 2001:db8::1#53(2001:db8::1) for api.ci-rosa-h-test.example.com failed: network unreachable
;; ANSWER SECTION:
MOCK_DIG_ANSWER 60 IN A 203.0.113.10
;; SERVER: 192.0.2.10#53(192.0.2.10)
;; WHEN: Tue Nov 17 16:16:33 UTC 2026
ANSWER
EOF

  # Route 53 fixtures. Every name below is a reserved documentation name, and every
  # value exists so that a test can prove it never reaches a published artifact.
  cat > "${mock_dir}/aws" <<'EOF'
#!/bin/bash
args="$*"
printf '%s\n' "${args}" >> "${MOCK_STATE_DIR}/aws-arguments"

route53_scenarios=" dns_full dns_zone_parent_only dns_zone_hidden_child dns_zone_adjacent"
route53_scenarios+=" dns_zone_mismatch dns_zone_denied dns_zone_truncated dns_zone_timeout"
route53_scenarios+=" dns_records_missing dns_records_denied dns_records_failed"
route53_scenarios+=" dns_zone_split_horizon dns_zone_private_only dns_ancestor_denied"
route53_scenarios+=" dns_zone_deep dns_zone_bounded dns_zone_undelegated"
route53_scenarios+=" dns_zone_malformed dns_records_malformed "
if [[ "${route53_scenarios}" != *" ${MOCK_SCENARIO} "* ]]; then
  # No cloud credentials: the step must degrade gracefully.
  exit 1
fi

# The four nameservers the cluster zone was assigned, and a different four that a stale
# delegation points at. None of them may appear in a published artifact.
CHILD_NS='{"Value":"ns-1.awsdns-00.example."},{"Value":"ns-2.awsdns-01.example."},{"Value":"ns-3.awsdns-02.example."},{"Value":"ns-4.awsdns-03.example."}'
STALE_NS='{"Value":"ns-91.awsdns-50.example."},{"Value":"ns-92.awsdns-51.example."},{"Value":"ns-93.awsdns-52.example."},{"Value":"ns-94.awsdns-53.example."}'
# The real ROSA API record is an alias with no ResourceRecords, so the fixture is one
# too. The second record set carries a type outside the published allowlist.
API_RECORD='{"Name":"api.ci-rosa-h-test.example.com.","Type":"A","AliasTarget":{"HostedZoneId":"ZELB","DNSName":"mock-nlb.example.","EvaluateTargetHealth":false}}'
API_ODD_RECORD='{"Name":"api.ci-rosa-h-test.example.com.","Type":"MOCKTYPE","TTL":60,"ResourceRecords":[{"Value":"198.51.100.10"}]}'
SOA_RECORD='{"Name":"ci-rosa-h-test.example.com.","Type":"SOA","TTL":900,"ResourceRecords":[{"Value":"ns-1.awsdns-00.example. hostmaster.example. 1 7200 900 1209600 86400"}]}'

dns_name=""
zone_id=""
start_name=""
while (( $# )); do
  case "$1" in
    --dns-name) dns_name="${2:-}"; shift ;;
    --hosted-zone-id) zone_id="${2:-}"; shift ;;
    --start-record-name) start_name="${2:-}"; shift ;;
  esac
  shift
done

# AWS lists the identifier before the name and nests the visibility flag, so the
# fixtures do too: a parser that depends on member order or on compact JSON must not
# pass these tests.
zone() {
  printf '{"Id":"/hostedzone/%s","Name":"%s","CallerReference":"mock","Config":{"Comment":"mock","PrivateZone":%s}}' \
    "$1" "$2" "$3"
}
zones() { printf '{"HostedZones":[%s],"IsTruncated":%s,"MaxItems":"5"}\n' "$1" "$2"; }
records() { printf '{"ResourceRecordSets":[%s],"IsTruncated":%s}\n' "$1" "${2:-false}"; }
ns_set() { printf '{"Name":"%s","Type":"NS","TTL":172800,"ResourceRecords":[%s]}' "$1" "$2"; }
denied() {
  echo "An error occurred (AccessDenied) when calling the $1 operation: User: arn:aws:iam::123456789012:user/MOCK_DENIED_PRINCIPAL is not authorized" >&2
  exit 255
}

case "${args}" in
  *"sts get-caller-identity"*)
    printf '{"Account":"123456789012"}\n'
    exit 0
    ;;
  *"list-hosted-zones-by-name"*)
    case "${MOCK_SCENARIO}" in
      dns_zone_denied) denied ListHostedZonesByName ;;
      dns_zone_malformed)
        # A reply the step cannot parse: exit 0, but not a document jq can read.
        printf '{"HostedZones":[{"Name":"ci-rosa-h-test.example.com."},\n'
        exit 0
        ;;
      dns_zone_truncated)
        # Five zones, none of them the one asked for, and more beyond this page: the
        # bounded read cannot establish that the zone is absent.
        zones "$(zone ZT1 a1.example.net. false),$(zone ZT2 a2.example.net. false),$(zone ZT3 a3.example.net. false),$(zone ZT4 a4.example.net. false),$(zone ZT5 a5.example.net. false)" true
        exit 0
        ;;
      dns_zone_adjacent)
        # The hosted zone of an unrelated cluster that sorts next to the one asked for.
        # The step must never adopt it, publish its name or read a record out of it.
        zones "$(zone ZADJACENT ci-rosa-h-test-2.example.com. false)" false
        exit 0
        ;;
    esac
    case "${dns_name}" in
      ci-rosa-h-test.example.com)
        case "${MOCK_SCENARIO}" in
          dns_zone_parent_only|dns_zone_hidden_child)
            # No hosted zone of its own; only an unrelated neighbour sorts here.
            zones "$(zone ZADJACENT ci-rosa-h-test-2.example.com. false)" false
            ;;
          dns_zone_private_only)
            zones "$(zone ZPRIVATE ci-rosa-h-test.example.com. true)" false
            ;;
          dns_zone_split_horizon)
            # The private zone sorts first: the step must still use the public one.
            zones "$(zone ZPRIVATE ci-rosa-h-test.example.com. true),$(zone ZCHILD ci-rosa-h-test.example.com. false)" false
            ;;
          *)
            zones "$(zone ZCHILD ci-rosa-h-test.example.com. false)" false
            ;;
        esac
        ;;
      example.com)
        if [[ "${MOCK_SCENARIO}" == "dns_ancestor_denied" ]]; then
          denied ListHostedZonesByName
        fi
        zones "$(zone ZPARENT example.com. false)" false
        ;;
      # The deep scenarios use a four-label base domain, so the walk has to climb.
      ci-rosa-h-test.d1.d2.example.com)
        zones "$(zone ZCHILD ci-rosa-h-test.d1.d2.example.com. false)" false
        ;;
      d1.d2.example.com)
        zones '' false
        ;;
      d2.example.com)
        if [[ "${MOCK_SCENARIO}" == "dns_zone_deep" ]]; then
          zones "$(zone ZGRANDPARENT d2.example.com. false)" false
        else
          zones '' false
        fi
        ;;
      *)
        zones '' false
        ;;
    esac
    exit 0
    ;;
  *"list-resource-record-sets"*)
    case "${MOCK_SCENARIO}" in
      dns_records_denied) denied ListResourceRecordSets ;;
      dns_records_malformed)
        printf '{"ResourceRecordSets":"not-an-array"}\n'
        exit 0
        ;;
      dns_records_failed)
        echo "An error occurred (Throttling) when calling the ListResourceRecordSets operation: Rate exceeded" >&2
        exit 254
        ;;
      dns_records_missing)
        # The zones exist but hold no record at the name asked for, so the API answers
        # with the record that sorts after it, and reports more beyond this page.
        records '{"Name":"other.ci-rosa-h-test.example.com.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"198.51.100.99"}]}' true
        exit 0
        ;;
    esac
    case "${zone_id}:${start_name}" in
      ZCHILD:api.ci-rosa-h-test.example.com.)
        records "${API_RECORD},${API_ODD_RECORD}"
        ;;
      ZPARENT:api.ci-rosa-h-test.example.com.)
        if [[ "${MOCK_SCENARIO}" == "dns_zone_parent_only" ]]; then
          records "${API_RECORD}"
        else
          records ''
        fi
        ;;
      ZCHILD:ci-rosa-h-test.example.com.)
        records "$(ns_set ci-rosa-h-test.example.com. "${CHILD_NS}"),${SOA_RECORD}"
        ;;
      ZPRIVATE:ci-rosa-h-test.example.com.)
        # A private zone's apex nameservers have nothing to do with a public delegation.
        records "$(ns_set ci-rosa-h-test.example.com. "${STALE_NS}")"
        ;;
      ZPARENT:ci-rosa-h-test.example.com.)
        case "${MOCK_SCENARIO}" in
          dns_zone_parent_only|dns_zone_undelegated)
            # No delegation. With no child zone this is the parent-zone-only layout;
            # with one, it is a zone that was created and never delegated.
            records ''
            ;;
          dns_zone_mismatch)
            records "$(ns_set ci-rosa-h-test.example.com. "${STALE_NS}")"
            ;;
          *)
            records "$(ns_set ci-rosa-h-test.example.com. "${CHILD_NS}")"
            ;;
        esac
        ;;
      *)
        records ''
        ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF

  # Unused by the hosted-control-plane scenarios below; kept so that a Classic scenario
  # can never reach the real CLI.
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-arguments"
exit 1
EOF

  cat > "${mock_dir}/rosa" <<'EOF'
#!/bin/bash
set -o nounset
state="${MOCK_STATE_DIR}"
printf '%s\n' "$*" >> "${state}/rosa-arguments"

bump() {
  local name="$1" count=0
  [[ ! -f "${state}/${name}" ]] || count=$(cat "${state}/${name}")
  count=$(( count + 1 ))
  printf '%s' "${count}" > "${state}/${name}"
  printf '%s' "${count}"
}

dns_error_line() {
  printf '2026-11-17 16:1%s:35 +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api-%s.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n' "$1" "$1"
}

long_padding() {
  local line i
  line=$(printf 'p%.0s' $(seq 1 400))
  for i in $(seq 1 500); do
    printf '2026-11-17 16:00:00 +0000 UTC hostedclusters ci-rosa-h-test pad-%04d %s\n' "${i}" "${line}"
  done
}

short_padding() {
  local i
  for i in $(seq 1 2000); do
    printf '2026-11-17 16:00:00 +0000 UTC ci-rosa-h-test short-%04d\n' "${i}"
  done
}

case "${1:-}" in
  login|verify)
    exit 0
    ;;
  whoami)
    printf '{"AWS Account ID":"123456789012"}\n'
    exit 0
    ;;
  list)
    printf '[]\n'
    exit 0
    ;;
  describe)
    if [[ "${2:-}" != "cluster" ]]; then
      printf '{}\n'
      exit 0
    fi
    count=$(bump describe-count)
    cluster_state="installing"
    if (( MOCK_READY_AFTER > 0 )) && (( count >= MOCK_READY_AFTER )); then
      cluster_state="ready"
    fi
    api_url="null"
    if [[ "${MOCK_SCENARIO}" == "dns_full" ]]; then
      # Deliberately not the name the step would derive from .name plus
      # .dns.base_domain, so a probe of this host proves the URL was used.
      api_url='"https://api-from-url.ci-rosa-h-test.example.com:443"'
    fi
    # A four-label base domain, so the ancestor walk has more than one step to take.
    base_domain="example.com"
    case "${MOCK_SCENARIO}" in
      dns_zone_deep|dns_zone_bounded) base_domain="d1.d2.example.com" ;;
    esac
    cat <<JSON
{
  "state": "${cluster_state}",
  "name": "ci-rosa-h-test",
  "dns": {"base_domain": "${base_domain}"},
  "api": {"url": ${api_url}},
  "console": {"url": null},
  "infra_id": null,
  "product": {"id": "rosa"},
  "status": {"description": "cluster is installing"}
}
JSON
    exit 0
    ;;
  logs)
    count=$(bump install-log-count)
    case "${MOCK_SCENARIO}" in
      clean)
        printf '2026-11-17 16:11:00 +0000 UTC hostedclusters ci-rosa-h-test Reconciliation active on resource\n'
        ;;
      non_dns_fatal)
        printf '2026-11-17 16:11:00 +0000 UTC hostedclusters ci-rosa-h-test LimitExceeded: too many addresses\n'
        ;;
      dns_late)
        # The DNS error only shows up in the log re-fetched after the failure.
        if (( count == 1 )); then
          printf '2026-11-17 16:11:00 +0000 UTC hostedclusters ci-rosa-h-test LimitExceeded: too many addresses\n'
        else
          printf '2026-11-17 16:14:00 +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
        fi
        ;;
      dns_repeat)
        # A new, distinct DNS error on every health check, with no fatal pattern, so the
        # wait loop keeps running. Padding makes the log far larger than the byte cap.
        long_padding
        for i in $(seq 1 "${count}"); do
          dns_error_line "${i}"
        done
        ;;
      dns_oversized)
        # One enormous DNS line, carrying an account identifier and the ANSI sequences
        # this step's own log() emits through retry_cmd.
        big=$(printf 'x%.0s' $(seq 1 200000))
        printf '\033[1m2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test role arn:aws:iam::123456789012:role/installer dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host %s\033[0m\n' "${big}"
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account\n'
        ;;
      dns_byte_cap)
        # Ten distinct DNS errors, each padded so that the ten together are far larger
        # than the byte cap while every one of them stays well under it. The same ten
        # are reported on every health check, so a line the cap kept out of the first
        # snapshot can only reach an artifact if it was not recorded as seen.
        pad=$(printf 'z%.0s' $(seq 1 900))
        for i in $(seq 1 10); do
          printf '2026-11-17 16:13:%02d +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api-b%02d.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host %s\n' "${i}" "${i}" "${pad}"
        done
        ;;
      dns_line_cap)
        # Many short non-DNS lines and more distinct DNS lines than the line cap allows.
        short_padding
        for i in $(seq 1 30); do
          printf '2026-11-17 16:13:%02d +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api-c%02d.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n' "${i}" "${i}"
        done
        ;;
      dns_nested)
        # Go keeps the underlying network error, so one DNS error line carries three
        # endpoints: the resolver and both ends of the failed transport. A scoped IPv6
        # resolver endpoint carries a zone identifier as well.
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: read udp 192.0.2.20:40000->192.0.2.10:53: i/o timeout\n'
        printf '2026-11-17 16:13:21 +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api.ci-rosa-h-test.example.com on [2001:db8::1%%eth0]:53: no such host\n'
        ;;
      dns_boundary)
        # The resolver endpoint of the first line straddles the byte cap: with 8133
        # characters of padding it starts at byte 8185 of the captured text, so a cap
        # applied before redaction cuts it into a fragment the filter no longer matches.
        printf '%s dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n' "$(printf 'y%.0s' $(seq 1 8133))"
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
        ;;
      dns_retry)
        # The same non-fatal DNS error on every health check, so a poll whose snapshot
        # could not be written must try again on the next one.
        printf '2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
        ;;
      dns_chronology)
        if (( count == 1 )); then
          printf '2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
          printf '2026-11-17 16:12:40 +0000 UTC hostedclusters ci-rosa-h-test role arn:aws:iam::123456789012:role/installer could not be assumed\n'
          printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
        else
          # The log the step re-fetches after it gives up no longer shows the DNS error.
          printf '2026-11-17 16:14:40 +0000 UTC hostedclusters ci-rosa-h-test Kube APIServer deployment is available\n'
          printf '2026-11-17 16:15:51 +0000 UTC hostedclusters ci-rosa-h-test The hosted control plane is available\n'
        fi
        ;;
      *)
        printf '2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.com on 192.0.2.10:53: no such host\n'
        ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF

  # The CI image that runs these tests (quay.io/openshift/ci:ci_shellcheck_latest)
  # ships no jq, so fall back to a stand-in that understands only the filters this
  # step uses. Real jq is used whenever it is installed.
  # Set FORCE_STUB_JQ=true to exercise the stand-in on a machine that has jq, so
  # both parser paths can be checked.
  if [[ "${FORCE_STUB_JQ:-false}" == true ]] || ! command -v jq >/dev/null; then
    cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
set -o nounset

raw=false
filter=""
input_file=""
for arg in "$@"; do
  case "${arg}" in
    -r|--raw-output) raw=true ;;
    -*) ;;
    *)
      if [[ -z "${filter}" ]]; then
        filter="${arg}"
      else
        input_file="${arg}"
      fi
      ;;
  esac
done

if [[ -n "${input_file}" ]]; then
  input=$(cat "${input_file}" 2>/dev/null || true)
else
  input=$(cat)
fi
input=$(printf '%s' "${input}" | tr '\n' ' ')

# The Route 53 filters emit one line per array element, so they are handled before the
# scalar cases below. The three filter strings must stay identical to the constants the
# step defines; test_jq_stand_in_matches_the_step_filters checks that they do.
scalar_in() {
  printf '%s' "$2" \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"
}

boolean_in() {
  local found
  found=$(printf '%s' "$2" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*(true|false)" | head -1)
  if [[ "${found}" == *true ]]; then printf 'true'; else printf 'false'; fi
}

# Print each top-level object of the array under key $1, one per line. A brace-depth
# scan rather than a text split, so member order, nesting and whitespace do not matter:
# the real API puts "Id" before "Name" and nests Config and ResourceRecords.
array_objects() {
  printf '%s' "$2" | awk -v key="$1" '
    {
      marker = "\"" key "\""
      i = index($0, marker)
      if (i == 0) exit
      s = substr($0, i + length(marker))
      j = index(s, "[")
      if (j == 0) exit
      s = substr(s, j + 1)
      depth = 0; instr = 0; esc = 0; out = ""
      for (p = 1; p <= length(s); p++) {
        c = substr(s, p, 1)
        if (esc) { out = out c; esc = 0; continue }
        if (c == "\\") { out = out c; esc = 1; continue }
        if (c == "\"") { instr = 1 - instr; out = out c; continue }
        if (!instr) {
          if (c == "{") { depth++; out = out c; continue }
          if (c == "}") {
            depth--; out = out c
            if (depth == 0) { print out; out = "" }
            continue
          }
          if (depth == 0) {
            if (c == "]") break
            continue
          }
        }
        out = out c
      }
    }'
}

require_array=""
is_route53_filter=false
case "${filter}" in
  '.HostedZones[]'*) require_array=HostedZones; is_route53_filter=true ;;
  '.ResourceRecordSets[]'*) require_array=ResourceRecordSets; is_route53_filter=true ;;
  'if (.IsTruncated'*) is_route53_filter=true ;;
esac
if [[ "${is_route53_filter}" == true && -n "${input}" ]]; then
  trimmed="${input#"${input%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  # Not a complete JSON object, so jq would not read it either.
  [[ "${trimmed}" == \{*\} ]] || exit 5
  if [[ -n "${require_array}" ]] \
    && ! printf '%s' "${trimmed}" | grep -q "\"${require_array}\"[[:space:]]*:[[:space:]]*\["; then
    # jq cannot iterate a missing key or a non-array value.
    exit 5
  fi
fi

case "${filter}" in
  '.HostedZones[] | [.Name, .Id, ((.Config.PrivateZone // false) | tostring)] | @tsv')
    while IFS= read -r chunk; do
      [[ -n "${chunk}" ]] || continue
      printf '%s\t%s\t%s\n' \
        "$(scalar_in Name "${chunk}")" \
        "$(scalar_in Id "${chunk}")" \
        "$(boolean_in PrivateZone "${chunk}")"
    done < <(array_objects HostedZones "${input}")
    exit 0
    ;;
  '.ResourceRecordSets[] | [.Name, .Type, ((.ResourceRecords // []) | map(.Value) | join(","))] | @tsv')
    while IFS= read -r chunk; do
      [[ -n "${chunk}" ]] || continue
      values=$(printf '%s' "${chunk}" \
        | grep -oE '"Value"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' \
        | tr '\n' ',')
      printf '%s\t%s\t%s\n' \
        "$(scalar_in Name "${chunk}")" "$(scalar_in Type "${chunk}")" "${values%,}"
    done < <(array_objects ResourceRecordSets "${input}")
    exit 0
    ;;
  'if (.IsTruncated == true) or (.NextToken != null) then "yes" else "no" end')
    if printf '%s' "${input}" \
      | grep -qE '"IsTruncated"[[:space:]]*:[[:space:]]*true|"NextToken"[[:space:]]*:[[:space:]]*"'; then
      printf 'yes\n'
    else
      printf 'no\n'
    fi
    exit 0
    ;;
esac

# Object mutation (record_cluster): keep the document as it is.
if [[ "${filter}" == *'+='* ]]; then
  printf '%s\n' "${input:-{\}}"
  exit 0
fi

default=""
has_default=false
if [[ "${filter}" == *'//'* ]]; then
  has_default=true
  default="${filter#*//}"
  default="${default#"${default%%[![:space:]]*}"}"
  default="${default%"${default##*[![:space:]]}"}"
  default="${default#\"}"
  default="${default%\"}"
  [[ "${default}" != "empty" ]] || default=""
  filter="${filter%%//*}"
  filter="${filter%"${filter##*[![:space:]]}"}"
fi

scalar_of() {
  local key="$1" json="$2"
  printf '%s' "${json}" \
    | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|null|true|false|-?[0-9.]+)" \
    | head -1 \
    | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*//"
}

object_of() {
  local key="$1" json="$2"
  printf '%s' "${json}" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\{[^}]*\}" | head -1
}

case "${filter}" in
  '."AWS Account ID"') out=$(scalar_of 'AWS Account ID' "${input}") ;;
  '.state'|'.name'|'.infra_id'|'.timers') out=$(scalar_of "${filter#.}" "${input}") ;;
  '.api.url') out=$(scalar_of url "$(object_of api "${input}")") ;;
  '.console.url') out=$(scalar_of url "$(object_of console "${input}")") ;;
  '.dns.base_domain') out=$(scalar_of base_domain "$(object_of dns "${input}")") ;;
  '.product.id') out=$(scalar_of id "$(object_of product "${input}")") ;;
  '.status.description') out=$(scalar_of description "$(object_of status "${input}")") ;;
  *) out="" ;;
esac

if [[ -z "${out}" || "${out}" == "null" ]]; then
  if [[ "${has_default}" == true ]]; then
    [[ -z "${default}" ]] || printf '%s\n' "${default}"
    exit 0
  fi
  printf 'null\n'
  exit 0
fi

if [[ "${raw}" == true ]]; then
  out="${out#\"}"
  out="${out%\"}"
fi
printf '%s\n' "${out}"
EOF
  fi

  chmod +x "${mock_dir}"/*
}

run_script() {
  local scenario="$1" case_dir="$2" ready_after="${3:-0}" block_observation="${4:-false}"
  local mock_dir="${case_dir}/bin"
  mkdir -p "${case_dir}/state" "${case_dir}/tmp" "${case_dir}/artifacts" "${case_dir}/shared" "${case_dir}/profile"
  make_mocks "${mock_dir}"
  # A directory where the first snapshot belongs makes that write fail for any user.
  [[ "${block_observation}" != "true" ]] || mkdir -p "${case_dir}/artifacts/dns-observation-01.txt"
  printf '%s' 'MOCK_OCM_TOKEN_SECRET' > "${case_dir}/profile/ocm-token"
  printf '[default]\naws_access_key_id = MOCKID\naws_secret_access_key = MOCK_AWS_SECRET_KEY\n' > "${case_dir}/profile/.awscred"
  printf '%s' 'mock-cluster-id' > "${case_dir}/shared/cluster-id"
  printf '%s' '{}' > "${case_dir}/shared/cluster-config"

  env \
    PATH="${mock_dir}:${PATH}" \
    TMPDIR="${case_dir}/tmp" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_READY_AFTER="${ready_after}" \
    ARTIFACT_DIR="${case_dir}/artifacts" \
    SHARED_DIR="${case_dir}/shared" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    LEASED_RESOURCE=us-west-2 \
    REGION="" \
    ENABLE_SHARED_VPC=no \
    ENABLE_BYOVPC=false \
    BYO_OIDC=false \
    OCM_LOGIN_ENV=staging \
    HOSTED_CP=true \
    CLUSTER_TIMEOUT=9000 \
    STALL_TIMEOUT=3600 \
    bash "${COMMAND_SCRIPT}" > "${case_dir}/output.log" 2>&1
}

new_case() {
  local case_dir="${TEST_ROOT}/$1"
  mkdir -p "${case_dir}"
  printf '%s' "${case_dir}"
}

# The install log is re-fetched (and ${ARTIFACT_DIR}/.install.log written) only once the
# step gives up. The observation snapshot must keep the earlier chronology.
test_dns_chronology_survives_install_log_refetch() {
  local case_dir rc
  case_dir=$(new_case dns-chronology)
  set +e
  run_script dns_chronology "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_exists "${observation}"
  # The DNS error lines are kept, with the resolver address of the failing client
  # redacted out of them.
  assert_contains "${observation}" "16:12:35 +0000 UTC hostedclusters ci-rosa-h-test lookup api.ci-rosa-h-test.example.com on [address redacted]: no such host"
  assert_contains "${observation}" "failed to create token for KMS provider service account"
  assert_contains "${observation}" "Observed by: rosa-cluster-wait-ready-cluster, install-log health check after 5 polls with an unchanged cluster state"
  assert_contains "${observation}" "OCM cluster state at observation: installing"
  assert_contains "${observation}" "Observed at:"
  assert_probe_origin_labels "${observation}"
  assert_probe_is_bounded_and_mocked "${case_dir}" "api.ci-rosa-h-test.example.com"
  assert_contains "${observation}" "MOCK_DIG_ANSWER"
  # Install-log lines that are not DNS errors are never copied into the artifact.
  assert_not_contains "${observation}" "could not be assumed"
  assert_no_secrets "${observation}"
  assert_no_resolver_details "${observation}"
  assert_no_cluster_identifier "${observation}"

  # The later install log no longer carries the DNS error; the snapshot is the only
  # artifact that still shows when it was observed.
  assert_file_exists "${case_dir}/artifacts/.install.log"
  assert_not_contains "${case_dir}/artifacts/.install.log" "no such host"
  # Diagnostics are still collected, and they point at the preserved chronology.
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "Earlier DNS errors were seen in install-log output while the step was still waiting."
  assert_contains "${case_dir}/output.log" "DNS-related error observed in install-log output; snapshot saved to"
  assert_no_secrets "${case_dir}/output.log"
}

# Failure-time diagnostics must label probe origin and time, and must not claim the CI
# pod's resolver is the management cluster's.
test_failure_diagnostics_label_probe_origin_and_time() {
  local case_dir rc
  case_dir=$(new_case dns-persistent)
  set +e
  run_script dns_persistent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_file_exists "${diagnostics}"
  assert_contains "${diagnostics}" "Captured by: rosa-cluster-wait-ready-cluster, running in a ci-operator step pod"
  assert_contains "${diagnostics}" "(UTC, after the step declared the install failed)"
  assert_contains "${diagnostics}" "=== DNS probe from this CI step pod ==="
  assert_contains "${diagnostics}" "were saved alongside this file as dns-observation-NN.txt; at most 3 are kept, so a"
  assert_contains "${diagnostics}" "(queried from this CI pod)"
  # No cloud credentials are available to the test, and none are gathered for them.
  assert_contains "${diagnostics}" "AWS credentials not available for Route 53 lookup"
  assert_contains "${diagnostics}" "This file is published as a public CI artifact: resolver addresses and internal"
  assert_probe_origin_labels "${diagnostics}"
  assert_file_exists "${case_dir}/artifacts/dns-observation-01.txt"
  assert_no_secrets "${diagnostics}"
  assert_no_resolver_details "${diagnostics}"
}

# The step source must no longer claim that the CI pod's own resolver is the management
# cluster's CoreDNS, which was the inaccuracy this change set out to correct.
test_script_makes_no_management_cluster_resolver_claim() {
  if grep -n "CoreDNS" "${COMMAND_SCRIPT}" >&2; then
    fail "the step must not attribute the CI pod's resolver to management-cluster CoreDNS"
  fi
}

# A failing or timing-out diagnostic command must not change the step result or stop the
# remaining diagnostics from being written.
test_probe_failures_do_not_change_step_result() {
  local scenario case_dir rc dig_runs
  for scenario in dns_probe_failure dns_probe_timeout; do
    dig_runs=true
    [[ "${scenario}" != "dns_probe_timeout" ]] || dig_runs=false
    case_dir=$(new_case "probe-${scenario}")
    set +e
    run_script "${scenario}" "${case_dir}"
    rc=$?
    set -e
    assert_status "${rc}" 1 "${scenario} must fail exactly like the baseline fatal error"
    assert_contains "${case_dir}/output.log" "ERROR: Fatal error detected in install logs:"
    assert_file_exists "${case_dir}/artifacts/dns-observation-01.txt"
    assert_probe_origin_labels "${case_dir}/artifacts/dns-observation-01.txt"
    assert_contains "${case_dir}/artifacts/dns-observation-01.txt" "=== End DNS error observation 1 ==="
    assert_file_exists "${case_dir}/artifacts/dns-diagnostics.txt"
    assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "=== End DNS Diagnostics ==="
    assert_probe_is_bounded_and_mocked "${case_dir}" "api.ci-rosa-h-test.example.com" "${dig_runs}"
    assert_no_secrets "${case_dir}/output.log"
  done
}

# Non-DNS failures keep their existing fail-fast behaviour and collect no DNS artifacts.
test_non_dns_failure_behaviour_is_unchanged() {
  local case_dir rc
  case_dir=$(new_case non-dns-fatal)
  set +e
  run_script non_dns_fatal "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "non-DNS fatal install error"
  assert_contains "${case_dir}/output.log" "ERROR: Fatal error detected in install logs:"
  assert_contains "${case_dir}/output.log" "LimitExceeded"
  assert_file_exists "${case_dir}/artifacts/.install.log"
  assert_file_absent "${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_absent "${case_dir}/artifacts/dns-diagnostics.txt"
  assert_file_absent "${case_dir}/state/dig-arguments"
}

# A DNS error that only appears in the post-failure log must not be reported as an
# earlier observation.
test_unobserved_dns_error_is_not_claimed_as_observed() {
  local case_dir rc
  case_dir=$(new_case dns-late)
  set +e
  run_script dns_late "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  assert_file_absent "${case_dir}/artifacts/dns-observation-01.txt"
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "The wait loop's periodic install-log health checks recorded no DNS error."
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "evidence that no earlier DNS error occurred."
}

# A healthy install must stay unaffected: no diagnostics, no probes, exit 0.
test_successful_install_collects_no_dns_diagnostics() {
  local case_dir rc
  case_dir=$(new_case clean)
  set +e
  run_script clean "${case_dir}" 8
  rc=$?
  set -e
  assert_status "${rc}" 0 "healthy install"
  assert_file_absent "${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_absent "${case_dir}/artifacts/dns-diagnostics.txt"
  assert_file_absent "${case_dir}/state/dig-arguments"
  assert_contains "${case_dir}/shared/api.url" "https://api.ci-rosa-h-test.example.com:443"
}

# Repeated, distinct DNS errors are capped in count and in size, and the wait loop keeps
# running because none of them is a fatal pattern.
test_observations_are_bounded() {
  local case_dir rc
  case_dir=$(new_case dns-repeat)
  set +e
  run_script dns_repeat "${case_dir}" 26
  rc=$?
  set -e
  assert_status "${rc}" 0 "non-fatal DNS errors must not fail the step"

  local -i count
  count=$(find "${case_dir}/artifacts" -maxdepth 1 -name 'dns-observation-*.txt' | wc -l)
  (( count == 3 )) || fail "expected 3 bounded observations, got ${count}"
  assert_file_absent "${case_dir}/artifacts/dns-observation-04.txt"
  assert_contains "${case_dir}/output.log" "keeping the first 3 observations only."

  # The install log dwarfs the artifact: none of its non-DNS content is copied, so each
  # observation stays small however large the log grows.
  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  local -i observation_size
  observation_size=$(wc -c < "${observation}")
  (( observation_size <= 16384 )) || fail "expected a bounded observation, got ${observation_size} bytes"
  assert_not_contains "${observation}" "pad-0001 "
  assert_not_contains "${observation}" "pad-0500 "
  assert_no_resolver_details "${observation}"

  # Only newly seen DNS lines are listed, so each observation adds information.
  local new_lines="${case_dir}/observation-02-new-lines"
  section_of "${case_dir}/artifacts/dns-observation-02.txt" "DNS-related lines not seen" "DNS probe taken at this observation" \
    > "${new_lines}"
  assert_contains "${new_lines}" "lookup api-2.ci-rosa-h-test.example.com"
  assert_not_contains "${new_lines}" "lookup api-1.ci-rosa-h-test.example.com on"
  # The earlier line stays readable in the earlier observation, which is where the
  # chronology lives now that no general install-log excerpt is published.
  assert_contains "${observation}" "lookup api-1.ci-rosa-h-test.example.com on"

  # The de-duplication state is a temporary file; it must not be left behind.
  [[ -z "$(grep -rl "no such host" "${case_dir}/tmp" 2>/dev/null)" ]] \
    || fail "expected no leftover temporary DNS state in ${case_dir}/tmp"
}

# The line cap binds when one poll sees more DNS errors than the cap allows, and the
# non-DNS bulk of the install log is left out of the artifact entirely.
test_error_line_cap_and_install_log_exclusion() {
  local case_dir rc
  case_dir=$(new_case dns-line-cap)
  set +e
  run_script dns_line_cap "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  local -i lines
  section_of "${observation}" "DNS-related lines not seen" "DNS probe taken at this observation" \
    > "${case_dir}/error-lines"
  lines=$(wc -l < "${case_dir}/error-lines")
  # 20 error lines plus the blank line that separates the section from the next one.
  (( lines <= 21 )) || fail "expected at most 20 error lines, got ${lines}"
  assert_contains "${case_dir}/error-lines" "lookup api-c01.ci-rosa-h-test.example.com"
  assert_not_contains "${case_dir}/error-lines" "lookup api-c30.ci-rosa-h-test.example.com"
  # None of the 2000 non-DNS install-log lines reaches the artifact.
  assert_not_contains "${observation}" "short-0001"
  assert_not_contains "${observation}" "short-2000"
  assert_no_resolver_details "${observation}"
}

# The byte cap binds when the new DNS lines of one poll are together larger than it
# allows. The lines it leaves out must stay available: they are not recorded as seen,
# so a later health check still saves them, while the lines already saved whole are
# not repeated.
test_byte_cap_defers_omitted_lines_to_a_later_observation() {
  local case_dir rc
  case_dir=$(new_case dns-byte-cap)
  set +e
  run_script dns_byte_cap "${case_dir}" 16
  rc=$?
  set -e
  assert_status "${rc}" 0 "non-fatal DNS errors must not fail the step"

  local first="${case_dir}/artifacts/dns-observation-01.txt"
  local second="${case_dir}/artifacts/dns-observation-02.txt"
  assert_file_exists "${first}"
  section_of "${first}" "DNS-related lines not seen" "DNS probe taken at this observation" \
    > "${case_dir}/byte-cap-lines-01"
  local -i section_size
  section_size=$(wc -c < "${case_dir}/byte-cap-lines-01")
  # 8192 bytes of log lines plus the blank line that separates the sections.
  (( section_size <= 8194 )) || fail "expected the error-line section to stay capped, got ${section_size}"
  assert_contains "${case_dir}/byte-cap-lines-01" "lookup api-b01.ci-rosa-h-test.example.com"
  assert_not_contains "${case_dir}/byte-cap-lines-01" "lookup api-b10.ci-rosa-h-test.example.com"

  # The line the byte cap kept out of the first snapshot is saved by a later one
  # instead of being lost, and a line already saved whole is not repeated there.
  assert_file_exists "${second}"
  section_of "${second}" "DNS-related lines not seen" "DNS probe taken at this observation" \
    > "${case_dir}/byte-cap-lines-02"
  assert_contains "${case_dir}/byte-cap-lines-02" "lookup api-b10.ci-rosa-h-test.example.com"
  assert_not_contains "${case_dir}/byte-cap-lines-02" "lookup api-b01.ci-rosa-h-test.example.com on"
  assert_no_resolver_details "${first}"
  assert_no_resolver_details "${second}"
  assert_no_cluster_identifier "${first}"
  assert_no_cluster_identifier "${second}"
}

# A snapshot that could not be written leaves its DNS lines unrecorded, so the next
# health check tries again instead of treating them as already seen.
test_failed_snapshot_write_is_retried() {
  local case_dir rc attempts
  case_dir=$(new_case snapshot-retry)
  set +e
  run_script dns_retry "${case_dir}" 26 true
  rc=$?
  set -e
  assert_status "${rc}" 0 "non-fatal DNS errors must not fail the step"
  attempts=$(grep -c "but the snapshot could not be written." "${case_dir}/output.log" || true)
  (( attempts >= 2 )) || fail "expected the snapshot write to be retried, got ${attempts} attempt(s)"
  assert_not_contains "${case_dir}/output.log" "snapshot saved to"
}

# A Go DNS error can carry the underlying network error, so one line holds the resolver
# endpoint and both ends of the failed transport. None of them may be published.
test_nested_transport_endpoints_are_redacted() {
  local case_dir rc
  case_dir=$(new_case dns-nested)
  set +e
  run_script dns_nested "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_exists "${observation}"
  # The line stays readable: only its addresses go.
  assert_contains "${observation}" "lookup api.ci-rosa-h-test.example.com on [address redacted]: read udp [address redacted]->[address redacted]: i/o timeout"
  # A scoped IPv6 endpoint is redacted with its zone identifier.
  assert_contains "${observation}" "lookup api.ci-rosa-h-test.example.com on [address redacted]: no such host"
  assert_not_contains "${observation}" "2001:db8"
  assert_not_contains "${observation}" "eth0"
  assert_no_resolver_details "${observation}"
  assert_no_resolver_details "${case_dir}/artifacts/dns-diagnostics.txt"
}

# Redaction runs before the byte cap, so an address that straddles the cap cannot
# survive as a readable fragment.
test_address_straddling_the_byte_cap_is_redacted() {
  local case_dir rc
  case_dir=$(new_case dns-boundary)
  set +e
  run_script dns_boundary "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  local -i section_size
  assert_file_exists "${observation}"
  section_of "${observation}" "DNS-related lines not seen" "DNS probe taken at this observation" \
    > "${case_dir}/boundary-lines"
  section_size=$(wc -c < "${case_dir}/boundary-lines")
  # 8192 bytes of log lines plus the blank line that separates the sections.
  (( section_size <= 8194 )) || fail "expected the error-line section to stay capped, got ${section_size}"
  assert_no_resolver_details "${observation}"
}

# A snapshot that cannot be written must not change the step result, must not be
# reported as saved, and must not be claimed in the failure-time diagnostics.
test_unwritable_snapshot_does_not_change_result() {
  local case_dir rc
  case_dir=$(new_case snapshot-unwritable)
  set +e
  run_script dns_persistent "${case_dir}" 0 true
  rc=$?
  set -e
  assert_status "${rc}" 1 "a failed snapshot write must not change the step result"
  assert_contains "${case_dir}/output.log" "ERROR: Fatal error detected in install logs:"
  assert_contains "${case_dir}/output.log" "but the snapshot could not be written."
  assert_not_contains "${case_dir}/output.log" "snapshot saved to"
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "0 bounded snapshot(s)"
}

# A single huge log line must not defeat the size bounds, the account mask or the ANSI
# stripping.
test_oversized_line_is_capped_and_masked() {
  local case_dir rc
  case_dir=$(new_case dns-oversized)
  set +e
  run_script dns_oversized "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  local -i section_size file_size
  section_of "${observation}" "DNS-related lines not seen" "DNS probe taken at this observation" \
    > "${case_dir}/new-lines"
  section_size=$(wc -c < "${case_dir}/new-lines")
  # 8192 bytes of log lines plus the blank line that separates the sections.
  (( section_size <= 8194 )) || fail "expected the error-line section to be capped at 8192 bytes, got ${section_size}"
  file_size=$(wc -c < "${observation}")
  (( file_size <= 16384 )) || fail "expected a bounded observation file, got ${file_size} bytes"

  assert_no_secrets "${observation}"
  assert_no_resolver_details "${observation}"
  assert_contains "${observation}" "arn:aws:iam::1234***:role/installer"
  if grep -q "$(printf '\033')" "${observation}"; then
    fail "expected ANSI escape sequences to be stripped from ${observation}"
  fi
}

# With an API URL and cloud credentials available, the probe host comes from the URL and
# the Route 53 evidence reports an exactly matched zone with a sound delegation.
test_api_url_and_route53_labelling() {
  local case_dir rc
  case_dir=$(new_case dns-full)
  set +e
  run_script dns_full "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  # The probe host comes from .api.url, which is a different name from the one the
  # step would derive from .name plus .dns.base_domain.
  assert_probe_is_bounded_and_mocked "${case_dir}" "api-from-url.ci-rosa-h-test.example.com"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "API URL: https://api-from-url.ci-rosa-h-test.example.com:443"
  assert_contains "${diagnostics}" "API hostname: api-from-url.ci-rosa-h-test.example.com"
  assert_not_contains "${diagnostics}" "derived API hostname"
  # The authoritative nameserver is taken from the answer, never from the diagnostic
  # line dig prints when it cannot reach a resolver.
  assert_contains "${diagnostics}" "=== dig @ns-mock.example.com. api-from-url.ci-rosa-h-test.example.com (authoritative) ==="
  assert_route53_section_labels "${diagnostics}"
  # An exactly matched public cluster zone, delegated by its parent to the nameservers
  # it was assigned: the reading the stand-in parser on an image without jq must reach
  # as well.
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  assert_contains "${diagnostics}" "Ancestor zone lookup: parent-zone-match (example.com)"
  assert_contains "${diagnostics}" "Topology: delegated-child-zone"
  assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" \
    "present; in the cluster zone; record sets: 2, types: A,OTHER"
  assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" \
    "present; record sets: 1, nameservers: 4"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" \
    "present; record sets: 1, nameservers: 4"
  assert_contains "${diagnostics}" "Delegation verdict: match"
  # A record type outside the allowlist is counted but never named.
  assert_not_contains "${diagnostics}" "MOCKTYPE"
  # An alias record has no ResourceRecords; it must still count as present.
  assert_not_contains "${diagnostics}" "mock-nlb"
  # The reads are scoped to this run's own zone and bounded.
  assert_contains "${case_dir}/state/aws-arguments" "route53 list-resource-record-sets --hosted-zone-id ZCHILD --start-record-name api.ci-rosa-h-test.example.com. --max-items 10"
  assert_route53_reads_are_bounded "${case_dir}" 5 ci-rosa-h-test.example.com example.com
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
  assert_no_resolver_details "${diagnostics}"
}

# A cluster zone with no hosted zone of its own is a valid ROSA layout: its records live
# in the base-domain zone, which carries no delegation for it. That must be reported as
# such, the records must be looked for in the parent zone, and no fault may be claimed.
test_parent_zone_only_topology_is_respected() {
  local case_dir rc
  case_dir=$(new_case dns-parent-only)
  set +e
  run_script dns_zone_parent_only "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): no-visible-match"
  assert_contains "${diagnostics}" "Ancestor zone lookup: parent-zone-match (example.com)"
  assert_contains "${diagnostics}" "Topology: parent-zone-only"
  assert_contains "${diagnostics}" "This is a valid ROSA layout and not by itself a fault."
  assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" \
    "present; in the example.com zone; record sets: 1, types: A"
  assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" \
    "not-checked; no hosted zone for the cluster zone is visible"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" \
    "absent; record sets: 0, nameservers: 0"
  assert_contains "${diagnostics}" "Delegation verdict: not-applicable"
  assert_contains "${diagnostics}" "there is no child zone for the ancestor to delegate to."
  assert_not_contains "${diagnostics}" "Delegation verdict: mismatch"
  assert_contains "${case_dir}/state/aws-arguments" "route53 list-resource-record-sets --hosted-zone-id ZPARENT --start-record-name api.ci-rosa-h-test.example.com."
  assert_route53_reads_are_bounded "${case_dir}" 4 ci-rosa-h-test.example.com example.com
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
  assert_no_resolver_details "${diagnostics}"
}

# A parent zone that does delegate the cluster zone while no hosted zone for it is
# visible is a different situation from the parent-zone-only layout, and must not be
# reported as the benign one: the child zone may be in another account, or gone.
test_delegation_without_a_visible_child_zone_is_distinguished() {
  local case_dir rc
  case_dir=$(new_case dns-hidden-child)
  set +e
  run_script dns_zone_hidden_child "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): no-visible-match"
  assert_contains "${diagnostics}" "Topology: child-zone-not-visible"
  assert_contains "${diagnostics}" "or it may have been deleted while the delegation stayed behind."
  assert_not_contains "${diagnostics}" "Topology: parent-zone-only"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" \
    "present; record sets: 1, nameservers: 4"
  # Nothing was read on the child side, so no verdict may be claimed either way.
  assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
}

# A name query is answered with the zones that sort at or after the name asked for, so a
# lexically adjacent zone of an unrelated cluster can come back. It must never be
# adopted as the cluster's zone, named in the artifact, or read from.
test_lexically_adjacent_zone_is_never_used() {
  local case_dir rc
  case_dir=$(new_case dns-zone-adjacent)
  set +e
  run_script dns_zone_adjacent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): no-visible-match"
  assert_contains "${diagnostics}" "Ancestor zone lookup: no-visible-match"
  assert_contains "${diagnostics}" "Topology: undetermined"
  assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" \
    "not-checked; no hosted zone to read it from"
  assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
  # Neither the neighbour's name nor its identifier may be published...
  assert_not_contains "${diagnostics}" "ci-rosa-h-test-2"
  assert_not_contains "${diagnostics}" "ZADJACENT"
  # ...and no record may be read out of it.
  assert_not_contains "${case_dir}/state/aws-arguments" "list-resource-record-sets"
  assert_route53_reads_are_bounded "${case_dir}" 2 ci-rosa-h-test.example.com example.com
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
}

# A delegation that points somewhere other than the nameservers the cluster zone was
# assigned is the finding this section exists for. It must be reported as a mismatch,
# with counts only: the nameserver names stay out of the public artifact.
test_delegation_mismatch_is_reported_without_nameservers() {
  local case_dir rc
  case_dir=$(new_case dns-zone-mismatch)
  set +e
  run_script dns_zone_mismatch "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  assert_contains "${diagnostics}" "Topology: delegated-child-zone"
  assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" \
    "present; record sets: 1, nameservers: 4"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" \
    "present; record sets: 1, nameservers: 4"
  assert_contains "${diagnostics}" "Delegation verdict: mismatch"
  assert_contains "${diagnostics}" "are not published here."
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
}

# A private hosted zone carries no public delegation, so its apex nameservers may not be
# compared with one. When a public zone of the same name exists it is the one to use.
test_private_zone_handling() {
  local case_dir rc diagnostics

  case_dir=$(new_case dns-zone-private-only)
  set +e
  run_script dns_zone_private_only "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  assert_contains "${diagnostics}" "zone visibility: private"
  # Both sides were read, but they are not comparable, so no fault is claimed.
  assert_contains "${diagnostics}" "Delegation verdict: not-applicable"
  assert_contains "${diagnostics}" "A private hosted zone carries no public delegation"
  assert_not_contains "${diagnostics}" "Delegation verdict: mismatch"
  assert_no_route53_response_content "${diagnostics}"

  # Split horizon: the private zone sorts first, but the public one decides, and its
  # nameservers match the delegation.
  case_dir=$(new_case dns-zone-split-horizon)
  set +e
  run_script dns_zone_split_horizon "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "zone visibility: public-and-private"
  assert_contains "${diagnostics}" "Delegation verdict: match"
  assert_contains "${case_dir}/state/aws-arguments" "--hosted-zone-id ZCHILD"
  assert_not_contains "${case_dir}/state/aws-arguments" "--hosted-zone-id ZPRIVATE"
  assert_no_route53_response_content "${diagnostics}"
}

# A visible zone that simply holds neither the API record nor a delegation must say so,
# rather than reporting an error or inventing a match. A bounded read that stopped short
# of the end of the zone says so too.
test_missing_records_are_reported_as_absent() {
  local case_dir rc
  case_dir=$(new_case dns-records-missing)
  set +e
  run_script dns_records_missing "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" \
    "absent; in the cluster zone; record sets: 0; bounded read truncated: yes"
  assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" \
    "absent; record sets: 0, nameservers: 0; bounded read truncated: yes"
  # Every read that stopped short of the end of the zone says so, including this one.
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" \
    "absent; record sets: 0, nameservers: 0; bounded read truncated: yes"
  # The cluster zone's own nameservers were not found, so no verdict may be claimed,
  # and a truncated absence must not elect the benign topology either.
  assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
  assert_not_contains "${diagnostics}" "Topology: parent-zone-only"
  # The record that sorts after the one asked for belongs to another name and must not
  # be counted or published.
  assert_not_contains "${diagnostics}" "other.ci-rosa-h-test.example.com"
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
}

# A denied, timed-out or truncated zone lookup is a different statement from "not
# there", and none of them may leak what the AWS CLI wrote to stderr or end the step
# differently. A truncated read still leaves the other questions worth asking.
test_route53_zone_lookup_errors_are_classified() {
  local case_dir rc scenario diagnostics
  for scenario in dns_zone_denied dns_zone_timeout dns_zone_truncated; do
    case_dir=$(new_case "route53-${scenario}")
    set +e
    run_script "${scenario}" "${case_dir}"
    rc=$?
    set -e
    assert_status "${rc}" 1 "${scenario} must fail exactly like the baseline fatal error"
    diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
    assert_route53_section_labels "${diagnostics}"
    # Neither the AWS CLI's error output nor the unrelated zones it returned are published.
    assert_not_contains "${diagnostics}" "MOCK_DENIED_PRINCIPAL"
    assert_not_contains "${diagnostics}" "An error occurred"
    assert_no_route53_response_content "${diagnostics}"
    assert_no_secrets "${diagnostics}"
    assert_no_secrets "${case_dir}/output.log"

    case "${scenario}" in
      dns_zone_truncated)
        # The read did not settle the question, so nothing is reported as absent, but
        # the ancestor and the records it might hold are still worth asking about.
        assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): lookup-truncated"
        assert_contains "${diagnostics}" "Ancestor zone lookup: lookup-truncated"
        assert_contains "${diagnostics}" "Topology: undetermined"
        assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
        # A read that did not answer is never turned into an absence, in the zone
        # lines or in the record lines that follow from them.
        assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" \
          "not-checked; the cluster zone lookup did not complete (lookup-truncated)"
        assert_not_contains "${diagnostics}" "lookup: no-visible-match"
        assert_not_contains "${diagnostics}" "Topology: parent-zone-only"
        assert_not_contains "${diagnostics}" "AccessDenied"
        ;;
      dns_zone_denied)
        assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): lookup-denied"
        assert_contains "${diagnostics}" "No further Route 53 read was attempted after this result."
        assert_not_contains "${diagnostics}" "Topology:"
        assert_not_contains "${diagnostics}" "AccessDenied"
        assert_not_contains "${case_dir}/state/aws-arguments" "list-resource-record-sets"
        ;;
      dns_zone_timeout)
        assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): lookup-timed-out"
        assert_contains "${diagnostics}" "No further Route 53 read was attempted after this result."
        assert_not_contains "${diagnostics}" "Topology:"
        ;;
    esac
  done
}

# A record read can be denied on its own: an IAM policy may allow listing zones while
# scoping ListResourceRecordSets to particular zones. A failed read publishes its state
# and no counts, because a zero there would read as "none found".
test_route53_record_lookup_errors_are_classified() {
  local case_dir rc scenario diagnostics expected
  for scenario in dns_records_denied dns_records_failed; do
    expected="lookup-denied"
    [[ "${scenario}" != "dns_records_failed" ]] || expected="lookup-failed"
    case_dir=$(new_case "route53-${scenario}")
    set +e
    run_script "${scenario}" "${case_dir}"
    rc=$?
    set -e
    assert_status "${rc}" 1 "${scenario} must fail exactly like the baseline fatal error"
    diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
    # The zone lookups succeeded, so the section reports the zones it found.
    assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
    assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" "${expected}"
    assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" "${expected}"
    assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" "${expected}"
    assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
    # A read that learned nothing must not publish a count that reads as "none found".
    assert_not_contains "${diagnostics}" "record sets: 0"
    assert_not_contains "${diagnostics}" "Throttling"
    assert_not_contains "${diagnostics}" "MOCK_DENIED_PRINCIPAL"
    assert_no_route53_response_content "${diagnostics}"
    assert_no_secrets "${diagnostics}"
  done
}

# An ancestor lookup that did not answer must not be reported downstream as an ancestor
# zone that is absent.
test_failed_ancestor_lookup_is_not_reported_as_absence() {
  local case_dir rc
  case_dir=$(new_case dns-ancestor-denied)
  set +e
  run_script dns_ancestor_denied "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  assert_contains "${diagnostics}" "Ancestor zone lookup: lookup-denied"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in an ancestor zone" \
    "not-checked; no ancestor zone was read (lookup-denied)"
  # The cluster zone is still readable, so its own records are still reported.
  assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" \
    "present; in the cluster zone; record sets: 2, types: A,OTHER"
  assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
  assert_not_contains "${diagnostics}" "Ancestor zone lookup: no-visible-match"
  assert_not_contains "${diagnostics}" "MOCK_DENIED_PRINCIPAL"
  assert_no_route53_response_content "${diagnostics}"
}

# Real ROSA base domains have more labels than the fixtures' three, so the walk has to
# climb, and it has to say when it stopped at its own bound rather than at an answer.
test_ancestor_walk_climbs_and_reports_its_bound() {
  local case_dir rc diagnostics

  case_dir=$(new_case dns-zone-deep)
  set +e
  run_script dns_zone_deep "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.d1.d2.example.com): exact-match"
  assert_contains "${diagnostics}" "Ancestor zone lookup: ancestor-zone-match (d2.example.com)"
  assert_contains "${case_dir}/state/aws-arguments" "--dns-name d1.d2.example.com"
  assert_contains "${case_dir}/state/aws-arguments" "--dns-name d2.example.com"
  assert_route53_reads_are_bounded "${case_dir}" 6 \
    ci-rosa-h-test.d1.d2.example.com d1.d2.example.com d2.example.com
  assert_no_route53_response_content "${diagnostics}"

  # The same zone with no visible ancestor: the walk stops at ROUTE53_MAX_ANCESTORS and
  # must not call that an absence, because example.com was never asked about.
  case_dir=$(new_case dns-zone-bounded)
  set +e
  run_script dns_zone_bounded "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Ancestor zone lookup: search-bounded"
  assert_not_contains "${diagnostics}" "Ancestor zone lookup: no-visible-match"
  assert_not_contains "${case_dir}/state/aws-arguments" "--dns-name example.com "
  assert_route53_reads_are_bounded "${case_dir}" 5 \
    ci-rosa-h-test.d1.d2.example.com d1.d2.example.com d2.example.com
  assert_no_route53_response_content "${diagnostics}"
}

# A hosted zone that exists with its own nameservers while its parent holds no
# delegation for it is the most actionable fault this section can observe, so it gets a
# verdict of its own rather than being folded into "not comparable".
test_undelegated_zone_is_reported() {
  local case_dir rc
  case_dir=$(new_case dns-zone-undelegated)
  set +e
  run_script dns_zone_undelegated "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  assert_contains "${diagnostics}" "Topology: delegated-child-zone"
  assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" \
    "present; record sets: 1, nameservers: 4"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" \
    "absent; record sets: 0, nameservers: 0"
  assert_contains "${diagnostics}" "Delegation verdict: not-delegated"
  assert_contains "${diagnostics}" "cannot reach those records."
  assert_not_contains "${diagnostics}" "Delegation verdict: not-comparable"
  assert_not_contains "${diagnostics}" "Topology: parent-zone-only"
  assert_no_route53_response_content "${diagnostics}"
  assert_no_secrets "${diagnostics}"
}

# A reply the step cannot parse is a read that did not answer. It must never be
# published as an absence, on either the zone or the record side.
test_unparseable_response_is_not_an_absence() {
  local case_dir rc diagnostics

  case_dir=$(new_case dns-zone-malformed)
  set +e
  run_script dns_zone_malformed "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): lookup-failed"
  assert_contains "${diagnostics}" "No further Route 53 read was attempted after this result."
  assert_not_contains "${diagnostics}" "lookup: no-visible-match"
  assert_not_contains "${diagnostics}" "Topology:"
  assert_no_route53_response_content "${diagnostics}"

  case_dir=$(new_case dns-records-malformed)
  set +e
  run_script dns_records_malformed "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  # The zone reads parsed, so the zones are still reported...
  assert_contains "${diagnostics}" "Cluster zone lookup (ci-rosa-h-test.example.com): exact-match"
  # ...while every record read is reported as a read that failed, with no counts.
  assert_route53_record "${diagnostics}" "API record (api.ci-rosa-h-test.example.com)" "lookup-failed"
  assert_route53_record "${diagnostics}" "Nameservers assigned to the cluster zone" "lookup-failed"
  assert_route53_record "${diagnostics}" "Delegation of the cluster zone in the example.com zone" "lookup-failed"
  assert_contains "${diagnostics}" "Delegation verdict: not-comparable"
  # No record line claims an absence, and none publishes a count it did not establish.
  assert_not_contains "${diagnostics}" "  absent"
  assert_not_contains "${diagnostics}" "record sets: 0"
  assert_no_route53_response_content "${diagnostics}"
}

# The step must no longer be able to publish a Route 53 response body: the artifact is
# built from states and counts, so no AWS CLI output may be echoed into it.
test_step_publishes_no_raw_route53_output() {
  local offenders
  # Every Route 53 call goes through the one capturing helper.
  offenders=$(grep -nE '^[^#]*aws route53' "${COMMAND_SCRIPT}" \
    | grep -v 'route53_call_body=$(timeout' || true)
  if [[ -n "${offenders}" ]]; then
    printf '%s\n' "${offenders}" >&2
    fail "every aws route53 call must go through route53_call, which captures its output"
  fi
  # ...whose stderr goes to the file the step classifies but never publishes.
  if ! grep -A2 -E '^[^#]*aws route53' "${COMMAND_SCRIPT}" | grep -q '2>"${stderr_file}"'; then
    fail "the Route 53 helper must capture stderr instead of letting it reach the artifact"
  fi
}

# The stand-in parser keys on the step's filter strings verbatim. A reformat on either
# side would silently make it return nothing, and only on an image without real jq, so
# the two are compared here instead.
test_jq_stand_in_matches_the_step_filters() {
  local filter
  while IFS= read -r filter; do
    [[ -n "${filter}" ]] || continue
    grep -Fq "  '${filter}')" "${BASH_SOURCE[0]}" \
      || fail "the jq stand-in has no case for the step's filter: ${filter}"
  done < <(route53_filters_of_the_step)
}

# On a machine that has real jq, prove the stand-in used on the CI image returns exactly
# what jq returns for those filters - including for the pretty-printed,
# identifier-first, nested documents the AWS CLI actually emits, which a parser that
# depended on member order or on compact JSON would get wrong while the fixtures, being
# written for it, still passed.
test_jq_stand_in_agrees_with_real_jq() {
  command -v jq >/dev/null || return 0
  local case_dir stub filter document body real stub_output pretty
  local -i real_rc stub_rc
  case_dir=$(new_case jq-differential)
  ( FORCE_STUB_JQ=true; make_mocks "${case_dir}/bin" )
  stub="${case_dir}/bin/jq"

  local -a documents=(
    '{"HostedZones":[{"Id":"/hostedzone/ZPRIVATE","Name":"ci-rosa-h-test.example.com.","CallerReference":"mock","Config":{"Comment":"mock","PrivateZone":true}},{"Id":"/hostedzone/ZCHILD","Name":"ci-rosa-h-test.example.com.","Config":{"PrivateZone":false}}],"IsTruncated":false,"MaxItems":"5"}'
    '{"HostedZones":[],"IsTruncated":true}'
    '{"ResourceRecordSets":[{"Name":"api.ci-rosa-h-test.example.com.","Type":"A","AliasTarget":{"HostedZoneId":"ZELB","DNSName":"mock-nlb.example.","EvaluateTargetHealth":false}},{"Name":"ci-rosa-h-test.example.com.","Type":"NS","TTL":172800,"ResourceRecords":[{"Value":"ns-1.awsdns-00.example."},{"Value":"ns-2.awsdns-01.example."}]}],"IsTruncated":true}'
    '{"ResourceRecordSets":[],"IsTruncated":false,"NextToken":"mock-token"}'
    '{"HostedZones":[{"Name":"ci-rosa-h-test.example.com."},'
    '{"HostedZones":"not-an-array"}'
    '{"ResourceRecordSets":"not-an-array"}'
    'not json at all'
  )

  while IFS= read -r filter; do
    [[ -n "${filter}" ]] || continue
    for document in "${documents[@]}"; do
      pretty=$(printf '%s' "${document}" | jq . 2>/dev/null) || pretty="${document}"
      for body in "${document}" "${pretty}"; do
        real_rc=0
        real=$(printf '%s' "${body}" | jq -r "${filter}" 2>/dev/null) || real_rc=$?
        stub_rc=0
        stub_output=$(printf '%s' "${body}" | "${stub}" -r "${filter}" 2>/dev/null) || stub_rc=$?
        # The output has to agree, and so does whether the parser accepted the body:
        # the step reads a rejected body as a failed lookup, not as an empty one.
        if [[ "${real}" != "${stub_output}" ]] \
          || { (( real_rc == 0 )) && (( stub_rc != 0 )); } \
          || { (( real_rc != 0 )) && (( stub_rc == 0 )); }; then
          printf 'filter: %s\nbody: %s\nreal jq: rc=%s [%s]\nstand-in: rc=%s [%s]\n' \
            "${filter}" "${body}" "${real_rc}" "${real}" "${stub_rc}" "${stub_output}" >&2
          fail "the jq stand-in disagrees with real jq"
        fi
      done
    done
  done < <(route53_filters_of_the_step)
}

route53_filters_of_the_step() {
  local -a filters=()
  local filter
  while IFS= read -r filter; do
    [[ -n "${filter}" ]] || continue
    filters+=("${filter}")
  done < <(sed -nE "s/^ROUTE53_[A-Z_]+FILTER='(.*)'\$/\1/p" "${COMMAND_SCRIPT}")
  # Pinned, so that renaming a constant cannot quietly empty the two checks below.
  (( ${#filters[@]} == 3 )) \
    || fail "expected 3 Route 53 jq filters in the step, found ${#filters[@]}"
  printf '%s\n' "${filters[@]}"
}

# The snapshot must reach its file through one write whose status is checked. A group
# of writes redirected into the file reports only the status of its last command, so an
# earlier failure would be masked by a later line that still succeeded and a partial
# snapshot would be counted as saved.
test_snapshot_reaches_its_file_through_one_checked_write() {
  local -i writes
  writes=$(grep -cE '> *"\$\{observation_file\}"' "${COMMAND_SCRIPT}" || true)
  (( writes == 1 )) || fail "expected exactly one write into the observation file, found ${writes}"
  if ! grep -A1 -E '> *"\$\{observation_file\}"' "${COMMAND_SCRIPT}" \
      | grep -qE '\|\|[[:space:]]*observation_written="no"'; then
    grep -n -A1 -E '> *"\$\{observation_file\}"' "${COMMAND_SCRIPT}" >&2
    fail "the write into the observation file must record its failure"
  fi
}

# The step must not copy resolver configuration into an artifact at all: no reader of
# /etc/resolv.conf may feed anything but a presence label.
test_script_publishes_no_resolver_configuration() {
  if grep -nE '(grep|cat|awk|sed|head|tail|cut|printf|echo)[^#]*/etc/resolv\.conf' "${COMMAND_SCRIPT}" >&2; then
    fail "the step must only test /etc/resolv.conf for readability, never read out its contents"
  fi
}

test_dns_chronology_survives_install_log_refetch
test_failure_diagnostics_label_probe_origin_and_time
test_script_makes_no_management_cluster_resolver_claim
test_script_publishes_no_resolver_configuration
test_snapshot_reaches_its_file_through_one_checked_write
test_probe_failures_do_not_change_step_result
test_non_dns_failure_behaviour_is_unchanged
test_unobserved_dns_error_is_not_claimed_as_observed
test_successful_install_collects_no_dns_diagnostics
test_observations_are_bounded
test_error_line_cap_and_install_log_exclusion
test_byte_cap_defers_omitted_lines_to_a_later_observation
test_nested_transport_endpoints_are_redacted
test_address_straddling_the_byte_cap_is_redacted
test_failed_snapshot_write_is_retried
test_unwritable_snapshot_does_not_change_result
test_oversized_line_is_capped_and_masked
test_step_publishes_no_raw_route53_output
test_jq_stand_in_matches_the_step_filters
test_jq_stand_in_agrees_with_real_jq
test_api_url_and_route53_labelling
test_parent_zone_only_topology_is_respected
test_delegation_without_a_visible_child_zone_is_distinguished
test_lexically_adjacent_zone_is_never_used
test_delegation_mismatch_is_reported_without_nameservers
test_undelegated_zone_is_reported
test_private_zone_handling
test_unparseable_response_is_not_an_absence
test_missing_records_are_reported_as_absent
test_route53_zone_lookup_errors_are_classified
test_route53_record_lookup_errors_are_classified
test_failed_ancestor_lookup_is_not_reported_as_absence
test_ancestor_walk_climbs_and_reports_its_bound

echo "PASS: rosa cluster wait-ready DNS diagnostics tests"
