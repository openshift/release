#!/bin/bash

set -euo pipefail

# This step runs on the amd64 build-farm (not on the s390x cluster). The runner
# image is based on quay.io/kuadrant/testsuite, which already COPYs the testsuite
# sources and runs `make poetry-no-dev` at build time
# (https://github.com/Kuadrant/testsuite/blob/main/Dockerfile).
#
# Stay in the baked-in WORKDIR so Poetry reuses the image virtualenv
# (POETRY_VIRTUALENVS_PATH=/opt/workdir/virtualenvs). OpenShift CI runs as an
# arbitrary UID that cannot write that path or the image WORKDIR, so:
#   - dynaconf overrides go to SECRETS_FOR_DYNACONF on a writable file
#     (same pattern as mounting settings → /run/secrets.yaml in the README)
#   - PYTHONPYCACHEPREFIX keeps .pyc writes out of the read-only tree
# Workload images on the s390x cluster remain s390x-specific.

TESTSUITE_DIR="${TESTSUITE_DIR}"
RESULTS_DIR="${ARTIFACT_DIR}/test-run-results"
mkdir -p "${RESULTS_DIR}"
mkdir -p "${HOME}/.pycache"
export PYTHONPYCACHEPREFIX="${HOME}/.pycache"

# OpenShift CI injects the cluster kubeconfig; prefer that over the image default
# (/run/kubeconfig from the Dockerfile).
if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

KEYCLOAK_URL="$(cat "${SHARED_DIR}/keycloak-url")"
MOCKSERVER_URL="$(cat "${SHARED_DIR}/mockserver-url")"
JAEGER_QUERY_URL="$(cat "${SHARED_DIR}/jaeger-query-url")"
JAEGER_COLLECTOR_URL="rpc://jaeger-collector.${TOOLS_NAMESPACE}.svc.cluster.local:4317"

COREDNS_ZONE="${COREDNS_ZONE:-k.example.com}"
COREDNS_NAMESPACE="${COREDNS_NAMESPACE:-kuadrant-coredns}"
COREDNS_LB_IP=""
COREDNS_PF_PID=""
COREDNS_LOCAL_PORT="${COREDNS_LOCAL_PORT:-15353}"
DNS_HOOK_DIR="${HOME}/kuadrant-dns-hook"
if [[ -f "${SHARED_DIR}/kuadrant-coredns-ip" ]]; then
  COREDNS_LB_IP="$(tr -d '[:space:]' <"${SHARED_DIR}/kuadrant-coredns-ip")"
fi
if [[ -f "${SHARED_DIR}/kuadrant-coredns-zone" ]]; then
  COREDNS_ZONE="$(tr -d '[:space:]' <"${SHARED_DIR}/kuadrant-coredns-zone")"
fi
if [[ -f "${SHARED_DIR}/kuadrant-coredns-namespace" ]]; then
  COREDNS_NAMESPACE="$(tr -d '[:space:]' <"${SHARED_DIR}/kuadrant-coredns-namespace")"
fi

# CI step pods cannot rewrite /etc/resolv.conf (Permission denied). Dynaconf
# dns.* is only used by geo/dig helpers, not by httpx. Bridge resolution by:
#   1) oc port-forward kuadrant-coredns :53 → 127.0.0.1:COREDNS_LOCAL_PORT (TCP)
#   2) pytest plugin that patches socket.getaddrinfo for *.COREDNS_ZONE
setup_coredns_client_resolver() {
  if [[ -z "${COREDNS_LB_IP}" ]]; then
    echo "WARNING: ${SHARED_DIR}/kuadrant-coredns-ip missing; DNS zone resolution may fail" >&2
    return 0
  fi

  echo "=== Bridging DNS zone ${COREDNS_ZONE} via port-forward to kuadrant-coredns ==="
  echo "CoreDNS LoadBalancer ${COREDNS_LB_IP}; local TCP DNS 127.0.0.1:${COREDNS_LOCAL_PORT}"

  mkdir -p "${DNS_HOOK_DIR}"
  cat >"${DNS_HOOK_DIR}/kuadrant_coredns_resolve.py" <<'PY'
"""Pytest plugin: resolve Kuadrant DNSPolicy hostnames via local CoreDNS forward."""
from __future__ import annotations

import os
import socket
import struct
import sys

_ZONE = os.environ.get("KUADRANT_COREDNS_ZONE", "k.example.com").strip(".").lower()
_DNS_HOST = os.environ.get("KUADRANT_COREDNS_DNS_HOST", "127.0.0.1")
_DNS_PORT = int(os.environ.get("KUADRANT_COREDNS_DNS_PORT", "15353"))
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
    with socket.create_connection((_DNS_HOST, _DNS_PORT), timeout=3.0) as sock:
        sock.sendall(struct.pack("!H", len(payload)) + payload)
        sock.settimeout(3.0)
        length_bytes = sock.recv(2)
        if len(length_bytes) < 2:
            return None
        (msg_len,) = struct.unpack("!H", length_bytes)
        data = b""
        while len(data) < msg_len:
            chunk = sock.recv(msg_len - len(data))
            if not chunk:
                break
            data += chunk
    if len(data) < 12:
        return None
    ancount = struct.unpack("!H", data[6:8])[0]
    i = 12
    # skip question
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
    if host_str and _belongs_to_zone(host_str):
        ip = _dns_query_a(host_str)
        if ip:
            return _ORIG_GETADDRINFO(ip, port, family, type, proto, flags)
    return _ORIG_GETADDRINFO(host, port, family, type, proto, flags)


def install() -> None:
    if socket.getaddrinfo is not _patched_getaddrinfo:
        socket.getaddrinfo = _patched_getaddrinfo  # type: ignore[assignment]
        print(
            f"[kuadrant_coredns_resolve] patching getaddrinfo for *.{_ZONE} "
            f"via {_DNS_HOST}:{_DNS_PORT}",
            file=sys.stderr,
        )


def pytest_configure(config):  # noqa: ARG001
    install()


install()
PY

  # Also provide sitecustomize for any non-pytest python helpers.
  cat >"${DNS_HOOK_DIR}/sitecustomize.py" <<'PY'
try:
    import kuadrant_coredns_resolve
except Exception as exc:  # pragma: no cover
    import sys
    print(f"[sitecustomize] kuadrant_coredns_resolve failed: {exc}", file=sys.stderr)
PY

  export PYTHONPATH="${DNS_HOOK_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
  export KUADRANT_COREDNS_ZONE="${COREDNS_ZONE}"
  export KUADRANT_COREDNS_DNS_HOST="127.0.0.1"
  export KUADRANT_COREDNS_DNS_PORT="${COREDNS_LOCAL_PORT}"

  # Tear down any stale forwarder on this port, then start a fresh one.
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${COREDNS_LOCAL_PORT}/tcp" 2>/dev/null || true
  fi
  oc port-forward -n "${COREDNS_NAMESPACE}" svc/kuadrant-coredns \
    "${COREDNS_LOCAL_PORT}:53" >"${ARTIFACT_DIR}/kuadrant-coredns-port-forward.log" 2>&1 &
  COREDNS_PF_PID=$!
  echo "${COREDNS_PF_PID}" >"${SHARED_DIR}/kuadrant-coredns-port-forward.pid"

  echo "Waiting for local DNS port-forward (pid ${COREDNS_PF_PID})..."
  ready=0
  for _ in $(seq 1 60); do
    if ! kill -0 "${COREDNS_PF_PID}" 2>/dev/null; then
      echo "ERROR: kuadrant-coredns port-forward exited early" >&2
      cat "${ARTIFACT_DIR}/kuadrant-coredns-port-forward.log" >&2 || true
      return 1
    fi
    if PYTHONPATH="${DNS_HOOK_DIR}" KUADRANT_COREDNS_ZONE="${COREDNS_ZONE}" \
      KUADRANT_COREDNS_DNS_HOST="127.0.0.1" KUADRANT_COREDNS_DNS_PORT="${COREDNS_LOCAL_PORT}" \
      "$(command -v python3 || command -v python)" - <<'PROBE'
import socket, struct, os, sys
zone = os.environ["KUADRANT_COREDNS_ZONE"]
host = os.environ["KUADRANT_COREDNS_DNS_HOST"]
port = int(os.environ["KUADRANT_COREDNS_DNS_PORT"])
# SOA/NS probe: query type NS (2)
def enc(n):
    o=b""
    for lab in n.strip(".").split("."):
        r=lab.encode(); o+=bytes([len(r)])+r
    return o+b"\x00"
q = enc(zone)+struct.pack("!HH", 2, 1)
payload = struct.pack("!HHHHHH", 0xBEEF, 0x0100, 1, 0, 0, 0)+q
try:
    with socket.create_connection((host, port), timeout=2.0) as s:
        s.sendall(struct.pack("!H", len(payload))+payload)
        s.settimeout(2.0)
        lb=s.recv(2)
        if len(lb)<2:
            sys.exit(1)
        (n,)=struct.unpack("!H", lb)
        data=b""
        while len(data)<n:
            c=s.recv(n-len(data))
            if not c: break
            data+=c
    rcode = data[3] & 0x0F if len(data)>=4 else 15
    # rcode 0 (NOERROR) or 3 (NXDOMAIN) both prove CoreDNS answered
    sys.exit(0 if rcode in (0, 3) else 1)
except Exception:
    sys.exit(1)
PROBE
    then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo "ERROR: could not reach kuadrant-coredns via port-forward on 127.0.0.1:${COREDNS_LOCAL_PORT}" >&2
    cat "${ARTIFACT_DIR}/kuadrant-coredns-port-forward.log" >&2 || true
    return 1
  fi
  echo "CoreDNS port-forward ready; getaddrinfo patch will load via pytest -p kuadrant_coredns_resolve"
}

stop_coredns_client_resolver() {
  if [[ -n "${COREDNS_PF_PID}" ]]; then
    echo "=== Stopping kuadrant-coredns port-forward (pid ${COREDNS_PF_PID}) ==="
    kill_pid_tree "${COREDNS_PF_PID}"
    wait_for_pids "${COREDNS_PF_PID}"
    COREDNS_PF_PID=""
  elif [[ -f "${SHARED_DIR}/kuadrant-coredns-port-forward.pid" ]]; then
    kill_pid_tree "$(cat "${SHARED_DIR}/kuadrant-coredns-port-forward.pid" 2>/dev/null || true)"
  fi
}

CFSSL_BIN="$(command -v cfssl || true)"
if [[ -z "${CFSSL_BIN}" ]]; then
  echo "ERROR: cfssl not found in the kuadrant-testsuite image" >&2
  exit 1
fi

if [[ ! -d "${TESTSUITE_DIR}" ]]; then
  echo "ERROR: baked-in testsuite directory not found at ${TESTSUITE_DIR}" >&2
  exit 1
fi

cd "${TESTSUITE_DIR}"
echo "=== Using baked-in Kuadrant testsuite at ${TESTSUITE_DIR} ==="

# Dynaconf secrets file (writable). Matches the container usage documented in
# Kuadrant/testsuite README: mount settings as SECRETS_FOR_DYNACONF=/run/secrets.yaml
export SECRETS_FOR_DYNACONF="${SHARED_DIR}/kuadrant-secrets.yaml"
echo "=== Generating ${SECRETS_FOR_DYNACONF} ==="
# Disable tracing while writing credentials into the config file
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
DNS_BLOCK=""
if [[ -n "${COREDNS_LB_IP}" ]]; then
  DNS_BLOCK="$(cat <<DNS_EOF
  dns:
    coredns_zone: "${COREDNS_ZONE}"
    dns_server:
      geo_code: "DE"
      address: "${COREDNS_LB_IP}"
    default_geo_server: "${COREDNS_LB_IP}"
DNS_EOF
)"
fi
cat > "${SECRETS_FOR_DYNACONF}" <<EOF
default:
  cfssl: "${CFSSL_BIN}"
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
    url: "${MOCKSERVER_URL}"
    image: "${MOCKSERVER_IMAGE}"
  llm_sim:
    image: "${LLM_SIM_IMAGE}"
  spicedb:
    image: "${SPICEDB_IMAGE}"
EOF
$WAS_TRACING && set -x

echo "Generated dynaconf secrets file (credentials redacted in logs)."

# ci-operator overrides the image ENTRYPOINT; invoke make targets explicitly.
export junit=yes
export resultsdir="${RESULTS_DIR}"
export USER="${USER:-ci}"

PROXY_LOG_DIR="${ARTIFACT_DIR}/gateway-istio-proxy-logs"
PROXY_COLLECTOR_PID=""
DNS_LOG_DIR="${ARTIFACT_DIR}/dns-diagnostics-logs"
DNS_COLLECTOR_PIDS=()

wait_for_pids() {
  local pid
  for pid in "$@"; do
    [[ -n "${pid}" ]] || continue
    wait "${pid}" 2>/dev/null || true
  done
}

kill_pid_tree() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  pkill -P "${pid}" 2>/dev/null || true
  kill "${pid}" 2>/dev/null || true
}

# Gateway/istio-proxy pods are created and deleted by the testsuite during smoke.
# A post-smoke dump is too late; follow istio-proxy logs concurrently into
# ARTIFACT_DIR while make smoke runs so wasm load errors survive teardown.
start_istio_proxy_log_collector() {
  mkdir -p "${PROXY_LOG_DIR}/.seen" "${PROXY_LOG_DIR}/.pids"
  echo "=== Starting concurrent istio-proxy log collector → ${PROXY_LOG_DIR} ==="
  (
    while true; do
      oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null \
        | while IFS=$'\t' read -r ns name containers; do
            [[ -n "${ns}" && -n "${name}" ]] || continue
            [[ " ${containers} " == *" istio-proxy "* || "${containers}" == *istio-proxy* ]] || continue
            # Focus on Istio Gateway dataplane pods (…-istio-…); skip istiod/etc.
            [[ "${name}" == *"-istio-"* || "${name}" == *"-istio" ]] || continue
            key="${ns}_${name}"
            seen_file="${PROXY_LOG_DIR}/.seen/${key}"
            [[ -e "${seen_file}" ]] && continue
            : >"${seen_file}"
            out="${PROXY_LOG_DIR}/${ns}_${name}_istio-proxy.log"
            echo "[collector] following ${ns}/${name} -c istio-proxy → ${out}"
            (
              # Stream until the pod disappears; retry briefly while it is Starting.
              while oc get pod -n "${ns}" "${name}" >/dev/null 2>&1; do
                oc logs -n "${ns}" "${name}" -c istio-proxy -f --timestamps=true >>"${out}" 2>&1 && break
                sleep 2
              done
            ) &
            echo $! >"${PROXY_LOG_DIR}/.pids/${key}.pid"
          done
      sleep 3
    done
  ) &
  PROXY_COLLECTOR_PID=$!
  echo "${PROXY_COLLECTOR_PID}" >"${PROXY_LOG_DIR}/.collector.pid"
}

stop_istio_proxy_log_collector() {
  echo "=== Stopping concurrent istio-proxy log collector ==="
  if [[ -n "${PROXY_COLLECTOR_PID}" ]] && kill -0 "${PROXY_COLLECTOR_PID}" 2>/dev/null; then
    kill_pid_tree "${PROXY_COLLECTOR_PID}"
  elif [[ -f "${PROXY_LOG_DIR}/.collector.pid" ]]; then
    kill_pid_tree "$(cat "${PROXY_LOG_DIR}/.collector.pid" 2>/dev/null || true)"
  fi
  if [[ -d "${PROXY_LOG_DIR}/.pids" ]]; then
    local f
    for f in "${PROXY_LOG_DIR}/.pids"/*.pid; do
      [[ -f "${f}" ]] || continue
      kill_pid_tree "$(cat "${f}")"
    done
  fi
  sleep 1
  if [[ -n "${PROXY_COLLECTOR_PID}" ]]; then
    wait_for_pids "${PROXY_COLLECTOR_PID}"
  fi
  if [[ -d "${PROXY_LOG_DIR}/.pids" ]]; then
    local f
    for f in "${PROXY_LOG_DIR}/.pids"/*.pid; do
      [[ -f "${f}" ]] || continue
      wait_for_pids "$(cat "${f}")"
    done
  fi

  echo "--- captured istio-proxy log files ---"
  ls -la "${PROXY_LOG_DIR}"/*_istio-proxy.log 2>/dev/null || echo "(no proxy log files captured)"
  {
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) istio-proxy wasm/error summary ====="
    if ls "${PROXY_LOG_DIR}"/*_istio-proxy.log >/dev/null 2>&1; then
      grep -h -iE 'wasm|plugin\.wasm|Unable to create|error|fail|503|ratelimit' \
        "${PROXY_LOG_DIR}"/*_istio-proxy.log 2>/dev/null || echo "(no wasm/error matches in captured logs)"
    else
      echo "(no proxy log files captured)"
    fi
  } | tee "${ARTIFACT_DIR}/gateway-istio-proxy-wasm-summary.txt" || true
}

# DNSPolicy smoke failures need live operator + CR status while tests run
# (DNSPolicy/DNSRecord objects are often gone after suite teardown).
start_dns_log_collector() {
  mkdir -p "${DNS_LOG_DIR}"
  echo "=== Starting concurrent DNS diagnostics collector → ${DNS_LOG_DIR} ==="
  {
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) DNS collector start ====="
    echo "DNS_PROVIDER_SECRET_NAME=${DNS_PROVIDER_SECRET_NAME}"
    echo "KUADRANT_NAMESPACE=${KUADRANT_NAMESPACE}"
  } >"${DNS_LOG_DIR}/dns-collector-meta.txt"

  # Stream dns-operator + kuadrant-operator logs for the whole smoke window.
  (
    while oc get deploy/dns-operator-controller-manager -n "${KUADRANT_NAMESPACE}" >/dev/null 2>&1; do
      oc logs -n "${KUADRANT_NAMESPACE}" deploy/dns-operator-controller-manager \
        -f --timestamps=true --all-containers=true >>"${DNS_LOG_DIR}/dns-operator-controller-manager.log" 2>&1 && break
      sleep 2
    done
  ) &
  DNS_COLLECTOR_PIDS+=("$!")

  (
    while oc get deploy/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}" >/dev/null 2>&1; do
      oc logs -n "${KUADRANT_NAMESPACE}" deploy/kuadrant-operator-controller-manager \
        -f --timestamps=true --all-containers=true >>"${DNS_LOG_DIR}/kuadrant-operator-controller-manager.log" 2>&1 && break
      sleep 2
    done
  ) &
  DNS_COLLECTOR_PIDS+=("$!")

  # Periodic CR/secret/event snapshots (no secret data values).
  (
    while true; do
      {
        echo "========== $(date -u +%Y-%m-%dT%H:%M:%SZ) =========="
        echo "--- DNSPolicy / DNSRecord / TLSPolicy (wide) ---"
        oc get dnspolicy,dnsrecord,tlspolicy -A -o wide 2>&1 || true
        echo "--- DNSPolicy yaml ---"
        oc get dnspolicy -A -o yaml 2>&1 || true
        echo "--- DNSRecord yaml ---"
        oc get dnsrecord -A -o yaml 2>&1 || true
        echo "--- DNS provider Secret metadata (keys only, no values) ---"
        for ns in kuadrant kuadrant2; do
          echo ">> namespace/${ns} secret/${DNS_PROVIDER_SECRET_NAME}"
          oc get secret "${DNS_PROVIDER_SECRET_NAME}" -n "${ns}" \
            -o go-template='name={{.metadata.name}} type={{.type}} keys={{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}' 2>&1 \
            || echo "(missing)"
        done
        echo "--- Events mentioning DNS / DNSPolicy / DNSRecord ---"
        oc get events -A --sort-by='.lastTimestamp' 2>/dev/null \
          | grep -iE 'dns|dnspolicy|dnsrecord|coredns|provider' | tail -80 || true
        echo "--- csv/pods dns-related ---"
        oc get csv,pods -n "${KUADRANT_NAMESPACE}" 2>&1 | grep -iE 'dns|NAME' || true
      } >>"${DNS_LOG_DIR}/dns-resources-snapshots.log" 2>&1
      sleep 10
    done
  ) &
  DNS_COLLECTOR_PIDS+=("$!")
  echo "${DNS_COLLECTOR_PIDS[*]}" >"${DNS_LOG_DIR}/.collector.pids"
}

stop_dns_log_collector() {
  echo "=== Stopping concurrent DNS diagnostics collector ==="
  local pid
  for pid in "${DNS_COLLECTOR_PIDS[@]}"; do
    kill_pid_tree "${pid}"
  done
  if [[ -f "${DNS_LOG_DIR}/.collector.pids" ]]; then
    for pid in $(cat "${DNS_LOG_DIR}/.collector.pids" 2>/dev/null || true); do
      kill_pid_tree "${pid}"
    done
  fi
  sleep 1
  wait_for_pids "${DNS_COLLECTOR_PIDS[@]}"
  if [[ -f "${DNS_LOG_DIR}/.collector.pids" ]]; then
    wait_for_pids $(cat "${DNS_LOG_DIR}/.collector.pids" 2>/dev/null || true)
  fi

  echo "--- captured DNS diagnostic files ---"
  ls -la "${DNS_LOG_DIR}" 2>/dev/null || echo "(none)"
  {
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) DNS error/condition summary ====="
    echo "--- from dns-operator log ---"
    grep -iE 'error|fail|warn|missing|not ready|provider|credential|dnspolicy|dnsrecord' \
      "${DNS_LOG_DIR}/dns-operator-controller-manager.log" 2>/dev/null | tail -120 \
      || echo "(no dns-operator matches)"
    echo "--- from kuadrant-operator log (dns) ---"
    grep -iE 'dns|DNSPolicy|DNSRecord|MissingDependency|provider' \
      "${DNS_LOG_DIR}/kuadrant-operator-controller-manager.log" 2>/dev/null | tail -120 \
      || echo "(no kuadrant-operator dns matches)"
    echo "--- last DNSPolicy/DNSRecord conditions from snapshots ---"
    grep -E 'type:|reason:|message:|status:|kind: DNS|name:' \
      "${DNS_LOG_DIR}/dns-resources-snapshots.log" 2>/dev/null | tail -160 \
      || echo "(no snapshot matches)"
  } | tee "${ARTIFACT_DIR}/dns-diagnostics-summary.txt" || true
}

dump_s390x_smoke_diagnostics() {
  local out="${ARTIFACT_DIR}/kuadrant-smoke-diagnostics.txt"
  echo "=== Dumping post-smoke diagnostics to ${out} ==="
  {
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) smoke diagnostics ====="
    echo "--- Kuadrant CRs ---"
    oc get kuadrant -A -o wide 2>&1 || true
    oc get kuadrant -A -o yaml 2>&1 || true

    echo "--- operator RELATED_IMAGE_WASMSHIM / manager image ---"
    oc set env deployment/kuadrant-operator-controller-manager \
      -n "${KUADRANT_NAMESPACE}" --list 2>&1 | grep RELATED_IMAGE || true
    oc get deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}' 2>&1 || true

    echo "--- kuadrant-operator-wasm Service / Endpoints ---"
    oc get svc,endpoints kuadrant-operator-wasm -n "${KUADRANT_NAMESPACE}" -o wide 2>&1 || true
    oc get svc,endpoints kuadrant-operator-wasm -n "${KUADRANT_NAMESPACE}" -o yaml 2>&1 || true

    echo "--- WasmPlugin (all namespaces) ---"
    oc get wasmplugin -A -o wide 2>&1 || true
    oc get wasmplugin -A -o yaml 2>&1 || true

    echo "--- RateLimitPolicy / AuthPolicy ---"
    oc get ratelimitpolicy -A -o wide 2>&1 || true
    oc get ratelimitpolicy -A -o yaml 2>&1 || true
    oc get authpolicy -A -o wide 2>&1 || true

    echo "--- Gateways / HTTPRoutes ---"
    oc get gateway -A -o wide 2>&1 || true
    oc get httproute -A -o wide 2>&1 || true

    echo "--- Limitador / Authorino ---"
    oc get limitador -A -o wide 2>&1 || true
    oc get limitador -A -o yaml 2>&1 || true
    oc get pods -A -l 'app.kubernetes.io/name=limitador' -o wide 2>&1 || true
    oc get pods -A -l 'app.kubernetes.io/name=authorino' -o wide 2>&1 || true

    echo "--- kuadrant-operator recent logs (wasm/shim/error) ---"
    oc logs -n "${KUADRANT_NAMESPACE}" deploy/kuadrant-operator-controller-manager \
      --tail=200 2>&1 | grep -iE 'wasm|shim|error|fail|ratelimit' || true

    echo "--- istiod / remaining gateway proxy log snippets (wasm) ---"
    for ns in istio-system openshift-operators "${KUADRANT_NAMESPACE}" kuadrant kuadrant2; do
      for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E 'istiod|gateway|istio-ingress|-istio-' || true); do
        echo ">>> ${ns}/${pod}"
        oc logs -n "${ns}" "${pod}" -c discovery --tail=80 2>/dev/null | grep -iE 'wasm|error|fail' || true
        oc logs -n "${ns}" "${pod}" -c istio-proxy --tail=80 2>/dev/null | grep -iE 'wasm|error|fail|503' || true
        oc logs -n "${ns}" "${pod}" --all-containers --tail=40 2>/dev/null | grep -iE 'wasm|error|fail' || true
      done
    done
    # Also scan any leftover kuadrant* namespaces still present
    for ns in $(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^kuadrant' || true); do
      for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E '-istio-' || true); do
        echo ">>> ${ns}/${pod}"
        oc logs -n "${ns}" "${pod}" -c istio-proxy --tail=200 2>/dev/null || true
      done
    done

    echo "--- DNSPolicy / TLSPolicy / DNSRecord (post-smoke; may be empty after teardown) ---"
    oc get dnspolicy,dnsrecord,tlspolicy -A -o wide 2>&1 || true
    oc get dnspolicy -A -o yaml 2>&1 || true
    oc get dnsrecord -A -o yaml 2>&1 || true

    echo "--- concurrent istio-proxy captures (see also ${PROXY_LOG_DIR}) ---"
    ls -la "${PROXY_LOG_DIR}"/*_istio-proxy.log 2>/dev/null || echo "(none)"
    echo "--- concurrent DNS captures (see also ${DNS_LOG_DIR}) ---"
    ls -la "${DNS_LOG_DIR}" 2>/dev/null || echo "(none)"
  } >"${out}" 2>&1 || true
  # Also echo a short summary to the step log
  echo "--- diagnostic summary ---"
  grep -E '^(--- |NAME |Error|error|wasm|RELATED|phase=|message:|Unable|manager=)' "${out}" 2>/dev/null | head -80 || true
  echo "(full dump: ${out})"
  echo "(proxy streams: ${PROXY_LOG_DIR}/ ; wasm summary: ${ARTIFACT_DIR}/gateway-istio-proxy-wasm-summary.txt)"
  echo "(dns streams: ${DNS_LOG_DIR}/ ; dns summary: ${ARTIFACT_DIR}/dns-diagnostics-summary.txt)"
}

FAILED=0

# CoreDNS client bridge is needed for DNSPolicy/TLSPolicy tests in both smoke
# and the full kuadrant suite (*.COREDNS_ZONE hostnames).
NEED_COREDNS_BRIDGE=false
if [[ "${RUN_SMOKE}" == "true" || "${RUN_KUADRANT}" == "true" ]]; then
  NEED_COREDNS_BRIDGE=true
fi
if [[ "${NEED_COREDNS_BRIDGE}" == "true" ]]; then
  setup_coredns_client_resolver
fi

if [[ "${RUN_SMOKE}" == "true" ]]; then
  echo "=== Running smoke tests (no Playwright) ==="
  start_istio_proxy_log_collector
  start_dns_log_collector
  # -p kuadrant_coredns_resolve: patch getaddrinfo for *.COREDNS_ZONE via port-forward
  if ! flags="${PYTEST_FLAGS} -p kuadrant_coredns_resolve" make smoke; then
    echo "WARNING: smoke tests reported failures" >&2
    FAILED=1
  fi
  stop_dns_log_collector
  stop_istio_proxy_log_collector
  dump_s390x_smoke_diagnostics
fi

if [[ "${RUN_KUADRANT}" == "true" ]]; then
  echo "=== Running single-cluster Kuadrant tests (make kuadrant, no ui/playwright) ==="
  start_istio_proxy_log_collector
  start_dns_log_collector
  if ! flags="${PYTEST_FLAGS} -p kuadrant_coredns_resolve" make kuadrant; then
    echo "WARNING: kuadrant tests reported failures" >&2
    FAILED=1
  fi
  stop_dns_log_collector
  stop_istio_proxy_log_collector
  dump_s390x_smoke_diagnostics
fi

if [[ "${NEED_COREDNS_BRIDGE}" == "true" ]]; then
  stop_coredns_client_resolver
fi

echo "=== Polishing JUnit reports ==="
make polish-junit || true

echo "=== Copying test artifacts to ${ARTIFACT_DIR} ==="
cp -a "${RESULTS_DIR}/." "${ARTIFACT_DIR}/" || true
if ls "${RESULTS_DIR}"/junit-*.xml >/dev/null 2>&1; then
  cp "${RESULTS_DIR}"/junit-*.xml "${ARTIFACT_DIR}/"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Testsuite finished with failures." >&2
  exit 1
fi

echo "=== Kuadrant testsuite run complete ==="
