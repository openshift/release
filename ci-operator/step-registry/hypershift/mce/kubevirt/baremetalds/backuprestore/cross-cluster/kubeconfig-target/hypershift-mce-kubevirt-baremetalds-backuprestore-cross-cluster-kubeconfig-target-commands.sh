#!/bin/bash

set -euo pipefail

role="$(<"${SHARED_DIR}/ofcir-role")"
[[ "${role}" == source || "${role}" == target ]] || { echo "Invalid OFCIR role" >&2; exit 1; }
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${role}"
if [[ "${role}" == source && ! -s "${KUBECONFIG}" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # The target MCE CLI download is exposed through the target virthost proxy.
  source "${SHARED_DIR}/proxy-conf.sh"
fi
cluster_name="$(<"${SHARED_DIR}/cluster-name")"
cluster_namespace="${E2E_HOSTED_CLUSTER_NAMESPACE:-local-cluster}"
hcp_cli=/usr/bin/hcp

oc wait --timeout=30m --for=condition=Available --namespace="${cluster_namespace}" \
  "hostedcluster/${cluster_name}"

if [[ -n "${MCE_VERSION:-}" && "$(arch)" == x86_64 ]]; then
  download_url="$(oc get ConsoleCLIDownload hcp-cli-download -o json |
    jq -r '.spec.links[] | select(.text == "Download hcp CLI for Linux for x86_64").href')"
  [[ -n "${download_url}" ]] || { echo "MCE hcp CLI download URL is missing" >&2; exit 1; }
  curl --insecure --fail --location --silent --show-error --output /tmp/hcp.tar.gz "${download_url}"
  tar -xzf /tmp/hcp.tar.gz -C /tmp hcp
  chmod +x /tmp/hcp
  hcp_cli=/tmp/hcp
fi
if [[ ! -x "${hcp_cli}" ]]; then
  hcp_cli=/usr/bin/hypershift
fi

"${hcp_cli}" create kubeconfig --namespace="${cluster_namespace}" --name="${cluster_name}" \
  > "${SHARED_DIR}/nested_kubeconfig"
cp "${SHARED_DIR}/nested_kubeconfig" "${SHARED_DIR}/nested_kubeconfig_${role}"
