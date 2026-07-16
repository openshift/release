#!/bin/bash

set -euo pipefail

# Deploy kuadrant-coredns matching the known-good ocpz-m42lp36 / rhcl-mc1 LPAR
# stacks: CoreDNS with the Kuadrant plugin, zone k.example.com, LoadBalancer
# pinned to .241 from the existing MetalLB default-pool (install-metallb).
# .240 is left for Istio Gateway LBs (verify-gateway / smoke). Do not create a
# second IPAddressPool — MetalLB rejects overlapping CIDRs.

derive_subnet_octet() {
  local subnet cidr
  if [[ -n "${LEASED_RESOURCE:-}" && -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
    if command -v yq-v4 >/dev/null 2>&1; then
      subnet="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".subnet" "${CLUSTER_PROFILE_DIR}/leases" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
      subnet="$(python3 - "${CLUSTER_PROFILE_DIR}/leases" "${LEASED_RESOURCE}" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
lease = sys.argv[2]
m = re.search(rf'(?m)^{re.escape(lease)}:\s*\n((?:[ \t].*\n)*)', text)
if not m:
    sys.exit(1)
sm = re.search(r'(?m)^[ \t]+subnet:\s*["\']?(\d+)', m.group(1))
if not sm:
    sys.exit(1)
print(sm.group(1))
PY
)" || true
    fi
    if [[ -n "${subnet:-}" && "${subnet}" != "null" ]]; then
      echo "${subnet}"
      return 0
    fi
  fi
  if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
    cidr="$(awk '/machineNetwork:/{f=1} f && /cidr:/{print; exit}' "${SHARED_DIR}/install-config.yaml" \
      | sed -E 's/.*"?(192\.168\.[0-9]+\.0\/[0-9]+)"?.*/\1/')"
    if [[ -n "${cidr}" ]]; then
      echo "${cidr}" | sed -E 's/192\.168\.([0-9]+)\.0\/24/\1/'
      return 0
    fi
  fi
  return 1
}

echo "=== Resolving CoreDNS LoadBalancer IP ==="
COREDNS_LB_IP="${COREDNS_LOADBALANCER_IP:-}"
if [[ -z "${COREDNS_LB_IP}" ]]; then
  octet="$(derive_subnet_octet || true)"
  if [[ -n "${octet}" ]]; then
    COREDNS_LB_IP="192.168.${octet}.${COREDNS_LB_HOST}"
  fi
fi
if [[ -z "${COREDNS_LB_IP}" ]]; then
  echo "ERROR: could not derive CoreDNS LB IP. Set COREDNS_LOADBALANCER_IP explicitly." >&2
  exit 1
fi
echo "CoreDNS LoadBalancer IP: ${COREDNS_LB_IP} (from existing pool ${METALLB_POOL_NAME})"

if ! oc get ipaddresspool "${METALLB_POOL_NAME}" -n "${METALLB_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: MetalLB IPAddressPool ${METALLB_POOL_NAME} not found in ${METALLB_NAMESPACE}; run install-metallb first." >&2
  oc get ipaddresspool -n "${METALLB_NAMESPACE}" -o wide >&2 || true
  exit 1
fi

echo "=== Deploying kuadrant-coredns (zone ${COREDNS_ZONE}) ==="
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${COREDNS_NAMESPACE}
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kuadrant-coredns
  namespace: ${COREDNS_NAMESPACE}
  labels:
    app.kubernetes.io/instance: kuadrant
    app.kubernetes.io/managed-by: static-manifest
    app.kubernetes.io/name: coredns
data:
  Corefile: |
    ${COREDNS_ZONE} {
        debug
        errors
        log
        health {
            lameduck 5s
        }
        ready
        geoip GeoLite2-City-demo.mmdb {
            edns-subnet
        }
        metadata
        transfer {
            to *
        }
        kuadrant
        prometheus 0.0.0.0:9153
    }
    . {
        forward . /etc/resolv.conf
        log
        errors
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuadrant-coredns
  namespace: ${COREDNS_NAMESPACE}
  labels:
    app.kubernetes.io/instance: kuadrant
    app.kubernetes.io/name: coredns
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: kuadrant
      app.kubernetes.io/name: coredns
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: kuadrant
        app.kubernetes.io/name: coredns
    spec:
      containers:
      - name: coredns
        image: ${COREDNS_IMAGE}
        imagePullPolicy: IfNotPresent
        args:
        - -conf
        - /etc/coredns/Corefile
        env:
        - name: WATCH_NAMESPACES
          value: ""
        ports:
        - containerPort: 53
          name: udp-53
          protocol: UDP
        - containerPort: 53
          name: tcp-53
          protocol: TCP
        - containerPort: 9153
          name: tcp-9153
          protocol: TCP
        livenessProbe:
          failureThreshold: 5
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          failureThreshold: 1
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 5
          timeoutSeconds: 5
        resources:
          limits:
            cpu: 100m
            memory: 128Mi
          requests:
            cpu: 100m
            memory: 128Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - ALL
          readOnlyRootFilesystem: true
        volumeMounts:
        - mountPath: /etc/coredns
          name: config-volume
      terminationGracePeriodSeconds: 30
      volumes:
      - name: config-volume
        configMap:
          name: kuadrant-coredns
          items:
          - key: Corefile
            path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kuadrant-coredns
  namespace: ${COREDNS_NAMESPACE}
  labels:
    app.kubernetes.io/instance: kuadrant
    app.kubernetes.io/name: coredns
  annotations:
    metallb.io/loadBalancerIPs: ${COREDNS_LB_IP}
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/instance: kuadrant
    app.kubernetes.io/name: coredns
  ports:
  - name: udp-53
    port: 53
    protocol: UDP
    targetPort: udp-53
  - name: tcp-53
    port: 53
    protocol: TCP
    targetPort: tcp-53
EOF

oc rollout status deployment/kuadrant-coredns -n "${COREDNS_NAMESPACE}" --timeout=300s

echo "=== Waiting for kuadrant-coredns LoadBalancer (${COREDNS_LB_IP}) ==="
assigned=""
for _ in $(seq 1 60); do
  assigned="$(oc get svc kuadrant-coredns -n "${COREDNS_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  echo "  external IP: ${assigned:-<pending>}"
  [[ "${assigned}" == "${COREDNS_LB_IP}" ]] && break
  sleep 10
done
if [[ "${assigned}" != "${COREDNS_LB_IP}" ]]; then
  echo "ERROR: kuadrant-coredns LB IP is ${assigned:-<unset>} (wanted ${COREDNS_LB_IP})" >&2
  oc get svc kuadrant-coredns -n "${COREDNS_NAMESPACE}" -o yaml >&2 || true
  oc get ipaddresspool,l2advertisement -n "${METALLB_NAMESPACE}" -o wide >&2 || true
  oc get events -n "${COREDNS_NAMESPACE}" --sort-by='.lastTimestamp' >&2 | tail -40 || true
  oc logs -n "${METALLB_NAMESPACE}" -l app=metallb --tail=80 >&2 || true
  exit 1
fi

echo "${COREDNS_LB_IP}" >"${SHARED_DIR}/kuadrant-coredns-ip"
echo "${COREDNS_ZONE}" >"${SHARED_DIR}/kuadrant-coredns-zone"
echo "${COREDNS_NAMESPACE}" >"${SHARED_DIR}/kuadrant-coredns-namespace"
echo "Wrote ${SHARED_DIR}/kuadrant-coredns-ip=${COREDNS_LB_IP} zone=${COREDNS_ZONE} ns=${COREDNS_NAMESPACE}"

echo "=== kuadrant-coredns install complete ==="
oc get deploy,svc,pods -n "${COREDNS_NAMESPACE}" -o wide
