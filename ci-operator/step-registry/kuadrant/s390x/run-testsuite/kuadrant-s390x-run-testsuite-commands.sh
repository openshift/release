#!/bin/bash

set -euo pipefail

# Runs the Kuadrant testsuite as an in-cluster Job on the s390x cluster.
#
# Bastion-proven s390x workarounds applied in-Job before make:
#   - Velocity MockServer echo (header-mirroring; Kuadrant/testsuite#952)
#   - Authorino/OIDC dataplane-ready soft-wait patch
#   - protobuf==6.32.1 pin (broken s390x upb ≥6.33.0)
#   - CFSSL ensure (baked in Dockerfile.s390x; fallback download if missing)
#   - CoreDNS getaddrinfo plugin + UI ignore
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
# Same as rhcl-mc1: use cluster thanos-querier (written by deploy-tools after UWM enable).
PROMETHEUS_URL="${PROMETHEUS_URL:-}"
if [[ -f "${SHARED_DIR}/prometheus-url" ]]; then
  PROMETHEUS_URL="$(tr -d '[:space:]' <"${SHARED_DIR}/prometheus-url")"
fi
if [[ -z "${PROMETHEUS_URL}" ]]; then
  PROMETHEUS_URL="https://thanos-querier.openshift-monitoring.svc.cluster.local:9091"
  echo "WARNING: SHARED_DIR/prometheus-url missing; falling back to ${PROMETHEUS_URL}" >&2
fi

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
  # Cluster monitoring thanos-querier (UWM enabled in deploy-tools). Bearer token
  # comes from the SA token kubeconfig mounted into the Job (rhcl-mc1 pattern;
  # installer kubeconfig is often cert-based and yields empty cluster.token).
  prometheus:
    project: "openshift-monitoring"
    service: "thanos-querier"
    url: "${PROMETHEUS_URL}"
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
# Velocity echo that mirrors request headers (httpbin-style). Header values are
# JSON-escaped so Authorino JsonResponse headers (e.g. "simple": "{\"data\":...}")
# survive into response.json()["headers"] for extract_response().
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
    "httpRequest": {},
    "httpResponseTemplate": {
      "templateType": "VELOCITY",
      "template": "#set($first = true)\n{\n  \"statusCode\": 200,\n  \"headers\": {\"content-type\": [\"application/json\"]},\n  \"body\": {\n    \"headers\": {\n#foreach($entry in $request.headers.entrySet())\n#set($raw = $entry.value.get(0))\n#set($q = '\"')\n#set($bs = '\\')\n#set($val = $raw.replace($bs, $bs + $bs).replace($q, $bs + $q))\n#if($first)#set($first = false)#else\n,\n#end\n      \"$entry.key\": \"$val\"\n#end\n    },\n    \"method\": \"$request.method\",\n    \"url\": \"$request.path\"\n  }\n}\n"
    },
    "priority": -10
  }
]
EOF

# ---------------------------------------------------------------------------
# 2a2. Authorino/OIDC dataplane-ready soft-wait (s390x race after AuthPolicy Enforced)
#     Applied in-Job onto the baked testsuite tree before make. The unified diff is
#     embedded below (step-registry only allows known companion suffixes).
# ---------------------------------------------------------------------------
DATAPLANE_PATCH_FILE="${WORK_DIR}/kuadrant-s390x-run-testsuite-dataplane-ready.patch"
cat > "${DATAPLANE_PATCH_FILE}" <<'PATCH_EOF'
diff --git a/testsuite/kuadrant/extensions/oidc_policy.py b/testsuite/kuadrant/extensions/oidc_policy.py
index 2896b48..6c13428 100644
--- a/testsuite/kuadrant/extensions/oidc_policy.py
+++ b/testsuite/kuadrant/extensions/oidc_policy.py
@@ -63,5 +63,6 @@ class OIDCPolicy(Policy):
     def wait_for_ready(self):
         """Wait for OIDCPolicy to be enforced"""
         super().wait_for_ready()
-        # Even after enforced condition OIDCPolicy requires a short sleep
-        time.sleep(OIDC_POST_ENFORCEMENT_WAIT)  # Workaround for issue #884
+        # CR Enforced is not enough for dataplane redirect; tests also poll for HTTP 302
+        # via wait_for_oidc_dataplane. Keep a short settle for issue #884.
+        time.sleep(OIDC_POST_ENFORCEMENT_WAIT)  # Workaround for https://github.com/Kuadrant/testsuite/issues/884
diff --git a/testsuite/tests/singlecluster/authorino/conftest.py b/testsuite/tests/singlecluster/authorino/conftest.py
index 38c3726..5553458 100644
--- a/testsuite/tests/singlecluster/authorino/conftest.py
+++ b/testsuite/tests/singlecluster/authorino/conftest.py
@@ -1,10 +1,16 @@
 """Conftest for Authorino tests"""
 
+import logging
+
+import backoff
 import pytest
 
 from testsuite.httpx.auth import HttpxOidcClientAuth
 from testsuite.kuadrant.authorino import AuthorinoCR, PreexistingAuthorino
 from testsuite.kuadrant.policy.authorization.auth_config import AuthConfig
+from testsuite.utils.constants import AUTH_DATAPLANE_READY_INTERVAL, AUTH_DATAPLANE_READY_TIMEOUT
+
+LOGGER = logging.getLogger(__name__)
 
 
 @pytest.fixture(scope="session")
@@ -55,3 +61,66 @@ def commit(request, authorization):
     request.addfinalizer(authorization.delete)
     authorization.commit()
     authorization.wait_for_ready()
+
+
+@pytest.fixture(scope="module")
+def wait_for_unauthenticated_denial():
+    """
+    Whether module setup should poll for unauthenticated /get denial (401/403) or a
+    `simple` response header as a dataplane-readiness signal.
+
+    Override to False in modules where that signal is wrong (e.g. mTLS frontend
+    validation, path-conditional AuthPolicies that leave /get open).
+    """
+    return True
+
+
+def _auth_dataplane_ready(response) -> bool:
+    """True when Authorino is active on the request path."""
+    if response.status_code in (401, 403):
+        # Required identity is enforced (typical OIDC / API key / x509 policies).
+        return True
+    if response.status_code != 200:
+        return False
+    try:
+        headers = response.json().get("headers", {})
+    except Exception:  # pylint: disable=broad-exception-caught
+        return False
+    # Anonymous (or other allow-unauthenticated) policies: wait for injected response headers.
+    return any(name.lower() == "simple" for name in headers)
+
+
+@pytest.fixture(scope="module", autouse=True)
+def wait_for_auth_dataplane(commit, client, wait_for_unauthenticated_denial):  # pylint: disable=unused-argument
+    """
+    Best-effort wait until Authorino is enforcing on the gateway dataplane.
+
+    AuthPolicy Enforced / first HTTP 200 after wasm 503s is not enough: traffic can be
+    fail-opened while the wasm filter is still loading. Retry an unauthenticated request
+    until identity denial (401/403) or an Authorino `simple` response header appears.
+
+    Timeout does not fail setup: modules where unauth /get is never denied would otherwise
+    become mass ERROR. Those tests still fail in-body if auth is not ready.
+    """
+    if not wait_for_unauthenticated_denial:
+        return
+
+    @backoff.on_predicate(
+        backoff.constant,
+        lambda ready: not ready,
+        interval=AUTH_DATAPLANE_READY_INTERVAL,
+        max_time=AUTH_DATAPLANE_READY_TIMEOUT,
+        jitter=None,
+    )
+    def _wait():
+        try:
+            return _auth_dataplane_ready(client.get("/get"))
+        except Exception:  # pylint: disable=broad-exception-caught
+            return False
+
+    if not _wait():
+        LOGGER.warning(
+            "Authorino dataplane readiness signal not observed within %ss "
+            "(unauthenticated /get never returned 401/403 or a 'simple' header); continuing",
+            AUTH_DATAPLANE_READY_TIMEOUT,
+        )
diff --git a/testsuite/tests/singlecluster/authorino/dinosaur/conftest.py b/testsuite/tests/singlecluster/authorino/dinosaur/conftest.py
index 8e9cea3..fa4bece 100644
--- a/testsuite/tests/singlecluster/authorino/dinosaur/conftest.py
+++ b/testsuite/tests/singlecluster/authorino/dinosaur/conftest.py
@@ -11,6 +11,12 @@ from testsuite.utils import ContentType
 from testsuite.kuadrant.policy.authorization import Pattern, PatternRef, Value, ValueFrom, DenyResponse
 
 
+@pytest.fixture(scope="module")
+def wait_for_unauthenticated_denial():
+    """Dinosaur AuthPolicy is path/when-conditional; unauth /get is not a readiness signal."""
+    return False
+
+
 @pytest.fixture(scope="session")
 def admin_rhsso(blame, keycloak):
     """Keycloak Admin realm"""
diff --git a/testsuite/tests/singlecluster/authorino/identity/x509/gateway_validation/conftest.py b/testsuite/tests/singlecluster/authorino/identity/x509/gateway_validation/conftest.py
index 69e048c..159f07e 100644
--- a/testsuite/tests/singlecluster/authorino/identity/x509/gateway_validation/conftest.py
+++ b/testsuite/tests/singlecluster/authorino/identity/x509/gateway_validation/conftest.py
@@ -8,6 +8,12 @@ from testsuite.kuadrant.policy.tls import TLSPolicy
 from testsuite.kubernetes.config_map import ConfigMap
 
 
+@pytest.fixture(scope="module")
+def wait_for_unauthenticated_denial():
+    """mTLS frontend validation: plain unauth /get is not a valid Authorino readiness signal."""
+    return False
+
+
 @pytest.fixture(scope="module")
 def exposer(request, testconfig, cluster) -> Exposer:
     """Exposer object instance with TLS passthrough"""
diff --git a/testsuite/tests/singlecluster/extensions/oidc_policy/conftest.py b/testsuite/tests/singlecluster/extensions/oidc_policy/conftest.py
index 0a72db0..9a2cba1 100644
--- a/testsuite/tests/singlecluster/extensions/oidc_policy/conftest.py
+++ b/testsuite/tests/singlecluster/extensions/oidc_policy/conftest.py
@@ -6,11 +6,14 @@ in their respective test files.
 """
 
 from contextlib import contextmanager
+
+import backoff
 import pytest
 
 from testsuite.gateway import Gateway, GatewayListener
 from testsuite.gateway.gateway_api.gateway import KuadrantGateway
 from testsuite.kuadrant.extensions.oidc_policy import OIDCPolicy
+from testsuite.utils.constants import OIDC_DATAPLANE_READY_INTERVAL, OIDC_DATAPLANE_READY_TIMEOUT
 
 
 @pytest.fixture(scope="module")
@@ -62,3 +65,32 @@ def commit(request, oidc_policy):
     request.addfinalizer(oidc_policy.delete)
     oidc_policy.commit()
     oidc_policy.wait_for_ready()
+
+
+@pytest.fixture(scope="module", autouse=True)
+def wait_for_oidc_dataplane(commit, client):  # pylint: disable=unused-argument
+    """
+    Wait until OIDCPolicy redirect is active on the gateway dataplane.
+
+    OIDCPolicy Enforced / fixed post-enforcement sleep is not enough: traffic can still
+    be fail-opened (HTTP 200) while AuthConfig/wasm is catching up. Retry an
+    unauthenticated request until it returns the OAuth2 redirect (302).
+    """
+
+    @backoff.on_predicate(
+        backoff.constant,
+        lambda ready: not ready,
+        interval=OIDC_DATAPLANE_READY_INTERVAL,
+        max_time=OIDC_DATAPLANE_READY_TIMEOUT,
+        jitter=None,
+    )
+    def _wait():
+        try:
+            return client.get("/").status_code == 302
+        except Exception:  # pylint: disable=broad-exception-caught
+            return False
+
+    assert _wait(), (
+        f"Timed out after {OIDC_DATAPLANE_READY_TIMEOUT}s waiting for OIDC dataplane readiness "
+        "(unauthenticated request never returned 302 redirect)"
+    )
diff --git a/testsuite/utils/constants.py b/testsuite/utils/constants.py
index 26c6a71..4c9ad83 100644
--- a/testsuite/utils/constants.py
+++ b/testsuite/utils/constants.py
@@ -167,9 +167,19 @@ DNS_PROPAGATION_WAIT = 300  # 5 minutes
 
 # --- Miscellaneous Workarounds (seconds) ---
 
-# Workaround for https://github.com/Kuadrant/testsuite/issues/884 — remove when fixed
+# Workaround for https://github.com/Kuadrant/testsuite/issues/884 — remove when fixed.
+# Prefer OIDC dataplane readiness polling (wait_for_oidc_dataplane) over relying on this alone.
 OIDC_POST_ENFORCEMENT_WAIT = 10
 
+# Wait for Authorino to enforce on the gateway dataplane after AuthPolicy is Enforced.
+# CR readiness alone is insufficient while wasm/Envoy is still loading (common on slow arches).
+AUTH_DATAPLANE_READY_TIMEOUT = 60
+AUTH_DATAPLANE_READY_INTERVAL = 1
+
+# Wait for OIDCPolicy redirect to be active on the gateway dataplane (unauth -> 302).
+OIDC_DATAPLANE_READY_TIMEOUT = 60
+OIDC_DATAPLANE_READY_INTERVAL = 1
+
 # Wait for OPA external registry cache TTL to expire (TTL + buffer).
 OPA_CACHE_TTL_WAIT = 2
 
PATCH_EOF

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
# 3. Build the in-container command (smoke + authorino/limitador/dnstls/
#    observability + optional catch-all kuadrant)
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

# Authorino/OIDC dataplane soft-wait (CR Enforced ≠ gateway ready on slow arches).
# Idempotent: skip if the baked image already includes the wait helpers.
echo '=== Applying s390x dataplane-ready testsuite patch ==='
if grep -q 'AUTH_DATAPLANE_READY_TIMEOUT' testsuite/utils/constants.py 2>/dev/null; then
  echo 'dataplane-ready helpers already present; skipping patch'
else
  if command -v git >/dev/null 2>&1; then
    git apply --verbose /kuadrant-hook/kuadrant-s390x-run-testsuite-dataplane-ready.patch
  elif command -v patch >/dev/null 2>&1; then
    patch -p1 < /kuadrant-hook/kuadrant-s390x-run-testsuite-dataplane-ready.patch
  else
    echo 'ERROR: neither git nor patch available to apply dataplane-ready patch' >&2
    exit 1
  fi
fi
grep -n AUTH_DATAPLANE_READY_TIMEOUT testsuite/utils/constants.py || true
grep -n wait_for_auth_dataplane testsuite/tests/singlecluster/authorino/conftest.py || true

# CFSSL: Dockerfile.s390x installs /usr/bin/cfssl; re-install if the baked image is older.
echo '=== Ensuring cfssl is on PATH ==='
if ! command -v cfssl >/dev/null 2>&1; then
  echo 'cfssl missing; downloading s390x binary from cloudflare/cfssl v1.6.5'
  mkdir -p /tmp/bin
  curl -fsSL -o /tmp/bin/cfssl \\
    https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssl_1.6.5_linux_s390x
  chmod +x /tmp/bin/cfssl
  export PATH=\"/tmp/bin:\$PATH\"
fi
command -v cfssl
cfssl version || true
"
# Make targets are independent: each records failure into rc but does not skip
# the next target. Order: smoke → authorino → limitador → dnstls → observability
# → kuadrant (catch-all single-cluster). Non-smoke targets use --reruns 0
# (Makefile defaults to --reruns 3; last --reruns on the pytest CLI wins).
if [[ "${RUN_SMOKE}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make smoke ==='
flags='${PYTEST_PLUGIN_FLAGS}' make smoke || rc=1
"
fi
if [[ "${RUN_AUTHORINO:-true}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make authorino (runs even if prior targets failed; --reruns 0) ==='
flags='${PYTEST_PLUGIN_FLAGS} --reruns 0' make authorino || rc=1
"
fi
if [[ "${RUN_LIMITADOR:-true}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make limitador (runs even if prior targets failed; --reruns 0) ==='
flags='${PYTEST_PLUGIN_FLAGS} --reruns 0' make limitador || rc=1
"
fi
if [[ "${RUN_DNSTLS:-true}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make dnstls (runs even if prior targets failed; --reruns 0) ==='
flags='${PYTEST_PLUGIN_FLAGS} --reruns 0' make dnstls || rc=1
"
fi
if [[ "${RUN_OBSERVABILITY:-true}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make observability (runs even if prior targets failed; --reruns 0) ==='
flags='${PYTEST_PLUGIN_FLAGS} --reruns 0' make observability || rc=1
"
fi
if [[ "${RUN_KUADRANT}" == "true" ]]; then
  CONTAINER_SCRIPT+="echo '=== make kuadrant (runs even if prior targets failed; --reruns 0) ==='
flags='${PYTEST_PLUGIN_FLAGS} --reruns 0' make kuadrant || rc=1
"
fi
CONTAINER_SCRIPT+="make polish-junit || true
# Debug summary before JUnit dump (survives even if follow logs drop mid-run).
echo '===KUADRANT_SUMMARY_BEGIN==='
echo \"rc=\${rc}\"
echo \"pwd=\$(pwd)\"
echo \"resultsdir=\${resultsdir}\"
ls -la \"\${resultsdir}\" 2>/dev/null || true
if command -v python3 >/dev/null 2>&1; then
  python3 - \"\${resultsdir}\" <<'PY' || true
import sys, xml.etree.ElementTree as ET, glob, os
rd = sys.argv[1]
for path in sorted(glob.glob(os.path.join(rd, \"junit-*.xml\"))):
    print(f\"--- {os.path.basename(path)} ---\")
    try:
        root = ET.parse(path).getroot()
    except Exception as exc:  # noqa: BLE001
        print(f\"parse_error: {exc}\")
        continue
    for s in root.iter(\"testsuite\"):
        print(
            \"suite\", s.get(\"name\"),
            \"tests\", s.get(\"tests\"),
            \"failures\", s.get(\"failures\"),
            \"errors\", s.get(\"errors\"),
            \"skipped\", s.get(\"skipped\"),
            \"time\", s.get(\"time\"),
        )
    for tc in root.iter(\"testcase\"):
        bad = tc.find(\"failure\")
        err = tc.find(\"error\")
        if bad is None and err is None:
            continue
        node = bad if bad is not None else err
        kind = \"FAILURE\" if bad is not None else \"ERROR\"
        msg = (node.get(\"message\") or \"\").replace(\"\\n\", \" \")[:300]
        print(f\"{kind} {tc.get('classname')}::{tc.get('name')} :: {msg}\")
PY
fi
echo '===KUADRANT_SUMMARY_END==='
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

# ---------------------------------------------------------------------------
# Token kubeconfig for Prometheus/Thanos (rhcl-mc1 pattern).
# SHARED_DIR/kubeconfig from libvirt UPI is often client-certificate auth, so
# testsuite cluster.token is empty → Illegal header value b'Bearer '.
# Mint a long-lived SA token kubeconfig like rhcl-mc1's admin kubeconfig.
# ---------------------------------------------------------------------------
TESTRUNNER_SA="kuadrant-testrunner"
echo "=== Creating ${TESTRUNNER_SA} ServiceAccount with cluster-admin (for Thanos bearer) ==="
oc -n "${TEST_RUNNER_NAMESPACE}" create sa "${TESTRUNNER_SA}" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-cluster-role-to-user cluster-admin \
  -z "${TESTRUNNER_SA}" -n "${TEST_RUNNER_NAMESPACE}"

TOKEN_KUBECONFIG="${WORK_DIR}/testrunner.kubeconfig"
[[ $- == *x* ]] && WAS_TRACING_KC=true || WAS_TRACING_KC=false
set +x  # Disable tracing due to token handling
API_SERVER="$(oc whoami --show-server)"
# Prefer bound token (OCP 4.11+); fall back to legacy sa secret token.
TESTRUNNER_TOKEN="$(oc -n "${TEST_RUNNER_NAMESPACE}" create token "${TESTRUNNER_SA}" --duration=12h 2>/dev/null || true)"
if [[ -z "${TESTRUNNER_TOKEN}" ]]; then
  SA_SECRET="$(oc -n "${TEST_RUNNER_NAMESPACE}" get sa "${TESTRUNNER_SA}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)"
  if [[ -n "${SA_SECRET}" ]]; then
    TESTRUNNER_TOKEN="$(oc -n "${TEST_RUNNER_NAMESPACE}" get secret "${SA_SECRET}" -o jsonpath='{.data.token}' | base64 -d)"
  fi
fi
if [[ -z "${TESTRUNNER_TOKEN}" ]]; then
  echo "ERROR: could not mint token for ${TESTRUNNER_SA}; Prometheus metrics tests will fail with empty Bearer" >&2
  $WAS_TRACING_KC && set -x
  exit 1
fi
# Build a token kubeconfig with oc (no jq/python dependency in the step image).
# insecure-skip-tls-verify matches the testsuite Prometheus client (verify=False).
rm -f "${TOKEN_KUBECONFIG}"
oc --kubeconfig="${TOKEN_KUBECONFIG}" config set-cluster cluster \
  --server="${API_SERVER}" --insecure-skip-tls-verify=true >/dev/null
oc --kubeconfig="${TOKEN_KUBECONFIG}" config set-credentials testrunner \
  --token="${TESTRUNNER_TOKEN}" >/dev/null
oc --kubeconfig="${TOKEN_KUBECONFIG}" config set-context testrunner \
  --cluster=cluster --user=testrunner >/dev/null
oc --kubeconfig="${TOKEN_KUBECONFIG}" config use-context testrunner >/dev/null
TOKEN_LEN="${#TESTRUNNER_TOKEN}"
unset TESTRUNNER_TOKEN
$WAS_TRACING_KC && set -x
if [[ "${TOKEN_LEN}" -lt 16 ]]; then
  echo "ERROR: testrunner kubeconfig token length=${TOKEN_LEN} (expected non-empty bearer)" >&2
  exit 1
fi
echo "Testrunner kubeconfig ready (token length=${TOKEN_LEN}; not logged)."

oc -n "${TEST_RUNNER_NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found=true --wait=true

# Secret: dynaconf settings + token kubeconfig (Prometheus fixture uses cluster.token).
oc -n "${TEST_RUNNER_NAMESPACE}" create secret generic kuadrant-testrunner-config \
  --from-file=secrets.yaml="${SECRETS_FILE}" \
  --from-file=kubeconfig="${TOKEN_KUBECONFIG}" \
  --dry-run=client -o yaml | oc apply -f -

# ConfigMap: CoreDNS getaddrinfo plugin + Velocity MockServer expectations
# (s390x workaround for Kuadrant/testsuite#952).
oc -n "${TEST_RUNNER_NAMESPACE}" create configmap kuadrant-testrunner-hook \
  --from-file=kuadrant_coredns_resolve.py="${PLUGIN_FILE}" \
  --from-file=echo_expectation.json="${ECHO_EXPECTATION_FILE}" \
  --from-file=kuadrant-s390x-run-testsuite-dataplane-ready.patch="${DATAPLANE_PATCH_FILE}" \
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
# Long s390x runs frequently drop `oc logs -f` (http2: client connection lost),
# which previously left ARTIFACT_DIR with a truncated Job log and no JUnit.
# We follow with restarts, periodically snapshot full logs, and dump pod
# termination diagnostics before cleanup.
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

extract_summary_from_log() {
  local logfile="$1" dest="$2"
  python3 - "$logfile" "$dest" <<'PY'
import os
import sys

logfile, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
out_path = os.path.join(dest, "kuadrant-testrunner-summary.txt")
capturing = False
buf = []
rc_line = None
with open(logfile, "r", errors="replace") as fh:
    for line in fh:
        raw = line.rstrip("\n")
        if raw.startswith("===KUADRANT_RC "):
            rc_line = raw
        if raw == "===KUADRANT_SUMMARY_BEGIN===":
            capturing = True
            buf = [raw]
            continue
        if capturing:
            buf.append(raw)
            if raw == "===KUADRANT_SUMMARY_END===":
                capturing = False
if buf or rc_line:
    with open(out_path, "w", encoding="utf-8") as out:
        if buf:
            out.write("\n".join(buf) + "\n")
        if rc_line:
            out.write(rc_line + "\n")
    print(f"wrote {out_path}")
else:
    print("no KUADRANT_SUMMARY/RC markers found in log", file=sys.stderr)
PY
}

snapshot_job_logs() {
  local dest="$1"
  # Full snapshot (not follow): recovers content after follow drops mid-stream.
  oc -n "${TEST_RUNNER_NAMESPACE}" logs "job/${JOB_NAME}" --timestamps=true 2>/dev/null \
    >"${dest}.tmp" || true
  if [[ -s "${dest}.tmp" ]]; then
    # Keep the larger of follow-captured vs full snapshot.
    if [[ ! -s "${dest}" ]] || [[ "$(wc -c <"${dest}.tmp")" -gt "$(wc -c <"${dest}")" ]]; then
      mv -f "${dest}.tmp" "${dest}"
    else
      rm -f "${dest}.tmp"
    fi
  else
    rm -f "${dest}.tmp"
  fi
}

dump_runner_diagnostics() {
  local pod="$1"
  echo "=== Test-runner diagnostics (pod=${pod:-none}) ==="
  oc -n "${TEST_RUNNER_NAMESPACE}" get pods -o wide 2>&1 \
    | tee "${ARTIFACT_DIR}/kuadrant-testrunner-pods.txt" || true
  oc -n "${TEST_RUNNER_NAMESPACE}" get job "${JOB_NAME}" -o yaml 2>&1 \
    | tee "${ARTIFACT_DIR}/kuadrant-testrunner-job.yaml" || true
  oc -n "${TEST_RUNNER_NAMESPACE}" describe job "${JOB_NAME}" 2>&1 \
    | tee "${ARTIFACT_DIR}/kuadrant-testrunner-job-describe.txt" || true
  if [[ -n "${pod}" ]]; then
    oc -n "${TEST_RUNNER_NAMESPACE}" get pod "${pod}" -o yaml 2>&1 \
      | tee "${ARTIFACT_DIR}/kuadrant-testrunner-pod.yaml" || true
    oc -n "${TEST_RUNNER_NAMESPACE}" describe pod "${pod}" 2>&1 \
      | tee "${ARTIFACT_DIR}/kuadrant-testrunner-pod-describe.txt" || true
    # Termination reason / exit code / OOM (best-effort).
    oc -n "${TEST_RUNNER_NAMESPACE}" get pod "${pod}" -o jsonpath='{range .status.containerStatuses[*]}{.name}{" ready="}{.ready}{" state="}{.state}{" lastState="}{.lastState}{"\n"}{end}' 2>&1 \
      | tee "${ARTIFACT_DIR}/kuadrant-testrunner-container-status.txt" || true
    oc -n "${TEST_RUNNER_NAMESPACE}" logs "${pod}" -c testsuite --timestamps=true --tail=-1 2>&1 \
      | tee "${ARTIFACT_DIR}/kuadrant-testrunner-pod-logs-final.txt" || true
    # Previous instance (if restarted); usually empty with backoffLimit=0.
    oc -n "${TEST_RUNNER_NAMESPACE}" logs "${pod}" -c testsuite --previous --timestamps=true --tail=-1 2>&1 \
      | tee "${ARTIFACT_DIR}/kuadrant-testrunner-pod-logs-previous.txt" || true
  fi
}

FAILED=0
JOB_LOG="${ARTIFACT_DIR}/kuadrant-testrunner-job.log"
: >"${JOB_LOG}"

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
  dump_runner_diagnostics ""
  FAILED=1
fi

if [[ -n "${RUNNER_POD}" ]]; then
  echo "=== Streaming logs from ${RUNNER_POD} (resilient follow) ==="
  # Wait until the container is running (image pull can take a while), then follow.
  oc -n "${TEST_RUNNER_NAMESPACE}" wait --for=condition=Ready \
    "pod/${RUNNER_POD}" --timeout=600s 2>/dev/null || true

  # Follow with restarts: a single `oc logs -f` often dies on long s390x runs
  # ("http2: client connection lost") and previously left us blind.
  follow_rounds=0
  while true; do
    if [[ "$(oc -n "${TEST_RUNNER_NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
      break
    fi
    if [[ "$(oc -n "${TEST_RUNNER_NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.failed}' 2>/dev/null)" =~ ^[1-9] ]]; then
      break
    fi
    phase="$(oc -n "${TEST_RUNNER_NAMESPACE}" get pod "${RUNNER_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]]; then
      break
    fi

    follow_rounds=$((follow_rounds + 1))
    echo "=== log follow round ${follow_rounds} (pod phase=${phase:-unknown}) ===" | tee -a "${JOB_LOG}"
    # Append follow output; ignore follow transport errors and continue.
    oc -n "${TEST_RUNNER_NAMESPACE}" logs -f "pod/${RUNNER_POD}" -c testsuite --timestamps=true 2>&1 \
      | tee -a "${JOB_LOG}" || true

    # Refresh full snapshot after each follow drop so we do not keep a tiny prefix.
    snapshot_job_logs "${JOB_LOG}"
    sleep 5
  done

  echo "=== Waiting for Job completion ==="
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

  # Final full log snapshot + diagnostics while the pod still exists.
  snapshot_job_logs "${JOB_LOG}"
  dump_runner_diagnostics "${RUNNER_POD}"

  # Prefer the largest available log source for JUnit/summary extraction.
  FINAL_LOG="${JOB_LOG}"
  if [[ -f "${ARTIFACT_DIR}/kuadrant-testrunner-pod-logs-final.txt" ]] \
    && [[ "$(wc -c <"${ARTIFACT_DIR}/kuadrant-testrunner-pod-logs-final.txt")" -gt "$(wc -c <"${JOB_LOG}")" ]]; then
    FINAL_LOG="${ARTIFACT_DIR}/kuadrant-testrunner-pod-logs-final.txt"
    cp -f "${FINAL_LOG}" "${JOB_LOG}" || true
  fi
  extract_junit_from_log "${FINAL_LOG}" "${RESULTS_DIR}" || true
  extract_summary_from_log "${FINAL_LOG}" "${ARTIFACT_DIR}" || true
fi

echo "=== Test-runner Job status ==="
oc -n "${TEST_RUNNER_NAMESPACE}" get pods -o wide 2>&1 || true

echo "=== Copying test artifacts to ${ARTIFACT_DIR} ==="
if ls "${RESULTS_DIR}"/junit-*.xml >/dev/null 2>&1; then
  cp "${RESULTS_DIR}"/junit-*.xml "${ARTIFACT_DIR}/" || true
fi
ls -la "${ARTIFACT_DIR}"/kuadrant-testrunner-* "${ARTIFACT_DIR}"/junit-*.xml 2>/dev/null || true

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Testsuite finished with failures." >&2
  if [[ -f "${ARTIFACT_DIR}/kuadrant-testrunner-summary.txt" ]]; then
    echo "=== Captured KUADRANT summary (for RCA) ===" >&2
    cat "${ARTIFACT_DIR}/kuadrant-testrunner-summary.txt" >&2 || true
  fi
  exit 1
fi

echo "=== Kuadrant testsuite run complete ==="
