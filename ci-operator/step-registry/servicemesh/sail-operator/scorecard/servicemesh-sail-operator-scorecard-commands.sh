#!/usr/bin/env bash
# ==============================================================================
# Operator Scorecard Test Script (Job-based)
#
# Runs Sail Operator scorecard tests as a batch/v1 Job on the cluster under
# test. Source and kubeconfig must already be prepared by
# servicemesh-common-prepare-job-workdir (PVC at /work + kubeconfig Secret).
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${SHARED_DIR:-}" || ! -f "${SHARED_DIR}/servicemesh-common-job-lib.sh" ]]; then
  echo "ERROR: ${SHARED_DIR}/servicemesh-common-job-lib.sh missing; run servicemesh-common-prepare-job-workdir first" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${SHARED_DIR}/servicemesh-common-job-lib.sh"

: "${MAISTRA_NAMESPACE:=maistra-e2e-test}"
: "${MAISTRA_WORKDIR_PVC:=maistra-workdir}"
: "${MAISTRA_KUBECONFIG_SECRET:=ci-kubeconfig}"
: "${MAISTRA_JOB_TTL_SECONDS:=3600}"
: "${SCORECARD_JOB_NAME:=sail-scorecard}"
: "${SCORECARD_COMMAND:=OCP=true make test.scorecard}"

if [[ -z "${MAISTRA_BUILDER_IMAGE:-}" ]]; then
  echo "ERROR: MAISTRA_BUILDER_IMAGE is required" >&2
  exit 1
fi

# Delete any previous Job so re-runs are clean (immutable Job spec).
oc delete job "${SCORECARD_JOB_NAME}" -n "${MAISTRA_NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "Starting scorecard Job ${MAISTRA_NAMESPACE}/${SCORECARD_JOB_NAME}..."

set +o errexit
servicemesh_apply_wait_collect_job "${MAISTRA_NAMESPACE}" "${SCORECARD_JOB_NAME}" "/work/artifacts" "${MAISTRA_JOB_WAIT_TIMEOUT}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${SCORECARD_JOB_NAME}
  namespace: ${MAISTRA_NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: ${MAISTRA_JOB_TTL_SECONDS}
  template:
    metadata:
      annotations:
        cpu-load-balancing.crio.io: "disable"
        cpu-quota.crio.io: "disable"
    spec:
      restartPolicy: Never
      containers:
      - name: scorecard
        image: ${MAISTRA_BUILDER_IMAGE}
        command: ["bash", "-lc"]
        args:
        - |
          set +e
          export KUBECONFIG=/etc/kubeconfig/kubeconfig
          export BUILD_WITH_CONTAINER=0
          export ARTIFACT_DIR=/work/artifacts
          export ARTIFACTS=/work/artifacts
          mkdir -p /work/artifacts
          cd /work
          entrypoint ${SCORECARD_COMMAND}
          exit \$?
        resources:
          requests:
            cpu: "1"
            memory: 8Gi
          limits:
            memory: 10Gi
        securityContext:
          capabilities:
            add: ["IPC_LOCK", "SYS_ADMIN"]
          privileged: true
          runAsUser: 0
        env:
        - name: BUILD_WITH_CONTAINER
          value: "0"
        - name: CI
          value: "${CI:-}"
        - name: ARTIFACT_DIR
          value: "/work/artifacts"
        - name: ARTIFACTS
          value: "/work/artifacts"
        - name: JOB_NAME
          value: "${JOB_NAME:-}"
        - name: JOB_TYPE
          value: "${JOB_TYPE:-}"
        - name: BUILD_ID
          value: "${BUILD_ID:-}"
        - name: PROW_JOB_ID
          value: "${PROW_JOB_ID:-}"
        - name: REPO_OWNER
          value: "${REPO_OWNER:-}"
        - name: REPO_NAME
          value: "${REPO_NAME:-}"
        - name: PULL_BASE_REF
          value: "${PULL_BASE_REF:-}"
        - name: PULL_BASE_SHA
          value: "${PULL_BASE_SHA:-}"
        - name: PULL_REFS
          value: "${PULL_REFS:-}"
        - name: PULL_NUMBER
          value: "${PULL_NUMBER:-}"
        - name: PULL_PULL_SHA
          value: "${PULL_PULL_SHA:-}"
        - name: PULL_HEAD_REF
          value: "${PULL_HEAD_REF:-}"
        - name: XDG_CACHE_HOME
          value: "${XDG_CACHE_HOME:-/tmp/cache}"
        volumeMounts:
        - name: work
          mountPath: /work
        - name: kubeconfig
          mountPath: /etc/kubeconfig
          readOnly: true
        - name: modules
          mountPath: /lib/modules
          readOnly: true
        - name: varlibdocker
          mountPath: /var/lib/docker
      volumes:
      - name: work
        persistentVolumeClaim:
          claimName: ${MAISTRA_WORKDIR_PVC}
      - name: kubeconfig
        secret:
          secretName: ${MAISTRA_KUBECONFIG_SECRET}
      - name: modules
        hostPath:
          path: /lib/modules
          type: Directory
      - name: varlibdocker
        emptyDir: {}
EOF
TEST_RC=$?
set -o errexit

echo "Scorecard Job finished with exit code: ${TEST_RC}"
exit "${TEST_RC}"
