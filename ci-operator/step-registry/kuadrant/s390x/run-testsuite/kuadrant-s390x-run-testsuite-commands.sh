#!/bin/bash

set -euo pipefail

# Runs the Kuadrant testsuite as an in-cluster Job on the s390x cluster.
#
# Why: the ci-operator step pod lives on the amd64 build farm, on a different
# network than the leased s390x cluster. It cannot resolve the private CoreDNS
# zone (*.k.example.com) nor reach the Gateway MetalLB IPs (192.168.x.240).
# That is exactly why test_gateway_basic_dns_tls kept failing with
# "Name or service not known" while limitador/auth tests (which use the public
# *.apps... ingress domain) passed.
#
# The m42lp36 reference LPAR works because the client runs *on* the cluster
# network. We reproduce that here by running the testsuite as a Job on an s390x
# worker node using an s390x-native testsuite image. From inside the cluster:
#   - CoreDNS is reachable at its Service ClusterIP:53
#   - Gateway MetalLB IPs are directly routable
# The step itself only orchestrates the Job and collects results/JUnit.

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

TEST_RUNNER_NAMESPACE="${TEST_RUNNER_NAMESPACE:-kuadrant-testrunner}"
TESTSUITE_S390X_IMAGE="${TESTSUITE_S390X_IMAGE:-quay.io/vray_rh/rhcl-testsuite:stablev1}"
# Must match the image USER/ownership so `make` can write stamp files in WORKDIR.
TESTSUITE_RUN_AS_USER="${TESTSUITE_RUN_AS_USER:-65532}"
JOB_NAME="kuadrant-testsuite-run"

COREDNS_ZONE="${COREDNS_ZONE:-k.example.com}"
COREDNS_NAMESPACE="${COREDNS_NAMESPACE:-kuadrant-coredns}"
if [[ -f "${SHARED_DIR}/kuadrant-coredns-zone" ]]; then
  COREDNS_ZONE="$(tr -d '[:space:]' <"${SHARED_DIR}/kuadrant-coredns-zone")"
fi
if [[ -f "${SHARED_DIR}/kuadrant-coredns-namespace" ]]; then
  COREDNS_NAMESPACE="$(tr -d '[:space:]' <"${SHARED_DIR}/kuadrant-coredns-namespace")"
fi

RESULTS_DIR="${ARTIFACT_DIR}/test-run-results"
mkdir -p "${RESULTS_DIR}"

KEYCLOAK_URL="$(cat "${SHARED_DIR}/keycloak-url")"
MOCKSERVER_URL="$(cat "${SHARED_DIR}/mockserver-url")"
JAEGER_QUERY_URL="$(cat "${SHARED_DIR}/jaeger-query-url")"
JAEGER_COLLECTOR_URL="rpc://jaeger-collector.${TOOLS_NAMESPACE}.svc.cluster.local:4317"

# In-cluster the testsuite reaches CoreDNS directly at its Service ClusterIP.
# The getaddrinfo plugin only redirects *.COREDNS_ZONE lookups there; every
# other name still uses normal cluster DNS.
COREDNS_DNS_HOST="$(oc get svc kuadrant-coredns -n "${COREDNS_NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ -z "${COREDNS_DNS_HOST}" ]]; then
  echo "WARNING: could not resolve kuadrant-coredns ClusterIP in ${COREDNS_NAMESPACE};" >&2
  echo "         DNSPolicy/TLSPolicy tests may fail to resolve *.${COREDNS_ZONE}" >&2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ---------------------------------------------------------------------------
# 1. dynaconf settings (credentials) → mounted into the Job as a Secret
# ---------------------------------------------------------------------------
SECRETS_FILE="${WORK_DIR}/secrets.yaml"
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
DNS_BLOCK=""
if [[ -n "${COREDNS_DNS_HOST}" ]]; then
  DNS_BLOCK="$(cat <<DNS_EOF
  dns:
    coredns_zone: "${COREDNS_ZONE}"
    dns_server:
      geo_code: "DE"
      address: "${COREDNS_DNS_HOST}"
    default_geo_server: "${COREDNS_DNS_HOST}"
DNS_EOF
)"
fi
cat > "${SECRETS_FILE}" <<EOF
default:
  cfssl: "cfssl"
  service_protection:
    system_project: "${KUADRANT_NAMESPACE}"
    project: "kuadrant"
    project2: "kuadrant2"
    authorino:
      deploy: false
  default_exposer: "openshift"
  control_plane:
    cluster: {}
    provider_secret: "${DNS_PROVIDER_SECRET_NAME}"
    issuer:
      name: "${CLUSTER_ISSUER_NAME}"
      kind: "ClusterIssuer"
${DNS_BLOCK}
  tools:
    project: "${TOOLS_NAMESPACE}"
  keycloak:
    url: "${KEYCLOAK_URL}"
    username: "${KEYCLOAK_ADMIN_USERNAME}"
    password: "${KEYCLOAK_ADMIN_PASSWORD}"
    test_user:
      username: "testUser"
      password: "testPassword"
  httpbin:
    image: "${HTTPBIN_IMAGE}"
  tracing:
    backend: "jaeger"
    collector_url: "${JAEGER_COLLECTOR_URL}"
    query_url: "${JAEGER_QUERY_URL}"
  mockserver:
    image: "${MOCKSERVER_IMAGE}"
    url: "${MOCKSERVER_URL}"
    # Using pre-deployed MockServer from tools namespace (configured with echo expectations)
  llm_sim:
    image: "${LLM_SIM_IMAGE}"
  spicedb:
    image: "${SPICEDB_IMAGE}"
EOF
$WAS_TRACING && set -x
echo "Generated dynaconf settings (credentials redacted in logs)."

# Log config for debugging (mask only passwords)
echo "=== Testsuite Configuration (for debugging backend deployment) ==="
cat "${SECRETS_FILE}" | sed -e "s/${KEYCLOAK_ADMIN_PASSWORD}/REDACTED/g" | tee "${ARTIFACT_DIR}/testsuite-config.yaml"

# ---------------------------------------------------------------------------
# 2a. Velocity MockServer expectations (s390x workaround for testsuite#952)
#     Mounted into the Job and copied over the upstream JAVASCRIPT file before
#     make smoke. Proven on rhcl-mc1 with mockserver-s390x-fixed-v10.
# ---------------------------------------------------------------------------
ECHO_EXPECTATION_FILE="${WORK_DIR}/echo_expectation.json"
cat > "${ECHO_EXPECTATION_FILE}" <<'EOF'
[
  {
    "id": "not-found",
    "httpRequest": {
      "path": "/unknown-endpoint"
    },
    "httpResponse": {
      "statusCode": 404
    }
  },
  {
    "id": "echo",
    "httpRequest": {
      "path": "/.*"
    },
    "httpResponseTemplate": {
      "templateType": "VELOCITY",
      "template": "{\"statusCode\": 200, \"headers\": {\"content-type\": [\"application/json\"]}, \"body\": \"{\\\"headers\\\": {}, \\\"method\\\": \\\"$request.method\\\", \\\"url\\\": \\\"$request.path\\\"}\"}"
    },
    "priority": -10
  }
]
EOF

# ---------------------------------------------------------------------------
# 2b. getaddrinfo plugin → mounted into the Job as a ConfigMap
#    Redirects only *.COREDNS_ZONE lookups to CoreDNS ClusterIP:53.
# ---------------------------------------------------------------------------
PLUGIN_FILE="${WORK_DIR}/kuadrant_coredns_resolve.py"
cat > "${PLUGIN_FILE}" <<'PY'
"""Pytest plugin: resolve Kuadrant DNSPolicy hostnames via cluster CoreDNS."""
from __future__ import annotations

import os
import socket
import struct
import sys

_ZONE = os.environ.get("KUADRANT_COREDNS_ZONE", "k.example.com").strip(".").lower()
_DNS_HOST = os.environ.get("KUADRANT_COREDNS_DNS_HOST", "")
_DNS_PORT = int(os.environ.get("KUADRANT_COREDNS_DNS_PORT", "53"))
_ORIG_GETADDRINFO = socket.getaddrinfo
_CACHE: dict[str, str] = {}


def _belongs_to_zone(host: str) -> bool:
    h = host.strip(".").lower()
    return h == _ZONE or h.endswith("." + _ZONE)


def _encode_name(name: str) -> bytes:
    out = b""
    for label in name.strip(".").split("."):
        raw = label.encode("idna")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def _dns_query_a(name: str) -> str | None:
    cached = _CACHE.get(name)
    if cached:
        return cached
    question = _encode_name(name) + struct.pack("!HH", 1, 1)  # A IN
    header = struct.pack("!HHHHHH", 0xC0DE, 0x0100, 1, 0, 0, 0)
    payload = header + question

    # Try UDP first (standard DNS), fallback to TCP if needed
    try:
        # UDP query - no length prefix needed
        udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp_sock.settimeout(2.0)
        udp_sock.sendto(payload, (_DNS_HOST, _DNS_PORT))
        data, _ = udp_sock.recvfrom(512)  # Standard DNS UDP packet size
        udp_sock.close()
    except OSError as e:
        # UDP failed, try TCP
        print(f"[kuadrant_coredns_resolve] UDP query for {name} failed: {e}, trying TCP", file=sys.stderr)
        try:
            with socket.create_connection((_DNS_HOST, _DNS_PORT), timeout=3.0) as sock:
                sock.sendall(struct.pack("!H", len(payload)) + payload)
                sock.settimeout(3.0)
                length_bytes = sock.recv(2)
                if len(length_bytes) < 2:
                    print(f"[kuadrant_coredns_resolve] TCP query for {name} failed: short read", file=sys.stderr)
                    return None
                (msg_len,) = struct.unpack("!H", length_bytes)
                data = b""
                while len(data) < msg_len:
                    chunk = sock.recv(msg_len - len(data))
                    if not chunk:
                        break
                    data += chunk
        except OSError as e2:
            print(f"[kuadrant_coredns_resolve] TCP query for {name} also failed: {e2}", file=sys.stderr)
            return None
    if len(data) < 12:
        return None
    ancount = struct.unpack("!H", data[6:8])[0]
    i = 12
    while i < len(data) and data[i] != 0:
        i += 1 + data[i]
    i += 5
    for _ in range(ancount):
        if i >= len(data):
            break
        if data[i] & 0xC0 == 0xC0:
            i += 2
        else:
            while i < len(data) and data[i] != 0:
                i += 1 + data[i]
            i += 1
        if i + 10 > len(data):
            break
        rtype, _, _, rdlen = struct.unpack("!HHIH", data[i : i + 10])
        i += 10
        rdata = data[i : i + rdlen]
        i += rdlen
        if rtype == 1 and rdlen == 4:
            ip = socket.inet_ntoa(rdata)
            _CACHE[name] = ip
            return ip
    return None


def _patched_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    if isinstance(host, bytes):
        try:
            host_str = host.decode("utf-8")
        except UnicodeDecodeError:
            host_str = ""
    else:
        host_str = host if isinstance(host, str) else ""
    if host_str and _DNS_HOST and _belongs_to_zone(host_str):
        ip = _dns_query_a(host_str)
        if ip:
            print(f"[kuadrant_coredns_resolve] {host_str} -> {ip} (via CoreDNS)", file=sys.stderr)
            return _ORIG_GETADDRINFO(ip, port, family, type, proto, flags)
        else:
            print(f"[kuadrant_coredns_resolve] {host_str} -> NO ANSWER from CoreDNS at {_DNS_HOST}:{_DNS_PORT}", file=sys.stderr)
    return _ORIG_GETADDRINFO(host, port, family, type, proto, flags)


def install() -> None:
    if socket.getaddrinfo is not _patched_getaddrinfo:
        socket.getaddrinfo = _patched_getaddrinfo  # type: ignore[assignment]
        print(
            f"[kuadrant_coredns_resolve] patching getaddrinfo for *.{_ZONE} "
            f"via {_DNS_HOST}:{_DNS_PORT}",
            file=sys.stderr,
        )
        # Test DNS connectivity on initialization
        if _DNS_HOST:
            test_ip = _dns_query_a("test.{0}".format(_ZONE))
            if test_ip:
                print(f"[kuadrant_coredns_resolve] DNS connectivity OK (test query returned {test_ip})", file=sys.stderr)
            else:
                print(f"[kuadrant_coredns_resolve] WARNING: DNS test query failed - CoreDNS might not be ready", file=sys.stderr)


def pytest_configure(config):  # noqa: ARG001
    install()


install()
PY

# ---------------------------------------------------------------------------
# 3. Build the in-container command (smoke and/or full kuadrant suite)
# ---------------------------------------------------------------------------
# protobuf ≥6.33.0 ships broken s390x upb wheels (protocolbuffers/protobuf#24103).
# Image may pin 6.32.1, but `make` → poetry sync upgrades from an unlocked/
# newer lock entry. Re-pin pyproject+lock in the Job before make so sync stays
# on 6.32.1.
PROTOBUF_PIN="${PROTOBUF_PIN:-6.32.1}"
# Ignore UI: the s390x testsuite image omits Playwright; collecting
# singlecluster/ui still imports conftest and fails make with ModuleNotFoundError.
PYTEST_PLUGIN_FLAGS="${PYTEST_FLAGS} -p kuadrant_coredns_resolve -vv --tb=short --ignore=testsuite/tests/singlecluster/ui"

CONTAINER_SCRIPT="set -o pipefail
cd /opt/workdir/kuadrant-testsuite
rc=0
echo '=== Pinning protobuf==${PROTOBUF_PIN} for s390x (avoid broken upb ≥6.33.0) ==='
# testsuite deps live in Poetry group \"main\" (see Dockerfile.s390x).
if ! poetry add --group main --no-interaction 'protobuf==${PROTOBUF_PIN}'; then
  poetry add --no-interaction 'protobuf==${PROTOBUF_PIN}'
fi
poetry run python -c \"from importlib.metadata import version; print('protobuf', version('protobuf'))\"

# s390x workaround for Kuadrant/testsuite#952 (JAVASCRIPT/GraalJS → Velocity).
# File is mounted from ConfigMap kuadrant-testrunner-hook (see step prep below).
echo '=== s390x workaround: install Velocity MockServer echo expectations ==='
cp -f /kuadrant-hook/echo_expectation.json testsuite/resources/echo_expectation.json
grep -n templateType testsuite/resources/echo_expectation.json || true
"
# Smoke and kuadrant are independent: each records failure into rc but does not
# skip the next target. Kuadrant always runs after smoke when enabled.
if [[ "${RUN_SMOKE}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make smoke ==='
flags='${PYTEST_PLUGIN_FLAGS}' make smoke || rc=1
"
fi
if [[ "${RUN_KUADRANT}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make kuadrant (runs even if smoke failed) ==='
flags='${PYTEST_PLUGIN_FLAGS}' make kuadrant || rc=1
"
fi
CONTAINER_SCRIPT+="make polish-junit || true
# Stream JUnit back to the step log (no tar/oc-cp dependency in the image).
for f in \"\${resultsdir}\"/junit-*.xml; do
  [ -e \"\$f\" ] || continue
  echo \"===KUADRANT_JUNIT_BEGIN \$(basename \"\$f\")===\"
  base64 -w0 \"\$f\"; echo
  echo '===KUADRANT_JUNIT_END==='
done
echo \"===KUADRANT_RC \${rc}===\"
exit \${rc}"

# ---------------------------------------------------------------------------
# 4. Create namespace + config objects + Job in the cluster
# ---------------------------------------------------------------------------
echo "=== Preparing test-runner namespace ${TEST_RUNNER_NAMESPACE} ==="
oc create namespace "${TEST_RUNNER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Explicit runAsUser requires anyuid; restricted SCC would otherwise reject it.
oc adm policy add-scc-to-user anyuid -z default -n "${TEST_RUNNER_NAMESPACE}"

oc -n "${TEST_RUNNER_NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found=true --wait=true

# Secret: dynaconf settings + admin kubeconfig (testsuite acts as cluster-admin).
oc -n "${TEST_RUNNER_NAMESPACE}" create secret generic kuadrant-testrunner-config \
  --from-file=secrets.yaml="${SECRETS_FILE}" \
  --from-file=kubeconfig="${SHARED_DIR}/kubeconfig" \
  --dry-run=client -o yaml | oc apply -f -

# ConfigMap: CoreDNS getaddrinfo plugin + Velocity MockServer expectations
# (s390x workaround for Kuadrant/testsuite#952).
oc -n "${TEST_RUNNER_NAMESPACE}" create configmap kuadrant-testrunner-hook \
  --from-file=kuadrant_coredns_resolve.py="${PLUGIN_FILE}" \
  --from-file=echo_expectation.json="${ECHO_EXPECTATION_FILE}" \
  --dry-run=client -o yaml | oc apply -f -

JOB_FILE="${WORK_DIR}/job.yaml"
cat > "${JOB_FILE}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${TEST_RUNNER_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: kuadrant-testrunner
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/arch: s390x
      securityContext:
        runAsNonRoot: true
        runAsUser: ${TESTSUITE_RUN_AS_USER}
        runAsGroup: ${TESTSUITE_RUN_AS_USER}
        fsGroup: ${TESTSUITE_RUN_AS_USER}
      containers:
      - name: testsuite
        image: ${TESTSUITE_S390X_IMAGE}
        # Always: same tag (stablev1) may be rebuilt; avoid stale node cache.
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          runAsNonRoot: true
          runAsUser: ${TESTSUITE_RUN_AS_USER}
          runAsGroup: ${TESTSUITE_RUN_AS_USER}
        command: ["bash", "-c"]
        args:
        - |
$(printf '%s\n' "${CONTAINER_SCRIPT}" | sed 's/^/          /')
        env:
        - name: KUBECONFIG
          value: /config/kubeconfig
        - name: SECRETS_FOR_DYNACONF
          value: /config/secrets.yaml
        - name: PYTHONPATH
          value: /kuadrant-hook
        - name: KUADRANT_COREDNS_ZONE
          value: "${COREDNS_ZONE}"
        - name: KUADRANT_COREDNS_DNS_HOST
          value: "${COREDNS_DNS_HOST}"
        - name: KUADRANT_COREDNS_DNS_PORT
          value: "53"
        - name: junit
          value: "yes"
        - name: resultsdir
          value: /test-run-results
        - name: HOME
          value: /tmp
        - name: PYTHONPYCACHEPREFIX
          value: /tmp/pycache
        volumeMounts:
        - name: config
          mountPath: /config
          readOnly: true
        - name: hook
          mountPath: /kuadrant-hook
          readOnly: true
        - name: results
          mountPath: /test-run-results
      volumes:
      - name: config
        secret:
          secretName: kuadrant-testrunner-config
      - name: hook
        configMap:
          name: kuadrant-testrunner-hook
      - name: results
        emptyDir: {}
EOF

echo "=== Test-runner Job manifest ==="
cat "${JOB_FILE}"

# ---------------------------------------------------------------------------
# 5. Launch the Job, stream logs, collect results
# ---------------------------------------------------------------------------
extract_junit_from_log() {
  local logfile="$1" dest="$2"
  python3 - "$logfile" "$dest" <<'PY'
import base64
import os
import sys

logfile, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
name = None
buf = []
with open(logfile, "r", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("===KUADRANT_JUNIT_BEGIN ") and line.endswith("==="):
            name = line[len("===KUADRANT_JUNIT_BEGIN "):-3].strip()
            buf = []
        elif line == "===KUADRANT_JUNIT_END===" and name:
            try:
                data = base64.b64decode("".join(buf))
                with open(os.path.join(dest, name), "wb") as out:
                    out.write(data)
                print(f"recovered {name} ({len(data)} bytes)")
            except Exception as exc:  # noqa: BLE001
                print(f"failed to decode {name}: {exc}", file=sys.stderr)
            name = None
            buf = []
        elif name is not None:
            buf.append(line)
PY
}

FAILED=0
JOB_LOG="${ARTIFACT_DIR}/kuadrant-testrunner-job.log"

echo "=== Launching test-runner Job ==="
oc apply -f "${JOB_FILE}"

echo "=== Waiting for test-runner pod to start ==="
RUNNER_POD=""
for _ in $(seq 1 60); do
  RUNNER_POD="$(oc -n "${TEST_RUNNER_NAMESPACE}" get pods -l job-name="${JOB_NAME}" \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  [[ -n "${RUNNER_POD}" ]] && break
  sleep 5
done
if [[ -z "${RUNNER_POD}" ]]; then
  echo "ERROR: test-runner pod never appeared" >&2
  oc -n "${TEST_RUNNER_NAMESPACE}" describe job "${JOB_NAME}" >&2 || true
  FAILED=1
fi

if [[ -n "${RUNNER_POD}" ]]; then
  echo "=== Streaming logs from ${RUNNER_POD} ==="
  # Wait until the container is running (image pull can take a while), then follow.
  oc -n "${TEST_RUNNER_NAMESPACE}" wait --for=condition=Ready \
    "pod/${RUNNER_POD}" --timeout=600s 2>/dev/null || true

  oc -n "${TEST_RUNNER_NAMESPACE}" logs -f "job/${JOB_NAME}" 2>&1 | tee "${JOB_LOG}" || true

  echo "=== Waiting for Job completion ==="
  # No Job activeDeadlineSeconds; wait until the Job reports terminal status
  # (step timeout is the outer bound).
  job_state=""
  while true; do
    if [[ "$(oc -n "${TEST_RUNNER_NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
      job_state="succeeded"; break
    fi
    if [[ "$(oc -n "${TEST_RUNNER_NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.failed}' 2>/dev/null)" =~ ^[1-9] ]]; then
      job_state="failed"; break
    fi
    sleep 10
  done
  echo "Job state: ${job_state}"
  [[ "${job_state}" == "succeeded" ]] || FAILED=1

  # Recover JUnit reports from the captured log stream.
  extract_junit_from_log "${JOB_LOG}" "${RESULTS_DIR}" || true
fi

echo "=== Test-runner Job status ==="
oc -n "${TEST_RUNNER_NAMESPACE}" get pods -o wide 2>&1 || true
oc -n "${TEST_RUNNER_NAMESPACE}" describe job "${JOB_NAME}" 2>&1 \
  | tee "${ARTIFACT_DIR}/kuadrant-testrunner-job-describe.txt" || true

echo "=== Copying test artifacts to ${ARTIFACT_DIR} ==="
if ls "${RESULTS_DIR}"/junit-*.xml >/dev/null 2>&1; then
  cp "${RESULTS_DIR}"/junit-*.xml "${ARTIFACT_DIR}/" || true
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Testsuite finished with failures." >&2
  exit 1
fi

echo "=== Kuadrant testsuite run complete ==="
