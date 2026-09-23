#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

NAMESPACE="${WAIT_NAMESPACE:-oran-o2ims}"

echo "Waiting for Inventory CR to be auto-created..."
for i in $(seq 1 60); do
  if oc get inventory default -n "$NAMESPACE" &>/dev/null; then
    echo "Inventory CR 'default' found."
    break
  fi
  echo "  attempt $i/60..."
  sleep 5
done

if ! oc get inventory default -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Inventory CR 'default' was not created after 5 minutes"
  exit 1
fi

echo ""
echo "Discovering services with TLS serving certs..."
TLS_SERVICES=$(oc get services -n "$NAMESPACE" \
  -o jsonpath='{range .items[?(@.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name)]}{.metadata.name}{"\n"}{end}')

echo "TLS services found:"
while read -r svc; do
  [ -z "$svc" ] && continue
  SECRET=$(oc get service "$svc" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}')
  echo "  $svc -> secret: $SECRET"
done <<< "$TLS_SERVICES"

echo ""
echo "Waiting for TLS service pods to be ready..."
FAILED=false
while read -r svc; do
  [ -z "$svc" ] && continue
  SELECTOR=$(oc get service "$svc" -n "$NAMESPACE" \
    -o go-template='{{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
  if [ -z "$SELECTOR" ]; then
    echo "  SKIP: $svc has no selector"
    continue
  fi
  echo "  $svc (selector: $SELECTOR)..."
  if ! oc wait pods -l "$SELECTOR" -n "$NAMESPACE" \
    --for=condition=Ready --timeout=5m; then
    echo "  ERROR: pods for $svc did not become ready within 5m"
    echo "  Pod status:"
    oc get pods -l "$SELECTOR" -n "$NAMESPACE" --no-headers | sed 's/^/    /'
    echo "  Recent events:"
    oc get events -n "$NAMESPACE" --field-selector reason!=Pulling,reason!=Pulled \
      --sort-by='.lastTimestamp' 2>/dev/null | grep "$svc" | tail -5 | sed 's/^/    /' \
      || echo "    (no events found)"
    FAILED=true
  fi
done <<< "$TLS_SERVICES"

if [ "$FAILED" = true ]; then
  echo "ERROR: one or more TLS service pods failed readiness checks"
  exit 1
fi

echo ""
echo "Verifying TLS secrets from service-ca..."
while read -r svc; do
  [ -z "$svc" ] && continue
  SECRET=$(oc get service "$svc" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}')
  if oc get secret "$SECRET" -n "$NAMESPACE" &>/dev/null; then
    echo "  $SECRET exists"
  else
    echo "  ERROR: $SECRET not found"
    FAILED=true
  fi
done <<< "$TLS_SERVICES"

if [ "$FAILED" = true ]; then
  echo "ERROR: one or more TLS secrets are missing"
  exit 1
fi

echo ""
echo "Final pod status in $NAMESPACE:"
oc get pods -n "$NAMESPACE"
