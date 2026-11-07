#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"
result_file="${ARTIFACT_DIR}/storage-checkup-result.json"
validation_file="${ARTIFACT_DIR}/validation.json"
workload_file="${ARTIFACT_DIR}/checkup-pods.json"
printf '{}\n' > "${result_file}"
printf '[]\n' > "${validation_file}"
printf '{}\n' > "${workload_file}"
printf '{}\n' > "${ARTIFACT_DIR}/context.json"
failure_reason="Storage checkup runner failed before results were validated"
failure_category=setup
job_complete=false
namespace=""
started=${SECONDS}

capture_result() {
  # A failed API request can leave partial output. Keep the last complete JSON
  # document so that reporting also works when the API is unavailable.
  if oc --request-timeout=10s -n "${namespace}" get configmap storage-checkup-config -o json \
    > "${result_file}.tmp" &&
    jq -e 'type == "object" and (.data | type == "object")' "${result_file}.tmp" > /dev/null; then
    mv "${result_file}.tmp" "${result_file}"
  else
    return 1
  fi
}

finish() {
  local exit_code=$?
  trap - EXIT
  if [[ -n ${namespace} && ${exit_code} != 0 ]]; then
    capture_result || true
  fi
  if [[ -n ${namespace} ]]; then
    # Record the actual runtime image IDs as well as the CSV pullspec. An API
    # outage during diagnostics must not replace the execution result.
    if oc --request-timeout=10s -n "${namespace}" get pods -l job-name=storage-checkup -o json \
      > "${workload_file}.tmp" && jq -e '.items | type == "array"' "${workload_file}.tmp" > /dev/null; then
      mv "${workload_file}.tmp" "${workload_file}"
    fi
  fi
  jq -n --argjson code "${exit_code}" --argjson elapsed "$((SECONDS - started))" \
    --argjson complete "${job_complete}" --arg reason "${failure_reason}" \
    --arg category "${failure_category}" --arg namespace "${namespace}" \
    --slurpfile context "${ARTIFACT_DIR}/context.json" --slurpfile result "${result_file}" \
    --slurpfile validation "${validation_file}" --slurpfile pods "${workload_file}" '
    ($code == 0 or ($complete and any($validation[0][]; .passed == false))) as $executed |
    {
      status: (if $code == 0 then "passed" else "failed" end),
      exit_code: $code, duration_seconds: $elapsed,
      failure_category: (if $code == 0 then null else $category end),
      context: $context[0], namespace: $namespace,
      runtime_images: [$pods[0].items[]? | .metadata.name as $pod |
        .status.containerStatuses[]? | select(.name == "storage-checkup") |
        {pod: $pod, image: .image, image_id: .imageID}],
      checks: ([{name: "execution", category: "execution", passed: $executed,
        message: (if $executed then "Storage checkup Job completed" else
          ([$reason, ($result[0].data["status.failureReason"] // "")] |
            map(tostring | select(. != "")) | join("\n")) end)}] + $validation[0] |
        map(. + {outcome: (if .passed != true then "failed"
          elif .skipped == true then "skipped" else "passed" end)}))
    }
  ' > "${ARTIFACT_DIR}/storage-checkup-summary.json"
  jq -r '
    # Remove characters XML 1.0 cannot represent, then escape XML markup.
    def xml: tostring | explode | map(select(. == 9 or . == 10 or . == 13 or
      (. >= 32 and . <= 55295) or (. >= 57344 and . <= 65533) or
      (. >= 65536 and . <= 1114111))) | implode | @html;
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    ("<testsuite name=\"cnv-storage-checkup\" tests=\"" + (.checks | length | tostring) +
      "\" failures=\"" + ([.checks[] | select(.outcome == "failed")] | length | tostring) +
      "\" skipped=\"" + ([.checks[] | select(.outcome == "skipped")] | length | tostring) +
      "\" time=\"" + (.duration_seconds | tostring) + "\">"),
    "<properties>",
    (.context | to_entries[] |
      "<property name=\"" + (.key | xml) + "\" value=\"" + (.value | xml) + "\"/>"),
    "</properties>",
    (.checks[] |
      ("<testcase classname=\"cnv.storage." + (.category | xml) + "\" name=\"" + (.name | xml) + "\">"),
      (if .outcome == "failed" then
        "<failure message=\"" + ((.message // "Required check failed") | xml) + "\">" +
        ((.value // .message // "Required result is missing or invalid") | xml) + "</failure>"
      elif .outcome == "skipped" then
        "<skipped message=\"" + ((.value // .message) | xml) + "\"/>" else empty end),
      ("<system-out>" + (tojson | xml) + "</system-out>"),
      "</testcase>"),
    ("<system-out>" + (tojson | xml) + "</system-out>"),
    "</testsuite>"
  ' "${ARTIFACT_DIR}/storage-checkup-summary.json" > "${ARTIFACT_DIR}/junit_storage_checkup.xml"
  exit "${exit_code}"
}
trap finish EXIT
trap 'failure_reason="Storage checkup runner was terminated"; exit 143' TERM
trap 'failure_reason="Storage checkup runner was interrupted"; exit 130' INT

fail() {
  failure_reason=$1
  echo "${failure_reason}" >&2
  exit 1
}

[[ ${CHECKUP_NUM_VMS} =~ ^([1-9]|[1-9][0-9]|100)$ ]] || fail "CHECKUP_NUM_VMS must be between 1 and 100"
[[ ${CHECKUP_JOB_TIMEOUT_SECONDS} =~ ^[1-9][0-9]*$ ]] || fail "CHECKUP_JOB_TIMEOUT_SECONDS must be a positive integer"
# Reserve five minutes of the registry step's 40-minute timeout for setup,
# API calls, and reporting after the Job deadline.
(( CHECKUP_JOB_TIMEOUT_SECONDS <= 2100 )) || fail "CHECKUP_JOB_TIMEOUT_SECONDS must not exceed 2100"

duration_seconds() {
  jq -ern --arg duration "$1" '
    if ($duration | test("^([0-9]+(\\.[0-9]+)?[hms])+$")) then
      [$duration | scan("([0-9]+(?:\\.[0-9]+)?)([hms])") |
        (.[0] | tonumber) * ({h: 3600, m: 60, s: 1}[.[1]])] | add | select(. > 0)
    else error("Use a positive duration in hours, minutes, or seconds") end
  '
}
checkup_seconds=$(duration_seconds "${CHECKUP_TIMEOUT}") || fail "Invalid CHECKUP_TIMEOUT"
vmi_seconds=$(duration_seconds "${CHECKUP_VMI_TIMEOUT}") || fail "Invalid CHECKUP_VMI_TIMEOUT"
jq -en --argjson checkup "${checkup_seconds}" --argjson vmi "${vmi_seconds}" \
  --argjson job "${CHECKUP_JOB_TIMEOUT_SECONDS}" '$vmi < $checkup and $checkup < $job' > /dev/null \
  || fail "Timeouts must satisfy CHECKUP_VMI_TIMEOUT < CHECKUP_TIMEOUT < CHECKUP_JOB_TIMEOUT_SECONDS"
case ${CHECKUP_SKIP_TEARDOWN} in
  never|onfailure|always) ;;
  *) fail "CHECKUP_SKIP_TEARDOWN must be never, onfailure, or always" ;;
esac
jq -en --argjson expected "${CHECKUP_EXPECTED_RESULTS}" '
  $expected | type == "object" and all(.[];
    . as $pattern | type == "string" and ("" | test($pattern) | true))
' > /dev/null || fail "CHECKUP_EXPECTED_RESULTS must be a JSON object of valid regular-expression strings"

context="${SHARED_DIR}/cnv-storage-checkup-context.json"
jq -e 'select(type == "object")' "${context}" > "${ARTIFACT_DIR}/context.json.tmp" \
  || fail "Could not read the prepared storage checkup context"
mv "${ARTIFACT_DIR}/context.json.tmp" "${ARTIFACT_DIR}/context.json"
image=$(jq -er '.image | select(type == "string" and length > 0)' "${context}")
storage_class=$(jq -er '.storage_class | select(type == "string" and length > 0)' "${context}")

namespace=$(printf '%s\n' "${CHECKUP_NAMESPACE_MANIFEST}" |
  oc --request-timeout=30s create -f - -o jsonpath='{.metadata.name}')
printf '%s\n' "${namespace}" > "${SHARED_DIR}/cnv-storage-checkup-namespace"

# The registry provides these manifests as step environment defaults. Only
# runtime values are substituted here; resource definitions live in the ref.
render_manifest() {
  sed -e "s|__NAMESPACE__|${namespace}|g" \
    -e "s|__CHECKUP_TIMEOUT__|${CHECKUP_TIMEOUT}|g" \
    -e "s|__STORAGE_CLASS__|${storage_class}|g" \
    -e "s|__CHECKUP_VMI_TIMEOUT__|${CHECKUP_VMI_TIMEOUT}|g" \
    -e "s|__CHECKUP_NUM_VMS__|${CHECKUP_NUM_VMS}|g" \
    -e "s|__CHECKUP_SKIP_TEARDOWN__|${CHECKUP_SKIP_TEARDOWN}|g" \
    -e "s|__CHECKUP_JOB_TIMEOUT_SECONDS__|${CHECKUP_JOB_TIMEOUT_SECONDS}|g" \
    -e "s|__CHECKUP_IMAGE__|${image}|g"
}

printf '%s\n' "${CHECKUP_RBAC_MANIFEST}" | render_manifest | oc --request-timeout=30s create -f -
printf '%s\n' "${CHECKUP_CONFIGMAP_MANIFEST}" | render_manifest | oc --request-timeout=30s create -f -
printf '%s\n' "${CHECKUP_JOB_MANIFEST}" | render_manifest | oc --request-timeout=30s create -f -

echo "Running CNV storage checkup in ${namespace} against ${storage_class}"
failure_category=execution
deadline=$((SECONDS + CHECKUP_JOB_TIMEOUT_SECONDS))
while true; do
  remaining_seconds=$((deadline - SECONDS))
  (( remaining_seconds > 0 )) || fail "Timed out waiting for the storage checkup Job"
  # Retry transient API failures and preserve the last complete Job document.
  if oc --request-timeout="$((remaining_seconds < 30 ? remaining_seconds : 30))s" \
    -n "${namespace}" get job storage-checkup -o json > "${ARTIFACT_DIR}/job.json.tmp" &&
    jq -e 'type == "object"' "${ARTIFACT_DIR}/job.json.tmp" > /dev/null; then
    mv "${ARTIFACT_DIR}/job.json.tmp" "${ARTIFACT_DIR}/job.json"
    if jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' "${ARTIFACT_DIR}/job.json" > /dev/null; then
      job_complete=true
      break
    fi
    if jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' "${ARTIFACT_DIR}/job.json" > /dev/null; then
      fail "Storage checkup Job failed; see its ConfigMap, pod logs, and events in the artifacts"
    fi
  else
    echo "Could not read a complete Job status; retrying until its deadline" >&2
  fi
  remaining_seconds=$((deadline - SECONDS))
  (( remaining_seconds > 0 )) || fail "Timed out waiting for the storage checkup Job"
  sleep "$((remaining_seconds < 10 ? remaining_seconds : 10))"
done

failure_category=results
capture_result || fail "Could not retrieve a complete storage checkup result ConfigMap"
jq --argjson expected "${CHECKUP_EXPECTED_RESULTS}" '
  def nonempty_string: if type == "string" then length > 0 else false end;
  .data as $data |
  [
    {name: "succeeded", category: "results", value: $data["status.succeeded"],
      passed: ($data["status.succeeded"] == "true")},
    {name: "failureReason", category: "results", value: $data["status.failureReason"],
      passed: ($data | has("status.failureReason") and .["status.failureReason"] == "")},
    {name: "completionTimestamp", category: "results", value: $data["status.completionTimestamp"],
      passed: ($data["status.completionTimestamp"] | nonempty_string)}
  ] +
  (["pvcBound", "vmBootFromGoldenImage", "vmVolumeClone", "vmHotplugVolume", "concurrentVMBoot", "vmLiveMigration"] |
    map(. as $name | ($data["status.result." + $name] // "") as $value |
      {name: $name, category: "operations", value: $value,
        passed: (if ($value | nonempty_string) then
          $name == "vmLiveMigration" or ($value | test("^skip"; "i") | not) else false end),
        skipped: (if $name == "vmLiveMigration" and ($value | nonempty_string) then
          ($value | test("(^|\\n)(VMI \\\"[^\\\"]+\\\" )?migration completed(\\n|$)") | not)
          else false end)})) +
  ($expected | to_entries | map(. as $entry |
    ($data["status.result." + $entry.key] // "") as $value |
    {name: ("expectation: " + $entry.key), category: "expectations", value: $value,
      passed: (if ($value | nonempty_string) then $value | test($entry.value) else false end)}))
' "${result_file}" > "${validation_file}.tmp"
mv "${validation_file}.tmp" "${validation_file}"
if ! jq -e 'all(.[]; .passed)' "${validation_file}" > /dev/null; then
  fail "Checkup result validation failed: $(jq -r '[.[] | select(.passed != true) | .name] | join(", ")' "${validation_file}")"
fi
echo "CNV storage checkup passed"
