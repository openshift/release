#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

operator_namespace="${QUAY_STS_OPERATOR_NAMESPACE}"
role_arn=$(cat "${SHARED_DIR}/STS_ROLE_ARN")
if [[ ! "${role_arn}" =~ ^arn:[^:]+:iam::[0-9]{12}:role/quay-sts-[a-f0-9]{16}$ ]]; then
  echo "Invalid STS_ROLE_ARN" >&2
  exit 1
fi

operator-sdk run bundle "${OO_BUNDLE}" \
  -n "${operator_namespace}" \
  --install-mode=AllNamespaces \
  --security-context-config=restricted \
  --timeout=10m

mapfile -t subscriptions < <(oc get subscriptions.operators.coreos.com \
  -n "${operator_namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ ${#subscriptions[@]} -ne 1 ]]; then
  echo "Expected exactly one test operator Subscription" >&2
  exit 1
fi

patch=$(printf '{"spec":{"config":{"env":[{"name":"ROLEARN","value":"%s"}]}}}' "${role_arn}")
oc patch subscription "${subscriptions[0]}" -n "${operator_namespace}" \
  --type=merge -p "${patch}" >/dev/null

for attempt in $(seq 1 60); do
  mapfile -t configured_roles < <(oc get deployment "${QUAY_STS_OPERATOR_DEPLOYMENT}" \
    -n "${operator_namespace}" \
    -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="ROLEARN")]}{.value}{"\n"}{end}' \
    2>/dev/null || true)
  if [[ ${#configured_roles[@]} -eq 1 && "${configured_roles[0]}" == "${role_arn}" ]]; then
    break
  fi
  if [[ ${attempt} -eq 60 ]]; then
    echo "Timed out waiting for the operator ROLEARN configuration" >&2
    exit 1
  fi
  sleep 10
done

oc rollout status "deployment/${QUAY_STS_OPERATOR_DEPLOYMENT}" \
  -n "${operator_namespace}" --timeout=10m
printf '%s\n' 'Installed the PR-built Quay Operator on the ephemeral cluster'
