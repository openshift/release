#!/bin/bash

# Runs in post, against a deployment that is usually already broken, so it is
# best-effort end to end: errexit explicitly off (see below), every oc call
# time-boxed, and a failure anywhere never stops later collection. Exits 0 on
# the normal path; any other exit is a bug in this collector.

set -o nounset
set -o pipefail
# ci-operator prepends "#!/bin/bash\nset -eu\n" to every step's commands
# (ci-tools multi_stage.CommandPrefix), so errexit is already on before this
# script's first line and the shebang above is only a comment. Turn it back off
# explicitly: the first oc call that fails - `oc logs --previous` for a
# container that never restarted always does - would otherwise kill the gather
# where it stands, silently, because that call sends stderr to /dev/null.
set +o errexit

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

# Seconds any single oc call may run. An unbounded call against a cluster
# mid-teardown burns the step's budget and loses everything after it.
CALL_TIMEOUT=60
# Ceiling on the whole step. A per-call timeout alone does not bound it: against
# a hung API server every call burns its full timeout and the sum runs for hours.
DEADLINE_AT=$(( $(date +%s) + 600 ))
LOG_TAIL=2000

ABSENT="${ARTIFACT_DIR}/absent-resources.txt"
SUMMARY="${ARTIFACT_DIR}/gather-summary.txt"
TOTAL_PODS=0
TOTAL_LOGS=0

past_deadline() { [[ "$(date +%s)" -ge "${DEADLINE_AT}" ]]; }

# --- result, said out loud --------------------------------------------------
# An empty artifact directory reads as a quiet system, not a failed collector.
# Say what was collected, every time - from an EXIT trap installed before any
# collection, so the report lands even when the script dies part-way through.
COMPLETE=false
# shellcheck disable=SC2329  # invoked by the EXIT trap installed below
report() {
  local rc=$?
  {
    [[ "${COMPLETE}" == true ]] || printf \
      'INCOMPLETE: quay-gather exited early (status %s); counts below are partial.\n' "${rc}"
    printf 'namespaces gathered: %s\n' "$(echo "${NAMESPACES:-}" | tr '\n' ' ')"
    printf 'totals: pods=%s container-logs=%s\n' "${TOTAL_PODS}" "${TOTAL_LOGS}"
  } >>"${SUMMARY}"

  if [[ "${TOTAL_PODS}" -eq 0 || "${TOTAL_LOGS}" -eq 0 ]]; then
    {
      echo "quay-gather collected ${TOTAL_PODS} pods and ${TOTAL_LOGS} container logs."
      echo
      echo "Every job running this step has Quay deployed, so this is a broken"
      echo "collector, not a quiet cluster. Likely causes, in order:"
      echo "  - the step exited before it finished (an INCOMPLETE line in"
      echo "    gather-summary.txt next to this one records that, with the status);"
      echo "  - the deploy path uses a namespace this step did not discover"
      echo "    (see gathered-namespaces.txt and quayregistries.json);"
      echo "  - the deploy failed before any pod was created (see the per-namespace"
      echo "    events.txt and olm-csvs.yaml);"
      echo "  - the API server was unreachable, or the step ran out of time (an"
      echo "    absent-resources.txt file next to this one records either)."
    } >"${ARTIFACT_DIR}/EMPTY-GATHER.txt"
    cat "${ARTIFACT_DIR}/EMPTY-GATHER.txt" >&2
  fi
  cat "${SUMMARY}" >&2
}
trap report EXIT
# An aborted job or a hit job deadline reaches the step as SIGTERM, which would
# otherwise kill the shell without running the EXIT trap. Turn it into a normal
# exit so the report still lands; grace_period in the ref is what buys the time.
trap 'exit 143' TERM INT

# run <outfile> <oc args...> — capture stdout+stderr, record failure in-band so a
# reader can tell "command failed" from "no such object". Returns the oc status so
# callers can count what was actually collected, and sets RUN_PARTIAL=true when the
# call failed *after* writing output, which the status alone cannot express.
RUN_PARTIAL=false
# Scratch sink for one call's stderr, kept out of ARTIFACT_DIR so a step killed
# mid-call leaves no stray file among the artifacts.
RUN_ERR="$(mktemp)"
run() {
  local out="$1"
  shift
  RUN_PARTIAL=false
  if past_deadline; then
    echo "[quay-gather] SKIPPED (deadline reached): oc $*" >>"${ABSENT}"
    return 1
  fi
  local rc=0
  # stderr goes to its own file until the test below, then back in-band. Merged
  # into ${out} from the start it would be indistinguishable from log content,
  # and the most common failure here writes only to stderr: a container that
  # never started ("is waiting to start: PodInitializing") would then be counted
  # as a collected log, silencing the marker on exactly the deploys it flags.
  timeout "${CALL_TIMEOUT}" oc "$@" >"${out}" 2>"${RUN_ERR}" || {
    rc=$?
    # Test before anything else is appended: afterwards the file is non-empty
    # either way and the two cases can no longer be told apart.
    [[ -s "${out}" ]] && RUN_PARTIAL=true
  }
  cat "${RUN_ERR}" >>"${out}"
  [[ "${rc}" -eq 0 ]] || echo "[quay-gather] FAILED (exit ${rc}): oc $*" >>"${out}"
  return "${rc}"
}

# gather_optional <outfile> <oc args...> — for resources whose CRD may not be
# installed. Records absence in one line instead of leaving a 0-byte file, which
# reads as "none exist" rather than "the type does not exist here".
gather_optional() {
  local out="$1"
  shift
  if past_deadline; then
    echo "[quay-gather] SKIPPED (deadline reached): oc $*" >>"${ABSENT}"
    return
  fi
  local err
  err="$(timeout "${CALL_TIMEOUT}" oc "$@" 2>&1 >"${out}")" || {
    rm -f "${out}"
    # Report what oc actually said: "not available" is wrong when the failure is
    # an unreachable API server rather than a missing CRD.
    echo "oc $* -> unavailable: ${err//$'\n'/ }" >>"${ABSENT}"
  }
}

echo "Gathering Quay operator diagnostics..."

# --- namespace discovery ----------------------------------------------------
# Do not hardcode. Two deploy paths use different namespaces: quay-deploy-aws-s3
# and quay-deploy-gcp-gcs install into quay-enterprise, while quay-install-quay
# uses `quay` with the operator in openshift-operators. A hardcoded pair silently
# collects nothing for the other path.
# The known names are always in the union, not just a fallback: a partial
# discovery (Subscription lookup lost to RBAC, or a spec.name mismatch) would
# otherwise silently drop the operator namespace and its logs.
discover_namespaces() {
  {
    # QUAYNAMESPACE is the namespace the deploy steps are told to use; it is the
    # only source that still works when the cluster API is unreachable.
    printf '%s\n' "${QUAYNAMESPACE:-}"
    printf '%s\n' quay quay-enterprise openshift-operators
    timeout "${CALL_TIMEOUT}" oc get quayregistry --all-namespaces \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null
    timeout "${CALL_TIMEOUT}" oc get subscription --all-namespaces \
      -o jsonpath='{range .items[?(@.spec.name=="quay-operator")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null
  } | sed '/^[[:space:]]*$/d' | sort -u
}

NAMESPACES="$(discover_namespaces)"
# Drop names that do not exist, so the known-name union does not fill the
# artifact dir with NotFound files. If the listing fails, keep the whole union.
EXISTING="$(timeout "${CALL_TIMEOUT}" oc get namespaces \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
if [[ -n "${EXISTING}" ]]; then
  NAMESPACES="$(grep -Fxf <(echo "${EXISTING}") <(echo "${NAMESPACES}"))"
fi
if [[ -z "${NAMESPACES}" ]]; then
  echo "[quay-gather] no candidate namespace exists; collecting cluster scope only" >&2
fi
echo "Gathering from namespaces:" >&2
echo "${NAMESPACES}" >&2
echo "${NAMESPACES}" >"${ARTIFACT_DIR}/gathered-namespaces.txt"

# --- tested-images.json -----------------------------------------------------
# Machine-readable record of the images this run tested, parsed by
# release-readiness (contract v1: change it additively only). It joins on the
# requested digests (pod spec.image, CSV related images, the catalog's bundle
# image); image_id is diagnostic only. Written before the bulk collection so the
# deadline cannot skip it. Anything that could not be read is null and named in
# "missing", with "complete": false; never a failure.
write_tested_images() {
  local out="${ARTIFACT_DIR}/tested-images.json"
  local missing=() json
  if ! command -v jq >/dev/null 2>&1; then
    echo '{"schema_version":1,"complete":false,"missing":["jq"]}' >"${out}"
    return
  fi
  oc_json() { ! past_deadline && timeout "${CALL_TIMEOUT}" oc "$@" -o json 2>/dev/null; }

  local requested="" resolved=""
  [[ -s "${SHARED_DIR:-}/quay_index_image_requested" ]] && requested="$(<"${SHARED_DIR}/quay_index_image_requested")"
  [[ -s "${SHARED_DIR:-}/quay_index_image" ]] && resolved="$(<"${SHARED_DIR}/quay_index_image")"
  # A tag-form override is recorded there verbatim; resolved_ref is digests only.
  [[ "${resolved}" == *@sha256:* ]] || resolved=""

  local sub="null" sub_ns="" csv=""
  if json="$(oc_json get subscription --all-namespaces)"; then
    sub="$(jq -c '[.items[] | select(.spec.name == "quay-operator")][0]' <<<"${json}")"
    sub_ns="$(jq -r '.metadata.namespace // empty' <<<"${sub}")"
    csv="$(jq -r '.status.installedCSV // .status.currentCSV // empty' <<<"${sub}")"
  fi
  [[ -n "${sub_ns}" ]] || missing+=("subscription")
  [[ -n "${csv}" ]] || missing+=("operator.csv")

  # Without the resolve step's record, a digest-pinned CatalogSource is just as exact.
  if [[ -z "${resolved}" && -n "${sub_ns}" ]] && json="$(oc_json get catalogsource -n \
      "$(jq -r '.spec.sourceNamespace' <<<"${sub}")" "$(jq -r '.spec.source' <<<"${sub}")")"; then
    resolved="$(jq -r '.spec.image // empty | select(contains("@sha256:"))' <<<"${json}")"
  fi
  [[ -n "${requested}" ]] || missing+=("catalog.requested_ref")
  [[ -n "${resolved}" ]] || missing+=("catalog.resolved_ref")

  local quay_version=""
  json="$(oc_json get quayregistry --all-namespaces)" \
    && quay_version="$(jq -r '[.items[].status.currentVersion // empty][0] // empty' <<<"${json}")"
  [[ -n "${quay_version}" ]] || missing+=("quay_version")

  # The bundle is the installed CSV's olm.bundle image in the pinned catalog. The
  # catalog repo is public, so this needs no credentials; FBC is YAML or JSON.
  local bundle="" fbc
  if [[ -n "${csv}" && -n "${resolved}" ]] && ! past_deadline && fbc="$(mktemp -d)"; then
    if timeout "${CALL_TIMEOUT}" oc image extract "${resolved}" --path "/configs/:${fbc}" \
        --confirm --filter-by-os=linux/amd64 >/dev/null 2>&1; then
      bundle="$(find "${fbc}" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec awk -v csv="${csv}" '
        function done_doc() { if (schema == "olm.bundle" && name == csv) print image; schema = name = image = "" }
        FNR == 1 { done_doc() }
        /^---/ { done_doc(); next }
        /^schema:/ { schema = $2 } /^name:/ { name = $2 } /^image:/ { image = $2 }
        END { done_doc() }' {} + 2>/dev/null | head -n1)"
      [[ -n "${bundle}" ]] || bundle="$(find "${fbc}" -type f -name '*.json' -exec cat {} + 2>/dev/null \
        | jq -r --arg csv "${csv}" 'select(.schema == "olm.bundle" and .name == $csv) | .image' 2>/dev/null | head -n1)"
    fi
    rm -rf -- "${fbc}"
  fi
  [[ -n "${bundle}" ]] || missing+=("operator.bundle_ref")

  # Images, two sources. "pod": each operator or Quay component pod, by a fixed
  # quay-component label -> role map. "csv-related": the operand images the
  # installed CSV hands the operator, which covers images no pod runs (builder,
  # builder-qemu); the *_PREVIOUS images only serve upgrades and are left out.
  local images="[]" ns more
  while IFS= read -r ns; do
    [[ -n "${ns}" ]] || continue
    json="$(oc_json get pods -n "${ns}")" || { missing+=("pods/${ns}"); continue; }
    more="$(jq -c '{"quay-app": "quay", "quay-app-upgrade": "quay", "quay-mirror": "quay",
        "clair-app": "clair", "clair-postgres": "clair-postgres", "postgres": "postgres",
        "redis": "redis"} as $roles
      | [.items[] | . as $p | $p.spec.containers[] as $c
      | (if $c.name == "quay-operator" then "quay-operator"
         else ($p.metadata.labels["quay-component"] // "" | $roles[.] // empty) end) as $role
      | {role: $role, source: "pod", pod: $p.metadata.name, container: $c.name,
         requested_ref: $c.image,
         image_id: ([$p.status.containerStatuses[]? | select(.name == $c.name) | .imageID
                     | select(. != "")][0] // null)}]' <<<"${json}")" \
      && images="$(jq -c --argjson more "${more}" '. + $more' <<<"${images}")" \
      || missing+=("pods/${ns}")
  done <<<"${NAMESPACES}"
  if [[ -n "${csv}" ]] && json="$(oc_json get csv -n "${sub_ns}" "${csv}")"; then
    more="$(jq -c '{"QUAY": "quay", "CLAIR": "clair", "BUILDER": "builder",
        "BUILDER_QEMU": "builder-qemu", "POSTGRES": "postgres",
        "CLAIRPOSTGRES": "clair-postgres", "REDIS": "redis"} as $roles
      | [.spec.install.spec.deployments[]?.spec.template.spec.containers[]?
      | select(.name == "quay-operator") as $c
      | ({role: "quay-operator", ref: $c.image},
         ($c.env[]? | select(.name | startswith("RELATED_IMAGE_COMPONENT_"))
          | {role: $roles[.name | ltrimstr("RELATED_IMAGE_COMPONENT_")], ref: .value}))
      | select(.role != null)
      | {role, source: "csv-related", pod: null, container: null,
         requested_ref: (if (.ref // "") == "" then null else .ref end),
         image_id: null}] | unique' <<<"${json}")" \
      && images="$(jq -c --argjson more "${more}" '. + $more' <<<"${images}")" \
      || missing+=("csv-related")
  else
    missing+=("csv-related")
  fi
  [[ "$(jq 'length' <<<"${images}")" -gt 0 ]] || missing+=("images")
  # requested_ref is the join key, so a tag-only ref leaves the record incomplete.
  jq -e 'all(.[]; (.requested_ref // "") | test("@sha256:[0-9a-f]{64}$"))' <<<"${images}" >/dev/null \
    || missing+=("images.requested_ref")
  jq -e 'any(.[]; .role == "builder")' <<<"${images}" >/dev/null || missing+=("builder")

  local missing_json="[]"
  [[ ${#missing[@]} -eq 0 ]] || missing_json="$(printf '%s\n' "${missing[@]}" | jq -R . | jq -sc .)"
  jq -n \
    --arg job "${JOB_NAME:-}" --arg build "${BUILD_ID:-}" --arg quay_version "${quay_version}" \
    --arg requested "${requested}" --arg resolved "${resolved}" \
    --arg channel "$(jq -r '.spec.channel // empty' <<<"${sub}")" \
    --arg csv "${csv}" --arg bundle "${bundle}" \
    --argjson missing "${missing_json}" --argjson images "${images}" \
    'def opt: if . == "" then null else . end;
    {schema_version: 1, job_name: ($job | opt), build_id: ($build | opt),
     captured_at: (now | todate), complete: ($missing | length == 0), missing: $missing,
     quay_version: ($quay_version | opt),
     catalog: {requested_ref: ($requested | opt), resolved_ref: ($resolved | opt), channel: ($channel | opt)},
     operator: {csv: ($csv | opt), bundle_ref: ($bundle | opt)},
     images: $images, provenance: []}' >"${out}" \
    || echo '{"schema_version":1,"complete":false,"missing":["write"]}' >"${out}"
  echo "[quay-gather] tested-images.json: $(jq -c '{complete, missing}' "${out}" 2>/dev/null)" >&2
}
write_tested_images

# --- cluster-scoped ---------------------------------------------------------
run "${ARTIFACT_DIR}/quayregistries.json" get quayregistry --all-namespaces -o json
run "${ARTIFACT_DIR}/quayregistry-describe.txt" describe quayregistry --all-namespaces
run "${ARTIFACT_DIR}/olm-subscriptions.yaml" get subscriptions --all-namespaces -o yaml
run "${ARTIFACT_DIR}/olm-csvs.yaml" get csv --all-namespaces -o yaml

# Present only when the matching operator is installed: NooBaa with ODF
# (quay-install-odf-operator), QuayIntegration with the quay-bridge-operator
# (quay-enable-quay-bridge-operator). Neither is in every job's path, and
# quayintegrations was previously queried without --all-namespaces, so it only
# ever saw the step's own namespace.
gather_optional "${ARTIFACT_DIR}/noobaas.json" get noobaas --all-namespaces -o json
gather_optional "${ARTIFACT_DIR}/quayintegrations.json" get quayintegrations --all-namespaces -o json

# --- per namespace ----------------------------------------------------------
# NAMESPACES is newline-separated; discovery already stripped blanks.
while IFS= read -r ns; do
  [[ -n "${ns}" ]] || continue
  if past_deadline; then
    echo "[quay-gather] SKIPPED (deadline reached): namespace ${ns}" >>"${ABSENT}"
    continue
  fi
  nsdir="${ARTIFACT_DIR}/${ns}"
  mkdir -p "${nsdir}"

  run "${nsdir}/pods.txt" get pods -n "${ns}" -o wide
  run "${nsdir}/events.txt" get events -n "${ns}" --sort-by=.lastTimestamp

  # Logs. Init containers matter as much as app containers here: Quay renders its
  # config and runs database migrations in them, so a migration failure is
  # invisible if only .spec.containers is walked.
  logdir="${nsdir}/logs"
  mkdir -p "${logdir}"
  ns_pods=0
  ns_logs=0
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    if past_deadline; then
      echo "[quay-gather] SKIPPED (deadline reached): logs for ${ns}/${pod}" >>"${ABSENT}"
      break
    fi
    ns_pods=$(( ns_pods + 1 )); TOTAL_PODS=$(( TOTAL_PODS + 1 ))
    containers="$(timeout "${CALL_TIMEOUT}" oc get pod "${pod}" -n "${ns}" \
      -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)"
    while IFS= read -r container; do
      [[ -n "${container}" ]] || continue
      # Guard here too: a pod with N containers would otherwise run N calls past
      # the deadline, overrunning it by N x CALL_TIMEOUT.
      if past_deadline; then
        echo "[quay-gather] SKIPPED (deadline reached): logs for ${ns}/${pod}/${container}" >>"${ABSENT}"
        break
      fi
      # Count only logs that were actually retrieved: run() always leaves a file,
      # with a FAILED marker inside when the call failed, so counting files would
      # report collection that never happened. A call that streamed log content
      # and then failed (RUN_PARTIAL) did collect evidence, and counts.
      if run "${logdir}/${pod}-${container}.log" \
        logs -n "${ns}" "${pod}" -c "${container}" --tail="${LOG_TAIL}" \
        || [[ "${RUN_PARTIAL}" == true ]]; then
        ns_logs=$(( ns_logs + 1 )); TOTAL_LOGS=$(( TOTAL_LOGS + 1 ))
      fi
      # A crashlooping pod's current log is often empty or a partial restart; the
      # failure is in the prior container. Keep the file only if it has content,
      # so pods that never restarted add no noise.
      prev="${logdir}/${pod}-${container}-previous.log"
      timeout "${CALL_TIMEOUT}" oc logs -n "${ns}" "${pod}" -c "${container}" \
        --previous --tail="${LOG_TAIL}" >"${prev}" 2>/dev/null
      prev_status=$?
      if [[ "${prev_status}" -ne 0 && -s "${prev}" ]]; then
        # Killed mid-stream: keep the partial capture but say so in-band.
        echo "[quay-gather] TRUNCATED (exit ${prev_status}): oc logs --previous" >>"${prev}"
      fi
      if [[ -s "${prev}" ]]; then
        # A kept previous log is collected evidence. Count it, or a crashlooping
        # pod caught between restarts reports zero logs - and the loud banner
        # below calls the collector broken - while its root cause sits on disk.
        ns_logs=$(( ns_logs + 1 )); TOTAL_LOGS=$(( TOTAL_LOGS + 1 ))
      else
        rm -f "${prev}"
      fi
    done <<<"${containers}"
  done < <(timeout "${CALL_TIMEOUT}" oc get pods -n "${ns}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  printf '%s pods=%s container-logs=%s\n' "${ns}" "${ns_pods}" "${ns_logs}" >>"${SUMMARY}"
done <<<"${NAMESPACES}"

COMPLETE=true
echo "Quay diagnostics gathering complete."
exit 0
