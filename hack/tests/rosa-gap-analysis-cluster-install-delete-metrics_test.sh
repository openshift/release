#!/bin/bash

# Behavioral tests for the ClusterOperator / node validation in
# ci-operator/step-registry/rosa/gap-analysis/cluster-install-delete-metrics/
# rosa-gap-analysis-cluster-install-delete-metrics-commands.sh
#
# Like github-downstream-sync-commands_test.sh, this lives outside the step
# registry because registry validation only accepts registered step files.
# Run by hack/validate-registry-commands.sh.
#
# The step only reaches a cluster through `oc` and `ocm`, so these tests put stub
# binaries ahead of the real ones on PATH and drive the step with a scripted API.
# No cluster, no credentials and no network are involved.
#
# Regression guarded: a failed or malformed `oc get ... -o json` used to be
# swallowed by `|| true`, leaving the parse results empty, which the step then
# reported as "All ClusterOperators are healthy" / "All nodes: READY
# (Total nodes: 0)" while the cluster had never actually been inspected.
#
# Also guarded: health must be asserted, not assumed. An item with no status, no
# Ready/Available condition, or a condition whose status is not "True" is
# unverified and must be reported, not counted as healthy. An item with a
# non-object status, a non-array conditions list, a non-object condition entry
# or a non-object metadata must fail validation before the health checks index
# it, rather than aborting the step under errexit with no result recorded.

set -o nounset
set -o errexit
set -o pipefail

# A caller's exported shell functions must not stand in for the tools this
# suite and the step rely on: an exported `jq` would otherwise shadow every
# assertion helper here, and `type -P` already keeps it out of the generated
# stub. Clearing them makes the suite independent of the caller's shell.
unset -f jq oc ocm cat date grep 2>/dev/null || true

# Absolute spelling of an existing directory. CDPATH is cleared in the
# subshell: when cd reaches a directory through CDPATH it prints the
# destination, and that line would be captured here as part of the path.
# The resolution is physical (-P), because the logical one rewrites a
# symlinked path textually: with a PATH entry like links/jump/../tools, where
# links/jump points at real/child, the lookup finds real/tools/jq while the
# logical answer is links/tools -- a different directory, and possibly a
# different executable.
absolute_dir(){
  local dir="$1"
  [[ -n "${dir}" ]] || return 1
  (CDPATH='' cd -P -- "${dir}" && pwd -P)
}
# Absolute spelling of a file path, whose parent directory is resolved
# physically as above. The basename is appended rather than resolved, so a
# symlinked file keeps the name the caller asked about.
absolute_file(){
  local path="$1" dir base
  [[ -n "${path}" ]] || return 1
  dir="$(absolute_dir "$(dirname -- "${path}")")" || return 1
  base="$(basename -- "${path}")"
  printf '%s/%s\n' "${dir%/}" "${base}"
}

# Normalised, absolute spelling of the work root. mktemp echoes a path
# relative to the current directory when TMPDIR itself is relative, and the
# probes below change directory, so this runs once, before any of them,
# against the directory the suite started in. Absolute spellings are
# normalised too: TMPDIR=/tmp/. makes mktemp answer /tmp/./tmp.XXXX, which
# names the same directory as a cd/pwd answer but does not compare equal to
# it, so a probe would report a difference that is not there.
resolve_workroot(){
  local root="$1"
  [[ -n "${root}" ]] || return 1
  [[ -d "${root}" ]] || return 1
  absolute_dir "${root}"
}

# Create the work root, arm its cleanup, and make it absolute. The trap is
# armed before the resolution can fail, so a work root that cannot be
# resolved is still removed -- the current directory has not changed yet, so
# the relative spelling in WORKROOT still names it.
setup_workroot(){
  local resolved
  WORKROOT="$(mktemp -d)" || return 1
  trap 'rm -rf "${WORKROOT}"' EXIT
  resolved="$(resolve_workroot "${WORKROOT}")" || return 1
  WORKROOT="${resolved}"
}

# Prologue-only mode, so a probe can exercise the work-root handling above
# from another directory without the suite running itself. It is answered
# before the step-script and tool checks on purpose: this mode creates,
# resolves and removes a work root and does nothing else, so an unresolvable
# relative STEP_UNDER_TEST, or a PATH without the tools the scenarios need,
# must not decide its outcome.
# Selected by an explicit argument, never by the environment: the registry
# validator runs this suite with no arguments and passes its own environment
# through, so an inherited variable -- even one set to 0 -- must not be able
# to turn a required job into a run that asserts nothing.
if [[ $# -eq 1 && "$1" == "--print-workroot" ]]; then
  if ! setup_workroot; then
    echo "FATAL: could not prepare the temporary work root" >&2
    exit 1
  fi
  printf '%s\n' "${WORKROOT}"
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo "FATAL: unknown argument: $1" >&2
  exit 1
fi

# Non-interactive bash reads the file named by BASH_ENV before it runs a
# script, and the generated stubs are bash scripts. An inherited BASH_ENV that
# exported KUBECONFIG would therefore replace the kubeconfig a direct fixture
# probe sets, and the probe would read a stub answer meant for another
# cluster. This shell has already read any inherited BASH_ENV -- that cannot
# be undone here -- so the unset governs only the children: the generated
# stubs and the step. run_step starts the step with env -i and was never
# exposed.
unset BASH_ENV

# The directory the suite was launched from, resolved physically like every
# other path here. PATH entries are looked up relative to the current
# directory, so a probe that changes directory needs this to keep an
# inherited relative entry naming the directory it named at launch.
LAUNCH_DIR="$(absolute_dir .)"

# Rewrites the relative entries of a PATH value so they keep naming the same
# directories from anywhere. An empty entry means the current directory to
# the shell, so it is rewritten for the same reason. Absolute entries, and
# the order, are left exactly as they are: nothing is added, dropped or
# reordered, so no system fallback is silently introduced. The base is
# expected to be physically resolved already, as LAUNCH_DIR is; the entry
# itself is appended as written, because a relative spelling that passes
# through a symlink and ".." must still be looked up the way the shell would
# look it up.
path_from_dir(){
  local base="${1%/}" value="$2" out="" entry
  while true; do
    entry="${value%%:*}"
    case "${entry}" in
      "")  out+="${base:-/}" ;;
      /*)  out+="${entry}" ;;
      *)   out+="${base}/${entry}" ;;
    esac
    if [[ "${value}" == *:* ]]; then
      out+=":"
      value="${value#*:}"
    else
      break
    fi
  done
  printf '%s' "${out}"
}

REPO_ROOT="$(absolute_dir "$(dirname "${BASH_SOURCE[0]}")/../..")"
# STEP_UNDER_TEST lets the suite be pointed at another copy of the step, which is
# how the regression was confirmed against the pre-fix version.
STEP="${STEP_UNDER_TEST:-${REPO_ROOT}/ci-operator/step-registry/rosa/gap-analysis/cluster-install-delete-metrics/rosa-gap-analysis-cluster-install-delete-metrics-commands.sh}"

if [[ ! -f "${STEP}" ]]; then
  echo "FATAL: step script not found: ${STEP}" >&2
  exit 1
fi

# The step shells out to jq. Skip rather than fail where it is unavailable, so
# this suite never turns an unrelated image change into a red required job.
# Known coverage gap: in an environment without these tools the suite runs no
# assertions, and the registry validator cannot distinguish that from a run
# whose assertions all passed. Closing it would require jq in the image the
# validation job uses.
for tool in jq date grep cat; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "SKIP: ${tool} is not available; skipping gap-analysis step tests" >&2
    exit 0
  fi
done

PASS=0
FAIL=0
if ! setup_workroot; then
  echo "FATAL: could not prepare the temporary work root" >&2
  exit 1
fi

# Absolute, so the probes below can re-run this file from another directory.
if ! SUITE_PATH="$(absolute_file "${BASH_SOURCE[0]}")"; then
  echo "FATAL: could not resolve this suite to an absolute path" >&2
  exit 1
fi

# Build an isolated sandbox with stub oc/ocm binaries.
# $1 = scenario name, consumed by the oc stub via OC_SCENARIO.
make_sandbox(){
  local name="$1" dir
  # mktemp, not a counter: every caller captures this function with command
  # substitution, so a counter would be incremented in a subshell and two runs
  # of one scenario would share a directory, letting the second read the
  # first's stub call counters and artifacts.
  dir="$(mktemp -d "${WORKROOT}/${name}-XXXXXX")"
  if [[ "${dir}" == *:* ]]; then
    # PATH is colon-separated, so such a directory could never be reached
    # through it and the step would fall through to a real client.
    echo "FATAL: sandbox path contains a colon and cannot be put on PATH: ${dir}" >&2
    exit 1
  fi
  # Command substitution does not inherit errexit, so without this guard a
  # failed mktemp would leave dir empty and every path below would be rooted
  # at /, writing stub binaries over /bin.
  if [[ -z "${dir}" || ! -d "${dir}" ]]; then
    echo "FATAL: could not create a sandbox under ${WORKROOT}" >&2
    exit 1
  fi
  mkdir -p "${dir}/bin" "${dir}/profile" "${dir}/shared" "${dir}/artifacts" "${dir}/state" "${dir}/tmp"

  echo "[default]" > "${dir}/profile/.awscred"
  echo "fake-offline-token" > "${dir}/profile/ocm-token"
  echo "fake-cluster-id" > "${dir}/shared/cluster-id"
  echo "fake-kubeconfig" > "${dir}/shared/kubeconfig"

  cat > "${dir}/bin/ocm" <<'OCM'
#!/bin/bash
# Every ocm call the step makes succeeds and prints nothing of substance,
# except for the hcp_diagnostics scenarios: those need a domain prefix so the
# step can resolve the hosted control-plane namespaces and actually reach its
# management-cluster diagnostic collection. Scoped by scenario name so no
# other HCP case changes behaviour.
if [[ "${OC_SCENARIO:-}" == hcp_diagnostics* \
   && "$*" == *"/api/clusters_mgmt/v1/clusters/"* \
   && "$*" != *"/credentials"* && "$*" != *"provision_shard"* ]]; then
  printf '{"domain_prefix":"dp","name":"fake-cluster"}\n'
fi
exit 0
OCM

  # The state directory is baked in rather than passed through the environment,
  # so the stub counts calls identically however it is invoked.
  # %q, not quoting by hand: a sandbox path containing a literal $ (TMPDIR can
  # hold one) would otherwise be partially expanded when the stub runs, the
  # counter file would land elsewhere and the call-sequence scenarios would
  # silently read the wrong fixture.
  { echo '#!/bin/bash'
    printf 'OC_STATE_DIR=%q\n' "${dir}/state"
    printf 'OC_SHARED_DIR=%q\n' "${dir}/shared"; } > "${dir}/bin/oc"
  cat >> "${dir}/bin/oc" <<'OC'
# Stub oc. Behaviour is selected by OC_SCENARIO and only covers the calls the
# validation sections make; anything else succeeds with empty output so the step
# can run to completion.

# Sequence number of this JSON read of <resource>. The step reads each resource
# once for the report and once again for the snapshot, so a scenario can fail
# only the snapshot read and leave the report queries healthy.
json_call_seq(){
  local file="${OC_STATE_DIR}/$1-json-calls" n=0
  [[ -f "${file}" ]] && n="$(cat "${file}")"
  n=$((n + 1))
  echo "${n}" > "${file}"
  echo "${n}"
}

# Payload for the scenarios where only the snapshot read misbehaves: the first
# read (the report) is healthy, every later read (the snapshot) fails or is
# structurally invalid.
snapshot_phase_json(){
  local resource="$1" seq
  seq="$(json_call_seq "${resource}")"
  healthy_payload(){
    case "${resource}" in
      co)    co_json False True ;;
      nodes) nodes_json True ;;
    esac
  }
  case "${OC_SCENARIO}" in
    report_co_json_only_fails)
      [[ "${resource}" == "co" ]] || { echo "stub oc: report_co_json_only_fails routed to ${resource}" >&2; exit 70; }
      ;;&
    report_nodes_json_only_fails)
      [[ "${resource}" == "nodes" ]] || { echo "stub oc: report_nodes_json_only_fails routed to ${resource}" >&2; exit 70; }
      ;;&
    report_co_json_only_fails|report_nodes_json_only_fails)
      # Inverted relative to the scenarios below: here it is the FIRST read --
      # the report's -- that fails, and the snapshot read stays healthy, so the
      # report failure alone has to decide the verdict.
      if [[ "${seq}" == "1" ]]; then
        echo "${API_ERROR}" >&2
        exit 1
      fi
      healthy_payload
      return 0 ;;
  esac
  if [[ "${seq}" == "1" ]]; then
    healthy_payload
    return 0
  fi
  case "${OC_SCENARIO}" in
    snapshot_query_fails) echo "${API_ERROR}" >&2; exit 1 ;;
    snapshot_shape_fails) printf '{"items":[{"metadata":{"name":"late"},"status":"invalid"}]}\n' ;;
    snapshot_empty)       printf '{"items":[]}\n' ;;
    snapshot_degraded)
      case "${resource}" in
        co)    co_json True True ;;
        nodes) nodes_json True ;;
      esac ;;
    snapshot_unavailable)
      case "${resource}" in
        co)    co_json False False ;;
        nodes) nodes_json True ;;
      esac ;;
    snapshot_notready)
      case "${resource}" in
        co)    co_json False True ;;
        nodes) nodes_json False ;;
      esac ;;
    *)
      echo "stub oc: snapshot_phase_json has no payload for OC_SCENARIO=${OC_SCENARIO}" >&2
      exit 70 ;;
  esac
}

# A realistic client error: it names the cluster API endpoint, which is exactly
# what must not reach a published artifact.
API_ERROR='Unable to connect to the server: dial tcp: lookup api.example-cluster.p3.openshiftapps.com:6443: no such host'

co_json(){
  local degraded="$1" unavailable="$2"
  cat <<JSON
{"items":[
 {"metadata":{"name":"authentication"},"status":{"conditions":[{"type":"Degraded","status":"${degraded}"},{"type":"Available","status":"True"}]}},
 {"metadata":{"name":"dns"},"status":{"conditions":[{"type":"Degraded","status":"False"},{"type":"Available","status":"${unavailable}"}]}}
]}
JSON
}
# A concatenation of two JSON documents: each parses on its own, so a
# per-document shape check accepts it while the counts and health lists read
# both of them.
two_document_json(){
  printf '{"items":[]}\n{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"%s","status":"True"}]}}]}\n' \
    "$1" "$2"
}
# A well-formed item whose name is the empty string. $1 is the condition type.
empty_name_json(){
  printf '{"items":[{"metadata":{"name":""},"status":{"conditions":[{"type":"%s","status":"False"}]}}]}\n' "$1"
}
# Contradicting non-True duplicates. $1 condition type, $2/$3 the two statuses
# in the order reported, $4 the item name.
two_status_json(){
  printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"%s","status":"%s"},{"type":"%s","status":"%s"}]}}]}\n' \
    "$4" "$1" "$2" "$1" "$3"
}
nodes_json(){
  local ready="$1"
  cat <<JSON
{"items":[
 {"metadata":{"name":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
 {"metadata":{"name":"node-b"},"status":{"conditions":[{"type":"Ready","status":"${ready}"}]}}
]}
JSON
}
# Well-formed list whose single item carries a structurally invalid status,
# conditions list, condition entry or metadata. $1 names the item, except in
# the json_metadata_nonobject case where the name is what is invalid.
# An unhandled scenario is a fatal stub bug: emitting nothing would look like a
# malformed payload to the step and let the scenario pass for the wrong reason.
malformed_json(){
  local name="$1"
  case "${OC_SCENARIO}" in
    json_status_nonobject)
      printf '{"items":[{"metadata":{"name":"%s"},"status":"invalid"}]}\n' "${name}" ;;
    json_conditions_nonarray)
      printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":"invalid"}}]}\n' "${name}" ;;
    json_condition_nonobject)
      printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":["invalid"]}}]}\n' "${name}" ;;
    json_metadata_nonobject)
      printf '{"items":[{"metadata":"invalid","status":{"conditions":[]}}]}\n' ;;
    *)
      echo "stub oc: malformed_json has no payload for OC_SCENARIO=${OC_SCENARIO}" >&2
      exit 70 ;;
  esac
}
# Structurally valid list whose single item never asserts health: no status at
# all, an empty conditions list, the relevant condition reported as Unknown, or
# a contradicting duplicate of it. $1 names the item, $2 is the condition type
# that would have proven health. Unhandled scenarios are fatal, as above.
unverified_json(){
  local name="$1" condition="$2"
  case "${OC_SCENARIO}" in
    json_no_status)
      printf '{"items":[{"metadata":{"name":"%s"}}]}\n' "${name}" ;;
    json_empty_conditions)
      printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[]}}]}\n' "${name}" ;;
    json_condition_unknown)
      printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"%s","status":"Unknown"}]}}]}\n' \
        "${name}" "${condition}" ;;
    json_condition_contradicts)
      printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"%s","status":"False"},{"type":"%s","status":"True"}]}}]}\n' \
        "${name}" "${condition}" "${condition}" ;;
    json_condition_contradicts_true_first)
      printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"%s","status":"True"},{"type":"%s","status":"False"}]}}]}\n' \
        "${name}" "${condition}" "${condition}" ;;
    *)
      echo "stub oc: unverified_json has no payload for OC_SCENARIO=${OC_SCENARIO}" >&2
      exit 70 ;;
  esac
}

# Management-cluster payloads. The step exports the management kubeconfig
# before taking its management snapshot, so keying on KUBECONFIG proves the two
# snapshots are built from two different reads rather than one shared payload.
# oc prefers an explicit --kubeconfig over the environment, so the stub must
# too: a diagnostic that passed the hosted kubeconfig while KUBECONFIG named
# the management one would otherwise be answered as a management call.
# Both spellings oc accepts are honoured; the value is resolved once, at the
# top of the stub, so every caller sees the same effective kubeconfig.
effective_kubeconfig(){
  local arg prev="" found="" have=false
  for arg in "$@"; do
    case "${arg}" in
      --kubeconfig=*) found="${arg#--kubeconfig=}"; have=true ;;
    esac
    if [[ "${prev}" == "--kubeconfig" ]]; then
      found="${arg}"
      have=true
    fi
    prev="${arg}"
  done
  # A valueless --kubeconfig at the end of the command line is an error to
  # oc, which then runs nothing at all: reported here as a non-zero return so
  # the caller can refuse the call before dispatching it, rather than letting
  # the environment stand in for the value the collector failed to pass.
  if [[ "${prev}" == "--kubeconfig" ]]; then
    return 1
  fi
  # The last occurrence wins, as the flag parser does.
  if [[ "${have}" == true ]]; then
    printf '%s' "${found}"
  else
    printf '%s' "${KUBECONFIG:-}"
  fi
}
if ! OC_EFFECTIVE_KUBECONFIG="$(effective_kubeconfig "$@")"; then
  echo "stub oc: flag needs an argument: kubeconfig" >&2
  exit 2
fi
# The exact fixture path, not a suffix: a diagnostic that reached for
# ${SHARED_DIR}/missing/hs-mc.kubeconfig names a file real oc cannot load, and
# answering it as a management call would hide that from both HCP scenarios.
is_management(){ [[ "${OC_EFFECTIVE_KUBECONFIG}" == "${OC_SHARED_DIR}/hs-mc.kubeconfig" ]]; }
mgmt_co_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"mgmt-operator"},"status":{"conditions":[{"type":"Available","status":"True"},{"type":"Degraded","status":"False"}]}}]}'
}
mgmt_nodes_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"mgmt-node-1","labels":{"node-role.kubernetes.io/master":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
}

# A wholly ordinary, healthy node: labels, spec and conditions exactly as
# Kubernetes reports them. Nothing about this payload is rejectable, so when
# the scenario's injected jq failure fires, the only thing that can have gone
# wrong is the projection itself.
projection_fail_nodes_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a","labels":{"node-role.kubernetes.io/worker":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
}
# Structurally invalid metadata.labels: not a map[string]string, so not a
# payload Kubernetes can produce. Kept as its own scenario so the step's
# strictness about malformed input is asserted separately from the
# processing-failure branch above.
labels_nonobject_nodes_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a","labels":"invalid"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
}
# A realistic payload: a valid first condition that would carry the verdict on
# its own, plus a second condition whose .type takes the shape named by the
# scenario. $1 names the item, $2 the healthy condition type.
condition_type_variant_json(){
  local name="$1" healthy="$2" second
  case "${OC_SCENARIO}" in
    condition_type_omitted)    second='{"status":"True"}' ;;
    condition_type_null)       second='{"type":null,"status":"True"}' ;;
    condition_type_empty)      second='{"type":"","status":"True"}' ;;
    condition_type_bool)       second='{"type":true,"status":"True"}' ;;
    condition_type_number)     second='{"type":1,"status":"True"}' ;;
    condition_type_object)     second='{"type":{},"status":"True"}' ;;
    condition_type_unfamiliar) second='{"type":"EvaluationConditionsDetected","status":"False"}' ;;
    *)
      echo "stub oc: condition_type_variant_json has no payload for ${OC_SCENARIO}" >&2
      exit 70 ;;
  esac
  printf '{"items":[{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"%s","status":"True"},%s]}}]}\n' \
    "${name}" "${healthy}" "${second}"
}
# ClusterOperators whose .status.versions holds zero, one or two entries named
# "operator". $1 names the item.
co_versions_json(){
  local name="$1" versions
  case "${OC_SCENARIO}" in
    co_versions_zero) versions='[{"name":"other","version":"4.22.0"}]' ;;
    co_versions_one)  versions='[{"name":"operator","version":"4.22.0"}]' ;;
    co_versions_two)  versions='[{"name":"operator","version":"4.22.0"},{"name":"operator","version":"4.22.1"}]' ;;
    co_versions_dup)  versions='[{"name":"operator","version":"4.22.0"},{"name":"operator","version":"4.22.0"}]' ;;
    co_versions_number)
                      versions='[{"name":"operator","version":422}]' ;;
    co_versions_null) versions='[{"name":"operator","version":null}]' ;;
    co_versions_absent)
                      versions='[{"name":"operator"}]' ;;
    co_versions_nonarray)
                      versions='{"operator":{"name":"operator","version":"4.22.0"}}' ;;
    co_versions_nonobject_entry)
                      versions='["operator"]' ;;
    co_versions_missing_name)
                      versions='[{"version":"4.22.0"}]' ;;
    co_versions_bad_sibling)
                      versions='[{"name":"kube-apiserver","version":422},{"name":"operator","version":"4.22.0"}]' ;;
    co_versions_sibling_missing_version)
                      versions='[{"name":"kube-apiserver"},{"name":"operator","version":"4.22.0"}]' ;;
    co_versions_sibling)
                      versions='[{"name":"kube-apiserver","version":"1.33"},{"name":"operator","version":"4.22.0"}]' ;;
    *)
      echo "stub oc: co_versions_json has no payload for ${OC_SCENARIO}" >&2
      exit 70 ;;
  esac
  printf '{"items":[{"metadata":{"name":"%s"},"status":{"versions":%s,"conditions":[{"type":"Available","status":"True"},{"type":"Degraded","status":"False"}]}}]}\n' \
    "${name}" "${versions}"
}
# A ClusterOperator reporting Degraded as the JSON boolean true. No selector
# matches a boolean, so an unvalidated payload would read as healthy.
boolean_status_co_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"authentication"},"status":{"conditions":[{"type":"Available","status":"True"},{"type":"Degraded","status":true}]}}]}'
}
# A node whose spec.unschedulable is the string "false": negating a string
# yields false, so the node would be published as unschedulable.
string_unschedulable_nodes_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a"},"spec":{"unschedulable":"false"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
}
# metadata.labels: false. jq's // operator substitutes its right side for
# false as well as null, so a plain default would treat this as "no labels".
labels_false_nodes_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a","labels":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
}
# Optional fields as Kubernetes actually reports them: one node with roles and
# an explicit spec, one with neither. Both must project and stay verified --
# an absent optional field is not a reason to distrust a payload.
optional_fields_nodes_json(){
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a","labels":{"node-role.kubernetes.io/worker":"","kubernetes.io/os":"linux"}},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"MemoryPressure","status":"False"},{"type":"Ready","status":"True"}]}},{"metadata":{"name":"node-b"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
}

if [[ "${1:-}" == "whoami" ]]; then
  echo "system:admin"
  exit 0
fi

if [[ "${1:-}" == "get" ]]; then
  resource="${2:-}"
  # Only the output option selects the JSON fixture: a bare "json" argument is
  # a resource type to oc, so a step that dropped its -o would otherwise still
  # be served the JSON list it no longer asked for.
  # The *last* output option decides the format, as the flag parser does: a
  # read that appended --output=wide after -o json gets a table from real oc,
  # so the fixture must not keep serving JSON.
  # A standalone -- ends the options, as it does for oc: everything after it
  # is a positional argument, never an output option. A -- that answers a
  # pending option is that option's value, not a terminator, which is why the
  # pending branch is taken first.
  # The positionals are counted in the same pass, so a named read can be told
  # from a list read: "get nodes" is a list, "get nodes node-a" is one object,
  # which has no items array at all. Only the options this fixture already
  # models consume a separate value; anything else starting with - is treated
  # as a flag, which is what the step's own calls use.
  output_format=""
  want_output=false
  options_ended=false
  trailing_positionals=0
  positional_count=0
  skip_value=false
  want_selector=""
  label_selector=""
  field_selector=""
  for a in "$@"; do
    if [[ "${options_ended}" == true ]]; then
      trailing_positionals=$((trailing_positionals + 1))
      continue
    fi
    if [[ "${want_output}" == true ]]; then
      output_format="${a}"
      want_output=false
      continue
    fi
    if [[ "${skip_value}" == true ]]; then
      skip_value=false
      # Each option keeps its own value, so the last -l does not erase a
      # --field-selector given earlier: oc applies both, and a read narrowed
      # by either one is a read this fixture cannot answer.
      case "${want_selector}" in
        label) label_selector="${a}" ;;
        field) field_selector="${a}" ;;
      esac
      want_selector=""
      continue
    fi
    case "${a}" in
      --)            options_ended=true ;;
      -o|--output)   want_output=true ;;
      -o=*)          output_format="${a#-o=}" ;;
      --output=*)    output_format="${a#--output=}" ;;
      -o?*)          output_format="${a#-o}" ;;
      # The two options that narrow a list read, in the spellings oc takes
      # them in. "-l=" alone yields the selector "=", as pflag hands it to
      # the client, which is a selector the fixture cannot honour either.
      # Ordered like the diagnostic scan below so the two can be read
      # side by side.
      -l|--selector) skip_value=true; want_selector=label ;;
      --field-selector)
                     skip_value=true; want_selector=field ;;
      --selector=*)  label_selector="${a#--selector=}" ;;
      --field-selector=*)
                     field_selector="${a#--field-selector=}" ;;
      -l=?*)         label_selector="${a#-l=}" ;;
      -l?*)          label_selector="${a#-l}" ;;
      -n|--namespace|--kubeconfig|--context|--request-timeout)
                     skip_value=true ;;
      -*)            : ;;
      *)             positional_count=$((positional_count + 1)) ;;
    esac
  done
  # The same for the other options this fixture consumes a value for: oc
  # errors out and reads nothing, so the fixture must not serve the healthy
  # listing to a call whose option lost its value.
  if [[ "${skip_value}" == true ]]; then
    echo "stub oc: flag needs an argument" >&2
    exit 2
  fi
  # oc reads what follows -- as more positional arguments, so a listing that
  # pushed its options past the terminator is asking for resources this
  # fixture has no payload for. It is refused with its own status rather than
  # answered from the list fixture, which would otherwise hand a healthy
  # table or a healthy JSON list to a command that never requested one.
  if [[ "${trailing_positionals}" -gt 0 ]]; then
    echo "stub oc: no fixture payload for ${trailing_positionals} argument(s) after --" >&2
    exit 4
  fi
  # A valueless -o or --output at the end of the command line is an error to
  # oc, which then prints nothing and reads nothing: the fixture refuses the
  # call rather than clearing the format and serving the default table, which
  # would let a step whose listing command lost its value still look healthy.
  if [[ "${want_output}" == true ]]; then
    echo "stub oc: flag needs an argument: output" >&2
    exit 2
  fi
  # The formats this fixture answers are the ones the step asks for: the wide
  # tables and the JSON reads, both of which have payloads, and the
  # ClusterVersion jsonpath, which the fixture lets through without a payload
  # of its own. A format outside that contract is refused rather than answered
  # with the default table, so a listing that asked for -o wid cannot look
  # like a healthy one. The status is distinct from the malformed-argument
  # refusals.
  case "${output_format}" in
    ""|wide|json) : ;;
    jsonpath=*)
      # Only the ClusterVersion read uses a jsonpath. Letting any resource
      # through would hand a listing that switched to jsonpath the whole wide
      # table, which is the regression this refusal exists for.
      if [[ "${resource}" != clusterversion ]]; then
        echo "stub oc: no fixture payload for output format ${output_format}" >&2
        exit 3
      fi ;;
    *)
      echo "stub oc: no fixture payload for output format ${output_format}" >&2
      exit 3 ;;
  esac
  # The list fixtures answer a list read. A named read ("get nodes node-a")
  # returns a single object from the real client, which the step rejects for
  # having no items array, so answering it with the healthy list would hide a
  # collector that asked for one object. The subcommand itself is the first
  # positional, so a resource alone is two. The ClusterVersion read names its
  # object on purpose and is not a list fixture, so it is untouched.
  # The singular spellings the dispatch below answers count as the same list
  # fixtures: oc accepts "get node" for "get nodes", and a read narrowed that
  # way must be refused the same way.
  case "${resource}" in
    co|clusteroperators|nodes|node)
      if [[ "${positional_count}" -gt 2 ]]; then
        echo "stub oc: no fixture payload for a named ${resource} read" >&2
        exit 6
      fi
      # A label or field selector filters the list for the real client, which
      # answers with the matching items only -- an empty list when nothing
      # matches.
      # This fixture holds one list and cannot filter it, so a read that
      # asked for a subset is refused rather than handed every item, which
      # would let a collector that narrowed its read still look healthy.
      # An empty selector selects everything, which is what is served.
      if [[ -n "${label_selector}" || -n "${field_selector}" ]]; then
        echo "stub oc: no fixture payload for a selected ${resource} read" >&2
        exit 7
      fi ;;
  esac
  wants_json=false
  [[ "${output_format}" == json ]] && wants_json=true

  case "${resource}" in
    # Keep the spellings here and in the nodes arm below in step with the
    # named-read and selector gate above: a spelling answered here but
    # missing there is served unfiltered.
    co|clusteroperators)
      if [[ "${wants_json}" == "true" ]]; then
        if is_management; then
          case "${OC_SCENARIO}" in
            hcp_management_fails) echo "${API_ERROR}" >&2; exit 1 ;;
            hcp_management_degraded)
              printf '%s\n' '{"items":[{"metadata":{"name":"mgmt-operator"},"status":{"conditions":[{"type":"Available","status":"False"},{"type":"Degraded","status":"True"}]}}]}' ;;
            hcp_management_versions_number)
              printf '%s\n' '{"items":[{"metadata":{"name":"mgmt-operator"},"status":{"versions":[{"name":"operator","version":422}],"conditions":[{"type":"Available","status":"True"},{"type":"Degraded","status":"False"}]}}]}' ;;
            *)                    mgmt_co_json ;;
          esac
          exit 0
        fi
        case "${OC_SCENARIO}" in
          # The payload is the healthy one, byte for byte, and the call still
          # fails: only the command's exit status says so, which is what the
          # step's own status check is for. Every read of this resource
          # behaves that way, so the report and the snapshot both have to
          # mark it unverified.
          co_json_rc1_with_payload)
                          co_json False True
                          echo "${API_ERROR}" >&2
                          exit 1 ;;
          json_fails|json_only_fails|persistent_outage)
                          echo "${API_ERROR}" >&2; exit 1 ;;
          json_two_documents)
                          two_document_json authentication Available ;;
          json_empty_name)
                          empty_name_json Available ;;
          json_precedence_false_first)
                          two_status_json Available False Unknown authentication ;;
          json_precedence_unknown_first)
                          two_status_json Available Unknown False authentication ;;
          json_malformed) echo "not json at all" ;;
          json_empty)     echo '{"items":[]}' ;;
          json_nonobject) echo '{"items":["unexpected-string-item"]}' ;;
          json_status_nonobject|json_conditions_nonarray|json_condition_nonobject|json_metadata_nonobject)
                          malformed_json authentication ;;
          json_no_status|json_empty_conditions|json_condition_unknown|json_condition_contradicts|json_condition_contradicts_true_first)
                          unverified_json authentication Available ;;
          snapshot_query_fails|snapshot_shape_fails|snapshot_empty|snapshot_degraded|snapshot_unavailable|snapshot_notready|report_co_json_only_fails)
                          snapshot_phase_json co ;;
          report_nodes_json_only_fails)
                          co_json False True ;;
          metadata_write_fails|snapshot_count_fails|snapshot_count_lies|snapshot_health_list_fails|report_health_jq_fails|metadata_target_is_dir|nodes_projection_unwritable|co_projection_unwritable|report_notready_jq_fails)
                          co_json False True ;;
          report_unavailable_jq_fails)
                          co_json True True ;;
          report_available_only_fails)
                          co_json False True ;;
          snapshot_projection_fails|nodes_labels_nonobject|nodes_labels_false|spec_unschedulable_string|optional_fields|hcp_healthy|hcp_management_fails|hcp_management_degraded|mgmt_identity_unreadable|hcp_diagnostics|hcp_diagnostics_outage)
                          co_json False True ;;
          condition_status_boolean)
                          boolean_status_co_json ;;
          co_versions_*)  co_versions_json authentication ;;
          snapshot_co_health_list_fails)
                          # Report read healthy, snapshot read degraded: the
                          # snapshot's own Degraded query -- which succeeds
                          # before the Available query fails -- then has a
                          # name to discard, while the report still has
                          # nothing to fail on, so the snapshot downgrade
                          # remains what makes the verdict FAILED.
                          if [[ "$(json_call_seq co)" == "1" ]]; then
                            co_json False True
                          else
                            co_json True True
                          fi ;;
          nodes_capture_unwritable|co_capture_unwritable|report_notready_only)
                          co_json False True ;;
          condition_type_omitted|condition_type_null|condition_type_empty|condition_type_bool|condition_type_number|condition_type_object|condition_type_unfamiliar)
                          condition_type_variant_json authentication Available ;;
          degraded)       co_json True True ;;
          unavailable)    co_json False False ;;
          *)              co_json False True ;;
        esac
        exit 0
      fi
      if [[ "${OC_SCENARIO}" == "wide_fails" || "${OC_SCENARIO}" == "persistent_outage" ]]; then
        echo "${API_ERROR}" >&2
        exit 1
      fi
      echo "NAME             VERSION   AVAILABLE   PROGRESSING   DEGRADED"
      echo "authentication   4.22.0    True        False         False"
      exit 0
      ;;
    nodes|node)
      if [[ "${wants_json}" == "true" ]]; then
        if is_management; then
          case "${OC_SCENARIO}" in
            hcp_management_fails) echo "${API_ERROR}" >&2; exit 1 ;;
            hcp_management_degraded)
              printf '%s\n' '{"items":[{"metadata":{"name":"mgmt-node-1"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}' ;;
            *)                    mgmt_nodes_json ;;
          esac
          exit 0
        fi
        case "${OC_SCENARIO}" in
          # The node twin of co_json_rc1_with_payload: a healthy payload and
          # a non-zero exit, so only the status check can catch it.
          nodes_json_rc1_with_payload)
                          nodes_json True
                          echo "${API_ERROR}" >&2
                          exit 1 ;;
          json_fails|json_only_fails|persistent_outage)
                          echo "${API_ERROR}" >&2; exit 1 ;;
          json_two_documents)
                          two_document_json node-a Ready ;;
          json_empty_name)
                          empty_name_json Ready ;;
          json_precedence_false_first)
                          two_status_json Ready False Unknown node-a ;;
          json_precedence_unknown_first)
                          two_status_json Ready Unknown False node-a ;;
          json_malformed) echo "not json at all" ;;
          json_empty)     echo '{"items":[]}' ;;
          json_nonobject) echo '{"items":["unexpected-string-item"]}' ;;
          json_status_nonobject|json_conditions_nonarray|json_condition_nonobject|json_metadata_nonobject)
                          malformed_json node-a ;;
          json_no_status|json_empty_conditions|json_condition_unknown|json_condition_contradicts|json_condition_contradicts_true_first)
                          unverified_json node-a Ready ;;
          snapshot_query_fails|snapshot_shape_fails|snapshot_empty|snapshot_degraded|snapshot_unavailable|snapshot_notready|report_nodes_json_only_fails)
                          snapshot_phase_json nodes ;;
          report_co_json_only_fails)
                          nodes_json True ;;
          metadata_write_fails|snapshot_count_fails|snapshot_count_lies|snapshot_health_list_fails|report_health_jq_fails|metadata_target_is_dir|nodes_projection_unwritable|co_projection_unwritable)
                          nodes_json True ;;
          report_notready_jq_fails|report_notready_only)
                          # Report read NotReady, snapshot read healthy: the
                          # snapshot must not be able to fail the run, so the
                          # report error alone carries the verdict.
                          if [[ "$(json_call_seq nodes)" == "1" ]]; then
                            nodes_json False
                          else
                            nodes_json True
                          fi ;;
          report_unavailable_jq_fails|report_available_only_fails)
                          nodes_json True ;;
          snapshot_projection_fails)
                          projection_fail_nodes_json ;;
          nodes_labels_nonobject)
                          labels_nonobject_nodes_json ;;
          nodes_labels_false)
                          labels_false_nodes_json ;;
          spec_unschedulable_string)
                          string_unschedulable_nodes_json ;;
          optional_fields)
                          optional_fields_nodes_json ;;
          hcp_healthy|hcp_management_fails|hcp_management_degraded|mgmt_identity_unreadable|condition_status_boolean|hcp_diagnostics|hcp_diagnostics_outage)
                          nodes_json True ;;
          condition_type_omitted|condition_type_null|condition_type_empty|condition_type_bool|condition_type_number|condition_type_object|condition_type_unfamiliar)
                          condition_type_variant_json node-a Ready ;;
          co_versions_*|nodes_capture_unwritable|co_capture_unwritable|snapshot_co_health_list_fails)
                          nodes_json True ;;
          notready)       nodes_json False ;;
          *)              nodes_json True ;;
        esac
        exit 0
      fi
      # When the API is unreachable the plain-text listing fails too. Reproducing
      # that is what makes the pre-fix "Total nodes: 0" symptom observable.
      # json_only_fails deliberately keeps the wide listing healthy, so that
      # scenario isolates a JSON transport failure from an unreachable API.
      if [[ "${OC_SCENARIO}" == "json_fails" || "${OC_SCENARIO}" == "wide_fails" \
         || "${OC_SCENARIO}" == "persistent_outage" ]]; then
        echo "${API_ERROR}" >&2
        exit 1
      fi
      echo "NAME     STATUS   ROLES    AGE   VERSION"
      echo "node-a   Ready    worker   1d    v1.31.0"
      echo "node-b   Ready    worker   1d    v1.31.0"
      exit 0
      ;;
  esac
fi

# Every other call -- log collection, describe, clusterversion, events. In a
# persistent outage these fail the same way the listings do, and their stderr
# is what used to be folded into the published diagnostics.
# Hosted control-plane diagnostics. The first cvo-logs alternative always
# fails so the two-alternative chain is exercised; in the outage variant the
# second alternative and the three listings fail too.
if [[ "${OC_SCENARIO}" == hcp_diagnostics* ]]; then
  # The subcommand and its resource, read as whole arguments: a substring
  # match would accept "get hostedclusterz" as the hostedcluster listing and
  # hand a collector typo the answer it expected. Only the options this step
  # actually passes are consumed, so an unexpected one stays visible.
  oc_subcommand=""
  oc_resource=""
  oc_selector=""
  oc_skip=0
  oc_want_selector=false
  oc_want_tail=false
  oc_options_ended=false
  for arg in "$@"; do
    if [[ "${oc_skip}" -gt 0 ]]; then
      oc_skip=$((oc_skip - 1))
      # The selector is kept, not just skipped: the cvo fallback is keyed on
      # its exact value, so a suffixed typo must not be read as the real one.
      if [[ "${oc_want_selector}" == true ]]; then
        oc_selector="${arg}"
        oc_want_selector=false
      fi
      oc_want_tail=false
      continue
    fi
    # A standalone -- ends the options for oc too: what follows is
    # positional, so a selector written after it is not this call's selector
    # and the pod names it leaves behind are what oc would reject. A --
    # answering a pending option is that option's value, which is why the
    # skip branch above runs first.
    if [[ "${oc_options_ended}" == true ]]; then
      if [[ -z "${oc_subcommand}" ]]; then
        oc_subcommand="${arg}"
      elif [[ -z "${oc_resource}" ]]; then
        oc_resource="${arg}"
      fi
      continue
    fi
    case "${arg}" in
      --)            oc_options_ended=true ;;
      -l|--selector) oc_skip=1; oc_want_selector=true ;;
      # The inline spellings of the same option, parsed here so the selector
      # is known before the lookup is recorded or answered: oc takes the last
      # selector, so an appended --selector=app=other is not the cvo lookup.
      --selector=*)  oc_selector="${arg#--selector=}" ;;
      -l=?*)         oc_selector="${arg#-l=}" ;;
      -l?*)          oc_selector="${arg#-l}" ;;
      -n|--namespace|--kubeconfig|--context) oc_skip=1 ;;
      # --tail takes a value too, in either spelling. Without this the
      # separate form would leave its number standing as the pod name, and a
      # fallback that oc reads identically would be refused as a named read.
      --tail)        oc_skip=1; oc_want_tail=true ;;
      -*) : ;;
      *)
        if [[ -z "${oc_subcommand}" ]]; then
          oc_subcommand="${arg}"
        elif [[ -z "${oc_resource}" ]]; then
          oc_resource="${arg}"
        fi ;;
    esac
  done
  # A valueless -l or --selector at the end of the command line is an error
  # to oc, the same as a valueless namespace or output option: it must not
  # leave the earlier selector standing and be answered as the cvo fallback.
  if [[ "${oc_want_selector}" == true ]]; then
    echo "stub oc: flag needs an argument: selector" >&2
    exit 2
  fi
  # The same for a --tail with no value at all: oc errors out and collects
  # nothing, so the fixture must not answer such a call as the fallback just
  # because no pod name was left behind. Only the missing value is modelled
  # here; the fixture does not judge the number itself, which is outside what
  # this parser decides.
  if [[ "${oc_want_tail}" == true ]]; then
    echo "stub oc: flag needs an argument: tail" >&2
    exit 2
  fi
  is_get(){ [[ "${oc_subcommand}" == get && "${oc_resource}" == "$1" ]]; }
  # The two cvo alternatives, keyed on whole arguments: the deployment
  # positional and the exact selector value, so neither
  # deployment/cluster-version-operatorz nor app=cluster-version-operatorz
  # is answered as the real one.
  is_cvo_deployment(){
    [[ "${oc_subcommand}" == logs && "${oc_resource}" == "deployment/cluster-version-operator" ]]
  }
  # The fallback reads logs by selector and nothing else: oc rejects a pod
  # name given alongside a selector, so a fallback that added one would
  # collect nothing. Both the recording and the answer are keyed on this, so
  # such a call is neither recorded as the alternative nor given its marker.
  is_cvo_selector(){
    [[ "${oc_subcommand}" == logs && -z "${oc_resource}" \
       && "${oc_selector}" == "app=cluster-version-operator" ]]
  }

  # The effective namespace and the effective all-namespaces value, last
  # occurrence wins, across the spellings oc takes them in: -n value,
  # -nvalue, -n=value, --namespace value, --namespace=value, and -A, -Avalue,
  # --all-namespaces, --all-namespaces=value. A diagnostic that appended
  # --namespace=default after a correct -n would otherwise still look scoped
  # to the hosted control plane.
  # diag_hcp_namespace_given records that some option named a hosted
  # control-plane namespace: that is what makes a pod listing a management
  # diagnostic at all, while the effective value decides whether it is
  # answered or refused.
  diag_namespace=""
  diag_hcp_namespace_given=false
  diag_all_namespaces=false
  diag_want_namespace=false
  diag_options_ended=false
  diag_skip=0
  diag_set_namespace(){
    diag_namespace="$1"
    [[ "$1" == ocm-* ]] && diag_hcp_namespace_given=true
    return 0
  }
  diag_set_all_namespaces(){
    # The true/false sets Go's ParseBool accepts; anything else is an error to
    # oc, so the fixture refuses it rather than guessing.
    case "$1" in
      true|True|TRUE|1|t|T)     diag_all_namespaces=true ;;
      false|False|FALSE|0|f|F)  diag_all_namespaces=false ;;
      *)
        echo "stub oc: unparseable boolean for the all-namespaces flag" >&2
        exit 2 ;;
    esac
  }
  for arg in "$@"; do
    if [[ "${diag_want_namespace}" == true ]]; then
      diag_set_namespace "${arg}"
      diag_want_namespace=false
      continue
    fi
    # The other options that take a value are consumed here too, so this
    # scan and the one above agree on which -- is a terminator and which is
    # an option's value. Without that agreement a -- answering -l would end
    # the options here while remaining a value there, and an
    # --all-namespaces written after it would stop being seen.
    if [[ "${diag_skip}" -gt 0 ]]; then
      diag_skip=$((diag_skip - 1))
      continue
    fi
    # The same terminator rule as the scan above: after it nothing is an
    # option, so a namespace or an all-namespaces flag written there is not
    # one.
    if [[ "${diag_options_ended}" == true ]]; then
      continue
    fi
    case "${arg}" in
      --)                 diag_options_ended=true ;;
      -l|--selector|--tail|--kubeconfig|--context)
                          diag_skip=1 ;;
      --namespace)        diag_want_namespace=true ;;
      --namespace=*)      diag_set_namespace "${arg#--namespace=}" ;;
      --all-namespaces)   diag_all_namespaces=true ;;
      --all-namespaces=*) diag_set_all_namespaces "${arg#--all-namespaces=}" ;;
      --*)                : ;;
      -?*)
        # Shorthands cluster: oc reads -Ao wide as -A -o wide and -nfoo as
        # -n foo, so a diagnostic written that way must be seen too. Only the
        # two shorthands this fixture models are decoded; at any other letter
        # the rest of the cluster is left alone, because it may be that
        # option's attached value, and -ojson is not -o -j -s -o -n.
        diag_shorthands="${arg#-}"
        while [[ -n "${diag_shorthands}" ]]; do
          case "${diag_shorthands}" in
            n)    diag_want_namespace=true;  diag_shorthands="" ;;
            n=*)  diag_set_namespace "${diag_shorthands#n=}"; diag_shorthands="" ;;
            n*)   diag_set_namespace "${diag_shorthands#n}";  diag_shorthands="" ;;
            A=*)  diag_set_all_namespaces "${diag_shorthands#A=}"; diag_shorthands="" ;;
            A*)   diag_all_namespaces=true; diag_shorthands="${diag_shorthands#A}" ;;
            *)    diag_shorthands="" ;;
          esac
        done ;;
    esac
  done
  # A valueless -n or --namespace at the end of the command line is an error
  # to oc, which then collects nothing at all: the fixture refuses it the same
  # way it refuses an unparseable boolean, rather than reading it as a
  # namespace of its own or letting an earlier one stand.
  if [[ "${diag_want_namespace}" == true ]]; then
    echo "stub oc: flag needs an argument: namespace" >&2
    exit 2
  fi

  # Every HCP diagnostic is collected after the step switches to the
  # management kubeconfig. A matched diagnostic call made with any other
  # kubeconfig is recorded and answered with a distinct status, so an outage
  # scenario cannot read a kubeconfig mismatch as the expected API error.
  diag_matched=false
  case "$*" in
    *"deployment/cluster-version-operator"*|*"app=cluster-version-operator"*)
      diag_matched=true ;;
  esac
  if is_get hostedcluster || is_get hostedcontrolplane; then
    diag_matched=true
  fi
  # Pod listings only in the hosted control-plane namespaces: the hosted
  # cluster's own pod listings are not management diagnostics. Any ocm-
  # namespace among the options makes it one, so a listing whose namespace
  # was overridden is still matched here and refused below on its effective
  # namespace instead of escaping the guard entirely.
  # A pod listing that dropped its namespace for -A is exactly the regression
  # the refusal below exists for, so it must be matched even without -n.
  if is_get pods && [[ "${diag_hcp_namespace_given}" == true || "${diag_all_namespaces}" == true ]]; then
    diag_matched=true
  fi
  if [[ "${diag_matched}" == true ]]; then
    mkdir -p "${OC_STATE_DIR}"
    if ! is_management; then
      echo "$*" >> "${OC_STATE_DIR}/diagnostic-wrong-kubeconfig"
      echo "stub oc: HCP diagnostic without the management kubeconfig" >&2
      exit 66
    fi
    # Namespaces, derived from the same fixture inputs the step reads: the
    # HostedCluster lives in ocm-<env>-<cluster id>, while the hosted
    # control plane, its pods and both cvo log alternatives live in that
    # namespace plus "-dp", mirroring the domain_prefix the ocm stub above
    # reports for this cluster. A call in the
    # other namespace is recorded and answered with its own status,
    # distinct from the kubeconfig mismatch and from the outage error.
    # oc ignores -n when it lists every namespace, so a diagnostic that asks
    # for all of them is not scoped to the hosted control plane at all. It is
    # recorded and refused with its own status, distinct from the kubeconfig
    # mismatch (66), the wrong namespace (67) and the outage error (1).
    if [[ "${diag_all_namespaces}" == true ]]; then
      echo "$*" >> "${OC_STATE_DIR}/diagnostic-all-namespaces"
      echo "stub oc: HCP diagnostic asked for all namespaces" >&2
      exit 68
    fi
    diag_hc_namespace="ocm-${OCM_LOGIN_ENV:-staging}-$(cat "${OC_SHARED_DIR}/cluster-id" 2>/dev/null)"
    if is_get hostedcluster; then
      diag_want="${diag_hc_namespace}"
    else
      diag_want="${diag_hc_namespace}-dp"
    fi
    if [[ "${diag_namespace}" != "${diag_want}" ]]; then
      echo "$* (namespace ${diag_namespace:-<none>}, expected ${diag_want})" \
        >> "${OC_STATE_DIR}/diagnostic-wrong-namespace"
      echo "stub oc: HCP diagnostic in the wrong namespace" >&2
      exit 67
    fi
    # The order of the two cvo-logs alternatives is part of the contract:
    # the deployment lookup runs first and the label selector is only its
    # fallback, and the fallback output alone cannot show that.
    # Only a logs call counts as a cvo lookup: a fallback that reached for
    # the same selector with another subcommand must not be recorded as the
    # label-selector alternative.
    if is_cvo_deployment; then
      echo deployment >> "${OC_STATE_DIR}/cvo-lookups"
    elif is_cvo_selector; then
      echo selector >> "${OC_STATE_DIR}/cvo-lookups"
    fi
  fi
  # The cvo answers belong to logs calls only, for the same reason the
  # recording above does: another subcommand reaching for the same selector
  # must not be handed a log marker.
  if is_cvo_deployment; then
    echo "${API_ERROR}" >&2
    exit 1
  fi
  if is_cvo_selector; then
    if [[ "${OC_SCENARIO}" == "hcp_diagnostics_outage" ]]; then
      echo "${API_ERROR}" >&2
      exit 1
    fi
    echo "CVO-LOG-FROM-LABEL-SELECTOR"
    exit 0
  fi
  # One marker and one error per resource, keyed on the exact resource
  # argument: a collector that listed the wrong resource would otherwise
  # write an artifact that still looks right.
  if is_get hostedcluster; then
    if [[ "${OC_SCENARIO}" == "hcp_diagnostics_outage" ]]; then
      echo "${API_ERROR} while listing hostedcluster" >&2
      exit 1
    fi
    echo "HCP-HOSTEDCLUSTER-OUTPUT"
    exit 0
  fi
  if is_get hostedcontrolplane; then
    if [[ "${OC_SCENARIO}" == "hcp_diagnostics_outage" ]]; then
      echo "${API_ERROR} while listing hostedcontrolplane" >&2
      exit 1
    fi
    echo "HCP-HOSTEDCONTROLPLANE-OUTPUT"
    exit 0
  fi
  if is_get pods && [[ "${diag_namespace}" == ocm-* ]]; then
    if [[ "${OC_SCENARIO}" == "hcp_diagnostics_outage" ]]; then
      echo "${API_ERROR} while listing HCP pods" >&2
      exit 1
    fi
    echo "HCP-PODS-OUTPUT"
    exit 0
  fi
fi
# The degraded operator's own describe output, in the scenario whose report
# names it. Keyed on the exact operator, so an artifact collected by
# describing another operator cannot satisfy the content assertion, and
# written to stdout only: the diagnostic collector's stderr handling and its
# status are unchanged.
if [[ "${OC_SCENARIO}" == "report_unavailable_jq_fails" && "${1:-}" == "describe" ]]; then
  if [[ "${2:-}" == "co" && "${3:-}" == "authentication" ]]; then
    echo "CO-DESCRIBE-AUTHENTICATION"
  fi
  exit 0
fi
if [[ "${OC_SCENARIO}" == "persistent_outage" ]]; then
  echo "${API_ERROR}" >&2
  exit 1
fi
exit 0
OC

  # Pass-through jq that fails exactly one invocation: the node snapshot
  # projection, identified by its program text. The projection-failure branch
  # is therefore covered by an injected processing failure rather than by a
  # payload the step refuses, so that test no longer depends on the step being
  # strict about malformed input.
  local jq_bin real_jq
  # type -P, not command -v: with an exported shell function named jq,
  # command -v answers "jq", the generated stub would exec itself through the
  # sandbox PATH and the suite would hang. %q quoting is kept so a path with
  # spaces stays one word.
  jq_bin="$(type -P jq || true)"
  if [[ -z "${jq_bin}" ]]; then
    echo "FATAL: no external jq executable found for the generated stub" >&2
    exit 1
  fi
  if [[ "${jq_bin}" != /* ]]; then
    if ! jq_bin="$(absolute_file "${jq_bin}")"; then
      echo "FATAL: could not resolve the jq path for the generated stub" >&2
      exit 1
    fi
  fi
  if [[ ! -x "${jq_bin}" ]]; then
    echo "FATAL: resolved jq is not executable: ${jq_bin}" >&2
    exit 1
  fi
  real_jq="$(printf '%q' "${jq_bin}")"
  { echo '#!/bin/bash'
    printf 'OC_STATE_DIR=%q\n' "${dir}/state"
    # The classic and hosted snapshot directory, which is where the only
    # scenario that consults it writes. A management-role variant would need
    # its own path.
    printf 'OC_ARTIFACT_DIR=%q\n' "${dir}/artifacts"; } > "${dir}/bin/jq"
  cat >> "${dir}/bin/jq" <<JQ
# Phase matching uses the payload's basename. A TMPDIR whose own name
# contains "-snapshot-" would otherwise make every report payload look like a
# snapshot one: report injections would never fire and snapshot injections
# would land on report queries.
# Computed on demand: a scenario that never consults a filename would
# otherwise fork basename once per payload path for nothing.
has_basename(){
  local want="\$1" arg
  for arg in \${JQ_FILES[@]+"\${JQ_FILES[@]}"}; do
    case "\$(basename -- "\${arg}")" in
      \${want}) return 0 ;;
    esac
  done
  return 1
}
JQ_ARGS=("\$@")
# jq takes its options first, then the program, then the payload paths. The
# program and the paths are matched separately: a TMPDIR whose own name
# contains a program's selector text would otherwise make every payload look
# like the query under test. Only the options this step passes are consumed
# (--arg/--argjson/--slurpfile take a name and a value), so an unexpected one
# is visible instead of silently shifting the program.
JQ_PROGRAM=""
JQ_FILES=()
jq_split_args(){
  local arg skip=0 have_program=false
  for arg in \${JQ_ARGS[@]+"\${JQ_ARGS[@]}"}; do
    if [[ "\${skip}" -gt 0 ]]; then
      skip=\$((skip - 1))
      continue
    fi
    case "\${arg}" in
      --arg|--argjson|--slurpfile|--rawfile) skip=2 ;;
      -*) : ;;
      *)
        if [[ "\${have_program}" == false ]]; then
          JQ_PROGRAM="\${arg}"
          have_program=true
        else
          JQ_FILES+=("\${arg}")
        fi ;;
    esac
  done
}
jq_split_args
program_matches(){ [[ "\${JQ_PROGRAM}" == *"\$1"* ]]; }

# fail_on_program matches the jq program text; fail_on_file matches the
# payload's basename. They are separate because a filename pattern must never
# be tested against a program and vice versa.
fail_on_program=''
fail_on_file=''
case "\${OC_SCENARIO:-}" in
  snapshot_projection_fails) fail_on_program='ready: all_true_status' ;;
  metadata_write_fails)      fail_on_program='clusteroperator_count:' ;;
  snapshot_count_fails|snapshot_count_lies|snapshot_health_list_fails)
                             fail_on_file='*-snapshot-nodes.json' ;;
  report_health_jq_fails)    fail_on_file='nodes.json' ;;
  report_unavailable_jq_fails|report_available_only_fails)
                             fail_on_file='clusteroperators.json' ;;
  report_notready_jq_fails)  fail_on_file='nodes.json' ;;
  snapshot_co_health_list_fails)
                             fail_on_file='*-snapshot-co.json' ;;
esac
if [[ -n "\${fail_on_program}" || -n "\${fail_on_file}" ]]; then
  matched=false
  if [[ -n "\${fail_on_program}" ]]; then
    program_matches "\${fail_on_program}" && matched=true
  fi
  if [[ -n "\${fail_on_file}" ]]; then
    has_basename "\${fail_on_file}" && matched=true
  fi
  # snapshot_count_fails targets the count of the snapshot node payload only.
  # get_snapshot_json runs the identical program against the same file first,
  # so failing that one would shadow the hazard under test; fail the second
  # occurrence instead, which is write_install_snapshot's own node_count read.
  # Only the report phase's own health query, never its shape check and never
  # the snapshot copy of the payload, so the scenario isolates a report-side
  # processing failure from a malformed payload.
  # Only the report phase's Available health list, so the Degraded query that
  # ran before it still succeeds: for report_unavailable_jq_fails its degraded
  # evidence must survive, and for report_available_only_fails it finds
  # nothing, so the failed Available query alone decides the verdict.
  # Only the report phase's Ready health list, so the count query that ran
  # before it still succeeds and its result must survive.
  if [[ "\${OC_SCENARIO}" == "report_notready_jq_fails" ]]; then
    matched=false
    program=false
    file=false
    program_matches 'select(.type == \$condition)' && program=true
    has_basename 'nodes.json' && file=true
    [[ "\${program}" == true && "\${file}" == true ]] && matched=true
  fi
  if [[ "\${OC_SCENARIO}" == "report_unavailable_jq_fails" \
     || "\${OC_SCENARIO}" == "report_available_only_fails" ]]; then
    matched=false
    program=false
    file=false
    program_matches 'select(.type == \$condition)' && program=true
    has_basename 'clusteroperators.json' && file=true
    [[ "\${program}" == true && "\${file}" == true ]] && matched=true
  fi
  if [[ "\${OC_SCENARIO}" == "report_health_jq_fails" ]]; then
    matched=false
    program=false
    file=false
    [[ "\${JQ_PROGRAM}" == '.items | length' ]] && program=true
    has_basename 'nodes.json' && file=true
    [[ "\${program}" == true && "\${file}" == true ]] && matched=true
  fi
  # The health-list program, matched by its distinctive condition selector,
  # runs after the projection has already been written.
  # Nodes only: the Available and Ready queries share their selector text, so
  # matching every snapshot payload would fail the operator list too and the
  # scenario could not show that a node-only error leaves the operators alone.
  if [[ "\${OC_SCENARIO}" == "snapshot_health_list_fails" ]]; then
    matched=false
    program=false
    file=false
    program_matches 'select(.type == \$condition)' && program=true
    has_basename '*-snapshot-nodes.json' && file=true
    [[ "\${program}" == true && "\${file}" == true ]] && matched=true
  fi
  # The operator twin of snapshot_health_list_fails, so narrowing that one to
  # nodes does not leave the operator branch uncovered.
  if [[ "\${OC_SCENARIO}" == "snapshot_co_health_list_fails" ]]; then
    matched=false
    program=false
    file=false
    program_matches 'select(.type == \$condition)' && program=true
    has_basename '*-snapshot-co.json' && file=true
    [[ "\${program}" == true && "\${file}" == true ]] && matched=true
  fi
  # snapshot_count_lies targets the FIRST count -- the one inside
  # get_snapshot_json -- because a later checked assignment would otherwise
  # mask the very gap this scenario exists to prove.
  if [[ "\${OC_SCENARIO}" == "snapshot_count_lies" ]]; then
    matched=false
    program=false
    file=false
    [[ "\${JQ_PROGRAM}" == '.items | length' ]] && program=true
    has_basename '*-snapshot-nodes.json' && file=true
    if [[ "\${program}" == true && "\${file}" == true ]]; then
      seq_file="\${OC_STATE_DIR}/snapshot-node-count-calls"
      n=0
      [[ -f "\${seq_file}" ]] && n="\$(cat "\${seq_file}")"
      n=\$((n + 1))
      echo "\${n}" > "\${seq_file}"
      # Which call did what, so a scenario cannot swap the failing one and
      # keep the same verdict: this one prints a count and fails on call 1.
      if [[ "\${n}" -eq 1 ]]; then
        matched=true
        echo "\${n} emitted-then-failed" >> "\${OC_STATE_DIR}/snapshot-count-sequence"
      else
        echo "\${n} passed-through" >> "\${OC_STATE_DIR}/snapshot-count-sequence"
      fi
    fi
  fi
  if [[ "\${OC_SCENARIO}" == "snapshot_count_fails" ]]; then
    matched=false
    program=false
    file=false
    [[ "\${JQ_PROGRAM}" == '.items | length' ]] && program=true
    has_basename '*-snapshot-nodes.json' && file=true
    if [[ "\${program}" == true && "\${file}" == true ]]; then
      # Per sandbox, not per role: this scenario is classic-topology only, so
      # there is exactly one role taking snapshots.
      seq_file="\${OC_STATE_DIR}/snapshot-node-count-calls"
      n=0
      [[ -f "\${seq_file}" ]] && n="\$(cat "\${seq_file}")"
      n=\$((n + 1))
      echo "\${n}" > "\${seq_file}"
      # Here the first call succeeds and only the second fails, the mirror of
      # snapshot_count_lies; the recorded sequence pins which is which.
      if [[ "\${n}" -ge 2 ]]; then
        matched=true
        echo "\${n} failed" >> "\${OC_STATE_DIR}/snapshot-count-sequence"
      else
        echo "\${n} passed-through" >> "\${OC_STATE_DIR}/snapshot-count-sequence"
      fi
    fi
  fi
  if [[ "\${matched}" == true ]]; then
    # snapshot_count_lies prints a plausible count and *then* fails, which a
    # numeric test on an unchecked substitution would happily accept.
    if [[ "\${OC_SCENARIO}" == "snapshot_count_lies" ]]; then
      echo 2
    fi
    # The report's Ready query names a node and *then* fails, so the step has
    # to discard that unverified name: a failure with no output would let a
    # missing discard pass unnoticed.
    if [[ "\${OC_SCENARIO}" == "report_notready_jq_fails" ]]; then
      echo node-b
    fi
    # The snapshot's own Ready health list does the same, so the step has to
    # discard the unverified name it printed: a failure with no output would
    # let a missing notready_raw clear pass unnoticed.
    if [[ "\${OC_SCENARIO}" == "snapshot_health_list_fails" ]]; then
      echo node-b
    fi
    # The operator twin does the same with an operator name, so the clear on
    # that branch is observable too.
    if [[ "\${OC_SCENARIO}" == "snapshot_co_health_list_fails" ]]; then
      echo authentication
    fi
    # Which invocation the injection actually hit, recorded from the match
    # itself: the scenario's other assertions hold for any snapshot-side
    # failure, so without this a failure injected at another stage -- an
    # input validation query, say, or the node count -- would look the same.
    # The payload half is the discriminator, because a failure injected on
    # another payload or at another stage records something else. The program
    # half guards the keying: re-pointing the injection at a different
    # program makes this record "other" rather than quietly agreeing.
    if [[ "\${OC_SCENARIO}" == "snapshot_projection_fails" ]]; then
      mkdir -p "\${OC_STATE_DIR}"
      {
        printf 'program='
        if program_matches 'ready: all_true_status'; then
          printf 'node-projection'
        else
          printf 'other'
        fi
        printf ' payload='
        if has_basename '*-snapshot-nodes.json'; then
          printf 'snapshot-nodes'
        else
          printf 'other'
        fi
        printf '\n'
      } >> "\${OC_STATE_DIR}/injected-jq-failure"
    fi
    # The metadata write fails midway, not before it starts: a partial
    # document goes out first, so a step that pointed jq at the final
    # metadata.json would leave that truncated object there. Whether the
    # seeded verdict is still intact is recorded here, while the write is in
    # flight, because the step's own cleanup removes the evidence afterwards.
    if [[ "\${OC_SCENARIO}" == "metadata_write_fails" ]]; then
      printf '%s' '{"cluster_role":"classic","overall_status":"PAS'
      mkdir -p "\${OC_STATE_DIR}"
      # Read with the shell rather than a new external tool, so this check
      # cannot turn an image without it into a red required job. The content
      # must still match the copy taken at seeding time and still parse as one
      # PASSED document, so an unreadable or truncated file fails closed.
      if [[ -f "\${OC_ARTIFACT_DIR}/metadata.json" \\
            && -f "\${OC_STATE_DIR}/metadata-seed.json" ]] \\
         && [[ "\$(<"\${OC_ARTIFACT_DIR}/metadata.json")" \\
               == "\$(<"\${OC_STATE_DIR}/metadata-seed.json")" ]] \\
         && ${real_jq} -es '(length == 1) and (.[0].overall_status == "PASSED")' \\
              "\${OC_ARTIFACT_DIR}/metadata.json" >/dev/null 2>&1; then
        echo intact > "\${OC_STATE_DIR}/metadata-during-write"
      else
        echo clobbered > "\${OC_STATE_DIR}/metadata-during-write"
      fi
    fi
    echo "jq: simulated processing failure" >&2
    exit 5
  fi
fi
exec ${real_jq} "\$@"
JQ

  if [[ "${name}" == mgmt_identity_unreadable* ]]; then
    local cat_bin
    cat_bin="$(type -P cat || true)"
    if [[ -z "${cat_bin}" ]]; then
      echo "FATAL: no external cat executable found for the generated stub" >&2
      exit 1
    fi
    if [[ "${cat_bin}" != /* ]]; then
      if ! cat_bin="$(absolute_file "${cat_bin}")"; then
        echo "FATAL: could not resolve the cat path for the generated stub" >&2
        exit 1
      fi
    fi
    if [[ ! -x "${cat_bin}" ]]; then
      echo "FATAL: resolved cat is not executable: ${cat_bin}" >&2
      exit 1
    fi
    # A cat that fails for one identity file. Simulated through the stub
    # rather than a permission bit, because root would bypass the bit.
    { echo '#!/bin/bash'
      echo 'for arg in "$@"; do'
      echo '  if [[ "${arg}" == */mc-cluster-id ]]; then'
      echo '    echo "cat: ${arg}: simulated read failure" >&2'
      echo '    exit 1'
      echo '  fi'
      echo 'done'
      printf 'exec %q "$@"\n' "${cat_bin}"
    } > "${dir}/bin/cat"
    chmod +x "${dir}/bin/cat"
    bash -n "${dir}/bin/cat"
  fi

  # Explicitly checked: a readable but non-executable stub still passes the
  # `bash -n` check below, and Bash would then fall through to the real ocm or
  # oc on the inherited PATH, quietly breaking the offline guarantee.
  if ! chmod +x "${dir}/bin/ocm" "${dir}/bin/oc" "${dir}/bin/jq"; then
    echo "FATAL: could not make the generated stubs executable in ${dir}" >&2
    exit 1
  fi
  for stub in ocm oc jq; do
    if [[ ! -x "${dir}/bin/${stub}" ]]; then
      echo "FATAL: generated ${stub} stub is not executable" >&2
      exit 1
    fi
  done

  # The stubs are generated inside heredocs, so the suite's own `bash -n` does
  # not cover them. A malformed stub silently changes what every scenario
  # exercises, so check them here instead of debugging the fallout later.
  local stub
  for stub in oc ocm jq; do
    if ! bash -n "${dir}/bin/${stub}"; then
      echo "FATAL: generated ${stub} stub is not valid bash" >&2
      exit 1
    fi
  done
  echo "${dir}"
}

# A valid snapshot from an earlier, successful run. The failure paths must
# remove it: leaving a stale PASSED artifact beside a failed run would let a
# consumer read the previous verdict as this run's.
seed_passed_metadata(){
  local dir="$1"
  mkdir -p "${dir}" || return 1
  printf '%s\n' '{"cluster_role":"classic","overall_status":"PASSED","clusteroperators_verified":true,"nodes_verified":true,"node_count":2}' \
    > "${dir}/metadata.json" || return 1
  jq -e '(.overall_status == "PASSED") and (.cluster_role | type) == "string"' "${dir}/metadata.json" >/dev/null
}
# run_step <scenario> -> sets RC, REPORT, STDERR, ARTIFACTS
# run_step <scenario> [hosted_cp]
# hosted_cp=true drives the HCP path: the step then resolves a management
# kubeconfig from SHARED_DIR and takes a second, management-role snapshot.
run_step(){
  local scenario="$1" hosted_cp="${2:-false}" dir
  dir="$(make_sandbox "${scenario}")" || exit 1
  if [[ "${scenario}" == "metadata_write_fails" \
     || "${scenario}" == "nodes_projection_unwritable" \
     || "${scenario}" == "co_projection_unwritable" \
     || "${scenario}" == "mgmt_identity_unreadable" ]]; then
    # Seeded before the step runs, and verified valid, so the absence checks
    # afterwards prove a removal rather than a file that never existed.
    seed_passed_metadata "${dir}/artifacts" || exit 1
    # A copy the stubs can compare against, so a check made while the step
    # runs does not have to trust a label. The state directory is part of
    # every sandbox.
    cp -- "${dir}/artifacts/metadata.json" "${dir}/state/metadata-seed.json" || exit 1
  fi
  if [[ "${scenario}" == "metadata_target_is_dir" ]]; then
    mkdir -p "${dir}/artifacts/metadata.json"
  fi
  if [[ "${scenario}" == "nodes_capture_unwritable" ]]; then
    # The wide-listing redirection fails because its target is a directory,
    # and so does the placeholder the failure handler writes.
    mkdir -p "${dir}/artifacts/diagnostics/nodes.txt"
  fi
  if [[ "${scenario}" == "co_capture_unwritable" ]]; then
    mkdir -p "${dir}/artifacts/diagnostics/clusteroperators.txt"
  fi
  if [[ "${scenario}" == "co_projection_unwritable" ]]; then
    mkdir -p "${dir}/artifacts/clusteroperators.json"
  fi
  if [[ "${scenario}" == "nodes_projection_unwritable" ]]; then
    # A directory at the projection path: the projection write and the
    # fallback that is supposed to replace it both fail.
    mkdir -p "${dir}/artifacts/nodes.json"
  fi
  if [[ "${hosted_cp}" == "true" ]]; then
    echo "fake-management-kubeconfig" > "${dir}/shared/hs-mc.kubeconfig"
    echo "mgmt-cluster" > "${dir}/shared/mc-cluster-name"
    echo "mgmt-cluster-id" > "${dir}/shared/mc-cluster-id"
  fi
  # Resolved under the exact environment the step will get: a stub that is
  # executable and syntactically valid is still useless if PATH cannot reach
  # it, and the step would then invoke a real oc/ocm/jq.
  local tool resolved
  for tool in oc ocm jq; do
    resolved="$(env -i PATH="${dir}/bin:${PATH}" HOME="${dir}" \
      bash -c "command -v ${tool} || true")"
    if [[ "${resolved}" != "${dir}/bin/${tool}" ]]; then
      echo "FATAL: ${tool} resolves to [${resolved}], not the generated stub ${dir}/bin/${tool}" >&2
      exit 1
    fi
  done

  set +o errexit
  env -i \
    PATH="${dir}/bin:${PATH}" \
    HOME="${dir}" \
    OC_SCENARIO="${scenario}" \
    CLUSTER_PROFILE_DIR="${dir}/profile" \
    SHARED_DIR="${dir}/shared" \
    ARTIFACT_DIR="${dir}/artifacts" \
    TMPDIR="${dir}/tmp" \
    OCM_LOGIN_ENV="staging" \
    REGION="us-east-1" \
    HOSTED_CP="${hosted_cp}" \
    CLUSTER_TOPOLOGY="" \
    CHANNEL_GROUP="stable" \
    OPENSHIFT_VERSION="4.22" \
    bash "${STEP}" > "${dir}/stdout.log" 2> "${dir}/stderr.log"
  RC=$?
  set -o errexit
  REPORT="${dir}/artifacts/diagnostics/gap-analysis-cluster-install-report.txt"
  SCRATCH_TMPDIR="${dir}/tmp"
  STDERR="${dir}/stderr.log"
  ARTIFACTS="${dir}/artifacts"
  STATE="${dir}/state"
}

# Assertions are plain commands so their exit status is the result; a missing
# report makes report_has fail and report_lacks fail too, so a scenario can never
# pass vacuously because the step died early.
report_exists(){ [[ -f "${REPORT}" ]]; }
report_has(){ report_exists && grep -qF "$1" "${REPORT}"; }
# Only grep's "no match" status is an absence. grep answers 2 when it cannot
# read the file, and a bare `!` would turn that into a passing assertion, the
# same way artifacts_lack already guards against.
report_lacks(){
  local status=0
  report_exists || return 1
  grep -qF "$1" "${REPORT}" || status=$?
  [[ "${status}" -eq 1 ]]
}
# Whole-line match, for assertions about an exact value: "Total nodes: 2" as a
# substring also accepts "Total nodes: 20". Substring matching stays for
# explanatory text, where a prefix is what is meant.
report_has_line(){ report_exists && grep -qxF "$1" "${REPORT}"; }
# The report must carry exactly one overall verdict, and it must be the
# expected one: a second, contradicting "Overall Status:" line would satisfy a
# substring search while leaving the report self-contradictory, and neither
# the exit code nor the metadata would notice.
report_verdict_is(){
  local expected="$1"
  report_exists || return 1
  [[ "$(grep -c '^Overall Status:' "${REPORT}")" -eq 1 ]] || return 1
  grep -qxF "Overall Status: ${expected}" "${REPORT}"
}
# Stub bookkeeping from the sandbox: which calls the step made, and in which
# order, where the published artifact cannot show it. The state directory
# itself must exist, or "the file is not there" would also be the answer for
# a sandbox that never recorded anything at all.
state_file_absent(){ [[ -d "${STATE}" && ! -e "${STATE}/$1" ]]; }
state_file_is(){
  local file="${STATE}/$1"; shift
  [[ -d "${STATE}" && -f "${file}" ]] || return 1
  [[ "$(cat "${file}")" == "$(printf '%s\n' "$@")" ]]
}
stderr_lacks(){
  local status=0
  [[ -f "${STDERR}" ]] || return 1
  grep -qF "$1" "${STDERR}" || status=$?
  [[ "${status}" -eq 1 ]]
}
stderr_has(){ grep -qF "$1" "${STDERR}"; }
# Only exit status 1 is "no match". grep answers 2 when it cannot read a file,
# and a bare `!` would turn that into a passing assertion.
artifact_exists(){ [[ -e "${ARTIFACTS}/$1" ]]; }
artifact_has_line(){ [[ -f "${ARTIFACTS}/$1" ]] && grep -qxF "$2" "${ARTIFACTS}/$1"; }
# The artifact's whole content, trailing newlines aside, for a command that
# printed nothing at all: the collector appends its sanitized line to
# whatever the command managed to write, so "contains the line" would still
# pass if a regression folded the command's stderr into the file beside it.
artifact_is_only_line(){
  local file="${ARTIFACTS}/$1" content
  [[ -f "${file}" ]] || return 1
  # The read is checked, not just compared: a cat that printed the expected
  # line and then failed would otherwise satisfy the comparison, and the
  # content it managed to print says nothing about the rest of the file.
  content="$(cat -- "${file}")" || return 1
  [[ "${content}" == "$2" ]]
}
artifact_lacks_line(){
  local status=0
  [[ -f "${ARTIFACTS}/$1" ]] || return 1
  grep -qxF "$2" "${ARTIFACTS}/$1" || status=$?
  [[ "${status}" -eq 1 ]]
}
artifacts_lack(){
  local status=0
  grep -rqF "$1" "${ARTIFACTS}" || status=$?
  [[ "${status}" -eq 1 ]]
}
# The snapshot metadata.json is the machine-readable twin of the report. It must
# not call a resource healthy that the report just failed the step over.
# -s with `length == 1` everywhere below: `jq -e` reports the status of the
# LAST document, so a file holding a PASSED object followed by a FAILED one
# would satisfy a FAILED assertion while containing conflicting verdicts.
metadata_lists(){
  local field="$1" name="$2" file="${ARTIFACTS}/metadata.json"
  [[ -f "${file}" ]] || return 1
  # An array with an element equal to $name. `index` on a string searches for
  # a substring, so "prefix-node-a-suffix" would otherwise satisfy a
  # membership assertion for node-a.
  jq -es --arg name "${name}" \
    "length == 1 and (.[0] | (${field} | type) == \"array\" and any(${field}[]; . == \$name))" \
    "${file}" >/dev/null
}
# Exact value of a metadata.json field, as a jq literal: metadata_eq
# '.nodes_verified' false. Distinguishes "verified and empty" from "could not
# look", which an array-membership check alone cannot.
metadata_eq(){
  local field="$1" expected="$2" file="${ARTIFACTS}/metadata.json"
  [[ -f "${file}" ]] || return 1
  jq -es "length == 1 and (.[0] | ${field} == ${expected})" "${file}" >/dev/null
}
# Value of a projected field for one named item of a snapshot projection file.
snapshot_item_field(){
  local name="$2" field="$3" expected="$4" path="${ARTIFACTS}/$1"
  [[ -f "${path}" ]] || return 1
  # Exactly one matching row, collected before the comparison: the filter is
  # a generator, so a duplicate row would let jq -e answer with the last
  # result and a contradicting pair would read as the value of its last half.
  jq -es --arg name "${name}" \
    "length == 1 and (.[0] | (.items | type) == \"array\" and ([.items[] | select(.name == \$name)] | length == 1 and (.[0].${field} == ${expected})))" "${path}" >/dev/null
}
# The step reads each resource twice: once for the report, once for the
# snapshot. These drive a throwaway sandbox's stub to its second read so an
# (a8) scenario can assert what the snapshot phase was actually handed, rather
# than only that it failed somehow -- a dead stub branch emits nothing, which
# the step also reports as a failed read.
stub_snapshot_read(){
  local scenario="$1" resource="$2" dir
  dir="$(make_sandbox "snapread-${scenario}-${resource}-${3}")" || exit 1
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json >/dev/null 2>&1 || true
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json 2>/dev/null
}
# Exactly one document, then the predicate on it: jq -e reports the status of
# the last document, so a healthy list concatenated before the intended one
# would satisfy these probes. The deliberate two-document fixture keeps its
# own length == 2 proof.
stub_snapshot_read_is_list(){
  stub_snapshot_read "$1" "$2" list \
    | jq -es 'length == 1 and (.[0] | type == "object" and (.items | type == "array"))' >/dev/null
}
# Transport alone cannot tell a malformed payload from an empty one: both make
# the step fail with the same verdict and flags. These pin which fixture the
# scenario is actually exercising.
stub_snapshot_read_has_string_status(){
  stub_snapshot_read "$1" "$2" shape \
    | jq -es 'length == 1 and (.[0] | (.items | type) == "array" and any(.items[]; (.status | type) == "string"))' >/dev/null
}
stub_snapshot_read_is_empty_list(){
  stub_snapshot_read "$1" "$2" empty \
    | jq -es 'length == 1 and (.[0] | (.items | type) == "array" and (.items | length) == 0)' >/dev/null
}
# The snapshot read must fail the way the scenario intends: exit status 1 with
# the synthetic client error on stderr. A bare "it failed" would also accept
# the stub's unhandled-scenario exit 70, which proves nothing about transport.
stub_snapshot_read_fails(){
  local scenario="$1" resource="$2" dir status=0
  dir="$(make_sandbox "snapfail-${scenario}-${resource}")" || exit 1
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json >/dev/null 2>&1 || true
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" \
    "${dir}/bin/oc" get "${resource}" -o json \
    >/dev/null 2>"${dir}/snapfail.err" || status=$?
  [[ "${status}" -eq 1 ]] && grep -qF 'openshiftapps.com' "${dir}/snapfail.err"
}
# Same checks against the management-role snapshot the HCP path writes under
# ARTIFACT_DIR/management.
management_metadata_eq(){
  local field="$1" expected="$2" file="${ARTIFACTS}/management/metadata.json"
  [[ -f "${file}" ]] || return 1
  jq -es "length == 1 and (.[0] | ${field} == ${expected})" "${file}" >/dev/null
}
snapshot_has_item(){
  local name="$2" path="${ARTIFACTS}/$1"
  [[ -f "${path}" ]] || return 1
  jq -es --arg name "${name}" 'length == 1 and (.[0] | (.items | type) == "array" and any(.items[]; .name == $name))' "${path}" >/dev/null
}
# A projection that was disowned must be empty, not merely missing one name:
# a leftover NotReady sibling would still be published. snapshot_lacks_item
# stays for the hosted/management isolation checks, where absence of a
# specific name is exactly the claim.
snapshot_items_empty(){
  local path="${ARTIFACTS}/$1"
  [[ -f "${path}" ]] || return 1
  jq -es 'length == 1 and (.[0] | .items == [])' "${path}" >/dev/null
}
snapshot_lacks_item(){
  local name="$2" path="${ARTIFACTS}/$1"
  [[ -f "${path}" ]] || return 1
  jq -es --arg name "${name}" 'length == 1 and (.[0] | (.items | type) == "array" and all(.items[]; .name != $name))' "${path}" >/dev/null
}
metadata_absent(){ [[ ! -e "${ARTIFACTS}/metadata.json" ]]; }
# The step writes .metadata.json.tmp beside the destination before renaming it
# into place, so a failed publication must not leave it behind.
metadata_tmp_absent(){ [[ ! -e "${ARTIFACTS}/.metadata.json.tmp" ]]; }
metadata_is_not_a_file(){ [[ ! -f "${ARTIFACTS}/metadata.json" ]]; }
# A plain mv onto a directory would deposit the temporary file *inside* it, so
# the sibling-path check alone cannot see the failure. The listing itself must
# succeed: an unreadable directory would otherwise read as an empty one.
metadata_dir_is_empty(){
  local dir="${ARTIFACTS}/metadata.json" listing
  [[ -d "${dir}" ]] || return 1
  listing="$(ls -A -- "${dir}")" || return 1
  [[ -z "${listing}" ]]
}
# The step keeps raw payloads and raw client errors in a scratch directory it
# removes on exit. Given a private TMPDIR, an empty one proves the removal
# still happens; the artifact checks alone would pass if it stopped.
scratch_is_empty(){
  local listing
  [[ -d "${SCRATCH_TMPDIR}" ]] || return 1
  # Checked assignment: ls can fail with no stdout, and a bare -z test on that
  # would read as "empty" without having proved anything.
  listing="$(ls -A "${SCRATCH_TMPDIR}")" || return 1
  [[ -z "${listing}" ]]
}
rc_is(){ [[ "${RC}" -eq "$1" ]]; }
rc_nonzero(){ [[ "${RC}" -ne 0 ]]; }

# Guards the scenarios below against passing for the wrong reason. A stub that
# emitted nothing -- a dead case branch, a misspelled scenario -- would make the
# step report exactly the same "JSON query failed or returned malformed data"
# those scenarios assert. Checking the fixture directly proves the step was
# handed a parseable one-item list and rejected it on the field types alone.
# Like stub_payload_is_json, but for fixtures that are deliberately not a
# single parseable document: it only proves the stub emitted something, so a
# dead branch cannot masquerade as a rejected payload.
stub_payload_nonempty(){
  local scenario="$1" resource="$2" dir
  dir="$(make_sandbox "fixture-${scenario}-${resource}")" || exit 1
  [[ -n "$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json)" ]]
}
# For the concatenated-documents fixture: each document must parse and be a
# list object, and there must be exactly two of them. "Nonempty" alone would
# accept invalid text, which the step rejects for a different reason.
payload_is_two_documents(){
  # stderr is dropped: invalid input is an expected answer here, not noise
  # worth printing beside the assertion that rejected it.
  jq -es 'length == 2 and all(.[]; type == "object" and (.items | type) == "array")' >/dev/null 2>&1
}
stub_payload_is_two_documents(){
  local scenario="$1" resource="$2" dir
  dir="$(make_sandbox "fixture2-${scenario}-${resource}")" || exit 1
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json \
    | payload_is_two_documents
}
# The specific malformed field each scenario is about: a duplicated or
# substituted fixture would otherwise satisfy "parseable one-item list" and
# produce the same verdict while testing a different input.
stub_payload_type_is(){
  local scenario="$1" resource="$2" path="$3" want="$4" dir
  dir="$(make_sandbox "fixtype-${scenario}-${resource}")" || exit 1
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json \
    | jq -es --arg want "${want}" "length == 1 and (.[0] | (${path} | type) == \$want)" >/dev/null
}
stub_payload_is_json(){
  local scenario="$1" resource="$2" dir
  dir="$(make_sandbox "fixture-${scenario}-${resource}")" || exit 1
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" "${dir}/bin/oc" get "${resource}" -o json \
    | jq -es 'length == 1 and (.[0] | type == "object" and (.items | type == "array") and (.items | length) == 1)' >/dev/null
}

check(){
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

# Assertions shared by every scenario where the API cannot be read.
assert_no_false_health(){
  check "step exits non-zero" rc_nonzero
  check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
  check "report does not claim nodes READY" report_lacks 'All nodes: READY'
  check "no SUCCESS line for operators on stderr" stderr_lacks 'All ClusterOperators are healthy'
  check "no SUCCESS line for nodes on stderr" stderr_lacks 'All nodes are Ready'
  check "overall status FAILED" report_verdict_is FAILED
}

###########################################
# (a) JSON query fails after a successful wide query
###########################################
echo "scenario: json_fails (wide query OK, JSON query fails)"
run_step json_fails
assert_no_false_health
check "report does not claim Total nodes: 0" report_lacks 'Total nodes: 0'
check "report records the CO JSON failure" report_has 'ClusterOperator JSON query failed'
check "report records the node JSON failure" report_has 'node JSON query failed'

###########################################
# (a2) JSON query returns a malformed payload
###########################################
echo "scenario: json_malformed (wide query OK, JSON unparseable)"
run_step json_malformed
assert_no_false_health
check "report records malformed CO data" report_has 'ClusterOperator JSON query failed or returned malformed data'

###########################################
# (a3) JSON well-formed but empty
###########################################
echo "scenario: json_empty (well-formed but zero items)"
run_step json_empty
assert_no_false_health
check "report records no operators returned" report_has 'no ClusterOperators returned'
check "report records no nodes returned" report_has 'no nodes returned'

###########################################
# (a4) JSON well-formed list whose items are not objects
###########################################
echo "scenario: json_nonobject (items present but not objects)"
run_step json_nonobject
assert_no_false_health
check "step fails validation rather than aborting" rc_is 1
check "report is complete (summary written)" report_has 'Validation Summary'

###########################################
# (a6) Items are objects but a health field has the wrong type.
# These must be rejected by the shape check: the health jq indexes
# .metadata.name and .status.conditions[].type, so under errexit an unguarded
# index would kill the step before any result reached the report, and a
# non-array conditions list would be skipped by `[]?` and read as healthy.
###########################################
for scenario in json_status_nonobject json_conditions_nonarray json_condition_nonobject json_metadata_nonobject; do
  echo "scenario: ${scenario} (well-formed list, structurally invalid health fields)"
  check "CO fixture is a parseable one-item list" stub_payload_is_json "${scenario}" co
  check "node fixture is a parseable one-item list" stub_payload_is_json "${scenario}" nodes
  # Each scenario owns one malformed field, asserted by name and JSON type for
  # both resources, so the four inputs cannot collapse into one.
  for resource in co nodes; do
    case "${scenario}" in
      json_status_nonobject)
        check "${resource} fixture has a string status" stub_payload_type_is "${scenario}" "${resource}" '.items[0].status' string ;;
      json_conditions_nonarray)
        check "${resource} fixture has an object status" stub_payload_type_is "${scenario}" "${resource}" '.items[0].status' object
        check "${resource} fixture has a string conditions field" stub_payload_type_is "${scenario}" "${resource}" '.items[0].status.conditions' string ;;
      json_condition_nonobject)
        check "${resource} fixture has an array conditions field" stub_payload_type_is "${scenario}" "${resource}" '.items[0].status.conditions' array
        check "${resource} fixture has a non-object condition entry" stub_payload_type_is "${scenario}" "${resource}" '.items[0].status.conditions[0]' string ;;
      json_metadata_nonobject)
        check "${resource} fixture has a string metadata field" stub_payload_type_is "${scenario}" "${resource}" '.items[0].metadata' string ;;
      *)
        check "${resource} scenario has a malformed-field assertion" false ;;
    esac
  done
  run_step "${scenario}"
  assert_no_false_health
  check "step fails validation rather than aborting" rc_is 1
  check "report is complete (summary written)" report_has 'Validation Summary'
  check "report records malformed CO data" report_has 'ClusterOperator JSON query failed or returned malformed data'
  check "report records malformed node data" report_has 'node JSON query failed or returned malformed data'
done

###########################################
# (a7) Items are well-formed but never assert health: no status, an empty
# conditions list, Ready/Available reported as Unknown, or a contradicting
# duplicate of that condition. Absence of a Ready=True / Available=True
# condition is not evidence of health, and a duplicate True must not mask a
# reported False.
###########################################
for scenario in json_no_status json_empty_conditions json_condition_unknown json_condition_contradicts; do
  echo "scenario: ${scenario} (well-formed items that never assert health)"
  check "CO fixture is a parseable one-item list" stub_payload_is_json "${scenario}" co
  check "node fixture is a parseable one-item list" stub_payload_is_json "${scenario}" nodes
  run_step "${scenario}"
  assert_no_false_health
  check "step fails validation rather than passing" rc_is 1
  check "report names the unverified operator" report_has 'Unavailable Operators: authentication'
  check "report names the unverified node" report_has 'NotReady Nodes: node-a'
  check "snapshot agrees about the operator" metadata_lists '.unavailable_operators' authentication
  check "snapshot agrees about the node" metadata_lists '.notready_nodes' node-a
done

###########################################
# (a8) The report reads succeed, and only the later snapshot read fails, comes
# back structurally invalid, or comes back well-formed but empty. The snapshot must not publish empty health
# arrays and a zero count beside an unchanged PASSED status; the failure has to
# reach overall_status, the *_verified flags and the step's exit code.
###########################################
for scenario in snapshot_query_fails snapshot_shape_fails snapshot_empty; do
  echo "scenario: ${scenario} (report reads OK, snapshot read fails)"
  case "${scenario}" in
    snapshot_query_fails)
      check "the snapshot read really fails" stub_snapshot_read_fails "${scenario}" co
      check "the snapshot node read really fails" stub_snapshot_read_fails "${scenario}" nodes ;;
    snapshot_shape_fails)
      check "the snapshot read is a parseable list" stub_snapshot_read_is_list "${scenario}" co
      check "the snapshot node read is a parseable list" stub_snapshot_read_is_list "${scenario}" nodes
      check "the operator payload carries the malformed string status" stub_snapshot_read_has_string_status "${scenario}" co
      check "the node payload carries the malformed string status" stub_snapshot_read_has_string_status "${scenario}" nodes ;;
    snapshot_empty)
      check "the snapshot read is a parseable list" stub_snapshot_read_is_list "${scenario}" co
      check "the snapshot node read is a parseable list" stub_snapshot_read_is_list "${scenario}" nodes
      check "the operator payload is an empty list" stub_snapshot_read_is_empty_list "${scenario}" co
      check "the node payload is an empty list" stub_snapshot_read_is_empty_list "${scenario}" nodes ;;
    *)
      check "a8 scenario has a fixture assertion" false ;;
  esac
  run_step "${scenario}"
  check "report still records the healthy report-phase read" report_has 'All operators: HEALTHY'
  check "report still records the healthy node read" report_has 'All nodes: READY'
  check "report records the snapshot verification failure" report_has 'snapshot did not confirm a healthy cluster'
  check "overall status FAILED" report_verdict_is FAILED
  check "step exits non-zero" rc_is 1
  check "snapshot status is FAILED, not PASSED" metadata_eq '.overall_status' '"FAILED"'
  check "snapshot marks operators unverified" metadata_eq '.clusteroperators_verified' 'false'
  check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
  check "snapshot does not report a ready node count" metadata_eq '.ready_node_count' '0'
  check "snapshot does not report a node count" metadata_eq '.node_count' '0'
  check "raw client error kept out of all artifacts" artifacts_lack 'openshiftapps.com'
done

###########################################
# (a8b) The snapshot read succeeds and passes the shape check, but projecting
# it fails. A processing failure is as unverified as a read failure, and must
# not leave an empty projection reading as a clean cluster. Operators stay
# verified here, so the failure is attributed to the resource it came from.
###########################################
echo "scenario: snapshot_projection_fails (valid read, projection cannot be computed)"
check "node fixture is a parseable one-item list" stub_payload_is_json snapshot_projection_fails nodes
run_step snapshot_projection_fails
# These two prove the read itself was accepted: the same payload passed the
# report phase's validation and was counted, so only the projection can have
# failed. Without them the scenario would be indistinguishable from (a8).
# Recorded by the jq stub from the invocation it actually failed: the node
# projection program, running on the snapshot node payload. The assertions
# below hold for any snapshot-side failure, so this is what pins the stage.
check "the injected failure was the node projection on the snapshot payload" \
  state_file_is injected-jq-failure 'program=node-projection payload=snapshot-nodes'
check "the same payload passed the report-phase validation" report_has 'All nodes: READY'
check "the report counted the node it read" report_has_line 'Total nodes: 1'
check "step exits non-zero" rc_is 1
check "report records the snapshot verification failure" report_has 'snapshot did not confirm a healthy cluster'
check "overall status FAILED" report_verdict_is FAILED
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot keeps operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "snapshot does not report a node count" metadata_eq '.node_count' '0'
check "snapshot does not report a ready node count" metadata_eq '.ready_node_count' '0'

###########################################
# (a9) Contradicting duplicate conditions, in both orders. The per-item
# projection and the count derived from it must follow the same all-True rule
# as the unhealthy lists, so condition order cannot change the verdict.
###########################################
for scenario in json_condition_contradicts json_condition_contradicts_true_first; do
  echo "scenario: ${scenario} (contradicting duplicate conditions)"
  run_step "${scenario}"
  check "step exits non-zero" rc_is 1
  check "report names the node" report_has 'NotReady Nodes: node-a'
  # The report is checked independently of the snapshot: a report-side
  # regression that reads only the first Available condition would still leave
  # the node report and both projections correct.
  check "report names the unavailable operator" report_has 'Unavailable Operators: authentication'
  check "snapshot lists the node as not ready" metadata_lists '.notready_nodes' node-a
  check "snapshot lists the operator as unavailable" metadata_lists '.unavailable_operators' authentication
  check "snapshot does not count the node as ready" metadata_eq '.ready_node_count' '0'
  check "projected node readiness is not True" snapshot_item_field nodes.json node-a ready '"False"'
  check "projected operator availability is not True" snapshot_item_field clusteroperators.json authentication available '"False"'
done

###########################################
# (a10) Optional fields exactly as Kubernetes reports them. Absent labels, an
# absent spec and extra condition types must all project cleanly and leave the
# snapshot verified: optional-field absence is not malformed input.
###########################################
echo "scenario: optional_fields (roles/spec present on one node, absent on the other)"
run_step optional_fields
check "step exits zero" rc_is 0
check "overall status PASSED" report_verdict_is PASSED
check "snapshot marks nodes verified" metadata_eq '.nodes_verified' 'true'
check "snapshot counts both nodes" metadata_eq '.node_count' '2'
check "snapshot counts both nodes ready" metadata_eq '.ready_node_count' '2'
check "roles are projected from labels" snapshot_item_field nodes.json node-a roles '["worker"]'
check "an unschedulable node is not schedulable" snapshot_item_field nodes.json node-a schedulable 'false'
check "a node without labels gets no roles" snapshot_item_field nodes.json node-b roles '[]'
check "a node without spec is schedulable" snapshot_item_field nodes.json node-b schedulable 'true'

###########################################
# (a11) Structurally invalid metadata.labels -- not a map[string]string, so
# not something Kubernetes emits. The step refuses to vouch for it. This is
# asserted on its own, separately from the processing-failure branch, so the
# strictness is not justified merely by keeping that branch testable.
###########################################
echo "scenario: nodes_labels_nonobject (labels is not an object)"
run_step nodes_labels_nonobject
check "step exits non-zero" rc_is 1
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot keeps operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a12) HCP: the hosted and management snapshots come from two different
# reads under two different kubeconfigs, and a management-side failure is
# informational -- it must not change the hosted verdict or the exit status.
###########################################
echo "scenario: hcp_healthy (hosted + management snapshots, both readable)"
run_step hcp_healthy true
check "step exits zero" rc_is 0
check "overall status PASSED" report_verdict_is PASSED
check "primary snapshot is the hosted role" metadata_eq '.cluster_role' '"hosted"'
check "primary snapshot records the hcp topology" metadata_eq '.topology' '"hcp"'
check "hosted snapshot counts the hosted nodes" metadata_eq '.node_count' '2'
check "hosted snapshot holds hosted nodes" snapshot_has_item nodes.json node-a
check "hosted snapshot holds no management node" snapshot_lacks_item nodes.json mgmt-node-1
check "management snapshot is written" management_metadata_eq '.cluster_role' '"management"'
check "management snapshot is informational" management_metadata_eq '.overall_status' '"INFO"'
check "management snapshot counts its own node" management_metadata_eq '.node_count' '1'
check "management snapshot marks nodes verified" management_metadata_eq '.nodes_verified' 'true'
check "management snapshot holds the management node" snapshot_has_item management/nodes.json mgmt-node-1
check "management snapshot holds no hosted node" snapshot_lacks_item management/nodes.json node-a

echo "scenario: hcp_management_fails (hosted readable, management reads fail)"
run_step hcp_management_fails true
check "step still exits zero" rc_is 0
check "overall status stays PASSED" report_verdict_is PASSED
check "hosted snapshot stays PASSED" metadata_eq '.overall_status' '"PASSED"'
check "hosted snapshot stays verified" metadata_eq '.nodes_verified' 'true'
check "hosted snapshot still counts its nodes" metadata_eq '.node_count' '2'
check "management snapshot stays informational, not FAILED" management_metadata_eq '.overall_status' '"INFO"'
check "management snapshot marks nodes unverified" management_metadata_eq '.nodes_verified' 'false'
check "management snapshot marks operators unverified" management_metadata_eq '.clusteroperators_verified' 'false'
check "management snapshot publishes no node count" management_metadata_eq '.node_count' '0'
check "raw client error kept out of all artifacts" artifacts_lack 'openshiftapps.com'

###########################################
# (a13) The report reads healthy and the snapshot then captures an unhealthy
# cluster. The snapshot is the later look, so its evidence wins: a nonempty
# captured unhealthy list must not sit beside overall_status PASSED, and the
# capture must fail the step.
###########################################
for scenario in snapshot_degraded snapshot_unavailable snapshot_notready; do
  echo "scenario: ${scenario} (report reads healthy, snapshot captures unhealthy)"
  run_step "${scenario}"
  check "report records the healthy report-phase operator read" report_has 'All operators: HEALTHY'
  check "report records the healthy report-phase node read" report_has 'All nodes: READY'
  check "step exits non-zero" rc_is 1
  check "overall status FAILED" report_verdict_is FAILED
  check "snapshot status is FAILED, not PASSED" metadata_eq '.overall_status' '"FAILED"'
  check "the reads themselves stayed verified" metadata_eq '.clusteroperators_verified' 'true'
  check "the node reads stayed verified" metadata_eq '.nodes_verified' 'true'
  # The captured resource is named in the snapshot it came from. Asserted in
  # the same run rather than a second one, so no scenario is run twice.
  case "${scenario}" in
    snapshot_degraded)
      check "degraded operator captured" metadata_lists '.degraded_operators' authentication ;;
    snapshot_unavailable)
      check "unavailable operator captured" metadata_lists '.unavailable_operators' dns ;;
    snapshot_notready)
      check "notready node captured" metadata_lists '.notready_nodes' node-b ;;
    *)
      check "a13 scenario names its captured resource" false ;;
  esac
done

###########################################
# (a14) The projections succeed and writing metadata.json then fails. The step
# must not log a written snapshot, must not publish a partial artifact, and
# must not report success.
###########################################
echo "scenario: metadata_write_fails (projections OK, metadata write fails)"
run_step metadata_write_fails
check "step exits non-zero" rc_is 1
# The sandbox held a valid PASSED metadata.json before the step ran, so the
# two absence checks below are removals, not an artifact that never existed.
check "report records the snapshot failure" report_has 'snapshot did not confirm a healthy cluster'
# The write handler's own message, so a regression that returned earlier -- at
# a projection, say -- cannot satisfy the rest of this case.
check "the injected write failure was reached" stderr_has 'failed to write metadata.json'
check "overall status FAILED" report_verdict_is FAILED
# Recorded by the jq stub while the failing write was in flight: the seeded
# verdict was still byte-identical and still parsed as PASSED, so the partial
# document never went near the published path.
check "the published verdict was untouched while the write was in flight" \
  state_file_is metadata-during-write intact
check "the stale PASSED artifact is removed, none published" metadata_absent
check "no temporary metadata file is left behind" metadata_tmp_absent
check "the projections that did succeed are still published" snapshot_has_item nodes.json node-a
check "no snapshot-written line on stderr" stderr_lacks 'Cluster install snapshot JSON written'

###########################################
# (a15) The snapshot node count cannot be computed. A count that failed is not
# a count of zero: the nodes must be marked unverified rather than published as
# an empty, verified cluster.
###########################################
echo "scenario: snapshot_count_fails (node count jq fails on the snapshot read)"
run_step snapshot_count_fails
# The mirror image: the payload check's own count succeeds and only the
# writer's second count fails, so the two scenarios cannot be swapped.
check "the first count passed and the second failed" state_file_is snapshot-count-sequence '1 passed-through' '2 failed'
check "report records the healthy report-phase node read" report_has 'All nodes: READY'
check "step exits non-zero" rc_is 1
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot publishes no node count" metadata_eq '.node_count' '0'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a16) An unhealthy management cluster is informational. It must not change
# the hosted cluster's verdict or the step's exit status.
###########################################
echo "scenario: hcp_management_degraded (management cluster itself unhealthy)"
run_step hcp_management_degraded true
check "step still exits zero" rc_is 0
check "overall status stays PASSED" report_verdict_is PASSED
check "hosted snapshot stays PASSED" metadata_eq '.overall_status' '"PASSED"'
check "hosted snapshot reports no unhealthy nodes" metadata_eq '.notready_nodes' '[]'
check "management snapshot stays informational" management_metadata_eq '.overall_status' '"INFO"'
check "management snapshot stayed verified" management_metadata_eq '.nodes_verified' 'true'
check "management snapshot records its degraded operator" management_metadata_eq '.degraded_operators' '["mgmt-operator"]'
check "management snapshot records its notready node" management_metadata_eq '.notready_nodes' '["mgmt-node-1"]'
# An unhealthy management cluster is a fact the capture recorded, not a failed
# capture: it completes normally and is not reported as a snapshot failure.
check "management capture completed, not failed" stderr_has 'Cluster install snapshot JSON written (management)'
check "no management snapshot failure warning" stderr_lacks 'management-cluster install snapshot failed'
check "management unhealth is not called a capture failure" stderr_lacks 'management: snapshot captured unhealthy'

# INFO isolation: the malformed payload belongs to the management cluster, so
# its own capture is unverified while the hosted cluster still passes.
echo "scenario: hcp_management_versions_number (management operator version is a number)"
run_step hcp_management_versions_number true
check "step still exits zero" rc_is 0
check "overall status stays PASSED" report_verdict_is PASSED
check "hosted snapshot stays PASSED" metadata_eq '.overall_status' '"PASSED"'
check "hosted operators stay verified" metadata_eq '.clusteroperators_verified' 'true'
check "hosted operator projection is intact" snapshot_has_item clusteroperators.json authentication
check "management snapshot stays informational" management_metadata_eq '.overall_status' '"INFO"'
check "management operators are unverified" management_metadata_eq '.clusteroperators_verified' 'false'
check "management publishes no operator count" management_metadata_eq '.clusteroperator_count' '0'
check "management operator projection is emptied" snapshot_items_empty management/clusteroperators.json
check "management nodes stay verified" management_metadata_eq '.nodes_verified' 'true'
check "the management capture reports it could not verify" stderr_has 'management: snapshot could not verify'
check "the management snapshot failure is logged" stderr_has 'management-cluster install snapshot failed'

###########################################
# (a17) The wide listing succeeds and only the JSON read fails. The both-fail
# case above keeps the old "Total nodes: 0" regression covered; this one
# catches a regression that would report READY on the strength of a wide read.
###########################################
echo "scenario: json_only_fails (wide read OK, JSON read fails)"
run_step json_only_fails
assert_no_false_health
check "step fails validation rather than aborting" rc_is 1
check "the wide listing did succeed" report_has 'NAME     STATUS   ROLES    AGE   VERSION'
check "report records the CO JSON failure" report_has 'ClusterOperator JSON query failed'
check "report records the node JSON failure" report_has 'node JSON query failed'
check "report does not claim Total nodes: 0" report_lacks 'Total nodes: 0'
check "scratch directory removed after a failed run" scratch_is_empty

###########################################
# (a17b) One resource's report JSON read fails while its sibling and both
# snapshot reads stay healthy. The snapshot cannot be what fails the run, so
# these prove the report branch alone sets the verdict.
###########################################
echo "scenario: report_co_json_only_fails (only the CO report read fails)"
run_step report_co_json_only_fails
check "step exits non-zero" rc_is 1
check "report records the CO JSON failure" report_has 'ClusterOperator JSON query failed'
check "the sibling resource is still reported healthy" report_has 'All nodes: READY'
check "overall status FAILED" report_verdict_is FAILED
check "the snapshot itself verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the snapshot itself verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the snapshot capture completed" stderr_has 'Cluster install snapshot JSON written'
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'

echo "scenario: report_nodes_json_only_fails (only the node report read fails)"
run_step report_nodes_json_only_fails
check "step exits non-zero" rc_is 1
check "report records the node JSON failure" report_has 'node JSON query failed'
check "the sibling resource is still reported healthy" report_has 'All operators: HEALTHY'
check "overall status FAILED" report_verdict_is FAILED
check "the snapshot itself verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the snapshot itself verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the snapshot capture completed" stderr_has 'Cluster install snapshot JSON written'
check "report does not claim nodes READY" report_lacks 'All nodes: READY'

###########################################
# (a17c) The read prints the healthy payload and then exits non-zero. The
# payload itself is impeccable, so only the command's exit status says the
# read failed: these two scenarios are what the status check in
# get_resource_json is for, and the sibling resource proves the failure did
# not spill over.
###########################################
echo "scenario: co_json_rc1_with_payload (healthy CO payload, non-zero exit)"
run_step co_json_rc1_with_payload
check "step exits non-zero" rc_is 1
check "report records the CO JSON failure" report_has 'ClusterOperator JSON query failed'
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
check "the sibling resource is still reported healthy" report_has 'All nodes: READY'
check "overall status FAILED" report_verdict_is FAILED
check "the snapshot marks the operators unverified" metadata_eq '.clusteroperators_verified' 'false'
check "no operator count is published" metadata_eq '.clusteroperator_count' '0'
check "the operator projection is emptied" snapshot_items_empty clusteroperators.json
check "the snapshot still verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the node projection is intact" snapshot_has_item nodes.json node-a
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

echo "scenario: nodes_json_rc1_with_payload (healthy node payload, non-zero exit)"
run_step nodes_json_rc1_with_payload
check "step exits non-zero" rc_is 1
check "report records the node JSON failure" report_has 'node JSON query failed'
check "report does not claim nodes READY" report_lacks 'All nodes: READY'
check "the sibling resource is still reported healthy" report_has 'All operators: HEALTHY'
check "overall status FAILED" report_verdict_is FAILED
check "the snapshot marks the nodes unverified" metadata_eq '.nodes_verified' 'false'
check "no node count is published" metadata_eq '.node_count' '0'
check "the node projection is emptied" snapshot_items_empty nodes.json
check "the snapshot still verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the operator projection is intact" snapshot_has_item clusteroperators.json authentication
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a18) The response is a concatenation of two JSON documents. Each parses on
# its own, so a per-document check would accept it while the counts and health
# lists silently read both.
###########################################
echo "scenario: json_two_documents (two concatenated JSON documents)"
check "CO fixture really is emitted" stub_payload_nonempty json_two_documents co
check "node fixture really is emitted" stub_payload_nonempty json_two_documents nodes
check "CO fixture is exactly two list documents" stub_payload_is_two_documents json_two_documents co
check "node fixture is exactly two list documents" stub_payload_is_two_documents json_two_documents nodes
run_step json_two_documents
assert_no_false_health
check "step fails validation rather than aborting" rc_is 1
check "report is complete (summary written)" report_has 'Validation Summary'
check "report records malformed CO data" report_has 'ClusterOperator JSON query failed or returned malformed data'
check "report records malformed node data" report_has 'node JSON query failed or returned malformed data'

###########################################
# (a19) A resource whose name is the empty string. The health selectors emit
# the name, and command substitution drops an empty one, so an unhealthy
# resource would vanish from the list it belongs in.
###########################################
echo "scenario: json_empty_name (unhealthy resource with an empty name)"
check "CO fixture is a parseable one-item list" stub_payload_is_json json_empty_name co
check "node fixture is a parseable one-item list" stub_payload_is_json json_empty_name nodes
run_step json_empty_name
assert_no_false_health
check "step fails validation rather than aborting" rc_is 1
check "report is complete (summary written)" report_has 'Validation Summary'
check "the payload is rejected, not silently emptied" report_has 'node JSON query failed or returned malformed data'

###########################################
# (a20) Contradicting non-True duplicates in both orders must project the same
# value: the guarantee is order-independence, not first-wins.
###########################################
for scenario in json_precedence_false_first json_precedence_unknown_first; do
  echo "scenario: ${scenario} (False and Unknown duplicates)"
  run_step "${scenario}"
  check "step exits non-zero" rc_is 1
  check "node is reported NotReady" metadata_lists '.notready_nodes' node-a
  check "operator is reported unavailable" metadata_lists '.unavailable_operators' authentication
  check "projected readiness is False regardless of order" snapshot_item_field nodes.json node-a ready '"False"'
  check "projected availability is False regardless of order" snapshot_item_field clusteroperators.json authentication available '"False"'
done

###########################################
# (a21) jq prints a plausible count and then exits non-zero. A numeric test on
# an unchecked substitution would accept it and keep the resource verified.
###########################################
echo "scenario: snapshot_count_lies (count printed, jq exits non-zero)"
run_step snapshot_count_lies
check "step exits non-zero" rc_is 1
# The first count call is the one that printed a plausible number and then
# failed; the writer never reaches its own count, so there is no second entry.
check "the first count call emitted a number and failed" state_file_is snapshot-count-sequence '1 emitted-then-failed'
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot publishes no node count" metadata_eq '.node_count' '0'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a22) A report-phase health query fails after its payload validated. Under
# errexit the assignment used to kill the step, losing the failure reason, the
# summary and the snapshot. It must record the failure and carry on.
###########################################
echo "scenario: report_health_jq_fails (report-side health jq fails)"
run_step report_health_jq_fails
check "step exits non-zero" rc_is 1
check "report records the evaluation failure" report_has 'node health could not be evaluated'
check "report is complete (summary written)" report_has 'Validation Summary'
check "overall status FAILED" report_verdict_is FAILED
check "report does not claim nodes READY" report_lacks 'All nodes: READY'
check "report does not publish an uncounted zero" report_lacks 'Total nodes: 0'
check "report says the count is unverified" report_has_line 'Total nodes: unverified'
check "no SUCCESS line for nodes on stderr" stderr_lacks 'All nodes are Ready'
# The report error must decide the verdict without costing the capture: a step
# that skipped the snapshot would otherwise satisfy every assertion above.
check "the snapshot was still written" metadata_eq '.cluster_role' '"classic"'
check "the snapshot verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the snapshot verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the snapshot records the failed verdict" metadata_eq '.overall_status' '"FAILED"'
check "the snapshot counted the nodes it verified" metadata_eq '.node_count' '2'
check "the snapshot capture completed" stderr_has 'Cluster install snapshot JSON written'

###########################################
# (a23) The projection is written and the health-list query then fails. The
# counts derived from the projection must not contradict the disowned list.
###########################################
echo "scenario: snapshot_health_list_fails (projection OK, health list fails)"
run_step snapshot_health_list_fails
check "step exits non-zero" rc_is 1
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot publishes no node count" metadata_eq '.node_count' '0'
check "ready count agrees with the disowned list" metadata_eq '.ready_node_count' '0'
check "the projection is emptied too" snapshot_items_empty nodes.json
# The failed query named a node before failing: that name is unverified and
# must not reach the published list.
check "the unverified name from the failed query is discarded" metadata_eq '.notready_nodes' '[]'
# Node-only: the operator snapshot must survive a node-side health-list error.
check "the operator snapshot stays verified" metadata_eq '.clusteroperators_verified' 'true'
check "the operator projection is intact" snapshot_has_item clusteroperators.json authentication
check "the operator count is still reported" metadata_eq '.clusteroperator_count' '2'
# A snapshot that could not verify the nodes must not publish a PASSED
# status, whatever the report concluded.
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a24) A directory already sits where metadata.json belongs. A plain mv would
# move the temp file inside it and return zero, leaving no metadata.json.
###########################################
echo "scenario: metadata_target_is_dir (directory at the metadata.json path)"
run_step metadata_target_is_dir
check "step exits non-zero" rc_is 1
check "report records the snapshot failure" report_has 'snapshot did not confirm a healthy cluster'
# The rename handler's own message, which the write failure does not emit, so
# this case cannot be satisfied by a failure at any earlier stage.
check "the rename stage was reached and reported" stderr_has 'failed to publish metadata.json'
check "the write stage was not the failure" stderr_lacks 'failed to write metadata.json'
check "overall status FAILED" report_verdict_is FAILED
check "no metadata.json file is claimed" metadata_is_not_a_file
check "no temporary metadata file is left behind" metadata_tmp_absent
# Nothing was deposited inside the directory either: a plain mv would have
# left the temporary file there, where the sibling check cannot see it.
check "the destination directory is still empty" metadata_dir_is_empty
check "no snapshot-written line on stderr" stderr_lacks 'Cluster install snapshot JSON written'

###########################################
# (a25) Only the Available health query fails. The Degraded operator the
# earlier query confirmed must stay in the report and still get diagnostics,
# while the overall operator assessment is recorded as unverified.
###########################################
echo "scenario: report_unavailable_jq_fails (only the Available query fails)"
run_step report_unavailable_jq_fails
check "step exits non-zero" rc_is 1
check "the confirmed degraded operator is still named" report_has 'Degraded Operators: authentication'
check "the operator assessment is unverified" report_has 'ClusterOperator health could not be evaluated'
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
check "diagnostics were collected for the degraded operator" artifact_exists diagnostics/co-authentication-describe.txt
# Not just a file: the artifact has to hold the description of the operator
# the report named, so describing another one cannot satisfy this case.
check "the describe artifact holds this operator's diagnostics" \
  artifact_has_line diagnostics/co-authentication-describe.txt 'CO-DESCRIBE-AUTHENTICATION'
check "report is complete (summary written)" report_has 'Validation Summary'
check "overall status FAILED" report_verdict_is FAILED

###########################################
# (a25b) The same report-side Available error with nothing else wrong: no
# degraded operator, no NotReady node, and both snapshot reads healthy. The
# query failure alone has to fail the run, which the case above cannot show
# because its degraded entry fails the run by itself.
###########################################
echo "scenario: report_available_only_fails (Available query fails, everything else healthy)"
run_step report_available_only_fails
check "step exits non-zero" rc_is 1
check "the operator assessment is unverified" report_has 'ClusterOperator health could not be evaluated'
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
check "no degraded entry carries the verdict" report_lacks 'Degraded Operators:'
check "no unavailable entry carries the verdict" report_lacks 'Unavailable Operators:'
check "the node side is unaffected" report_has 'All nodes: READY'
check "report is complete (summary written)" report_has 'Validation Summary'
check "overall status FAILED" report_verdict_is FAILED
# The snapshot read is healthy, so it cannot be what fails the run.
check "the snapshot was still written" metadata_eq '.cluster_role' '"classic"'
check "the snapshot verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the snapshot verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the snapshot lists no unavailable operator" metadata_eq '.unavailable_operators' '[]'
check "the snapshot lists no degraded operator" metadata_eq '.degraded_operators' '[]'
check "the snapshot lists no NotReady node" metadata_eq '.notready_nodes' '[]'
check "the snapshot records the failed verdict" metadata_eq '.overall_status' '"FAILED"'
check "the snapshot capture completed" stderr_has 'Cluster install snapshot JSON written'

###########################################
# (a26) metadata.labels: false. A plain `// {}` default treats false like a
# missing map, so the node would project with no roles and stay verified.
###########################################
echo "scenario: nodes_labels_false (labels reported as false)"
run_step nodes_labels_false
check "step exits non-zero" rc_is 1
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot keeps operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a27) The node projection cannot be written and neither can the empty
# replacement. Metadata must not be published from the stale projection.
###########################################
echo "scenario: nodes_projection_unwritable (projection path is a directory)"
run_step nodes_projection_unwritable
check "step exits non-zero" rc_is 1
# The sandbox held a valid PASSED metadata.json, so this is a removal.
check "the stale PASSED metadata is removed, none published" metadata_absent
check "the refusal is reported" stderr_has 'could not clear the node projection'
check "no snapshot-written line on stderr" stderr_lacks 'Cluster install snapshot JSON written'
check "overall status FAILED" report_verdict_is FAILED

###########################################
# (a27b) The ClusterOperator twin of (a27): the same refusal must hold for the
# operator projection, and nothing disowned may stay published.
###########################################
echo "scenario: co_projection_unwritable (operator projection path is a directory)"
run_step co_projection_unwritable
check "step exits non-zero" rc_is 1
check "overall status FAILED" report_verdict_is FAILED
# As above: a stale PASSED artifact must not survive the refusal.
check "the stale PASSED metadata is removed, none published" metadata_absent
check "the refusal is reported" stderr_has 'could not clear the ClusterOperator projection'
check "no snapshot-written line on stderr" stderr_lacks 'Cluster install snapshot JSON written'

###########################################
# (a29) Only the Ready health query fails. The node count the earlier query
# established must still be reported, and the NotReady names it produced must
# not be invented: the section is unverified, the count is not.
###########################################
echo "scenario: report_notready_jq_fails (only the Ready query fails)"
run_step report_notready_jq_fails
check "step exits non-zero" rc_is 1
check "the count that was read is still reported" report_has_line 'Total nodes: 2'
check "report does not publish an uncounted zero" report_lacks 'Total nodes: 0'
check "the node assessment is unverified" report_has 'node health could not be evaluated'
# The failed query printed a name before failing: unverified output that must
# not reach the report, while the count the successful query produced must.
check "the unverified name from the failed query is discarded" report_lacks 'NotReady Nodes:'
# The snapshot read is healthy here, so it cannot be what fails the run: the
# report error alone has to carry the verdict.
check "the snapshot itself verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the snapshot itself verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the snapshot lists no NotReady node" metadata_eq '.notready_nodes' '[]'
check "the snapshot capture completed" stderr_has 'Cluster install snapshot JSON written'
check "report does not claim nodes READY" report_lacks 'All nodes: READY'
check "report is complete (summary written)" report_has 'Validation Summary'

###########################################
# (a28) Direct checks on the harness contracts the step depends on: a scratch
# listing that cannot be read is not an empty directory, and a sandbox path
# containing a literal $ must reach the generated stubs unexpanded.
###########################################
echo "scenario: harness self-checks"
unreadable_scratch_is_not_empty(){
  local probe saved status
  probe="$(mktemp -d "${WORKROOT}/unreadable-XXXXXX")" || return 1
  mkdir -p "${probe}/inner"
  chmod 000 "${probe}/inner"
  saved="${SCRATCH_TMPDIR:-}"
  SCRATCH_TMPDIR="${probe}/inner"
  status=0
  scratch_is_empty || status=$?
  SCRATCH_TMPDIR="${saved}"
  chmod 755 "${probe}/inner"
  [[ "${status}" -ne 0 ]]
}
# Asserts the effect, not the text: %q escapes the $, so the generated line is
# not byte-identical to the path. What matters is that evaluating it yields the
# real directory rather than a partially expanded one.
stub_baked_path_resolves(){
  local stub="$1" variable="$2" expected="$3" actual
  actual="$(bash -c 'eval "$(grep -m1 "^$2=" "$1")"; printf %s "${!2}"' _ "${stub}" "${variable}")" || return 1
  [[ "${actual}" == "${expected}" ]]
}
dollar_path_is_literal(){
  local dir
  dir="$(make_sandbox 'dollar$name')" || return 1
  # Every path baked into a stub, not just the first: a plainly quoted one
  # would expand at stub runtime and read the wrong location in silence.
  stub_baked_path_resolves "${dir}/bin/oc" OC_STATE_DIR "${dir}/state" \
    && stub_baked_path_resolves "${dir}/bin/oc" OC_SHARED_DIR "${dir}/shared" \
    && stub_baked_path_resolves "${dir}/bin/jq" OC_STATE_DIR "${dir}/state"
}
# Root carries CAP_DAC_OVERRIDE, so chmod 000 does not make ls fail and this
# check could only pass vacuously. Skipped loudly rather than silently.
if [[ "$(id -u)" -ne 0 ]]; then
  check "an unreadable scratch listing is not treated as empty" unreadable_scratch_is_not_empty
else
  echo "  SKIP: running as root, an unreadable directory cannot be simulated"
fi
check "a sandbox path containing \$ reaches both stubs literally" dollar_path_is_literal

# A stub directory whose name contains a colon cannot be reached through PATH,
# and the step would then fall through to whatever client is installed. The
# sentinel below stands in for that client: it is harmless, it only records
# that it was reached, and it must never run.
colon_stub_dir_is_refused(){
  local probe resolved
  probe="$(mktemp -d "${WORKROOT}/colon-XXXXXX")" || return 1
  mkdir -p "${probe}/real:dir/bin" "${probe}/sentinel"
  printf '#!/bin/bash\nprintf reached > %q\n' "${probe}/sentinel/called" > "${probe}/sentinel/oc"
  printf '#!/bin/bash\necho stub\n' > "${probe}/real:dir/bin/oc"
  chmod 0755 "${probe}/sentinel/oc" "${probe}/real:dir/bin/oc"
  # The hazard is real: with a colon in the directory, PATH resolution reaches
  # the sentinel instead of the stub.
  # Absolute bash: the probe PATH deliberately holds nothing but the two
  # directories under test, so bash itself would not be findable through it.
  resolved="$(env -i PATH="${probe}/real:dir/bin:${probe}/sentinel" \
    "$(command -v bash)" -c 'command -v oc || true')"
  [[ "${resolved}" == "${probe}/sentinel/oc" ]] || return 1
  # Nothing was executed: resolution alone must not invoke the stand-in.
  [[ ! -e "${probe}/sentinel/called" ]] || return 1
  # And make_sandbox refuses to build a sandbox at such a path at all, saying
  # why rather than failing for some unrelated reason.
  local refusal
  refusal="$( ( WORKROOT="${probe}/real:dir"; make_sandbox colonprobe ) 2>&1 >/dev/null )" && return 1
  [[ "${refusal}" == *"contains a colon"* ]] || return 1
  [[ ! -e "${probe}/sentinel/called" ]]
}
# The contract run_step enforces before every launch: under the child's exact
# environment, each client name must resolve to this sandbox's generated stub,
# so no real client can ever be reached.
child_resolves_only_stubs(){
  local dir tool resolved
  dir="$(make_sandbox resolvecheck)" || return 1
  for tool in oc ocm jq; do
    resolved="$(env -i PATH="${dir}/bin:${PATH}" HOME="${dir}" bash -c "command -v ${tool} || true")"
    [[ "${resolved}" == "${dir}/bin/${tool}" ]] || return 1
  done
}
check "a colon in the stub directory is refused, sentinel never invoked" colon_stub_dir_is_refused
check "the child resolves oc, ocm and jq to this sandbox's stubs" child_resolves_only_stubs

###########################################
# (a30) A condition supplied with a JSON boolean status. No selector matches a
# boolean, so an unvalidated payload would read as healthy even though the
# operator reports Degraded.
###########################################
echo "scenario: condition_status_boolean (Degraded reported as a JSON boolean)"
check "CO fixture is a parseable one-item list" stub_payload_is_json condition_status_boolean co
run_step condition_status_boolean
# Only the operator payload is malformed here: the healthy node side must keep
# reporting normally, which is what makes the operator rejection meaningful.
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
check "no SUCCESS line for operators on stderr" stderr_lacks 'All ClusterOperators are healthy'
check "the healthy sibling is still reported" report_has 'All nodes: READY'
check "overall status FAILED" report_verdict_is FAILED
check "step fails validation rather than aborting" rc_is 1
check "report is complete (summary written)" report_has 'Validation Summary'
check "the payload is rejected as malformed" report_has 'ClusterOperator JSON query failed or returned malformed data'

###########################################
# (a31) spec.unschedulable supplied as a string. Negating a string yields
# false, so the node would be published as unschedulable while still verified.
###########################################
echo "scenario: spec_unschedulable_string (unschedulable reported as a string)"
check "node fixture is a parseable one-item list" stub_payload_is_json spec_unschedulable_string nodes
run_step spec_unschedulable_string
# The payload is well-formed, so the report phase accepts and counts it: that
# is what distinguishes a projection error from a shape rejection.
check "the report phase accepted the payload" report_has 'All nodes: READY'
check "the report counted the node it read" report_has_line 'Total nodes: 1'
check "step exits non-zero" rc_is 1
check "snapshot marks nodes unverified" metadata_eq '.nodes_verified' 'false'
check "snapshot keeps operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a32) A present management identity file that cannot be read. Both call
# sites suppress errexit, so an unchecked read would leave the identity empty
# and publish a PASSED snapshot anyway.
###########################################
echo "scenario: mgmt_identity_unreadable (mc-cluster-id present but unreadable)"
run_step mgmt_identity_unreadable true
check "step exits non-zero" rc_is 1
check "the primary capture reports the unreadable identity" stderr_has 'hosted: could not read mc-cluster-id'
# The sandbox held a valid PASSED snapshot, so this is a removal of the
# previous verdict, not merely a refusal to write a new one.
check "the stale PASSED verdict is removed, none published" metadata_absent
check "report records the snapshot failure" report_has 'snapshot did not confirm a healthy cluster'
check "overall status FAILED" report_verdict_is FAILED

###########################################
# (a33) The API stays unreachable, so the diagnostic collections fail too.
# Their stderr names the cluster API endpoint and used to be folded into the
# published diagnostics with 2>&1.
###########################################
echo "scenario: persistent_outage (listings and diagnostics all fail)"
run_step persistent_outage
check "step exits non-zero" rc_is 1
check "no endpoint anywhere in the artifacts" artifacts_lack 'openshiftapps.com'
# The whole content, trailing newlines aside, for every artifact the
# diagnostic collector wrote in this run: the command printed nothing, so the
# sanitized line is all the file may hold. "Contains the line" would still
# accept the command's stderr appended beside it, which is the leak this
# scenario exists for.
for outage_artifact in cvo-logs.txt pods-openshift-cluster-version.txt \
                       pods-openshift-kube-apiserver.txt pods-openshift-etcd.txt \
                       pods-openshift-monitoring.txt; do
  check "diagnostics/${outage_artifact} holds only the sanitized line" \
    artifact_is_only_line "diagnostics/${outage_artifact}" '(unavailable: oc exited 1)'
done
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
check "report does not claim nodes READY" report_lacks 'All nodes: READY'
check "overall status FAILED" report_verdict_is FAILED
check "scratch directory removed afterwards" scratch_is_empty

###########################################
# (a34) Harness contracts for this round: membership means an array element,
# and the generated stub must never resolve jq to a shell function.
###########################################
echo "scenario: harness self-checks (membership and interpreter resolution)"
membership_rejects_a_string_field(){
  local probe saved status=0
  probe="$(mktemp -d "${WORKROOT}/member-XXXXXX")" || return 1
  mkdir -p "${probe}/artifacts"
  printf '%s\n' '{"notready_nodes":"prefix-node-a-suffix"}' > "${probe}/artifacts/metadata.json"
  saved="${ARTIFACTS:-}"
  ARTIFACTS="${probe}/artifacts"
  metadata_lists '.notready_nodes' node-a || status=$?
  # And a real array still passes.
  printf '%s\n' '{"notready_nodes":["node-a"]}' > "${probe}/artifacts/metadata.json"
  local positive=0
  metadata_lists '.notready_nodes' node-a || positive=$?
  ARTIFACTS="${saved}"
  [[ "${status}" -ne 0 && "${positive}" -eq 0 ]]
}
# $1 is the external jq the sandbox is expected to embed. Builds a sandbox
# with an exported jq function in scope -- the condition that made command -v
# answer "jq" and the stub exec itself through the sandbox PATH -- and
# compares the emitted token with printf %q of that path. The token is never
# used as a path and never evaluated: %q escaping makes it a shell word, not
# a filename, so testing it with -x would fail for any path containing a
# space. A self-referential stub is still rejected, without running it.
jq_stub_embeds(){
  local expected_jq="$1" dir exec_line token want
  [[ -x "${expected_jq}" ]] || return 1
  # make_sandbox absolutises whatever type -P returned, so a caller passing a
  # relative spelling (PATH can hold relative entries) must be normalised the
  # same way, by the same helper, before the comparison.
  if [[ "${expected_jq}" != /* ]]; then
    expected_jq="$(absolute_file "${expected_jq}")" || return 1
  fi
  jq(){ echo "shell function jq"; }
  export -f jq
  dir="$(make_sandbox jqfn)" || { unset -f jq; return 1; }
  unset -f jq
  exec_line="$(grep -m1 '^exec ' "${dir}/bin/jq")" || return 1
  token="${exec_line#exec }"
  token="${token%% \"\$@\"}"
  want="$(printf '%q' "${expected_jq}")"
  [[ "${token}" == "${want}" ]] || return 1
  # Never the sandbox's own stub, and always absolute once unescaped.
  [[ "${token}" != *"${dir}/bin"* ]] || return 1
  [[ "${expected_jq}" == /* ]]
}
jq_resolution_ignores_a_shell_function(){
  jq_stub_embeds "$(type -P jq)"
}
# A relative PATH entry whose spelling passes through a symlink and then "..".
# The lookup finds real/tools/jq; rewriting that path textually would name
# links/tools instead, a different directory holding a different executable.
jq_stub_handles_a_symlinked_relative_path_entry(){
  local probe want found status
  probe="$(mktemp -d "${WORKROOT}/jqsym-XXXXXX")" || return 1
  mkdir -p "${probe}/real/tools" "${probe}/real/child" "${probe}/links/tools" || return 1
  ln -s ../real/child "${probe}/links/jump" || return 1
  cp "$(absolute_file "$(type -P jq)")" "${probe}/real/tools/jq" || return 1
  chmod 0755 "${probe}/real/tools/jq" || return 1
  # A decoy at the logically-rewritten location. It is never executed: if the
  # normalisation followed the textual path, the sandbox would embed this one
  # and the comparison below would catch it.
  printf '#!/bin/bash\nexit 99\n' > "${probe}/links/tools/jq" || return 1
  chmod 0755 "${probe}/links/tools/jq" || return 1
  # The hazard has to reproduce: the lookup must answer the symlinked spelling.
  found="$(cd "${probe}" && PATH="links/jump/../tools:${PATH}" type -P jq)" || return 1
  [[ "${found}" == "links/jump/../tools/jq" ]] || return 1
  want="$(cd -P "${probe}/real/tools" && pwd -P)/jq" || return 1
  # The staged entry stays relative and first, which is what this probe
  # tests. The inherited entries are resolved from the launch directory, so
  # an inherited relative one still names the harness tools after the cd.
  ( cd "${probe}" \
      && PATH="links/jump/../tools:$(path_from_dir "${LAUNCH_DIR}" "${PATH}")" \
         jq_stub_embeds "${want}" ) || status=$?
  status="${status:-0}"
  rm -rf "${probe}"
  [[ "${status}" -eq 0 ]]
}
jq_stub_handles_a_spaced_path(){
  local probe spaced saved status
  probe="$(mktemp -d "${WORKROOT}/jqpath-XXXXXX")" || return 1
  # A directory name with a space and a shell-special character: %q has to
  # escape both, and the self-check must not mistake the escaped token for a
  # filename.
  spaced="${probe}/tool bin\$x"
  mkdir -p "${spaced}" || return 1
  cp "$(type -P jq)" "${spaced}/jq" || return 1
  chmod 0755 "${spaced}/jq"
  saved="${PATH}"
  PATH="${spaced}:${PATH}"
  status=0
  jq_stub_embeds "${spaced}/jq" || status=$?
  PATH="${saved}"
  [[ "${status}" -eq 0 ]]
}
# An items map keyed by name visits the same rows, so an iteration-only
# assertion accepts a changed publication format. The array requirement is
# what rejects it, and the same rows in an array must still pass.
snapshot_assertions_require_an_items_array(){
  local probe saved object_status=0 array_status=0
  probe="$(mktemp -d "${WORKROOT}/itemsarray-XXXXXX")" || return 1
  mkdir -p "${probe}/artifacts" || return 1
  saved="${ARTIFACTS:-}"
  ARTIFACTS="${probe}/artifacts"
  printf '%s\n' '{"items":{"node-a":{"name":"node-a","ready":true}}}' > "${probe}/artifacts/nodes.json"
  snapshot_has_item nodes.json node-a && object_status=1
  snapshot_lacks_item nodes.json node-z && object_status=$((object_status + 2))
  snapshot_item_field nodes.json node-a ready true && object_status=$((object_status + 4))
  printf '%s\n' '{"items":[{"name":"node-a","ready":true}]}' > "${probe}/artifacts/nodes.json"
  snapshot_has_item nodes.json node-a || array_status=1
  snapshot_lacks_item nodes.json node-z || array_status=$((array_status + 2))
  snapshot_item_field nodes.json node-a ready true || array_status=$((array_status + 4))
  ARTIFACTS="${saved}"
  rm -rf "${probe}"
  [[ "${object_status}" -eq 0 && "${array_status}" -eq 0 ]]
}
# The diagnostic stub answers a management-only call made with the hosted
# kubeconfig with its own status, distinct from the API error an outage
# scenario expects, and records it where an assertion can see it.
diagnostic_stub_rejects_the_hosted_kubeconfig(){
  local dir status=0
  dir="$(make_sandbox diagkubeconfig)" || return 1
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster -n ocm-staging-fake-cluster-id --ignore-not-found -o wide \
    >/dev/null 2>"${dir}/diag.err" || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  [[ -s "${dir}/state/diagnostic-wrong-kubeconfig" ]] || return 1
  # And the same call with the management kubeconfig is answered normally.
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster -n ocm-staging-fake-cluster-id --ignore-not-found -o wide \
    >"${dir}/diag.out" 2>/dev/null || status=$?
  [[ "${status}" -eq 0 ]] && grep -qF 'HCP-HOSTEDCLUSTER-OUTPUT' "${dir}/diag.out"
}
# Prologue mode is selected by an argument, so an inherited variable cannot
# turn an ordinary run into one that asserts nothing. Every nested run here is
# bounded: each either answers in prologue mode or stops at the step-script
# check, so a regression in the argument handling cannot make this probe
# re-enter the whole suite.
suite_ignores_an_inherited_prologue_variable(){
  local value out rc
  for value in 0 1; do
    rc=0
    out="$(GAP_TEST_PRINT_WORKROOT="${value}" STEP_UNDER_TEST=/nonexistent-routing-step.sh \
           bash "${SUITE_PATH}" < /dev/null 2>&1)" || rc=$?
    # Prologue mode would have printed a work root and exited zero.
    [[ "${rc}" -eq 1 ]] || return 1
    [[ "${out}" == *"step script not found"* ]] || return 1
  done
  # The dedicated argument still selects prologue mode, and nothing else does.
  rc=0
  # TMPDIR is pinned under this suite's own work root, so even a child that is
  # killed before its trap runs cannot leave a directory outside it.
  out="$(TMPDIR="${WORKROOT}" bash "${SUITE_PATH}" --print-workroot < /dev/null)" || return 1
  [[ "${out}" == "${WORKROOT}"/* ]] || return 1
  [[ "$(printf '%s' "${out}" | wc -l)" -eq 0 ]] || return 1
  [[ ! -e "${out}" ]] || return 1
  # An unknown argument is fatal, and the step override bounds this run too in
  # case the argument guard itself is what regressed.
  out="$(STEP_UNDER_TEST=/nonexistent-routing-step.sh \
         bash "${SUITE_PATH}" --not-a-mode < /dev/null 2>&1)" || rc=$?
  [[ "${rc}" -eq 1 && "${out}" == *"unknown argument"* ]]
}
# A duplicate row for one name makes the field filter a generator, and jq -e
# answers with the last result: a contradicting pair would read as its second
# half. The helper must require exactly one matching row.
snapshot_item_field_requires_one_row(){
  local probe saved status=0
  probe="$(mktemp -d "${WORKROOT}/onerow-XXXXXX")" || return 1
  mkdir -p "${probe}/artifacts" || return 1
  saved="${ARTIFACTS:-}"
  ARTIFACTS="${probe}/artifacts"
  # One matching row: the only shape that may pass.
  printf '%s\n' '{"items":[{"name":"node-a","ready":"True"}]}' > "${probe}/artifacts/nodes.json"
  snapshot_item_field nodes.json node-a ready '"True"' || status=1
  # No matching row.
  printf '%s\n' '{"items":[{"name":"node-b","ready":"True"}]}' > "${probe}/artifacts/nodes.json"
  snapshot_item_field nodes.json node-a ready '"True"' && status=$((status + 2))
  # Two matching rows, False first then True: the hazard the review named.
  printf '%s\n' '{"items":[{"name":"node-a","ready":"False"},{"name":"node-a","ready":"True"}]}' > "${probe}/artifacts/nodes.json"
  snapshot_item_field nodes.json node-a ready '"True"' && status=$((status + 4))
  # And the reverse order, so neither half can be read as the answer.
  printf '%s\n' '{"items":[{"name":"node-a","ready":"True"},{"name":"node-a","ready":"False"}]}' > "${probe}/artifacts/nodes.json"
  snapshot_item_field nodes.json node-a ready '"True"' && status=$((status + 8))
  snapshot_item_field nodes.json node-a ready '"False"' && status=$((status + 16))
  ARTIFACTS="${saved}"
  rm -rf "${probe}"
  [[ "${status}" -eq 0 ]]
}
# The two-document fixture check must reject everything that is not exactly
# two list documents, or the scenario could stop testing concatenation.
two_document_check_rejects_other_shapes(){
  local status=0
  printf '%s\n' 'not json at all' | payload_is_two_documents && status=1
  printf '%s\n' '{"items":[]}' | payload_is_two_documents && status=$((status + 2))
  printf '%s\n' '{"items":[]}' '{"items":[]}' '{"items":[]}' | payload_is_two_documents && status=$((status + 4))
  printf '%s\n' '1' '2' | payload_is_two_documents && status=$((status + 8))
  printf '%s\n' '{"items":[]}' '{"notitems":[]}' | payload_is_two_documents && status=$((status + 16))
  # The shape the stub fixture emits still passes.
  printf '%s\n' '{"items":[]}' \
    '{"items":[{"metadata":{"name":"authentication"},"status":{"conditions":[{"type":"Available","status":"True"}]}}]}' \
    | payload_is_two_documents || status=$((status + 32))
  [[ "${status}" -eq 0 ]]
}
# The injected Ready-query failure must print a name and then fail: a failure
# with no output would let a missing discard in the step pass unnoticed.
notready_jq_fixture_emits_then_fails(){
  local dir out status=0
  dir="$(make_sandbox notreadyfixture)" || return 1
  printf '%s\n' '{"items":[]}' > "${dir}/nodes.json"
  out="$(OC_SCENARIO=report_notready_jq_fails "${dir}/bin/jq" -r --arg condition Ready \
         '.items[]? | select([.status.conditions[]? | select(.type == $condition) | .status] | (length > 0 and all(. == "True")) | not) | .metadata.name' \
         "${dir}/nodes.json" 2>"${dir}/jq.err")" || status=$?
  [[ "${status}" -eq 5 ]] || return 1
  [[ "${out}" == "node-b" ]] || return 1
  grep -qF 'simulated processing failure' "${dir}/jq.err"
}
# One verdict line, and the whole line must match: a report that kept an
# earlier PASSED and appended FAILED is self-contradictory, and neither the
# exit code nor the metadata would catch it.
report_verdict_assertion_requires_one_line(){
  local probe saved status=0
  probe="$(mktemp -d "${WORKROOT}/verdict-XXXXXX")" || return 1
  mkdir -p "${probe}/artifacts/diagnostics" || return 1
  saved="${REPORT:-}"
  REPORT="${probe}/artifacts/diagnostics/report.txt"
  : > "${REPORT}"
  report_verdict_is FAILED && status=1                      # no verdict at all
  printf '%s\n' 'Overall Status: FAILED' > "${REPORT}"
  report_verdict_is FAILED || status=$((status + 2))        # the only valid case
  report_verdict_is PASSED && status=$((status + 4))        # wrong verdict
  printf '%s\n' 'Overall Status: PASSED' 'Overall Status: FAILED' > "${REPORT}"
  report_verdict_is FAILED && status=$((status + 8))        # conflicting pair
  report_verdict_is PASSED && status=$((status + 16))
  printf '%s\n' 'Overall Status: FAILED' 'Overall Status: FAILED' > "${REPORT}"
  report_verdict_is FAILED && status=$((status + 32))       # duplicated verdict
  printf '%s\n' 'Overall Status: FAILED (snapshot)' > "${REPORT}"
  report_verdict_is FAILED && status=$((status + 64))       # trailing suffix
  REPORT="${saved}"
  rm -rf "${probe}"
  [[ "${status}" -eq 0 ]]
}
# The seeded artifact must really be a valid PASSED snapshot, or the removal
# assertions above would be vacuous.
seeded_metadata_is_valid_passed(){
  local probe
  probe="$(mktemp -d "${WORKROOT}/seedmeta-XXXXXX")" || return 1
  seed_passed_metadata "${probe}/artifacts" || return 1
  [[ -f "${probe}/artifacts/metadata.json" ]] || return 1
  jq -e '.overall_status == "PASSED"' "${probe}/artifacts/metadata.json" >/dev/null || return 1
  rm -rf "${probe}"
}
check "membership requires an array element, not a substring" membership_rejects_a_string_field
check "the seeded previous snapshot is a valid PASSED artifact" seeded_metadata_is_valid_passed
# A mistyped resource must be answered by neither the success marker nor the
# outage error: a substring match would hand a collector typo the answer the
# scenario expects.
diagnostic_stub_rejects_a_mistyped_resource(){
  local dir out status=0
  dir="$(make_sandbox diagtypo)" || return 1
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get hostedclusterz -n ocm-staging-fake-cluster-id -o wide 2>/dev/null)" || status=$?
  [[ "${status}" -eq 0 && "${out}" != *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
  status=0
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics_outage OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get hostedclusterz -n ocm-staging-fake-cluster-id -o wide 2>/dev/null)" || status=$?
  [[ "${status}" -eq 0 ]] || return 1
  # The intended resource still gets its marker and its outage error.
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get hostedcluster -n ocm-staging-fake-cluster-id -o wide 2>/dev/null)" || return 1
  [[ "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics_outage OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster -n ocm-staging-fake-cluster-id -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 ]]
}
# A payload path whose own name contains a program selector must not be read
# as the program: the injection belongs to the query, not to the directory a
# fixture happens to live in.
jq_stub_matches_the_program_not_the_path(){
  local dir poisoned status=0
  dir="$(make_sandbox jqprogram)" || return 1
  poisoned="${dir}/select(.type == \$condition)"
  mkdir -p "${poisoned}" || return 1
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' \
    > "${poisoned}/classic-snapshot-nodes.json" || return 1
  # The count query is not the health list, so the health-list injection must
  # leave it alone even though its payload path carries the selector text.
  OC_SCENARIO=snapshot_health_list_fails "${dir}/bin/jq" -r '.items | length' \
    "${poisoned}/classic-snapshot-nodes.json" >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]] || return 1
  # The health list itself is still injected.
  status=0
  OC_SCENARIO=snapshot_health_list_fails "${dir}/bin/jq" -r --arg condition Ready \
    '.items[]? | select([.status.conditions[]? | select(.type == $condition) | .status] | (length > 0 and all(. == "True")) | not) | .metadata.name' \
    "${poisoned}/classic-snapshot-nodes.json" >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 5 ]]
}
# The two cvo alternatives are keyed on whole arguments too: a suffixed
# deployment or selector must get neither the intended answer nor a recorded
# lookup, while the real calls still do.
diagnostic_stub_rejects_a_mistyped_cvo_call(){
  local dir status=0 ns="ocm-staging-fake-cluster-id-dp"
  dir="$(make_sandbox diagcvotypo)" || return 1
  cvo(){
    status=0
    KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO="$1" OCM_LOGIN_ENV=staging \
      "${dir}/bin/oc" "${@:2}" >"${dir}/cvo.out" 2>/dev/null || status=$?
  }
  # A suffixed deployment is not the first alternative: no API error, no record.
  cvo hcp_diagnostics logs deployment/cluster-version-operatorz -n "${ns}" --tail=500
  [[ "${status}" -eq 0 ]] || return 1
  [[ ! -e "${dir}/state/cvo-lookups" ]] || return 1
  # A suffixed selector is not the fallback: no marker, no record.
  cvo hcp_diagnostics logs -n "${ns}" -l app=cluster-version-operatorz --tail=500
  [[ "${status}" -eq 0 ]] || return 1
  [[ "$(cat "${dir}/cvo.out")" != *"CVO-LOG-FROM-LABEL-SELECTOR"* ]] || return 1
  [[ ! -e "${dir}/state/cvo-lookups" ]] || return 1
  # The same typo in the outage scenario is not the expected API error either.
  cvo hcp_diagnostics_outage logs -n "${ns}" -l app=cluster-version-operatorz --tail=500
  [[ "${status}" -eq 0 ]] || return 1
  # The intended calls still behave: deployment fails first, selector answers.
  cvo hcp_diagnostics logs deployment/cluster-version-operator -n "${ns}" --tail=500
  [[ "${status}" -eq 1 ]] || return 1
  cvo hcp_diagnostics logs -n "${ns}" -l app=cluster-version-operator --tail=500
  [[ "${status}" -eq 0 ]] || return 1
  [[ "$(cat "${dir}/cvo.out")" == *"CVO-LOG-FROM-LABEL-SELECTOR"* ]] || return 1
  [[ "$(cat "${dir}/state/cvo-lookups")" == "$(printf '%s\n' deployment selector)" ]]
}
# The snapshot Ready health list names a node before failing, so the discard
# the step performs is observable; the count and shape queries are untouched.
snapshot_health_fixture_emits_then_fails(){
  local dir out status=0
  dir="$(make_sandbox snaphealthfixture)" || return 1
  printf '%s\n' '{"items":[{"metadata":{"name":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' \
    > "${dir}/classic-snapshot-nodes.json" || return 1
  out="$(OC_SCENARIO=snapshot_health_list_fails "${dir}/bin/jq" -r --arg condition Ready \
         '.items[]? | select([.status.conditions[]? | select(.type == $condition) | .status] | (length > 0 and all(. == "True")) | not) | .metadata.name' \
         "${dir}/classic-snapshot-nodes.json" 2>"${dir}/jq.err")" || status=$?
  [[ "${status}" -eq 5 ]] || return 1
  [[ "${out}" == "node-b" ]] || return 1
  grep -qF 'simulated processing failure' "${dir}/jq.err" || return 1
  # The count and shape queries on the same payload are not injected.
  status=0
  OC_SCENARIO=snapshot_health_list_fails "${dir}/bin/jq" -r '.items | length' \
    "${dir}/classic-snapshot-nodes.json" >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]] || return 1
  status=0
  OC_SCENARIO=snapshot_health_list_fails "${dir}/bin/jq" -es 'length == 1' \
    "${dir}/classic-snapshot-nodes.json" >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]]
}
# oc prefers an explicit --kubeconfig over the environment: a diagnostic that
# passed the hosted kubeconfig while KUBECONFIG named the management one is a
# mismatch, whichever spelling it used, and the environment-only management
# call stays the positive control.
diagnostic_stub_honours_an_explicit_kubeconfig(){
  local dir status=0 out ns="ocm-staging-fake-cluster-id"
  dir="$(make_sandbox diagexplicitkc)" || return 1
  # Management environment, hosted kubeconfig passed explicitly: a mismatch.
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster --kubeconfig "${dir}/shared/kubeconfig" -n "${ns}" -o wide \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster "--kubeconfig=${dir}/shared/kubeconfig" -n "${ns}" -o wide \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  [[ "$(wc -l < "${dir}/state/diagnostic-wrong-kubeconfig")" -eq 2 ]] || return 1
  # The same mismatch in the outage scenario is still 66, not the API error.
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics_outage OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster --kubeconfig "${dir}/shared/kubeconfig" -n "${ns}" -o wide \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  # Environment-only management, and an explicit management kubeconfig, both
  # answer normally; the namespace guard still applies to them.
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get hostedcluster -n "${ns}" -o wide 2>/dev/null)" || return 1
  [[ "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
  out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get hostedcluster --kubeconfig "${dir}/shared/hs-mc.kubeconfig" -n "${ns}" -o wide 2>/dev/null)" || return 1
  [[ "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster --kubeconfig "${dir}/shared/hs-mc.kubeconfig" -n wrong-ns -o wide \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 67 ]]
}
# Only the fixture's own management kubeconfig is the management cluster. A
# path that merely ends in hs-mc.kubeconfig names a file real oc cannot load,
# so answering it as a management diagnostic would hide a collector that built
# the wrong path.
diagnostic_stub_requires_the_fixture_management_kubeconfig(){
  local dir status=0 out scenario ns="ocm-staging-fake-cluster-id"
  local good bad
  dir="$(make_sandbox diagexactkc)" || return 1
  good="${dir}/shared/hs-mc.kubeconfig"
  bad="${dir}/shared/missing/hs-mc.kubeconfig"
  kc(){
    status=0
    out="$(KUBECONFIG="$1" OC_SCENARIO="$2" OCM_LOGIN_ENV=staging \
           "${dir}/bin/oc" "${@:3}" 2>/dev/null)" || status=$?
  }
  for scenario in hcp_diagnostics hcp_diagnostics_outage; do
    # Same basename, wrong directory: a mismatch in both spellings, and in
    # the outage scenario too, where it must not be read as the API error.
    kc "${good}" "${scenario}" get hostedcluster --kubeconfig "${bad}" -n "${ns}" -o wide
    [[ "${status}" -eq 66 ]] || return 1
    kc "${good}" "${scenario}" get hostedcluster "--kubeconfig=${bad}" -n "${ns}" -o wide
    [[ "${status}" -eq 66 ]] || return 1
    # The environment is no safer than the flag: a wrong path there is a
    # mismatch too.
    kc "${bad}" "${scenario}" get hostedcluster -n "${ns}" -o wide
    [[ "${status}" -eq 66 ]] || return 1
    # The last --kubeconfig wins in both directions.
    kc "${good}" "${scenario}" get hostedcluster --kubeconfig "${good}" --kubeconfig "${bad}" -n "${ns}" -o wide
    [[ "${status}" -eq 66 ]] || return 1
    kc "${bad}" "${scenario}" get hostedcluster --kubeconfig "${bad}" --kubeconfig "${good}" -n "${ns}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    # The two positives the fixture is built on: the environment alone, and
    # the exact fixture path passed explicitly, in either spelling.
    kc "${good}" "${scenario}" get hostedcluster -n "${ns}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    kc "${dir}/shared/kubeconfig" "${scenario}" get hostedcluster --kubeconfig "${good}" -n "${ns}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    kc "${dir}/shared/kubeconfig" "${scenario}" get hostedcluster "--kubeconfig=${good}" -n "${ns}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    # A valueless --kubeconfig at the end is an error to oc, which runs
    # nothing: the fixture refuses the call before dispatching it, so neither
    # scenario answers with its marker or with the simulated API error.
    kc "${good}" "${scenario}" get hostedcluster -n "${ns}" -o wide --kubeconfig
    [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
    kc "${good}" "${scenario}" get hostedcluster --kubeconfig "${good}" -n "${ns}" -o wide --kubeconfig
    [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
    # The refusal happens before the guards, so it is not recorded as one of
    # the diagnostic mismatches either.
    kc "${dir}/shared/kubeconfig" "${scenario}" get hostedcluster -n wrong-ns -o wide --kubeconfig
    [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
    # The same call with the management kubeconfig would otherwise reach the
    # namespace guard, so this one proves the parse error comes first.
    kc "${good}" "${scenario}" get hostedcluster -n wrong-ns -o wide --kubeconfig
    [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
  done
  # Four refusals per scenario were recorded as kubeconfig mismatches. The
  # kubeconfig is checked before the namespace and all-namespaces guards, so
  # none of these calls may appear in those records either.
  [[ "$(wc -l < "${dir}/state/diagnostic-wrong-kubeconfig")" -eq 8 ]] || return 1
  [[ ! -e "${dir}/state/diagnostic-wrong-namespace" ]] || return 1
  [[ ! -e "${dir}/state/diagnostic-all-namespaces" ]] || return 1
  # The management snapshot reads are still answered from the management
  # payloads, so the stricter match did not cut the management captures off.
  out="$(KUBECONFIG="${good}" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get nodes -o json 2>/dev/null)" || return 1
  [[ "${out}" == *"mgmt-node-1"* ]] || return 1
  out="$(KUBECONFIG="${bad}" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get nodes -o json 2>/dev/null)" || return 1
  [[ "${out}" != *"mgmt-node-1"* ]]
}
# The last selector decides which pods oc would read, whatever spelling it is
# written in, so the fixture must parse the inline forms before it records or
# answers a cvo lookup.
diagnostic_stub_uses_the_last_cvo_selector(){
  local dir status=0 scenario ns="ocm-staging-fake-cluster-id-dp"
  dir="$(make_sandbox diagcvolast)" || return 1
  sel(){
    status=0
    KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO="$1" OCM_LOGIN_ENV=staging \
      "${dir}/bin/oc" "${@:2}" >"${dir}/sel.out" 2>/dev/null || status=$?
  }
  marker(){ [[ "$(cat "${dir}/sel.out")" == *"CVO-LOG-FROM-LABEL-SELECTOR"* ]]; }
  for scenario in hcp_diagnostics hcp_diagnostics_outage; do
    # A later non-cvo selector overrides the cvo one: neither recorded nor
    # answered, in either inline spelling.
    sel "${scenario}" logs -n "${ns}" -l app=cluster-version-operator --selector=app=other --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    [[ ! -e "${dir}/state/cvo-lookups" ]] || return 1
    sel "${scenario}" logs -n "${ns}" -l app=cluster-version-operator -l=app=other --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    [[ ! -e "${dir}/state/cvo-lookups" ]] || return 1
    sel "${scenario}" logs -n "${ns}" -l app=cluster-version-operator -lapp=other --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    [[ ! -e "${dir}/state/cvo-lookups" ]] || return 1
  done
  # The inline cvo selector on its own is the fallback, and so is a correct
  # selector that overrides an earlier wrong one, in every spelling.
  local spelling
  for spelling in "--selector=app=cluster-version-operator" "-l=app=cluster-version-operator" \
                  "-lapp=cluster-version-operator"; do
    sel hcp_diagnostics logs -n "${ns}" "${spelling}" --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    marker || return 1
    sel hcp_diagnostics logs -n "${ns}" --selector=app=other "${spelling}" --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    marker || return 1
    sel hcp_diagnostics logs -n "${ns}" -l app=other "${spelling}" --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    marker || return 1
    # The same calls in the outage scenario answer with the API error.
    sel hcp_diagnostics_outage logs -n "${ns}" "${spelling}" --tail=500
    [[ "${status}" -eq 1 ]] || return 1
  done
  # Twelve accepted fallbacks were recorded, all as the selector alternative.
  [[ "$(wc -l < "${dir}/state/cvo-lookups")" -eq 12 ]] || return 1
  [[ -z "$(grep -v '^selector$' "${dir}/state/cvo-lookups")" ]] || return 1
  # The guards still come first for an inline selector: the kubeconfig, the
  # namespace and the all-namespaces refusals keep their own statuses.
  status=0
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" logs -n "${ns}" --selector=app=cluster-version-operator --tail=500 \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  sel hcp_diagnostics logs -n wrong-ns --selector=app=cluster-version-operator --tail=500
  [[ "${status}" -eq 67 ]] || return 1
  sel hcp_diagnostics logs -n "${ns}" -A --selector=app=cluster-version-operator --tail=500
  [[ "${status}" -eq 68 ]] || return 1
  # A pod name alongside the selector is not the fallback: oc refuses that
  # combination, so it is neither recorded nor answered, in both scenarios
  # and with either --tail spelling.
  for scenario in hcp_diagnostics hcp_diagnostics_outage; do
    sel "${scenario}" logs pod-a -n "${ns}" -l app=cluster-version-operator --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    sel "${scenario}" logs pod-a -n "${ns}" --selector=app=cluster-version-operator --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    sel "${scenario}" logs pod-a -n "${ns}" -l app=cluster-version-operator --tail 500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
  done
  # Not recorded either: the count is still the twelve accepted fallbacks.
  [[ "$(wc -l < "${dir}/state/cvo-lookups")" -eq 12 ]] || return 1
  # The selector-only call is still the positive control, in both scenarios
  # and in both --tail spellings: oc reads them identically, so the fixture
  # must too. The separate form is the one that used to leave its number
  # standing as a pod name.
  local tail_form
  for tail_form in "--tail=500" "--tail 500"; do
    # shellcheck disable=SC2086 # the spelling under test includes its own split
    sel hcp_diagnostics logs -n "${ns}" -l app=cluster-version-operator ${tail_form}
    [[ "${status}" -eq 0 ]] || return 1
    marker || return 1
    # shellcheck disable=SC2086
    sel hcp_diagnostics logs -n "${ns}" --selector=app=cluster-version-operator ${tail_form}
    [[ "${status}" -eq 0 ]] || return 1
    marker || return 1
    # shellcheck disable=SC2086
    sel hcp_diagnostics_outage logs -n "${ns}" -l app=cluster-version-operator ${tail_form}
    [[ "${status}" -eq 1 ]] || return 1
    # The deployment-first order and the guards are asserted above for the
    # inline spelling; here they are re-asserted for the separate one, which
    # is the spelling whose value used to be read as a pod name.
    if [[ "${tail_form}" == "--tail 500" ]]; then
      sel hcp_diagnostics logs deployment/cluster-version-operator -n "${ns}" --tail 500
      [[ "${status}" -eq 1 ]] || return 1
      status=0
      KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
        "${dir}/bin/oc" logs -n "${ns}" -l app=cluster-version-operator --tail 500 \
        >/dev/null 2>&1 || status=$?
      [[ "${status}" -eq 66 ]] || return 1
      sel hcp_diagnostics logs -n wrong-ns -l app=cluster-version-operator --tail 500
      [[ "${status}" -eq 67 ]] || return 1
      sel hcp_diagnostics logs -n "${ns}" -A -l app=cluster-version-operator --tail 500
      [[ "${status}" -eq 68 ]] || return 1
    fi
  done
  # Options end at a standalone --: a selector written after it is a
  # positional argument to oc, which rejects the call, so the fixture
  # neither records the lookup nor answers it -- in both scenarios and in
  # the attached, equals and separate spellings. The selector before the
  # terminator stays the positive control.
  local before
  before="$(wc -l < "${dir}/state/cvo-lookups")" || return 1
  for scenario in hcp_diagnostics hcp_diagnostics_outage; do
    sel "${scenario}" logs -n "${ns}" -- -lapp=cluster-version-operator --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    sel "${scenario}" logs -n "${ns}" -- --selector=app=cluster-version-operator --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    sel "${scenario}" logs -n "${ns}" -- -l app=cluster-version-operator --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
    sel "${scenario}" logs -n "${ns}" -- -l=app=cluster-version-operator --tail=500
    [[ "${status}" -eq 0 ]] || return 1
    ! marker || return 1
  done
  [[ "$(wc -l < "${dir}/state/cvo-lookups")" -eq "${before}" ]] || return 1
  # The same selector before the terminator is still the fallback.
  sel hcp_diagnostics logs -n "${ns}" -l app=cluster-version-operator --tail=500 --
  [[ "${status}" -eq 0 ]] || return 1
  marker || return 1
  sel hcp_diagnostics_outage logs -n "${ns}" -l app=cluster-version-operator --tail=500 --
  [[ "${status}" -eq 1 ]] || return 1
  # A -- that answers a pending selector is that option's value, not a
  # terminator, and "--" is not the cvo selector.
  sel hcp_diagnostics logs -n "${ns}" -l -- --tail=500
  [[ "${status}" -eq 0 ]] || return 1
  ! marker || return 1
  # The namespace scan stops there too: a namespace written after the
  # terminator does not scope the call, so the guard still fires.
  sel hcp_diagnostics logs -l app=cluster-version-operator --tail=500 -- -n "${ns}"
  [[ "${status}" -eq 67 ]] || return 1
  # A valueless --tail is an error to oc, which collects nothing, so it is
  # not the fallback either.
  sel hcp_diagnostics logs -n "${ns}" -l app=cluster-version-operator --tail
  [[ "${status}" -eq 2 ]] || return 1
  ! marker || return 1
  # A valueless selector at the end is an error, not a reason to keep the
  # earlier one, whichever spelling opened it.
  sel hcp_diagnostics logs -n "${ns}" -l app=cluster-version-operator --tail=500 -l
  [[ "${status}" -eq 2 ]] || return 1
  ! marker || return 1
  sel hcp_diagnostics logs -n "${ns}" --selector=app=cluster-version-operator --tail=500 --selector
  [[ "${status}" -eq 2 ]] || return 1
  ! marker || return 1
  # And the deployment alternative is still tried first and still fails first.
  sel hcp_diagnostics logs deployment/cluster-version-operator -n "${ns}" --tail=500
  [[ "${status}" -eq 1 ]] || return 1
  sel hcp_diagnostics logs -n "${ns}" --selector=app=cluster-version-operator --tail=500
  [[ "${status}" -eq 0 ]] && marker
}
# The absence helpers answer "absent" only for grep's no-match status. A file
# they cannot read answers 2, and a bare negation would turn that into a pass
# that checked nothing at all.
absence_helpers_require_a_real_no_match(){
  local dir result=0
  local saved_report="${REPORT}" saved_stderr="${STDERR}" saved_path="${PATH}"
  local saved_artifacts="${ARTIFACTS}"
  dir="$(mktemp -d "${WORKROOT}/absence-XXXXXX")" || return 1
  [[ -n "${dir}" && -d "${dir}" ]] || return 1
  REPORT="${dir}/report.txt"
  STDERR="${dir}/stderr.log"
  printf '%s\n' 'cluster is HEALTHY' > "${REPORT}" || result=1
  cp -- "${REPORT}" "${STDERR}" || result=1
  # A match is not an absence, and a real no-match is.
  report_lacks 'HEALTHY' && result=1
  report_lacks 'NOT-IN-THE-FILE' || result=1
  stderr_lacks 'HEALTHY' && result=1
  stderr_lacks 'NOT-IN-THE-FILE' || result=1
  # A missing file is not an absence either: the step may have died before
  # writing anything.
  REPORT="${dir}/not-written.txt"
  STDERR="${dir}/not-written.log"
  report_lacks 'NOT-IN-THE-FILE' && result=1
  stderr_lacks 'NOT-IN-THE-FILE' && result=1
  # A directory at the path is not an absence either. The helpers answer that
  # from the regular-file check, without consulting grep at all, so the answer
  # does not depend on which status a particular grep reports for a path it
  # cannot read as a file.
  mkdir -p "${dir}/as-a-directory" || result=1
  REPORT="${dir}/as-a-directory"
  STDERR="${dir}/as-a-directory"
  report_lacks 'NOT-IN-THE-FILE' && result=1
  stderr_lacks 'NOT-IN-THE-FILE' && result=1
  # A read error is not an absence. Deterministic for any user, including
  # root: a grep on PATH that answers 2, the status it uses for a file it
  # cannot read.
  mkdir -p "${dir}/bin" || result=1
  # Silent: the status is the whole point, and a message on the suite's own
  # stderr would read like a failure in a passing run.
  printf '%s\n' '#!/bin/bash' 'exit 2' > "${dir}/bin/grep" || result=1
  chmod +x "${dir}/bin/grep" || result=1
  REPORT="${dir}/report.txt"
  STDERR="${dir}/stderr.log"
  PATH="${dir}/bin:${PATH}"
  report_lacks 'NOT-IN-THE-FILE' && result=1
  stderr_lacks 'NOT-IN-THE-FILE' && result=1
  # The file checks are what make the answer independent of how a particular
  # grep reports an unusable path: with a grep that answers "no match" for a
  # file that is not there at all, only those checks can tell the two apart.
  printf '%s\n' '#!/bin/bash' 'exit 1' > "${dir}/bin/grep" || result=1
  REPORT="${dir}/not-written.txt"
  STDERR="${dir}/not-written.log"
  report_lacks 'NOT-IN-THE-FILE' && result=1
  stderr_lacks 'NOT-IN-THE-FILE' && result=1
  printf '%s\n' '#!/bin/bash' 'exit 2' > "${dir}/bin/grep" || result=1
  REPORT="${dir}/report.txt"
  STDERR="${dir}/stderr.log"
  # artifacts_lack, which already had this guard, agrees on every answer.
  ARTIFACTS="${dir}"
  artifacts_lack 'NOT-IN-THE-FILE' && result=1
  # The real grep from here on.
  PATH="${saved_path}"
  artifacts_lack 'HEALTHY' && result=1
  artifacts_lack 'NOT-IN-THE-FILE' || result=1
  ARTIFACTS="${saved_artifacts}"
  REPORT="${saved_report}"
  STDERR="${saved_stderr}"
  return "${result}"
}
# Non-interactive bash reads the file named by BASH_ENV before it runs a
# script, and the generated stubs are bash scripts, so an inherited BASH_ENV
# that exported KUBECONFIG would decide which cluster a direct fixture probe
# appears to talk to. The suite clears it for the children it starts; the
# file written here shows what that is protecting against.
direct_probes_run_without_an_inherited_bash_env(){
  local dir status=0 out ns="ocm-staging-fake-cluster-id"
  [[ -z "${BASH_ENV+set}" ]] || return 1
  dir="$(make_sandbox bashenv)" || return 1
  { printf 'export GAP_TEST_BASH_ENV_SENTINEL=loaded\n'
    printf 'export KUBECONFIG=%q\n' "${dir}/shared/kubeconfig"; } > "${dir}/bash-env.sh" || return 1
  # Bash expands the BASH_ENV value before using it as a filename, so a path
  # holding a literal dollar sign cannot be written there directly. The
  # literal path travels in its own variable and BASH_ENV names that
  # variable, which bash expands back to the path itself -- so the file is
  # found whatever the path contains, and the assertions below never have to
  # be skipped. The file only exports a sentinel and a sandbox kubeconfig
  # path: no client, credential or real cluster is involved.
  local sourced=""
  sourced="$(BASH_ENV_FILE="${dir}/bash-env.sh" BASH_ENV='${BASH_ENV_FILE}' \
             bash -c 'printf "%s %s" "${GAP_TEST_BASH_ENV_SENTINEL:-unset}" "${KUBECONFIG:-}"')" || return 1
  [[ "${sourced}" == "loaded ${dir}/shared/kubeconfig" ]] || return 1
  # With such a file in effect the stub reads the hosted kubeconfig and
  # refuses the diagnostic, whatever the caller set.
  BASH_ENV_FILE="${dir}/bash-env.sh" BASH_ENV='${BASH_ENV_FILE}' \
    KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" \
    OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster -n "${ns}" -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  # Cleared, the same call is answered from the management kubeconfig the
  # probe actually passed.
  status=0
  out="$(BASH_ENV='' KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics \
         OCM_LOGIN_ENV=staging "${dir}/bin/oc" get hostedcluster -n "${ns}" -o wide 2>/dev/null)" || status=$?
  [[ "${status}" -eq 0 && "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
  # The hosted kubeconfig stays the negative control.
  status=0
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster -n "${ns}" -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  # The same, from a directory whose own name holds a literal dollar sign:
  # the indirection is what makes the file findable there, so the sourced
  # check must hold for this path too.
  local dollar
  dollar="$(mktemp -d "${WORKROOT}/bashenv-\$literal-XXXXXX")" || return 1
  [[ "${dollar}" == *'$literal'* ]] || return 1
  # A distinct sentinel, so this case cannot pass by sourcing the other file.
  { printf 'export GAP_TEST_BASH_ENV_SENTINEL=loaded-dollar\n'
    printf 'export KUBECONFIG=%q\n' "${dir}/shared/kubeconfig"; } > "${dollar}/bash-env.sh" || return 1
  sourced="$(BASH_ENV_FILE="${dollar}/bash-env.sh" BASH_ENV='${BASH_ENV_FILE}' \
             bash -c 'printf "%s %s" "${GAP_TEST_BASH_ENV_SENTINEL:-unset}" "${KUBECONFIG:-}"')" || return 1
  [[ "${sourced}" == "loaded-dollar ${dir}/shared/kubeconfig" ]] || return 1
  rm -rf "${dollar}"
  [[ -z "${BASH_ENV+set}" ]]
}
# Order preserved, relative and empty entries rewritten, absolute entries
# untouched, nothing added, dropped or reordered.
path_rewrite_keeps_every_entry_in_place(){
  [[ "$(path_from_dir /base 'a:/b::c/../d')" == "/base/a:/b:/base:/base/c/../d" ]] || return 1
  [[ "$(path_from_dir /base/ a)" == "/base/a" ]] || return 1
  [[ "$(path_from_dir /base /only)" == "/only" ]] || return 1
  [[ "$(path_from_dir /base 'a:')" == "/base/a:/base" ]] || return 1
  # A base of / still rewrites an empty entry, which means the current
  # directory to the shell.
  [[ "$(path_from_dir / 'a::b')" == "/a:/:/b" ]] || return 1
  # Entries with spaces and shell-special characters pass through unharmed.
  [[ "$(path_from_dir '/ba se' 'to ol$x')" == "/ba se/to ol\$x" ]]
}
# The suite can be launched with a relative PATH entry that holds the tools
# it needs. Four probes change directory before they run a tool -- two jq
# lookups, the prologue re-run and the relative-TMPDIR mktemp -- and an
# inherited relative entry would stop naming those tools from there: the
# suite would then report a jq regression for a missing mktemp.
relative_path_entries_survive_a_probe_directory_change(){
  local launch tool found result=0
  launch="$(mktemp -d "${WORKROOT}/launchpath-XXXXXX")" || return 1
  [[ -n "${launch}" && -d "${launch}" ]] || return 1
  mkdir -p "${launch}/tools" "${launch}/elsewhere" || return 1
  for tool in bash mktemp mkdir ln cp chmod rm grep cat jq date basename dirname; do
    found="$(type -P "${tool}")" || return 1
    ln -s "$(absolute_file "${found}")" "${launch}/tools/${tool}" || return 1
  done
  # The launch directory is the one the suite was started in, absolute and
  # resolved; the subshells below override it deliberately, so this is
  # asserted first.
  [[ "${LAUNCH_DIR}" == /* && "${LAUNCH_DIR}" == "$(absolute_dir .)" ]] || result=1
  # The hazard itself: from another directory the inherited relative entry
  # finds nothing, while the entry resolved from the launch directory does.
  ( cd "${launch}/elsewhere" && PATH="tools" type -P mktemp >/dev/null 2>&1 ) && result=1
  ( cd "${launch}/elsewhere" && PATH="$(path_from_dir "${launch}" tools)" \
      type -P mktemp >/dev/null 2>&1 ) || result=1
  # Both directory-changing probes pass when the suite was launched from such
  # a directory with only that relative entry on PATH.
  ( cd "${launch}" && LAUNCH_DIR="${launch}" PATH="tools" \
      jq_stub_handles_a_relative_path_entry ) || result=1
  ( cd "${launch}" && LAUNCH_DIR="${launch}" PATH="tools" \
      jq_stub_handles_a_symlinked_relative_path_entry ) || result=1
  # The prologue probe changes directory too, and re-runs the suite itself
  # from there: it must still find bash and the rest of the tools.
  ( cd "${launch}" && LAUNCH_DIR="${launch}" PATH="tools" \
      workroot_resolution_survives_a_relative_tmpdir ) || result=1
  # And the direct relative-TMPDIR probe, which changes into its own
  # sandbox before running mktemp -- a different invocation from the
  # prologue one above.
  ( cd "${launch}" && LAUNCH_DIR="${launch}" PATH="tools" \
      path_helpers_resolve_a_relative_tmpdir ) || result=1
  rm -rf "${launch}"
  return "${result}"
}
# A named read is one object, not a list. The list fixtures must refuse it,
# while the list reads the step actually makes, and the named ClusterVersion
# read, stay exactly as they are.
list_fixtures_refuse_a_named_read(){
  local dir status=0 out
  dir="$(make_sandbox namedread)" || return 1
  named_read_call(){
    status=0
    out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=healthy "${dir}/bin/oc" "$@" 2>/dev/null)" || status=$?
  }
  # Named node and operator reads, in the spellings a collector could drift
  # into, are refused rather than answered with the healthy list.
  named_read_call get nodes node-a -o json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  named_read_call get nodes node-a -o wide
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  named_read_call get co authentication -o json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  named_read_call get clusteroperators authentication -o json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  named_read_call get nodes node-a --request-timeout=60s -o json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  # An option value is not a name, in either spelling of the option oc takes
  # a separate value for, and a name alongside one is still a named read.
  named_read_call get nodes --request-timeout 60s -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  named_read_call get nodes --request-timeout 60s node-a -o json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  # The list reads the step makes are untouched, including the option values
  # that must not be counted as names.
  named_read_call get nodes -o json --request-timeout=60s
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  named_read_call get co -o json --request-timeout=60s
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  named_read_call get nodes -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* ]] || return 1
  named_read_call get co -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* ]] || return 1
  # A named ClusterVersion read is the step's own call and keeps working.
  named_read_call get clusterversion version -o 'jsonpath={.status.desired.version}'
  [[ "${status}" -eq 0 ]] || return 1
  # The option-value and terminator rules still hold alongside the count: a
  # namespace value is not a name, and the last output option still wins.
  named_read_call get nodes -n openshift-monitoring -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* ]] || return 1
  named_read_call get nodes -o wide --output json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  named_read_call get nodes -- node-a
  [[ "${status}" -eq 4 && -z "${out}" ]] || return 1
  # A valueless option at the end is an error to oc, which reads nothing, so
  # the fixture refuses it instead of serving the listing - the same rule the
  # output option already had.
  named_read_call get nodes -l
  [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
  named_read_call get nodes -o wide -n
  [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
  named_read_call get nodes --request-timeout
  [[ "${status}" -eq 2 && -z "${out}" ]]
}
# The degraded operator's describe artifact must hold that operator's own
# diagnostics: the fixture answers only the exact operator the report named.
describe_fixture_answers_only_the_named_operator(){
  local dir status=0 out
  dir="$(make_sandbox describeco)" || return 1
  describe_call(){
    status=0
    out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=report_unavailable_jq_fails \
           "${dir}/bin/oc" "$@" 2>/dev/null)" || status=$?
  }
  describe_call describe co authentication
  [[ "${status}" -eq 0 && "${out}" == *"CO-DESCRIBE-AUTHENTICATION"* ]] || return 1
  describe_call describe co dns
  [[ "${status}" -eq 0 && -z "${out}" ]] || return 1
  describe_call describe co
  [[ "${status}" -eq 0 && -z "${out}" ]] || return 1
  # Another scenario is unaffected: the marker belongs to this one.
  status=0
  out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=healthy \
         "${dir}/bin/oc" describe co authentication 2>/dev/null)" || status=$?
  [[ "${status}" -eq 0 && -z "${out}" ]]
}
# The operator payload of the snapshot health-list failure really does carry a
# degraded operator, so the Degraded query that runs before the failing
# Available query has a name to produce and the discard is observable.
snapshot_co_failure_fixture_has_a_degraded_operator(){
  local dir payload names
  dir="$(make_sandbox codegraded)" || return 1
  # The first read is the report's and is healthy by design; the snapshot
  # read is the one that carries the degraded operator.
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=snapshot_co_health_list_fails \
    "${dir}/bin/oc" get co -o json >/dev/null 2>&1 || return 1
  payload="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=snapshot_co_health_list_fails \
             "${dir}/bin/oc" get co -o json 2>/dev/null)" || return 1
  names="$(printf '%s' "${payload}" | jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | .metadata.name')" || return 1
  [[ "${names}" == "authentication" ]] || return 1
  # And nothing is unavailable in it, so the empty unavailable list is not
  # what makes the new assertion pass.
  names="$(printf '%s' "${payload}" | jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Available" and .status!="True")) | .metadata.name')" || return 1
  [[ -z "${names}" ]]
}
# The artifact-content helper answers from a read that succeeded. A cat that
# printed the expected line and then failed says nothing about the rest of
# the file, so it must not be read as "the file holds only this line".
artifact_content_helper_requires_a_successful_read(){
  local dir result=0 saved_artifacts="${ARTIFACTS}" saved_path="${PATH}"
  local line='(unavailable: oc exited 1)'
  dir="$(mktemp -d "${WORKROOT}/onlyline-XXXXXX")" || return 1
  [[ -n "${dir}" && -d "${dir}" ]] || return 1
  mkdir -p "${dir}/diagnostics" "${dir}/bin" || return 1
  ARTIFACTS="${dir}"
  printf '%s\n' "${line}" > "${dir}/diagnostics/only.txt" || result=1
  printf '%s\n%s\n' "${line}" 'leaked stderr line' > "${dir}/diagnostics/extra.txt" || result=1
  mkdir -p "${dir}/diagnostics/as-a-directory" || result=1
  # The real answers first.
  artifact_is_only_line diagnostics/only.txt "${line}" || result=1
  artifact_is_only_line diagnostics/extra.txt "${line}" && result=1
  artifact_is_only_line diagnostics/never-written.txt "${line}" && result=1
  artifact_is_only_line diagnostics/as-a-directory "${line}" && result=1
  # A read that fails, with and without output: the second is the one a
  # comparison on an unchecked substitution would have accepted.
  printf '%s\n' '#!/bin/bash' 'exit 1' > "${dir}/bin/cat" || result=1
  chmod +x "${dir}/bin/cat" || result=1
  PATH="${dir}/bin:${PATH}"
  artifact_is_only_line diagnostics/only.txt "${line}" && result=1
  # %q and a syntax check, the way the sandbox stubs are written: a value
  # interpolated raw could make this stub a syntax error, and the probe would
  # then silently degenerate into the case above instead of testing this one.
  { printf '%s\n' '#!/bin/bash'
    printf 'printf %%s\\\\n %q\n' "${line}"
    printf '%s\n' 'exit 1'; } > "${dir}/bin/cat" || result=1
  bash -n "${dir}/bin/cat" || result=1
  [[ "$("${dir}/bin/cat")" == "${line}" ]] || result=1
  artifact_is_only_line diagnostics/only.txt "${line}" && result=1
  PATH="${saved_path}"
  # And the real cat still answers the real file.
  artifact_is_only_line diagnostics/only.txt "${line}" || result=1
  ARTIFACTS="${saved_artifacts}"
  return "${result}"
}
# A label selector filters the list for the real client. The list fixtures
# cannot filter, so they refuse a selected read instead of answering with
# every item; an unselected read, and the selector paths of the HCP log
# collection, are untouched.
list_fixtures_refuse_a_selected_read(){
  local dir status=0 out hcp="ocm-staging-fake-cluster-id-dp"
  dir="$(make_sandbox selread)" || return 1
  sel_call(){
    status=0
    out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=healthy "${dir}/bin/oc" "$@" 2>/dev/null)" || status=$?
  }
  # Every spelling of a selector the fixture cannot honour.
  sel_call get nodes -l fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes --selector fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes --selector=fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes -l=fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes -lfixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get co -l fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get clusteroperators -l fixture-absent=true -o wide
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  # The field selector narrows the same way, in both spellings.
  sel_call get nodes --field-selector=metadata.name=fixture-absent -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes --field-selector metadata.name=fixture-absent -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get co --field-selector=metadata.name=fixture-absent -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  # The two options are tracked apart: an empty one does not cancel a
  # narrowing given by the other, because oc applies both.
  sel_call get nodes -l fixture-absent=true --field-selector= -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes --field-selector=metadata.name=absent --selector= -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes --field-selector=metadata.name=absent -l '' -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get co -l '' --field-selector=metadata.name=absent -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  # Within one option the last value wins, as it does for oc: a selector
  # replaced by an empty one leaves the read unfiltered.
  sel_call get nodes -l a=1 -l '' -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  sel_call get nodes -l '' -l a=1 -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  sel_call get nodes --field-selector=metadata.name=absent --field-selector= -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  # The reads the step actually makes are unselected and unchanged, and an
  # empty selector selects everything, which is what the fixture serves.
  sel_call get nodes -o json --request-timeout=60s
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  sel_call get co -o json --request-timeout=60s
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  sel_call get nodes -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* ]] || return 1
  sel_call get nodes -l '' -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  # Isolation: the cvo log fallback still answers its selector, and a
  # selected pod listing is not a list fixture at all.
  status=0
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" logs -n "${hcp}" -l app=cluster-version-operator --tail=500 2>/dev/null)" || status=$?
  [[ "${status}" -eq 0 && "${out}" == *"CVO-LOG-FROM-LABEL-SELECTOR"* ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${hcp}" -l app=x -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]]
}
# The payload those two scenarios print is the healthy one, trailing
# newlines aside, and it is a well-formed non-empty list: the only
# difference from a healthy read is the exit status, so the assertions above
# cannot be met by an empty or malformed body. The step's full validator is
# exercised against these same payloads by the scenarios around them.
rc1_payload_is_the_healthy_payload(){
  local dir resource scenario healthy failing status
  dir="$(make_sandbox rc1payload)" || return 1
  for resource in co nodes; do
    case "${resource}" in
      co)    scenario=co_json_rc1_with_payload ;;
      nodes) scenario=nodes_json_rc1_with_payload ;;
      *)     return 1 ;;
    esac
    healthy="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=healthy \
               "${dir}/bin/oc" get "${resource}" -o json 2>/dev/null)" || return 1
    status=0
    failing="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" \
               "${dir}/bin/oc" get "${resource}" -o json 2>/dev/null)" || status=$?
    # Same bytes, different status.
    [[ "${status}" -eq 1 ]] || return 1
    [[ -n "${failing}" && "${failing}" == "${healthy}" ]] || return 1
    # And the body really is the shape the step accepts, so a regression
    # cannot pass by the payload being rejected instead.
    printf '%s' "${failing}" | jq -es 'length == 1 and (.[0] | has("items")
      and (.items | type) == "array"
      and (.items | length) > 0
      and all(.items[]; (.metadata.name | type) == "string"
                        and (.metadata.name | length) > 0))' >/dev/null || return 1
    # Every read of that resource behaves the same way -- same status and
    # same body -- so the report phase and the snapshot phase both see it.
    # The repeat is checked on both counts: a fixture that answered the
    # second read differently would leave one of the two phases untested.
    local repeated sibling sibling_resource
    status=0
    repeated="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" \
                "${dir}/bin/oc" get "${resource}" -o json 2>/dev/null)" || status=$?
    [[ "${status}" -eq 1 ]] || return 1
    [[ "${repeated}" == "${healthy}" ]] || return 1
    # The sibling resource is untouched in that scenario: zero status and a
    # list of its own, not an empty body.
    case "${resource}" in
      co)    sibling_resource=nodes ;;
      nodes) sibling_resource=co ;;
      *)     return 1 ;;
    esac
    status=0
    sibling="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO="${scenario}" \
               "${dir}/bin/oc" get "${sibling_resource}" -o json 2>/dev/null)" || status=$?
    [[ "${status}" -eq 0 ]] || return 1
    printf '%s' "${sibling}" | jq -es 'length == 1 and (.[0].items | type) == "array"
      and (.[0].items | length) > 0' >/dev/null || return 1
  done
  return 0
}
# oc accepts the singular spelling for the same list, so the singular read is
# the same list fixture: unselected it serves the whole list, selected or
# named it is refused like the plural.
singular_list_reads_follow_the_same_rules(){
  local dir status=0 out
  dir="$(make_sandbox singularnode)" || return 1
  node_call(){
    status=0
    out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=healthy "${dir}/bin/oc" "$@" 2>/dev/null)" || status=$?
  }
  # Unselected, the singular read is the whole fixture: same shape, same two
  # items, byte for byte what the plural spelling answers.
  node_call get node -o json
  [[ "${status}" -eq 0 ]] || return 1
  local singular="${out}"
  node_call get nodes -o json
  [[ "${status}" -eq 0 && "${out}" == "${singular}" ]] || return 1
  printf '%s' "${singular}" | jq -es 'length == 1 and (.[0].items | type) == "array"
    and (.[0].items | length) == 2' >/dev/null || return 1
  node_call get node -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* ]] || return 1
  # Selected, it is refused like the plural. The option spellings themselves
  # are pinned by the plural probe; what this covers is that the gate knows
  # this resource spelling at all.
  node_call get node -l fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  node_call get node --selector=fixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  node_call get node -lfixture-absent=true -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  node_call get node --field-selector=metadata.name=absent -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  node_call get node --field-selector metadata.name=absent -o wide
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  # The two options stay independent here too, and an empty last value
  # within one option still leaves the read unfiltered.
  node_call get node -l fixture-absent=true --field-selector= -o json
  [[ "${status}" -eq 7 && -z "${out}" ]] || return 1
  node_call get node -l a=1 -l '' -o json
  [[ "${status}" -eq 0 && "${out}" == "${singular}" ]] || return 1
  # And a named singular read is refused as a named read, not a selected one.
  node_call get node node-a -o json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  # The gate and the dispatch have to name the same spellings. The singular
  # operator alias is answered by neither today, so a selected read of it is
  # not handed a list: if it is ever added to the dispatch alone -- the drift
  # that made the singular node read a false success -- this starts failing.
  node_call get clusteroperator -l fixture-absent=true -o json
  [[ -z "${out}" ]] || return 1
  node_call get clusteroperator -o json
  [[ -z "${out}" ]]
}
# A leading healthy document must not let a fixture probe pass: jq -e reports
# the last document, so the probes slurp and require exactly one.
fixture_probes_require_one_document(){
  local probe status=0
  probe="$(mktemp -d "${WORKROOT}/onedoc-XXXXXX")" || return 1
  printf '%s\n%s\n' '{"items":[{"metadata":{"name":"ok"},"status":{"conditions":[]}}]}' \
    '{"items":[{"metadata":{"name":"late"},"status":"invalid"}]}' > "${probe}/two.json"
  # The predicates the probes use, applied the old way and the new way.
  jq -e '(.items | type) == "array" and any(.items[]; (.status | type) == "string")' \
    < "${probe}/two.json" >/dev/null 2>&1 || status=1
  [[ "${status}" -eq 0 ]] || return 1          # the hazard must reproduce
  jq -es 'length == 1 and (.[0] | (.items | type) == "array" and any(.items[]; (.status | type) == "string"))' \
    < "${probe}/two.json" >/dev/null 2>&1 && return 1
  # One document still passes.
  printf '%s\n' '{"items":[{"metadata":{"name":"late"},"status":"invalid"}]}' > "${probe}/one.json"
  jq -es 'length == 1 and (.[0] | (.items | type) == "array" and any(.items[]; (.status | type) == "string"))' \
    < "${probe}/one.json" >/dev/null || return 1
  rm -rf "${probe}" || true
  return 0
}
# The output option, not a bare argument, selects the JSON fixture: a list
# request that lost its -o must not be served the JSON payload.
oc_stub_requires_an_output_option(){
  local dir out status=0
  dir="$(make_sandbox ocoutputopt)" || return 1
  json_call(){
    status=0
    out="$(KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=healthy "${dir}/bin/oc" "$@" 2>/dev/null)" || status=$?
  }
  # Every spelling the step could use is served.
  json_call get nodes -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes -ojson
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes -o=json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes --output json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes --output=json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  # A bare positional json is a resource name, not a format request: it names
  # one node, and a named read has no list payload, so the refusal is what
  # proves it was never read as an output format.
  json_call get nodes json
  [[ "${status}" -eq 6 && -z "${out}" ]] || return 1
  # And the plain-text listing stays plain text.
  json_call get nodes -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  # The last output option wins, across spellings and in both orders.
  json_call get nodes -o json --output=wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes --output wide -ojson
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes -ojson -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes -o=wide --output json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  # A valueless output option at the end is an error to oc, which then reads
  # nothing: the fixture refuses the call instead of serving the default
  # table, in either spelling and whatever preceded it.
  json_call get nodes -o wide -o
  [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
  json_call get nodes -o json --output
  [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
  json_call get nodes -o
  [[ "${status}" -eq 2 && -z "${out}" ]] || return 1
  # The complete overrides and the plain wide read are unaffected.
  json_call get nodes -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes -o json --output wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes --output wide -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  # A format the fixture has no payload for is refused, with its own status,
  # rather than answered with the default table: a mistyped -o wid must not
  # look like a healthy listing. The last option is resolved first, so a
  # mistype that was corrected afterwards is still served.
  json_call get nodes -o wid
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes --output wid
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes -owid
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes -o wide -o wid
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes -o=wid
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes --output=wid
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes -o wid -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes -o wid --output json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  # The formats the step actually uses are all accepted: the wide table and
  # the JSON read are served from payloads, and the ClusterVersion jsonpath is
  # let through without one. A listing with no output option at all is still
  # the default table, and a jsonpath on any other resource is refused rather
  # than handed that table.
  json_call get nodes -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get clusterversion version -o 'jsonpath={.status.desired.version}'
  [[ "${status}" -eq 0 ]] || return 1
  json_call get clusterversion version "-ojsonpath={.status.desired.version}"
  [[ "${status}" -eq 0 ]] || return 1
  json_call get nodes -o 'jsonpath={.items[0].metadata.name}'
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get co -o 'jsonpath={.items[0].metadata.name}'
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  # Options end at a standalone --: what follows is positional to oc, so a
  # listing that pushed its output option past the terminator asked for
  # resources this fixture has no payload for and is refused, rather than
  # being handed the healthy JSON list or the default table by accident.
  json_call get nodes -- -o json
  [[ "${status}" -eq 4 && -z "${out}" ]] || return 1
  json_call get nodes -- -o json --request-timeout=60s
  [[ "${status}" -eq 4 && -z "${out}" ]] || return 1
  json_call get nodes -- -o wide
  [[ "${status}" -eq 4 && -z "${out}" ]] || return 1
  json_call get nodes -o json -- extra
  [[ "${status}" -eq 4 && -z "${out}" ]] || return 1
  # A terminator with nothing after it ends the options and nothing else, so
  # the options before it still decide the format.
  json_call get nodes -o json --
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes -o wide --
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  json_call get nodes --
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]] || return 1
  # A -- that answers a pending option is that option's value, not a
  # terminator: "--" is not a format this fixture serves, and the options
  # after it are still options, so a later one still decides the format.
  json_call get nodes -o --
  [[ "${status}" -eq 3 && -z "${out}" ]] || return 1
  json_call get nodes --output -- -o json
  [[ "${status}" -eq 0 && "${out}" == *'"items"'* ]] || return 1
  json_call get nodes -o -- -o wide
  [[ "${status}" -eq 0 && "${out}" == *"NAME"* && "${out}" != *'"items"'* ]]
}
# A diagnostic that lists every namespace is not scoped to the hosted control
# plane, whatever -n says; it is recorded and refused with its own status.
diagnostic_stub_refuses_all_namespaces(){
  local dir status=0 ns="ocm-staging-fake-cluster-id-dp" scenario spelling
  dir="$(make_sandbox diagallns)" || return 1
  for scenario in hcp_diagnostics hcp_diagnostics_outage; do
    for spelling in -A --all-namespaces --all-namespaces=true -A=true; do
      status=0
      KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO="${scenario}" OCM_LOGIN_ENV=staging \
        "${dir}/bin/oc" get pods -n "${ns}" "${spelling}" -o wide >/dev/null 2>&1 || status=$?
      [[ "${status}" -eq 68 ]] || return 1
    done
  done
  [[ "$(wc -l < "${dir}/state/diagnostic-all-namespaces")" -eq 8 ]] || return 1
  grep -qF -- '-A=true' "${dir}/state/diagnostic-all-namespaces" || return 1
  # An explicit false is not an all-namespaces request, and the last value
  # wins when the flag is repeated.
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" -A=false -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" -A --all-namespaces=false -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" --all-namespaces=false -A=true -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 68 ]] || return 1
  grep -qF -- '--all-namespaces=true' "${dir}/state/diagnostic-all-namespaces" || return 1
  grep -qE -- '(^| )-A( |$)' "${dir}/state/diagnostic-all-namespaces" || return 1
  # A -- that answers a pending option is that option's value, not a
  # terminator: the all-namespaces flag after it is still a flag, and the
  # two argument scans have to agree about that or this refusal is lost.
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" -l -- --all-namespaces >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 68 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" --selector -- --all-namespaces >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 68 ]] || return 1
  # A pod listing that dropped -n for -A is matched and refused too.
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -A -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 68 ]] || return 1
  # The kubeconfig mismatch is still reported first, so 66 wins over 68.
  status=0
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" -A -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  # 68 is distinct from the kubeconfig, namespace and outage statuses, and the
  # namespace-only call is still the positive control.
  status=0
  KUBECONFIG="${dir}/shared/kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 66 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n ocm-staging-fake-cluster-id -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 67 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics_outage OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get pods -n "${ns}" -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 ]] || return 1
  local out
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get pods -n "${ns}" -o wide 2>/dev/null)" || return 1
  [[ "${out}" == *"HCP-PODS-OUTPUT"* ]]
}
check "a mistyped HCP resource gets neither answer" diagnostic_stub_rejects_a_mistyped_resource
check "the JSON fixture needs an output option" oc_stub_requires_an_output_option
# The effective namespace is the last one given, in every spelling the stub
# models: an appended override must be seen, a correcting override must be
# honoured, and a clustered shorthand is one of those spellings. Both HCP
# scenarios are covered.
# The helper writes the caller's status and out, and is kept at this level so
# it is visibly shared rather than leaking out of a nested definition.
last_ns_call(){
  local call_dir="$1" call_scenario="$2"
  shift 2
  status=0
  out="$(KUBECONFIG="${call_dir}/shared/hs-mc.kubeconfig" OC_SCENARIO="${call_scenario}" \
         OCM_LOGIN_ENV=staging "${call_dir}/bin/oc" "$@" 2>/dev/null)" || status=$?
}
diagnostic_stub_uses_the_last_namespace(){
  local dir status=0 out scenario
  local hcp="ocm-staging-fake-cluster-id-dp" hc="ocm-staging-fake-cluster-id"
  dir="$(make_sandbox diagnslast)" || return 1
  for scenario in hcp_diagnostics hcp_diagnostics_outage; do
    # A correct -n followed by an appended override: the override decides, in
    # each spelling, and the call is recorded as the wrong namespace.
    last_ns_call "${dir}" "${scenario}" get pods -n "${hcp}" --namespace=default -o wide
    [[ "${status}" -eq 67 ]] || return 1
    last_ns_call "${dir}" "${scenario}" get pods -n "${hcp}" --namespace default -o wide
    [[ "${status}" -eq 67 ]] || return 1
    last_ns_call "${dir}" "${scenario}" get pods -n "${hcp}" -n=default -o wide
    [[ "${status}" -eq 67 ]] || return 1
    last_ns_call "${dir}" "${scenario}" get pods -n "${hcp}" -ndefault -o wide
    [[ "${status}" -eq 67 ]] || return 1
    # A wrong namespace corrected by a later override is answered: the
    # success scenario with its marker, the outage one with its API error.
    last_ns_call "${dir}" "${scenario}" get pods -n default --namespace="${hcp}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-PODS-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    # Mixed spellings, last one still wins, including the clustered shorthand.
    last_ns_call "${dir}" "${scenario}" get pods --namespace=default -n "${hcp}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-PODS-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    last_ns_call "${dir}" "${scenario}" get pods --namespace default -n"${hcp}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-PODS-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    # The equals spelling alone is enough to scope another HCP diagnostic.
    last_ns_call "${dir}" "${scenario}" get hostedcluster --namespace="${hc}" -o wide
    if [[ "${scenario}" == hcp_diagnostics ]]; then
      [[ "${status}" -eq 0 && "${out}" == *"HCP-HOSTEDCLUSTER-OUTPUT"* ]] || return 1
    else
      [[ "${status}" -eq 1 ]] || return 1
    fi
    # A clustered -A is still an all-namespaces request, however it is spelled,
    # and that refusal keeps its own status rather than the namespace one.
    last_ns_call "${dir}" "${scenario}" get pods -n "${hcp}" -Ao wide
    [[ "${status}" -eq 68 ]] || return 1
    last_ns_call "${dir}" "${scenario}" get pods -An "${hcp}" -o wide
    [[ "${status}" -eq 68 ]] || return 1
    # A valueless namespace option at the end is an error to oc, not a
    # namespace, and not a diagnostic the fixture answers.
    last_ns_call "${dir}" "${scenario}" get hostedcontrolplane -n "${hcp}" -n
    [[ "${status}" -eq 2 ]] || return 1
    last_ns_call "${dir}" "${scenario}" get hostedcontrolplane -n "${hcp}" --namespace
    [[ "${status}" -eq 2 ]] || return 1
  done
  # Four wrong-namespace calls per scenario were recorded, and nothing else
  # was: the answered calls and the refusals above keep their own records.
  [[ "$(wc -l < "${dir}/state/diagnostic-wrong-namespace")" -eq 8 ]] || return 1
  [[ "$(wc -l < "${dir}/state/diagnostic-all-namespaces")" -eq 4 ]] || return 1
  # Each refusal names the override as the effective namespace, not the
  # correct one it replaced.
  [[ "$(grep -c 'namespace default, expected ' \
        "${dir}/state/diagnostic-wrong-namespace")" -eq 8 ]]
}
check "an all-namespaces diagnostic is refused distinctly" diagnostic_stub_refuses_all_namespaces
check "the last namespace option decides the scope" diagnostic_stub_uses_the_last_namespace
# The real probes, against the real multi-document fixture: these are the
# assertions that fail if any of them goes back to plain jq -e.
stub_payload_is_not_one_document(){ ! stub_payload_is_json "$@"; }
stub_snapshot_read_is_not_one_list(){ ! stub_snapshot_read_is_list "$@"; }
check "a mistyped cvo deployment or selector gets neither answer" diagnostic_stub_rejects_a_mistyped_cvo_call
check "only the fixture management kubeconfig is the management cluster" \
  diagnostic_stub_requires_the_fixture_management_kubeconfig
check "the last selector option decides the cvo lookup" diagnostic_stub_uses_the_last_cvo_selector
check "an explicit kubeconfig decides the diagnostic cluster" diagnostic_stub_honours_an_explicit_kubeconfig
check "a named node or operator read is not answered with a list" list_fixtures_refuse_a_named_read
check "a selected node or operator read is not answered with the whole list" \
  list_fixtures_refuse_a_selected_read
check "the failing read prints the same payload a healthy read would" \
  rc1_payload_is_the_healthy_payload
check "the singular list spelling follows the same rules" \
  singular_list_reads_follow_the_same_rules
check "the artifact-content helper needs a successful read" \
  artifact_content_helper_requires_a_successful_read
check "the describe fixture answers only the operator it was given" \
  describe_fixture_answers_only_the_named_operator
check "the operator snapshot failure fixture really is degraded" \
  snapshot_co_failure_fixture_has_a_degraded_operator
check "the absence helpers accept only a real no-match" absence_helpers_require_a_real_no_match
check "direct fixture probes ignore an inherited BASH_ENV" \
  direct_probes_run_without_an_inherited_bash_env
check "fixture probes require exactly one JSON document" fixture_probes_require_one_document
check "a two-document CO fixture is not accepted as one list" stub_payload_is_not_one_document json_two_documents co
check "a two-document node fixture is not accepted as one list" stub_payload_is_not_one_document json_two_documents nodes
check "a two-document snapshot read is not accepted as one list" stub_snapshot_read_is_not_one_list json_two_documents co
check "the snapshot health fixture emits a name before failing" snapshot_health_fixture_emits_then_fails
check "the jq stub matches the program, not the payload path" jq_stub_matches_the_program_not_the_path
# Only a logs call is a cvo lookup: another subcommand carrying the same
# selector must neither be answered with a log marker nor recorded.
diagnostic_stub_ignores_a_nonlogs_selector(){
  local dir status=0 out
  dir="$(make_sandbox diagselector)" || return 1
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" get pods -n ocm-staging-fake-cluster-id-dp -l app=cluster-version-operator -o wide 2>/dev/null)" || status=$?
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${out}" != *"CVO-LOG-FROM-LABEL-SELECTOR"* ]] || return 1
  [[ ! -e "${dir}/state/cvo-lookups" ]] || return 1
  out="$(KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
         "${dir}/bin/oc" logs -n ocm-staging-fake-cluster-id-dp -l app=cluster-version-operator --tail=500 2>/dev/null)" || return 1
  [[ "${out}" == *"CVO-LOG-FROM-LABEL-SELECTOR"* ]] || return 1
  [[ "$(cat "${dir}/state/cvo-lookups")" == selector ]]
}
check "the Ready-query fixture emits a name before failing" notready_jq_fixture_emits_then_fails
check "a non-logs call with the cvo selector is not a cvo lookup" diagnostic_stub_ignores_a_nonlogs_selector
check "a report verdict must be the only Overall Status line" report_verdict_assertion_requires_one_line
check "an inherited prologue variable cannot skip the suite" suite_ignores_an_inherited_prologue_variable
check "a projected field needs exactly one matching row" snapshot_item_field_requires_one_row
check "the two-document fixture check rejects other shapes" two_document_check_rejects_other_shapes
check "snapshot assertions require an items array" snapshot_assertions_require_an_items_array
# Each diagnostic must name its own namespace: the HostedCluster lives in the
# HC namespace, the hosted control plane and its pods and both cvo log
# alternatives in the HCP one. A call in the other namespace is answered with
# its own status, distinct from the kubeconfig mismatch and from the outage.
diagnostic_stub_rejects_the_wrong_namespace(){
  local dir hc hcp status
  dir="$(make_sandbox diagnamespace)" || return 1
  hc="ocm-staging-fake-cluster-id"
  hcp="${hc}-dp"
  oc_diag(){
    status=0
    KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics OCM_LOGIN_ENV=staging \
      "${dir}/bin/oc" "$@" >"${dir}/diag.out" 2>/dev/null || status=$?
  }
  # Right namespace, right answer.
  oc_diag get hostedcluster -n "${hc}" -o wide
  [[ "${status}" -eq 0 ]] && grep -qF 'HCP-HOSTEDCLUSTER-OUTPUT' "${dir}/diag.out" || return 1
  oc_diag get hostedcontrolplane -n "${hcp}" -o wide
  [[ "${status}" -eq 0 ]] && grep -qF 'HCP-HOSTEDCONTROLPLANE-OUTPUT' "${dir}/diag.out" || return 1
  oc_diag get pods -n "${hcp}" -o wide
  [[ "${status}" -eq 0 ]] && grep -qF 'HCP-PODS-OUTPUT' "${dir}/diag.out" || return 1
  oc_diag logs -n "${hcp}" -l app=cluster-version-operator --tail=500
  [[ "${status}" -eq 0 ]] && grep -qF 'CVO-LOG-FROM-LABEL-SELECTOR' "${dir}/diag.out" || return 1
  [[ ! -e "${dir}/state/diagnostic-wrong-namespace" ]] || return 1
  # Wrong namespace, including both cvo alternatives, each rejected with 67.
  oc_diag get hostedcluster -n "${hcp}" -o wide
  [[ "${status}" -eq 67 ]] || return 1
  oc_diag get hostedcontrolplane -n "${hc}" -o wide
  [[ "${status}" -eq 67 ]] || return 1
  oc_diag get pods -n "${hc}" -o wide
  [[ "${status}" -eq 67 ]] || return 1
  oc_diag logs deployment/cluster-version-operator -n "${hc}" --tail=500
  [[ "${status}" -eq 67 ]] || return 1
  oc_diag logs -n "${hc}" -l app=cluster-version-operator --tail=500
  [[ "${status}" -eq 67 ]] || return 1
  # Every mismatch recorded, and 67 is not the outage status.
  [[ "$(wc -l < "${dir}/state/diagnostic-wrong-namespace")" -eq 5 ]] || return 1
  status=0
  KUBECONFIG="${dir}/shared/hs-mc.kubeconfig" OC_SCENARIO=hcp_diagnostics_outage OCM_LOGIN_ENV=staging \
    "${dir}/bin/oc" get hostedcluster -n "${hc}" -o wide >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 ]]
}
check "diagnostic calls with the wrong kubeconfig are rejected distinctly" diagnostic_stub_rejects_the_hosted_kubeconfig
check "diagnostic calls in the wrong namespace are rejected distinctly" diagnostic_stub_rejects_the_wrong_namespace
check "jq resolves to an external executable despite a shell function" jq_resolution_ignores_a_shell_function
jq_stub_handles_a_relative_path_entry(){
  local probe saved status
  probe="$(mktemp -d "${WORKROOT}/jqrel-XXXXXX")" || return 1
  mkdir -p "${probe}/tools" || return 1
  cp "$(type -P jq)" "${probe}/tools/jq" || return 1
  chmod 0755 "${probe}/tools/jq"
  # PATH is changed only inside the subshell, so the caller's is untouched and
  # needs no restore. A relative entry makes type -P answer with a relative
  # spelling while make_sandbox embeds the absolute one.
  saved="${PATH}"
  ( cd "${probe}" \
      && PATH="tools:$(path_from_dir "${LAUNCH_DIR}" "${saved}")" \
         jq_stub_embeds "tools/jq" ) || status=$?
  status="${status:-0}"
  [[ "${status}" -eq 0 ]]
}
check "a jq installed under a spaced, shell-special path is embedded correctly" jq_stub_handles_a_spaced_path
# The same probe under an exported CDPATH: cd announces a directory it found
# through CDPATH, and that announcement must not end up inside a resolved path.
jq_stub_handles_a_relative_path_entry_under_cdpath(){
  ( export CDPATH=.; jq_stub_handles_a_relative_path_entry )
}
# absolute_dir and absolute_file are what every tool path goes through, so the
# CDPATH hazard is pinned on them directly as well.
path_helpers_ignore_cdpath(){
  local probe dir file
  probe="$(mktemp -d "${WORKROOT}/cdpath probe-XXXXXX")" || return 1
  mkdir -p "${probe}/tools" || return 1
  : > "${probe}/tools/jq" || return 1
  dir="$(cd "${probe}" && export CDPATH=. && absolute_dir tools)" || return 1
  # One line, not a cd announcement followed by the real path.
  [[ "$(printf '%s' "${dir}" | wc -l)" -eq 0 ]] || return 1
  [[ "${dir}" == "${probe}/tools" ]] || return 1
  file="$(cd "${probe}" && export CDPATH=. && absolute_file tools/jq)" || return 1
  [[ "${file}" == "${probe}/tools/jq" ]] || return 1
  rm -rf "${probe}"
}
# The helper contract behind the sandbox probe: a path that reaches a
# directory through a symlink and then ".." must resolve to the directory the
# lookup would use, not to the textually rewritten one beside it.
path_helpers_resolve_symlinks_physically(){
  local probe answer want
  probe="$(mktemp -d "${WORKROOT}/physdir-XXXXXX")" || return 1
  mkdir -p "${probe}/real/tools" "${probe}/real/child" "${probe}/links/tools" || return 1
  ln -s ../real/child "${probe}/links/jump" || return 1
  answer="$(cd "${probe}" && absolute_dir links/jump/../tools)" || return 1
  want="$(cd -P "${probe}/real/tools" && pwd -P)" || return 1
  rm -rf "${probe}"
  [[ -n "${answer}" && "${answer}" == "${want}" ]]
}
# A real relative TMPDIR, the way GNU mktemp echoes it back, resolved against
# the directory the suite started in. Everything happens inside a sacrificial
# tree under WORKROOT; the sentinel proves nothing outside it was touched.
path_helpers_resolve_a_relative_tmpdir(){
  local sac rel abs
  sac="$(mktemp -d "${WORKROOT}/reltmp-XXXXXX")" || return 1
  mkdir -p "${sac}/tmp" || return 1
  : > "${sac}/sentinel" || return 1
  # The inherited PATH is rebased on the launch directory before the cd, so
  # a relative entry still names mktemp from inside the sandbox. TMPDIR
  # stays relative: that is what this probe is about.
  rel="$(cd "${sac}" \
           && PATH="$(path_from_dir "${LAUNCH_DIR}" "${PATH}")" TMPDIR=tmp mktemp -d)" || return 1
  # The hazard has to reproduce, or this probe proves nothing.
  [[ "${rel}" != /* ]] || return 1
  abs="$(cd "${sac}" && absolute_dir "${rel}")" || return 1
  [[ "${abs}" == /* ]] || return 1
  [[ "$(cd "${sac}/${rel}" && pwd -P)" == "$(cd "${abs}" && pwd -P)" ]] || return 1
  # Still the same directory from anywhere else, which is what sandbox
  # creation and the cleanup trap both depend on.
  ( cd / && [[ -d "${abs}" ]] ) || return 1
  [[ -f "${sac}/sentinel" ]] || return 1
  rm -rf "${sac}"
  [[ -d "${WORKROOT}" ]]
}
# Prologue mode must not depend on the step script or on the tools the
# scenarios need: an unresolvable relative STEP_UNDER_TEST, and a PATH holding
# no more than the prologue and its cleanup use, must still yield an absolute
# work root inside the relative TMPDIR, removed again on exit. No real client
# is ever started. type -P answers relatively when the matching PATH entry is
# relative, so each tool is absolutised before it is linked.
workroot_prologue_ignores_suite_prerequisites(){
  local sac out bash_bin tool src
  bash_bin="$(absolute_file "$(type -P bash)")" || return 1
  [[ -x "${bash_bin}" ]] || return 1
  sac="$(mktemp -d "${WORKROOT}/prologue-XXXXXX")" || return 1
  mkdir -p "${sac}/tmp" "${sac}/tools" || return 1
  : > "${sac}/sentinel" || return 1
  for tool in mktemp rm; do
    src="$(absolute_file "$(type -P "${tool}")")" || return 1
    ln -s "${src}" "${sac}/tools/${tool}" || return 1
    [[ -x "${sac}/tools/${tool}" ]] || return 1
  done
  out="$(cd "${sac}" && PATH="${sac}/tools" TMPDIR=tmp \
         STEP_UNDER_TEST=./step-that-is-not-here.sh \
         "${bash_bin}" "${SUITE_PATH}" --print-workroot < /dev/null)" || return 1
  # One absolute path: not a SKIP line, and not a FATAL about the step script
  # or a missing tool, both of which the ordinary route would raise here.
  [[ "$(printf '%s' "${out}" | wc -l)" -eq 0 ]] || return 1
  # Inside the relative TMPDIR it was given, and cleaned up by its own trap.
  [[ "${out}" == "${sac}"/tmp/* ]] || return 1
  [[ ! -e "${out}" ]] || return 1
  [[ -f "${sac}/sentinel" ]] || return 1
  rm -rf "${sac}"
  [[ -d "${WORKROOT}" ]]
}
# An absolute TMPDIR carrying a "." component: mktemp keeps the spelling, so
# the work root must still be normalised or every path comparison against a
# cd/pwd answer reports a difference that is not there.
workroot_resolution_normalises_a_dotted_tmpdir(){
  local sac out
  sac="$(mktemp -d "${WORKROOT}/dottmp-XXXXXX")" || return 1
  mkdir -p "${sac}/tmp" || return 1
  : > "${sac}/sentinel" || return 1
  out="$(TMPDIR="${sac}/tmp/." bash "${SUITE_PATH}" --print-workroot < /dev/null)" || return 1
  [[ "$(printf '%s' "${out}" | wc -l)" -eq 0 ]] || return 1
  [[ "${out}" != *"/./"* ]] || return 1
  [[ "${out}" == "${sac}"/tmp/* ]] || return 1
  [[ -f "${sac}/sentinel" ]] || return 1
  rm -rf "${sac}"
  [[ -d "${WORKROOT}" ]]
}
# The prologue itself, re-run under a relative TMPDIR in a sacrificial tree.
# This pins the resolution in the suite, not just the helper it calls.
workroot_resolution_survives_a_relative_tmpdir(){
  local sac out
  sac="$(mktemp -d "${WORKROOT}/workroot-XXXXXX")" || return 1
  mkdir -p "${sac}/tmp" || return 1
  : > "${sac}/sentinel" || return 1
  # The inherited PATH is rebased on the launch directory before the cd, and
  # handed to the child: a relative entry would otherwise stop naming the
  # tools -- starting with bash itself -- once this probe changes directory.
  # The staged relative TMPDIR is the thing under test and stays relative.
  out="$(cd "${sac}" \
           && PATH="$(path_from_dir "${LAUNCH_DIR}" "${PATH}")" TMPDIR=tmp \
              bash "${SUITE_PATH}" --print-workroot < /dev/null)" || return 1
  # One line, absolute, and inside the relative TMPDIR it was given: a
  # relative answer, or a fallback to the system temporary directory, is the
  # regression. The single-line test is tool-free on purpose, so it cannot
  # pass by accident where the tool it would have used is missing.
  [[ "${out}" != *$'\n'* ]] || return 1
  [[ "${out}" == /* ]] || return 1
  [[ "${out}" == "${sac}"/tmp/* ]] || return 1
  # The child removed its own work root before exiting: the location alone
  # says nothing about the cleanup trap, and a leaked work root inside a
  # relative TMPDIR is exactly what that trap exists to prevent. Asserted
  # before the parent tree is removed, so the parent cleanup cannot hide it.
  [[ ! -e "${out}" ]] || return 1
  # Nothing outside the sacrificial tree was touched.
  [[ -f "${sac}/sentinel" ]] || return 1
  rm -rf "${sac}"
  [[ -d "${WORKROOT}" ]]
}
workroot_is_absolute(){
  [[ "${WORKROOT}" == /* && -d "${WORKROOT}" ]]
}
workroot_is_the_same_directory_from_anywhere(){
  local here there
  here="$(cd "${WORKROOT}" && pwd -P)" || return 1
  there="$(cd / && cd "${WORKROOT}" && pwd -P)" || return 1
  [[ -n "${here}" && "${here}" == "${there}" ]]
}
check "a relative PATH entry still yields an absolute embedded path" jq_stub_handles_a_relative_path_entry
check "a symlinked relative PATH entry keeps the executable the lookup found" jq_stub_handles_a_symlinked_relative_path_entry
check "a relative PATH entry resolves with CDPATH exported" jq_stub_handles_a_relative_path_entry_under_cdpath
# Placed after the two probes it drives, which are defined above it.
check "the PATH rewrite keeps every entry in place" path_rewrite_keeps_every_entry_in_place
check "a relative PATH entry survives a probe directory change" \
  relative_path_entries_survive_a_probe_directory_change
check "the path helpers ignore CDPATH" path_helpers_ignore_cdpath
check "the path helpers resolve symlinks physically" path_helpers_resolve_symlinks_physically
check "a relative TMPDIR resolves to one absolute workspace" path_helpers_resolve_a_relative_tmpdir
check "the suite work root is absolute" workroot_is_absolute
check "the work root resolves under a relative TMPDIR" workroot_resolution_survives_a_relative_tmpdir
check "the work root is normalised under a dotted TMPDIR" workroot_resolution_normalises_a_dotted_tmpdir
check "prologue mode ignores the step and tool prerequisites" workroot_prologue_ignores_suite_prerequisites
check "the work root is the same directory from any cwd" workroot_is_the_same_directory_from_anywhere

###########################################
# (a35) The hosted control-plane diagnostics actually run. The first cvo-logs
# alternative fails and the second succeeds, so the two-alternative chain is
# exercised: a successful collection keeps its output in full and the failed
# attempt's client error stays out of the artifact.
###########################################
echo "scenario: hcp_diagnostics (management diagnostics collected, first cvo alternative fails)"
run_step hcp_diagnostics true
check "step exits zero" rc_is 0
check "the HCP namespaces were resolved" stderr_has 'HCP namespace: ocm-staging-fake-cluster-id-dp'
# Each artifact must carry its own resource's marker and none of the others,
# so a collector that listed the wrong resource cannot pass.
check "the hostedcluster listing is published" artifact_has_line diagnostics/hostedcluster.txt 'HCP-HOSTEDCLUSTER-OUTPUT'
check "the hostedcluster artifact holds no other listing" artifact_lacks_line diagnostics/hostedcluster.txt 'HCP-HOSTEDCONTROLPLANE-OUTPUT'
check "the hostedcluster artifact holds no pod listing" artifact_lacks_line diagnostics/hostedcluster.txt 'HCP-PODS-OUTPUT'
check "the hostedcontrolplane listing is published" artifact_has_line diagnostics/hostedcontrolplane.txt 'HCP-HOSTEDCONTROLPLANE-OUTPUT'
check "the hostedcontrolplane artifact holds no other listing" artifact_lacks_line diagnostics/hostedcontrolplane.txt 'HCP-HOSTEDCLUSTER-OUTPUT'
check "the hostedcontrolplane artifact holds no pod listing" artifact_lacks_line diagnostics/hostedcontrolplane.txt 'HCP-PODS-OUTPUT'
check "the HCP pod listing is published" artifact_has_line diagnostics/pods-hcp-namespace.txt 'HCP-PODS-OUTPUT'
check "the HCP pod artifact holds no other listing" artifact_lacks_line diagnostics/pods-hcp-namespace.txt 'HCP-HOSTEDCLUSTER-OUTPUT'
check "the HCP pod artifact holds no control-plane listing" artifact_lacks_line diagnostics/pods-hcp-namespace.txt 'HCP-HOSTEDCONTROLPLANE-OUTPUT'
check "the second cvo alternative's output is kept" artifact_has_line diagnostics/cvo-logs.txt 'CVO-LOG-FROM-LABEL-SELECTOR'
check "the failed first alternative left no sanitized line" artifact_lacks_line diagnostics/cvo-logs.txt '(unavailable: oc exited 1)'
check "the deployment lookup ran first, the selector only as its fallback" state_file_is cvo-lookups deployment selector
check "every diagnostic used the management kubeconfig" state_file_absent diagnostic-wrong-kubeconfig
check "every diagnostic used its own namespace" state_file_absent diagnostic-wrong-namespace
check "no diagnostic listed every namespace" state_file_absent diagnostic-all-namespaces
check "no endpoint anywhere in the artifacts" artifacts_lack 'openshiftapps.com'
check "scratch directory removed afterwards" scratch_is_empty

###########################################
# (a36) The same path with the management cluster unreachable: every HCP
# diagnostic fails, so each artifact must hold only the sanitized line.
###########################################
echo "scenario: hcp_diagnostics_outage (every HCP diagnostic fails)"
run_step hcp_diagnostics_outage true
check "step exits zero" rc_is 0
# The four diagnostics the management cluster could not answer hold the
# sanitized line and nothing else. The guest-side monitoring listing is not
# among them: it is collected with the hosted kubeconfig, succeeds with no
# output in this scenario, and so carries no sanitized line to assert.
check "the hostedcluster artifact is sanitized" artifact_is_only_line diagnostics/hostedcluster.txt '(unavailable: oc exited 1)'
check "no hostedcluster output survives the outage" artifacts_lack 'HCP-HOSTEDCLUSTER-OUTPUT'
check "no hostedcontrolplane output survives the outage" artifacts_lack 'HCP-HOSTEDCONTROLPLANE-OUTPUT'
check "no pod listing output survives the outage" artifacts_lack 'HCP-PODS-OUTPUT'
check "the hostedcontrolplane artifact is sanitized" artifact_is_only_line diagnostics/hostedcontrolplane.txt '(unavailable: oc exited 1)'
check "the HCP pod artifact is sanitized" artifact_is_only_line diagnostics/pods-hcp-namespace.txt '(unavailable: oc exited 1)'
check "both cvo alternatives failed and were sanitized" artifact_is_only_line diagnostics/cvo-logs.txt '(unavailable: oc exited 1)'
check "the deployment lookup ran first, the selector only as its fallback" state_file_is cvo-lookups deployment selector
check "every diagnostic used the management kubeconfig" state_file_absent diagnostic-wrong-kubeconfig
check "every diagnostic used its own namespace" state_file_absent diagnostic-wrong-namespace
check "no diagnostic listed every namespace" state_file_absent diagnostic-all-namespaces
check "no endpoint anywhere in the artifacts" artifacts_lack 'openshiftapps.com'
check "scratch directory removed afterwards" scratch_is_empty

###########################################
# (a37) A supplied condition whose .type is not a nonempty string. The health
# selectors cannot name such a condition, so they skip it and the valid
# Available=True / Ready=True sibling carries the whole verdict. Each variant
# must be rejected as malformed instead.
###########################################
for scenario in condition_type_omitted condition_type_null condition_type_empty \
                condition_type_bool condition_type_number condition_type_object; do
  echo "scenario: ${scenario} (malformed condition .type beside a valid sibling)"
  check "CO fixture is a parseable one-item list" stub_payload_is_json "${scenario}" co
  check "node fixture is a parseable one-item list" stub_payload_is_json "${scenario}" nodes
  run_step "${scenario}"
  assert_no_false_health
  check "step fails validation rather than aborting" rc_is 1
  check "report is complete (summary written)" report_has 'Validation Summary'
  check "report records malformed CO data" report_has 'ClusterOperator JSON query failed or returned malformed data'
  check "report records malformed node data" report_has 'node JSON query failed or returned malformed data'
  check "no snapshot claims PASSED" metadata_eq '.overall_status' '"FAILED"'
done

###########################################
# (a38) An unfamiliar but well-formed condition type is legitimate: the API
# only requires a string. It must not be rejected, and the cluster must still
# read healthy.
###########################################
echo "scenario: condition_type_unfamiliar (EvaluationConditionsDetected beside the health condition)"
run_step condition_type_unfamiliar
check "step exits zero" rc_is 0
check "report claims operators healthy" report_has 'All operators: HEALTHY'
check "report claims nodes READY" report_has 'All nodes: READY'
check "overall status PASSED" report_verdict_is PASSED
check "snapshot status is PASSED" metadata_eq '.overall_status' '"PASSED"'
check "snapshot marks operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "snapshot marks nodes verified" metadata_eq '.nodes_verified' 'true'

###########################################
# (a39) The wide-listing capture file cannot be written, so the failure
# handler's placeholder write fails too. That must not abort the run before
# the retrieval failure is recorded, the snapshot is taken and the summary is
# written.
###########################################
for scenario in nodes_capture_unwritable co_capture_unwritable; do
  echo "scenario: ${scenario} (capture path is a directory)"
  run_step "${scenario}"
  check "step exits non-zero" rc_is 1
  check "the placeholder failure is reported, not fatal" stderr_has 'Could not write the placeholder capture file'
  check "report is complete (summary written)" report_has 'Validation Summary'
  check "overall status FAILED" report_verdict_is FAILED
  check "the snapshot was still taken" metadata_eq '.overall_status' '"FAILED"'
  # Per resource: the intended section reports its retrieval failure and the
  # sibling is unaffected, so a cross-wired fixture cannot pass.
  case "${scenario}" in
    nodes_capture_unwritable)
      check "the node retrieval failure is recorded" report_has 'unable to retrieve nodes'
      check "the operator side is unaffected" report_has 'All operators: HEALTHY' ;;
    co_capture_unwritable)
      check "the operator retrieval failure is recorded" report_has 'unable to retrieve ClusterOperators'
      check "the node side is unaffected" report_has 'All nodes: READY' ;;
    *)
      check "a39 scenario has per-resource assertions" false ;;
  esac
done

###########################################
# (a23b) The operator twin of (a23): a node-side health-list failure must not
# be the only thing covered, so this fails the operator list only and the node
# snapshot must survive.
###########################################
echo "scenario: snapshot_co_health_list_fails (operator health list fails)"
run_step snapshot_co_health_list_fails
check "step exits non-zero" rc_is 1
check "snapshot marks operators unverified" metadata_eq '.clusteroperators_verified' 'false'
check "no operator count is published" metadata_eq '.clusteroperator_count' '0'
check "the operator projection is emptied" snapshot_items_empty clusteroperators.json
# The failed query named an operator before failing: unverified, so it must
# not reach the published list.
check "the unverified operator name is discarded" metadata_eq '.unavailable_operators' '[]'
# The Degraded query ran first and named this operator, but the Available
# query then failed: an unverified assessment publishes no names from either
# list.
check "the degraded name from the earlier query is discarded too" \
  metadata_eq '.degraded_operators' '[]'
check "the node snapshot stays verified" metadata_eq '.nodes_verified' 'true'
check "the node projection is intact" snapshot_has_item nodes.json node-a
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a40) .status.versions entries named "operator": none, one, or more than
# one (repeated or differing). More than one must not fan the projection out
# into duplicate rows that inflate clusteroperator_count while the snapshot
# still reports PASSED; it marks the operators unverified instead.
###########################################
echo "scenario: co_versions_zero (no operator version entry)"
run_step co_versions_zero
check "step exits zero" rc_is 0
check "snapshot marks operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "exactly one operator row" metadata_eq '.clusteroperator_count' '1'
check "the version defaults to empty" snapshot_item_field clusteroperators.json authentication version '""'

echo "scenario: co_versions_one (a single operator version entry)"
run_step co_versions_one
check "step exits zero" rc_is 0
check "snapshot marks operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "exactly one operator row" metadata_eq '.clusteroperator_count' '1'
check "the version is projected" snapshot_item_field clusteroperators.json authentication version '"4.22.0"'

# Identical repeats are still more than one entry. Nothing in the API or in
# the field's contract makes a repeated entry legitimate, so the step treats
# the payload as unverified rather than guessing which repeat is the truth.
echo "scenario: co_versions_dup (the same operator version listed twice)"
run_step co_versions_dup
check "step exits non-zero" rc_is 1
check "snapshot marks operators unverified" metadata_eq '.clusteroperators_verified' 'false'
check "no operator count is published" metadata_eq '.clusteroperator_count' '0'
check "the operator projection is emptied" snapshot_items_empty clusteroperators.json
check "the node side stays verified" metadata_eq '.nodes_verified' 'true'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

# The API defines .status.versions as an array of objects whose name and
# version are both required strings, so every shape below is malformed and
# must mark the operators unverified instead of publishing a projected value.
# The last two carry the malformation on an entry the projection never reads,
# which must not be waved through just because the operator entry beside it
# happens to be well formed.
for scenario in co_versions_number co_versions_null co_versions_absent \
                co_versions_nonarray co_versions_nonobject_entry \
                co_versions_missing_name co_versions_bad_sibling \
                co_versions_sibling_missing_version; do
  echo "scenario: ${scenario} (malformed .status.versions)"
  run_step "${scenario}"
  check "step exits non-zero" rc_is 1
  check "snapshot marks operators unverified" metadata_eq '.clusteroperators_verified' 'false'
  check "no operator count is published" metadata_eq '.clusteroperator_count' '0'
  check "the operator projection is emptied" snapshot_items_empty clusteroperators.json
  check "no version is published for the operator" snapshot_lacks_item clusteroperators.json authentication
  check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'
  check "overall status FAILED" report_verdict_is FAILED
  # The report phase accepted this payload, so the rejection above really is
  # the projection talking and not an earlier read failing the scenario.
  check "the report phase accepted the operator payload" report_has 'All operators: HEALTHY'
  # The node side of the same capture is healthy and must stay that way.
  check "the node side stays verified" metadata_eq '.nodes_verified' 'true'
  check "the node projection is intact" snapshot_has_item nodes.json node-a
done

# A well-formed operand entry beside the operator entry is ordinary: only the
# entry named "operator" is projected, and the capture stays verified.
echo "scenario: co_versions_sibling (an operand entry beside the operator one)"
run_step co_versions_sibling
check "step exits zero" rc_is 0
check "snapshot marks operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "exactly one operator row" metadata_eq '.clusteroperator_count' '1'
check "the operator version is projected" snapshot_item_field clusteroperators.json authentication version '"4.22.0"'

echo "scenario: co_versions_two (two differing operator version entries)"
run_step co_versions_two
check "step exits non-zero" rc_is 1
check "snapshot marks operators unverified" metadata_eq '.clusteroperators_verified' 'false'
check "no inflated operator count" metadata_eq '.clusteroperator_count' '0'
check "the operator projection is emptied" snapshot_items_empty clusteroperators.json
check "the node side stays verified" metadata_eq '.nodes_verified' 'true'
check "snapshot status is FAILED" metadata_eq '.overall_status' '"FAILED"'

###########################################
# (a5) The plain-text wide query itself fails
###########################################
echo "scenario: wide_fails (wide query fails, JSON query OK)"
run_step wide_fails
check "step exits non-zero" rc_nonzero
check "report records the CO retrieval failure" report_has 'unable to retrieve ClusterOperators'
check "report does not claim operators healthy" report_lacks 'All operators: HEALTHY'
check "report does not claim nodes READY" report_lacks 'All nodes: READY'
check "raw client error kept out of the report" report_lacks 'openshiftapps.com'
check "raw client error kept out of all artifacts" artifacts_lack 'openshiftapps.com'

###########################################
# (b1) Nonempty healthy response
###########################################
echo "scenario: healthy (nonempty operators and nodes, all good)"
run_step healthy
check "step exits zero" rc_is 0
check "report claims operators healthy" report_has 'All operators: HEALTHY'
check "report claims nodes READY" report_has 'All nodes: READY'
check "report counts the nodes it saw" report_has_line 'Total nodes: 2'
check "overall status PASSED" report_verdict_is PASSED
check "snapshot status is PASSED" metadata_eq '.overall_status' '"PASSED"'
check "snapshot marks operators verified" metadata_eq '.clusteroperators_verified' 'true'
check "snapshot marks nodes verified" metadata_eq '.nodes_verified' 'true'
check "snapshot counts both nodes" metadata_eq '.node_count' '2'
check "snapshot counts both nodes ready" metadata_eq '.ready_node_count' '2'
check "projected node readiness is True" snapshot_item_field nodes.json node-a ready '"True"'
check "projected operator availability is True" snapshot_item_field clusteroperators.json authentication available '"True"'
check "scratch directory removed after a successful run" scratch_is_empty

###########################################
# (b2) Nonempty degraded response
###########################################
echo "scenario: degraded (one degraded operator)"
run_step degraded
check "step exits non-zero" rc_nonzero
check "report names the degraded operator" report_has 'Degraded Operators: authentication'
check "report does not also claim operators healthy" report_lacks 'All operators: HEALTHY'
check "nodes still evaluated and READY" report_has 'All nodes: READY'
check "overall status FAILED" report_verdict_is FAILED

###########################################
# (b3) Nonempty unavailable response
###########################################
echo "scenario: unavailable (one unavailable operator)"
run_step unavailable
check "step exits non-zero" rc_nonzero
check "report names the unavailable operator" report_has 'Unavailable Operators: dns'
check "report does not also claim operators healthy" report_lacks 'All operators: HEALTHY'
check "overall status FAILED" report_verdict_is FAILED

###########################################
# (b4) Nonempty NotReady node response
###########################################
echo "scenario: notready (one NotReady node)"
run_step notready
check "step exits non-zero" rc_nonzero
check "report names the NotReady node" report_has 'NotReady Nodes: node-b'
check "report does not also claim nodes READY" report_lacks 'All nodes: READY'
check "operators still evaluated and healthy" report_has 'All operators: HEALTHY'
check "overall status FAILED" report_verdict_is FAILED

# The same NotReady node, seen by the report only: the later snapshot read is
# healthy, so the snapshot cannot be what fails the run and the report-side
# verdict has to stand on its own.
echo "scenario: report_notready_only (report sees NotReady, snapshot healthy)"
run_step report_notready_only
check "step exits non-zero" rc_is 1
check "report names the NotReady node" report_has 'NotReady Nodes: node-b'
check "report does not also claim nodes READY" report_lacks 'All nodes: READY'
check "overall status FAILED" report_verdict_is FAILED
check "the snapshot itself verified the nodes" metadata_eq '.nodes_verified' 'true'
check "the snapshot saw no NotReady node" metadata_eq '.notready_nodes' '[]'
check "the snapshot verified the operators" metadata_eq '.clusteroperators_verified' 'true'
check "the snapshot capture completed" stderr_has 'Cluster install snapshot JSON written'

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
