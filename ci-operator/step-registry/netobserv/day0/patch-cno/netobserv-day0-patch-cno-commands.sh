#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

echo "Patching network.config/cluster: installationPolicy=${CNO_NETOBSERV_INSTALLATION_POLICY}"
oc patch network.config/cluster --type=merge \
  -p "{\"spec\":{\"networkObservability\":{\"installationPolicy\":\"${CNO_NETOBSERV_INSTALLATION_POLICY}\"}}}"

sleep 300

echo "Waiting for FlowCollector resource to be created by CNO..."
for i in $(seq 1 60); do
    if oc get flowcollector/cluster &>/dev/null; then
        echo "FlowCollector/cluster found after $((i * 10))s"
        break
    fi
    if [[ "${i}" -eq 60 ]]; then
        echo "ERROR: FlowCollector/cluster not created after 600s" >&2
        exit 1
    fi
    sleep 10
done

echo "Waiting for FlowCollector/cluster Ready condition..."
oc wait flowcollector/cluster --for=condition=Ready --timeout="${WAIT_TIMEOUT}"

echo "Waiting for NetObserv operator controller manager..."
oc wait deployment/netobserv-controller-manager \
    -n "${NETOBSERV_OPERATOR_NAMESPACE}" \
    --for=condition=Available \
    --timeout="${WAIT_TIMEOUT}"

echo "Waiting for NetObserv static plugin..."

oc wait deployment/netobserv-plugin-static \
    -n "${NETOBSERV_OPERATOR_NAMESPACE}" \
    --for=condition=Available \
    --timeout="${WAIT_TIMEOUT}"


echo "Waiting for eBPF agent DaemonSet Ready..."
# Wait on the DaemonSet rather than individual pods: agent pods may restart
# during startup, which invalidates the pod names oc wait latched onto and
# causes spurious timeouts. The DaemonSet condition is re-evaluated on each
# poll, so it survives pod restarts.
for i in $(seq 1 30); do
    DS_LISTING=$(oc get daemonset -n "${NETOBSERV_PRIVILEGED_NAMESPACE}" \
        -l app=netobserv-ebpf-agent --no-headers 2>/dev/null || true)
    if [[ -n "${DS_LISTING}" ]]; then
        echo "${DS_LISTING}"
        break
    fi
    if [[ "${i}" -eq 30 ]]; then
        echo "ERROR: netobserv-ebpf-agent DaemonSet not found in ${NETOBSERV_PRIVILEGED_NAMESPACE}" >&2
        exit 1
    fi
    sleep 10
done
# Wait on pod counts rather than the Available condition: on large clusters the
# DaemonSet controller can lag or flap updating the condition even when all
# pods are Ready (observed: 123/123 desired/ready but condition never True
# within the wait window). numberReady == desiredNumberScheduled is the
# authoritative signal.
DS_NAME=$(oc get daemonset -n "${NETOBSERV_PRIVILEGED_NAMESPACE}" \
    -l app=netobserv-ebpf-agent -o jsonpath='{.items[0].metadata.name}')
DS_WAIT_SECS=900
DS_WAIT_END=$(( SECONDS + DS_WAIT_SECS ))
while true; do
    DESIRED=$(oc get daemonset "${DS_NAME}" -n "${NETOBSERV_PRIVILEGED_NAMESPACE}" \
        -o jsonpath='{.status.desiredNumberScheduled}')
    READY=$(oc get daemonset "${DS_NAME}" -n "${NETOBSERV_PRIVILEGED_NAMESPACE}" \
        -o jsonpath='{.status.numberReady}')
    if [[ -n "${DESIRED}" && "${READY}" == "${DESIRED}" && "${READY}" != "0" ]]; then
        echo "eBPF agent DaemonSet Ready: ${READY}/${DESIRED}"
        break
    fi
    if [[ "${SECONDS}" -ge "${DS_WAIT_END}" ]]; then
        echo "ERROR: eBPF agent DaemonSet ${DS_NAME} not Ready after ${DS_WAIT_SECS}s (${READY:-0}/${DESIRED:-0})" >&2
        oc get daemonset "${DS_NAME}" -n "${NETOBSERV_PRIVILEGED_NAMESPACE}" -o yaml >&2 || true
        exit 1
    fi
    sleep 10
done

echo "Waiting for FLP Deployment Ready..."
# FLP runs as a Deployment in service mode regardless of deployment model
# (Direct or Kafka), so wait on the Deployment in the service namespace.
oc wait deployment -n "${NETOBSERV_NAMESPACE}" \
    -l app=flowlogs-pipeline \
    --for=condition=Available \
    --timeout="${WAIT_TIMEOUT}"

echo "Waiting for plugin deployment..."
oc wait deployment -n "${NETOBSERV_NAMESPACE}" \
    -l app=netobserv-plugin \
    --for=condition=Available \
    --timeout="${WAIT_TIMEOUT}"

echo "All NetObserv components are Ready."


echo "`date +%s`" > "${SHARED_DIR}/netobserv-start-time.txt"

#  let netobserv soak on the cluster
sleep 1800

# Save component state to artifacts for debugging
oc get flowcollector/cluster -o json > "${ARTIFACT_DIR}/flowcollector.json" || true
oc get pods -n "${NETOBSERV_OPERATOR_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/pods-netobserv-operator.txt" || true
oc get pods -n "${NETOBSERV_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/pods-netobserv.txt" || true
oc get pods -n "${NETOBSERV_PRIVILEGED_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/pods-ebpf.txt" || true
oc get network.config/cluster -o jsonpath='{.spec.networkObservability}' \
    | python3 -m json.tool > "${ARTIFACT_DIR}/network-config-networkObservability.json" || true

echo "FlowCollector status:"
python3 -m json.tool "${ARTIFACT_DIR}/flowcollector.json" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('status',{}), indent=2))" || true

# Persist environment summary to SHARED_DIR for diff-resource step
python3 - <<'PYEOF'
import subprocess, json, os

def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout.strip()

shared_dir = os.environ["SHARED_DIR"]

# Node info
worker_instance_type = run(
    "oc get nodes -l node-role.kubernetes.io/worker "
    "-o jsonpath='{.items[0].metadata.labels.node\\.kubernetes\\.io/instance-type}'"
) or "unknown"
worker_count = int(run(
    "oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l"
) or "0")

# OCP version
ocp_version = run(
    "oc get clusterversion version "
    "-o jsonpath='{.status.desired.version}'"
) or "unknown"

# FlowCollector spec
fc_raw = run("oc get flowcollector/cluster -o json 2>/dev/null")
fc = json.loads(fc_raw) if fc_raw else {}
fc_spec = fc.get("spec", {})
agent_type = fc_spec.get("agent", {}).get("type", "eBPF")
agent_spec = fc_spec.get("agent", {}).get(agent_type.lower(), {})
sampling    = agent_spec.get("sampling", "N/A")
deploy_model = fc_spec.get("deploymentModel", "Direct")
loki_enabled = "lokistack" in json.dumps(fc_spec).lower()

# Loki — check for LokiStack CR
loki_cr = run("oc get lokistack -A --no-headers 2>/dev/null | head -1")
loki_present = bool(loki_cr)

summary = {
    "ocp_version": ocp_version,
    "worker_count": worker_count,
    "worker_instance_type": worker_instance_type,
    "flowcollector": {
        "deployment_model": deploy_model,
        "sampling": sampling,
        "loki_enabled": loki_present,
    },
}

out = os.path.join(shared_dir, "day0-env-summary.json")
with open(out, "w") as f:
    json.dump(summary, f, indent=2)
print(f"Environment summary written to {out}:")
print(json.dumps(summary, indent=2))
PYEOF
