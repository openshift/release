#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-network-operator ovn secondary encap pre ************"

namespace="openshift-ovn-kubernetes"
configmap_name="env-overrides"
mapping_file="${SHARED_DIR}/cno-secondary-encap-mapping.tsv"
artifacts_dir="${ARTIFACT_DIR:-${SHARED_DIR}}"
configmap_file="${artifacts_dir}/cno-secondary-encap-env-overrides.yaml"

if [[ "${EXTRANET_NETWORK_SUBNET_V4}" != */24 ]]; then
  echo "EXTRANET_NETWORK_SUBNET_V4 must use a /24 subnet, got ${EXTRANET_NETWORK_SUBNET_V4}" >&2
  exit 1
fi

secondary_prefix="${EXTRANET_NETWORK_SUBNET_V4%0/24}"
if [[ "${secondary_prefix}" == "${EXTRANET_NETWORK_SUBNET_V4}" ]]; then
  echo "EXTRANET_NETWORK_SUBNET_V4 must end with .0/24, got ${EXTRANET_NETWORK_SUBNET_V4}" >&2
  exit 1
fi

escaped_secondary_prefix=$(printf '%s' "${secondary_prefix}" | sed 's/\./\\./g')

# get_ovnkube_container returns the container name that provides the OVN
# tooling inside an ovnkube-node pod.
get_ovnkube_container() {
  local pod_name="$1"
  local containers

  containers=$(oc get pod -n "${namespace}" "${pod_name}" -o jsonpath='{.spec.containers[*].name}')
  for candidate in ovnkube-controller ovnkube-node; do
    if [[ " ${containers} " == *" ${candidate} "* ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  echo "unable to find a supported OVN container in pod ${pod_name}" >&2
  return 1
}

# get_secondary_interface_record returns the "<interface>\t<address/cidr>" pair
# for the extra-network address that matches the configured secondary subnet.
get_secondary_interface_record() {
  local pod_name="$1"
  local container_name="$2"

  oc exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- bash -c \
    "ip -o -4 addr show scope global | awk '\$4 ~ /^${escaped_secondary_prefix}/ {print \$2 \"\t\" \$4; exit}'"
}

oc wait pod -n "${namespace}" -l app=ovnkube-node --for=condition=Ready --timeout=10m

readarray -t ovnkube_pods < <(oc get pods -n "${namespace}" -l app=ovnkube-node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ ${#ovnkube_pods[@]} -eq 0 ]]; then
  echo "no ovnkube-node pods found in ${namespace}" >&2
  exit 1
fi

: > "${mapping_file}"

for pod_name in "${ovnkube_pods[@]}"; do
  node_name=$(oc get pod -n "${namespace}" "${pod_name}" -o jsonpath='{.spec.nodeName}')
  container_name=$(get_ovnkube_container "${pod_name}")
  secondary_record=$(get_secondary_interface_record "${pod_name}" "${container_name}")

  if [[ -z "${secondary_record}" ]]; then
    echo "unable to find a secondary interface in pod ${pod_name} for subnet ${EXTRANET_NETWORK_SUBNET_V4}" >&2
    exit 1
  fi

  secondary_iface=${secondary_record%%$'\t'*}
  secondary_cidr=${secondary_record#*$'\t'}
  secondary_ip=${secondary_cidr%%/*}

  echo "Discovered secondary encap source for ${node_name}: ${secondary_iface} ${secondary_ip}"
  printf '%s\t%s\t%s\t%s\n' "${node_name}" "${secondary_ip}" "${secondary_iface}" "${pod_name}" >> "${mapping_file}"
done

echo "Resolved per-node secondary interface mapping:"
while IFS=$'\t' read -r node_name secondary_ip secondary_iface pod_name; do
  echo "  node=${node_name} pod=${pod_name} interface=${secondary_iface} ip=${secondary_ip}"
done < "${mapping_file}"

{
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${configmap_name}
  namespace: ${namespace}
data:
EOF

  while IFS=$'\t' read -r node_name secondary_ip _secondary_iface _pod_name; do
    cat <<EOF
  ${node_name}: |
    OVN_ENCAP_IP=${secondary_ip}
EOF
  done < "${mapping_file}"
} > "${configmap_file}"

echo "Applying ${namespace}/${configmap_name}"
cat "${configmap_file}"
oc apply -f "${configmap_file}"
echo "Applied ${namespace}/${configmap_name}:"
oc get configmap -n "${namespace}" "${configmap_name}" -o yaml

echo "Restarting ovnkube-node to pick up the updated env-overrides ConfigMap"
oc rollout restart daemonset/ovnkube-node -n "${namespace}"
oc rollout status daemonset/ovnkube-node -n "${namespace}" --timeout=15m
oc wait pod -n "${namespace}" -l app=ovnkube-node --for=condition=Ready --timeout=10m

echo "Mounted env-overrides content observed from ovnkube-node pods:"
while IFS=$'\t' read -r node_name _secondary_ip _secondary_iface _pod_name; do
  pod_name=$(oc get pods -n "${namespace}" -l app=ovnkube-node --field-selector "spec.nodeName=${node_name}" -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "${pod_name}" ]]; then
    echo "  node=${node_name} pod=<missing> override_file=<unavailable>"
    continue
  fi

  container_name=$(get_ovnkube_container "${pod_name}")
  echo "----- ${node_name} (${pod_name}) /env/${node_name} -----"
  oc exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- bash -c \
    "if [[ -f \"/env/${node_name}\" ]]; then cat \"/env/${node_name}\"; else echo \"override file missing\"; fi"
done < "${mapping_file}"
