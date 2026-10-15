#!/usr/bin/env bash
# Prepares DUT namespace, workdir PVC, kubeconfig Secret, and copies the Prow
# checkout into the PVC for Job-based Service Mesh suites.
#
# Also installs shared helpers into ${SHARED_DIR}/servicemesh-common-job-lib.sh
# for subsequent suite steps (ci-operator only injects each step's commands.sh).

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${SHARED_DIR:-}" ]]; then
  echo "ERROR: SHARED_DIR is required" >&2
  exit 1
fi

# Canonical shared Job helpers live in this heredoc (step-registry only allows
# *-commands.sh). Subsequent suite steps source ${SHARED_DIR}/servicemesh-common-job-lib.sh.
cat > "${SHARED_DIR}/servicemesh-common-job-lib.sh" <<'JOBLIB_EOF'
# Shared helpers for Job-based OpenShift Service Mesh CI suites.
# Installed into SHARED_DIR by servicemesh-common-prepare-job-workdir.

: "${MAISTRA_NAMESPACE:=maistra-e2e-test}"
: "${MAISTRA_WORKDIR_PVC:=maistra-workdir}"
: "${MAISTRA_WORKDIR_PVC_SIZE:=20Gi}"
: "${MAISTRA_COPY_POD:=maistra-workdir-copy}"
: "${MAISTRA_KUBECONFIG_SECRET:=ci-kubeconfig}"
: "${MAISTRA_JOB_TTL_SECONDS:=3600}"
: "${MAISTRA_JOB_WAIT_TIMEOUT:=100m}"
: "${MAISTRA_BUILDER_IMAGE:=}"

servicemesh_create_privileged_namespace() {
  local ns="${1:-${MAISTRA_NAMESPACE}}"
  if oc get namespace "${ns}" >/dev/null 2>&1; then
    echo "Namespace ${ns} already exists"
    return 0
  fi

  oc create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/audit: "privileged"
    pod-security.kubernetes.io/enforce: "privileged"
    pod-security.kubernetes.io/warn: "privileged"
EOF
  echo "Created namespace ${ns}"
}

servicemesh_ensure_workdir_pvc() {
  local ns="${1:-${MAISTRA_NAMESPACE}}"
  local pvc="${2:-${MAISTRA_WORKDIR_PVC}}"
  local size="${3:-${MAISTRA_WORKDIR_PVC_SIZE}}"

  if oc get pvc "${pvc}" -n "${ns}" >/dev/null 2>&1; then
    echo "PVC ${ns}/${pvc} already exists"
    return 0
  fi

  # Do not wait for Bound here: default CSI classes (e.g. gp3-csi) use
  # WaitForFirstConsumer and only bind after a consumer pod is scheduled.
  oc apply -n "${ns}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${ns}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${size}
EOF
  echo "Created PVC ${ns}/${pvc} (bind deferred until copy-pod consumer)"
}

servicemesh_ensure_kubeconfig_secret() {
  local ns="${1:-${MAISTRA_NAMESPACE}}"
  local secret="${2:-${MAISTRA_KUBECONFIG_SECRET}}"

  if [[ -z "${KUBECONFIG:-}" || ! -f "${KUBECONFIG}" ]]; then
    echo "ERROR: KUBECONFIG must point to a readable kubeconfig file" >&2
    return 1
  fi

  # Disable tracing around secret creation.
  local was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  set +x

  oc delete secret "${secret}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
  oc create secret generic "${secret}" \
    --from-file=kubeconfig="${KUBECONFIG}" \
    -n "${ns}" >/dev/null

  ${was_tracing} && set -x
  echo "Created kubeconfig Secret ${ns}/${secret}"
}

servicemesh_wait_pod_running() {
  local ns="$1"
  local pod="$2"
  local timeout_s="${3:-600}"
  local interval=10
  local elapsed=0

  while (( elapsed < timeout_s )); do
    local phase
    phase="$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Running" ]]; then
      echo "Pod ${ns}/${pod} is Running"
      return 0
    fi
    if [[ "${phase}" == "Failed" || "${phase}" == "Succeeded" ]]; then
      echo "ERROR: Pod ${ns}/${pod} is ${phase}" >&2
      oc describe pod "${pod}" -n "${ns}" >&2 || true
      return 1
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: timed out waiting for pod ${ns}/${pod}" >&2
  oc describe pod "${pod}" -n "${ns}" >&2 || true
  oc describe pvc -n "${ns}" >&2 || true
  return 1
}

# Wait until no VolumeAttachment remains for the PVC's PV (EBS Multi-Attach risk).
servicemesh_wait_volume_detached() {
  local ns="$1"
  local pvc="$2"
  local timeout_s="${3:-300}"
  local interval=5
  local elapsed=0
  local pv attachments

  pv="$(oc get pvc "${pvc}" -n "${ns}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  if [[ -z "${pv}" ]]; then
    echo "PVC ${ns}/${pvc} has no bound PV yet; nothing to detach"
    return 0
  fi

  echo "Waiting for VolumeAttachments of PV ${pv} to clear..."
  while (( elapsed < timeout_s )); do
    attachments="$(oc get volumeattachment -o custom-columns=NAME:.metadata.name,PV:.spec.source.persistentVolumeName --no-headers 2>/dev/null \
      | awk -v pv="${pv}" '$2 == pv { print $1 }' || true)"
    if [[ -z "${attachments}" ]]; then
      echo "VolumeAttachments cleared for PV ${pv}"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: VolumeAttachments still present for PV ${pv} after ${timeout_s}s:" >&2
  echo "${attachments}" >&2
  oc get volumeattachment >&2 || true
  return 1
}

servicemesh_fill_workdir_pvc() {
  local ns="${1:-${MAISTRA_NAMESPACE}}"
  local pvc="${2:-${MAISTRA_WORKDIR_PVC}}"
  local copy_pod="${3:-${MAISTRA_COPY_POD}}"
  local image="${4:-${MAISTRA_BUILDER_IMAGE}}"
  local pvc_phase

  if [[ -z "${image}" ]]; then
    echo "ERROR: MAISTRA_BUILDER_IMAGE is required to fill the workdir PVC" >&2
    return 1
  fi

  oc delete pod "${copy_pod}" -n "${ns}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  servicemesh_wait_volume_detached "${ns}" "${pvc}" 120 || true

  # Create the consumer first so WaitForFirstConsumer StorageClasses can bind.
  oc apply -n "${ns}" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${copy_pod}
  namespace: ${ns}
spec:
  restartPolicy: Never
  containers:
  - name: copy
    image: ${image}
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
      runAsUser: 0
    volumeMounts:
    - name: work
      mountPath: /work
  volumes:
  - name: work
    persistentVolumeClaim:
      claimName: ${pvc}
EOF

  servicemesh_wait_pod_running "${ns}" "${copy_pod}" 600

  pvc_phase="$(oc get pvc "${pvc}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "PVC ${ns}/${pvc} phase after copy-pod Running: ${pvc_phase:-unknown}"
  if [[ "${pvc_phase}" != "Bound" ]]; then
    echo "ERROR: PVC ${ns}/${pvc} is not Bound after copy-pod is Running" >&2
    oc describe pvc "${pvc}" -n "${ns}" >&2 || true
    oc describe pod "${copy_pod}" -n "${ns}" >&2 || true
    return 1
  fi

  echo "Copying source checkout into ${ns}/${copy_pod}:/work/ ..."
  # Trailing /. copies directory contents into dest.
  oc cp ./. "${ns}/${copy_pod}:/work/"

  echo "Deleting copy pod ${ns}/${copy_pod} to release RWO volume..."
  oc delete pod "${copy_pod}" -n "${ns}" --wait=true
  servicemesh_wait_volume_detached "${ns}" "${pvc}" 300
  echo "Workdir PVC ${ns}/${pvc} filled"
}

servicemesh_prepare_job_workdir() {
  local ns="${MAISTRA_NAMESPACE}"

  servicemesh_create_privileged_namespace "${ns}"
  # Allow privileged Job pods (builder image + docker/modules mounts).
  oc adm policy add-scc-to-user privileged -z default -n "${ns}" >/dev/null 2>&1 || true

  servicemesh_ensure_workdir_pvc "${ns}" "${MAISTRA_WORKDIR_PVC}" "${MAISTRA_WORKDIR_PVC_SIZE}"
  servicemesh_ensure_kubeconfig_secret "${ns}" "${MAISTRA_KUBECONFIG_SECRET}"
  servicemesh_fill_workdir_pvc "${ns}" "${MAISTRA_WORKDIR_PVC}" "${MAISTRA_COPY_POD}" "${MAISTRA_BUILDER_IMAGE}"
}

servicemesh_job_pod_name() {
  local ns="$1"
  local job="$2"
  oc get pods -n "${ns}" -l "job-name=${job}" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk 'NF{n=$0} END{print n}'
}

servicemesh_collect_job_logs() {
  local ns="$1"
  local job="$2"
  local out_dir="${3:-${ARTIFACT_DIR}}"
  local pod

  mkdir -p "${out_dir}"
  pod="$(servicemesh_job_pod_name "${ns}" "${job}")"
  if [[ -z "${pod}" ]]; then
    echo "WARNING: no pod found for job ${ns}/${job}; cannot collect logs"
    return 0
  fi

  echo "================================================================"
  echo "BEGIN job logs (${ns}/${job} pod ${pod})"
  echo "================================================================"
  oc logs "${pod}" -n "${ns}" --all-containers=true 2>&1 | tee "${out_dir}/job-${job}.log" || true
  echo "================================================================"
  echo "END job logs"
  echo "================================================================"
}

servicemesh_collect_job_artifacts() {
  local ns="$1"
  local job="$2"
  local remote_dir="${3:-/work/artifacts}"
  local out_dir="${4:-${ARTIFACT_DIR}}"
  local pod

  mkdir -p "${out_dir}"
  pod="$(servicemesh_job_pod_name "${ns}" "${job}")"
  if [[ -z "${pod}" ]]; then
    echo "WARNING: no pod found for job ${ns}/${job}; cannot collect artifacts"
    return 0
  fi

  echo "Copying artifacts from ${ns}/${pod}:${remote_dir} -> ${out_dir}"
  if oc exec -n "${ns}" "${pod}" -- sh -c "test -d '${remote_dir}'" >/dev/null 2>&1; then
    oc cp "${ns}/${pod}:${remote_dir}/." "${out_dir}/" || true
  else
    echo "WARNING: ${remote_dir} not present in job pod ${pod}"
  fi
}

servicemesh_describe_job_failure() {
  local ns="$1"
  local job="$2"

  echo "=== Job failure diagnostics for ${ns}/${job} ==="
  oc get job "${job}" -n "${ns}" -o yaml 2>&1 || true
  oc describe job "${job}" -n "${ns}" 2>&1 || true
  oc get pods -n "${ns}" -l "job-name=${job}" -o wide 2>&1 || true
  local pod
  pod="$(servicemesh_job_pod_name "${ns}" "${job}")"
  if [[ -n "${pod}" ]]; then
    oc describe pod "${pod}" -n "${ns}" 2>&1 || true
  fi
  oc get events -n "${ns}" --sort-by='.lastTimestamp' 2>&1 | tail -n 80 || true
  echo "=== End Job failure diagnostics ==="
}

servicemesh_job_container_exit_code() {
  local ns="$1"
  local job="$2"
  local pod
  pod="$(servicemesh_job_pod_name "${ns}" "${job}")"
  if [[ -z "${pod}" ]]; then
    echo "1"
    return 0
  fi
  oc get pod "${pod}" -n "${ns}" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null \
    || echo "1"
}

servicemesh_duration_to_seconds() {
  local d="$1"
  case "${d}" in
    *h) echo $(( ${d%h} * 3600 )) ;;
    *m) echo $(( ${d%m} * 60 )) ;;
    *s) echo "${d%s}" ;;
    *) echo "${d}" ;;
  esac
}

# Wait until Job reaches Complete or Failed (or timeout). Returns 0 on Complete, 1 otherwise.
servicemesh_wait_job_terminal() {
  local ns="$1"
  local job="$2"
  local wait_timeout="${3:-${MAISTRA_JOB_WAIT_TIMEOUT}}"
  local timeout_s interval=15 elapsed=0
  local complete failed

  timeout_s="$(servicemesh_duration_to_seconds "${wait_timeout}")"
  echo "Waiting for Job ${ns}/${job} Complete|Failed (timeout=${wait_timeout})..."

  while (( elapsed <= timeout_s )); do
    complete="$(oc get job "${job}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed="$(oc get job "${job}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [[ "${complete}" == "True" ]]; then
      echo "Job ${ns}/${job} condition Complete=True"
      return 0
    fi
    if [[ "${failed}" == "True" ]]; then
      echo "Job ${ns}/${job} condition Failed=True"
      return 1
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: timed out waiting for Job ${ns}/${job} after ${wait_timeout}" >&2
  return 1
}

# Apply a Job manifest from stdin, wait for completion, collect logs/artifacts.
# Returns the container exit code (non-zero on failure/timeout).
servicemesh_apply_wait_collect_job() {
  local ns="$1"
  local job="$2"
  local remote_artifacts="${3:-/work/artifacts}"
  local wait_timeout="${4:-${MAISTRA_JOB_WAIT_TIMEOUT}}"
  local was_errexit=false
  local wait_rc exit_code

  [[ $- == *e* ]] && was_errexit=true

  oc apply -n "${ns}" -f -

  set +e
  servicemesh_wait_job_terminal "${ns}" "${job}" "${wait_timeout}"
  wait_rc=$?
  if ${was_errexit}; then
    set -e
  fi

  servicemesh_collect_job_logs "${ns}" "${job}" "${ARTIFACT_DIR}"
  servicemesh_collect_job_artifacts "${ns}" "${job}" "${remote_artifacts}" "${ARTIFACT_DIR}"

  if [[ "${wait_rc}" -ne 0 ]]; then
    echo "ERROR: Job ${ns}/${job} did not reach Complete condition" >&2
    servicemesh_describe_job_failure "${ns}" "${job}"
    exit_code="$(servicemesh_job_container_exit_code "${ns}" "${job}")"
    if [[ -z "${exit_code}" ]]; then
      exit_code=1
    fi
    return "${exit_code}"
  fi

  exit_code="$(servicemesh_job_container_exit_code "${ns}" "${job}")"
  if [[ -z "${exit_code}" ]]; then
    exit_code=0
  fi
  echo "Job ${ns}/${job} completed with container exit code ${exit_code}"
  return "${exit_code}"
}
JOBLIB_EOF

# shellcheck disable=SC1090
source "${SHARED_DIR}/servicemesh-common-job-lib.sh"

echo "Preparing Job workdir in namespace ${MAISTRA_NAMESPACE}..."
servicemesh_prepare_job_workdir
echo "Job workdir preparation completed successfully"
