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
if [[ ! "${QUAY_OPERATOR_CHANNEL}" =~ ^[a-zA-Z0-9._-]+$ ]] ||
   [[ ! "${QUAY_OPERATOR_SOURCE}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Invalid Quay catalog configuration" >&2
  exit 1
fi

cat <<EOF | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: ${operator_namespace}
spec:
  channel: ${QUAY_OPERATOR_CHANNEL}
  config:
    env:
    - name: ROLEARN
      value: ${role_arn}
  installPlanApproval: Automatic
  name: quay-operator
  source: ${QUAY_OPERATOR_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

installed_csv=""
for attempt in $(seq 1 90); do
  installed_csv=$(oc get subscription quay-operator -n "${operator_namespace}" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [[ -n "${installed_csv}" ]]; then
    phase=$(oc get csv "${installed_csv}" -n "${operator_namespace}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "Succeeded" ]]; then
      break
    fi
  fi
  if [[ ${attempt} -eq 90 ]]; then
    echo "Timed out waiting for the ART Quay Operator CSV" >&2
    oc get subscription,csv,installplan -n "${operator_namespace}" -o wide >&2 || true
    exit 1
  fi
  sleep 10
done

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
    oc get deployment -n "${operator_namespace}" -o wide >&2 || true
    exit 1
  fi
  sleep 10
done

oc rollout status "deployment/${QUAY_STS_OPERATOR_DEPLOYMENT}" \
  -n "${operator_namespace}" --timeout=10m
printf 'Installed ART Quay Operator CSV %s from channel %s\n' \
  "${installed_csv}" "${QUAY_OPERATOR_CHANNEL}"
