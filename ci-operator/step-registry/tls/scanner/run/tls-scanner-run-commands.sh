#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

run_tls_scan() {

  # TLS Scanner - scans TLS configurations of all pods in the cluster
  local NAMESPACE="tls-scanner"
  local OWNS_NAMESPACE=true
  local SCANNER_IMAGE="${PULL_SPEC_TLS_SCANNER_TOOL}"
  local ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

  if [[ -n "${TLS_SCANNER_CLUSTER_LABEL:-}" ]]; then
    SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner/${TLS_SCANNER_CLUSTER_LABEL}"
    case "${TLS_SCANNER_CLUSTER_LABEL}" in
      management)
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
        if [[ -z "${SCAN_NAMESPACE:-}" && -f "${SHARED_DIR}/cluster-name" ]]; then
          CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
          SCAN_NAMESPACE="clusters-${CLUSTER_NAME}"
        fi
        ;;
      guest)
        export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
        ;;
      *)
        echo "Unknown TLS_SCANNER_CLUSTER_LABEL: ${TLS_SCANNER_CLUSTER_LABEL}"
        exit 1
        ;;
    esac
  else
    SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner"
  fi

  echo "TLS scanner target: ${TLS_SCANNER_CLUSTER_LABEL:-default} cluster"
  echo "KUBECONFIG: ${KUBECONFIG:-<unset>}"
  if [[ -n "${SCAN_NAMESPACE:-}" ]]; then
    echo "Namespace filter: ${SCAN_NAMESPACE}"
  fi

  # Determine scanner arguments based on whether a specific namespace is requested
  if [[ -n "${SCAN_NAMESPACE:-}" ]]; then
      SCANNER_ARGS="--all-pods --namespace-filter ${SCAN_NAMESPACE}"
  else
      SCANNER_ARGS="--all-pods"
  fi

  # Enable post-quantum cryptography checks when requested by the step ref.
  if [[ "${PQC_CHECK:-false}" == "true" ]]; then
      SCANNER_ARGS="${SCANNER_ARGS} --pqc-check"
      echo "PQC readiness mode enabled: checks TLS 1.3 support and mlkem or mlkem25519 support per target."
  fi

  if [[ -n "${SCAN_LIMIT_IPS:-}" && "${SCAN_LIMIT_IPS}" != "0" ]]; then
      SCANNER_ARGS="${SCANNER_ARGS} --limit-ips ${SCAN_LIMIT_IPS}"
      echo "Limiting scan to ${SCAN_LIMIT_IPS} IPs (smoke testing)."
  fi

  if [[ -n "${TLS_PROFILE_TYPE:-}" ]]; then
      SCANNER_ARGS="${SCANNER_ARGS} --tls-profile-type ${TLS_PROFILE_TYPE}"
      echo "Using expected TLS profile type for compliance checks: ${TLS_PROFILE_TYPE}"
  fi

  local scanner_cpu="${SCANNER_CPU}"
  local scanner_memory="${SCANNER_MEMORY}"
  if [[ "${TLS_SCANNER_CLUSTER_LABEL:-}" == "guest" ]]; then
    scanner_cpu="${SCANNER_CPU_GUEST:-1}"
    scanner_memory="${SCANNER_MEMORY_GUEST:-2Gi}"
  fi
  echo "Scanner pod resources: cpu=${scanner_cpu} memory=${scanner_memory}"

  mkdir -p "${SCANNER_ARTIFACT_DIR}"

  echo "=== TLS Scanner ==="
  echo "Image: ${SCANNER_IMAGE}"

  # For management cluster scans, deploy the scanner pod into the HCP namespace
  # so it satisfies the HCP NetworkPolicy intra-namespace allow rules.
  # The HCP namespace already exists and must not be deleted at cleanup.
  if [[ "${TLS_SCANNER_CLUSTER_LABEL:-}" == "management" && -n "${SCAN_NAMESPACE:-}" ]]; then
      NAMESPACE="${SCAN_NAMESPACE}"
      OWNS_NAMESPACE=false
  fi

  if [[ "${OWNS_NAMESPACE}" == "true" ]]; then
      # Shared clusters can retain tls-scanner resources from prior jobs.
      # Pods are immutable; delete any leftover namespace before recreating.
      echo "Removing any previous tls-scanner resources..."
      oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=120s || true
      oc create namespace "${NAMESPACE}"
  else
      # Just remove any leftover scanner pod from a prior run; do not touch the namespace.
      oc delete pod/tls-scanner -n "${NAMESPACE}" --ignore-not-found --wait=true --timeout=60s || true
  fi

  # Cleanup on exit
  cleanup() {
      echo "Cleaning up..."
      if [[ "${OWNS_NAMESPACE}" == "true" ]]; then
          oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=false || true
      else
          oc delete pod/tls-scanner -n "${NAMESPACE}" --ignore-not-found --wait=false || true
      fi
  }
  trap cleanup EXIT

  # hostNetwork/hostPID are required for host-mode scanning but defeat NetworkPolicy
  # for pod-mode management cluster scans (host-networked pods source from the node
  # IP, which does not match any pod/namespace selector in HCP ingress rules).
  # Pod-mode scanning uses the kube API for discovery and exec, so neither is needed.
  if [[ "${OWNS_NAMESPACE}" == "false" ]]; then
      HOST_NETWORK="false"
      HOST_PID="false"
      # PodSecurity restricted-compliant securityContext for HCP namespace scans.
      # The scanner binary only needs kube API access in pod-mode, so root is not required.
      SECURITY_CONTEXT_YAML="      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 65532
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault"
  else
      HOST_NETWORK="true"
      HOST_PID="true"
      SECURITY_CONTEXT_YAML="      privileged: true
      runAsUser: 0"
  fi

  # Grant cluster-admin to the default service account for full API access
  oc adm policy add-cluster-role-to-user cluster-admin -z default -n "${NAMESPACE}"

  # Grant privileged SCC to the service account (required for hostNetwork/hostPID/privileged
  # container in host-mode scans).
  if [[ "${OWNS_NAMESPACE}" == "true" ]]; then
      oc adm policy add-scc-to-user privileged -z default -n "${NAMESPACE}"
  fi

  # Wait for RBAC/SCC changes to propagate before creating the pod
  # This ensures the SCC admission controller sees the new binding
  echo "Waiting for RBAC/SCC changes to propagate..."
  sleep 10

  # Create the scanner pod
  cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: tls-scanner
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: default
  restartPolicy: Never
  hostNetwork: ${HOST_NETWORK}
  hostPID: ${HOST_PID}
  containers:
  - name: scanner
    image: ${SCANNER_IMAGE}
    command:
    - /bin/bash
    - -c
    - |
      mkdir -p /results
      /usr/local/bin/tls-scanner -j 4 ${SCANNER_ARGS} \
        --json-file /results/results.json \
        --csv-file /results/results.csv \
        --junit-file /results/junit_tls_scan.xml \
        --log-file /results/scan.log 2>&1 | tee /results/output.log
      SCAN_EXIT_CODE=\${PIPESTATUS[0]}
      echo "Scan complete. Exit code: \${SCAN_EXIT_CODE}" | tee -a /results/output.log
      touch /results/scan.done
      # Keep pod alive for artifact collection
      sleep 120
      # We are intentionally ignoring the scanner exit code for the moment
      # exit \${SCAN_EXIT_CODE}
    resources:
      requests:
        cpu: "${scanner_cpu}"
        memory: ${scanner_memory}
      limits:
        cpu: "${scanner_cpu}"
        memory: ${scanner_memory}
    securityContext:
${SECURITY_CONTEXT_YAML}
    volumeMounts:
    - name: results
      mountPath: /results
  volumes:
  - name: results
    emptyDir: {}
EOF

  echo "Waiting for scanner pod to start..."
  oc wait --for=condition=Ready pod/tls-scanner -n "${NAMESPACE}" --timeout=5m || {
      echo "Pod failed to start:"
      oc describe pod/tls-scanner -n "${NAMESPACE}"
      oc get events -n "${NAMESPACE}"
      exit 1
  }

  echo "Streaming scanner logs (live)..."
  oc logs -f pod/tls-scanner -n "${NAMESPACE}" &
  LOGS_PID=$!

  echo "Waiting for scan to finish (pod stays alive 120s after scan for artifact collection)..."
  while true; do
      phase=$(oc get pod/tls-scanner -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      echo "Poll: phase=${phase}"
      # Scanner completion check first — must copy artifacts while pod is still running.
      if oc exec pod/tls-scanner -n "${NAMESPACE}" -- test -f /results/scan.done 2>/dev/null; then
          echo "/results/scan.done found — proceeding to copy artifacts"
          break
      fi
      # Fallback: pod already exited (sleep window expired or crash).
      if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
          echo "Warning: pod ${phase} before artifact collection — oc cp will likely fail"
          break
      fi
      sleep 15
  done

  echo "Copying artifacts..."
  oc cp "${NAMESPACE}/tls-scanner:/results/." "${SCANNER_ARTIFACT_DIR}/" || echo "Warning: Failed to copy some artifacts"

  if [[ -f "${SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" ]]; then
      if [[ -n "${TLS_SCANNER_CLUSTER_LABEL:-}" ]]; then
        junit_artifact="${ARTIFACT_DIR}/junit_tls_scan_${TLS_SCANNER_CLUSTER_LABEL}.xml"
      else
        junit_artifact="${ARTIFACT_DIR}/junit_tls_scan.xml"
      fi
      cp "${SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" "${junit_artifact}"
      echo "JUnit results copied to ${junit_artifact} for Spyglass"
  fi

  wait $LOGS_PID 2>/dev/null || true

  if [[ "$(oc get pod/tls-scanner -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Failed" ]]; then
      echo "Scanner pod failed"
      oc describe pod/tls-scanner -n "${NAMESPACE}"
      exit 1
  fi

  oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/tls-scanner -n "${NAMESPACE}" --timeout=10m || {
      echo "Scanner did not complete successfully - timeout exceeded"
      oc describe pod/tls-scanner -n "${NAMESPACE}"
      exit 1
  }

  echo "=== TLS Scanner Complete ==="
  echo "Artifacts saved to: ${SCANNER_ARTIFACT_DIR}"
  ls -la "${SCANNER_ARTIFACT_DIR}" || true

  # Unregister the trap so it doesn't fire after the function returns (local
  # variables NAMESPACE/OWNS_NAMESPACE would be unbound at that point).
  trap - EXIT
}

if [[ "${TLS_SCANNER_RUN_HYPERSHIFT:-false}" == "true" ]]; then
  for label in management guest; do
    echo "=== TLS scanner: ${label} cluster ==="
    (
      export TLS_SCANNER_CLUSTER_LABEL="${label}"
      run_tls_scan
    )
  done
  echo "=== HyperShift TLS scanner complete (management + guest) ==="
  exit 0
fi

run_tls_scan
