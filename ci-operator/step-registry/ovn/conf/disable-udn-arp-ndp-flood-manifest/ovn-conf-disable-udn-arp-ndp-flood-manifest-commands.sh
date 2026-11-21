#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Write the install-time manifest that enables ARP/NDP flood suppression for
# user-defined networks. No cluster, kubeconfig or SSH access is used. The
# step is a no-op unless DISABLE_UDN_ARP_NDP_FLOOD is set to "true" by the
# job, so it can sit in a shared workflow without affecting other lanes.

die() { echo "ERROR: $*" >&2; exit 1; }

# Only "" (feature not requested on this lane) and "true" are accepted; any
# other value is a misconfiguration and fails rather than being interpreted.
case "${DISABLE_UDN_ARP_NDP_FLOOD:-}" in
  "") exit 0 ;;
  "true") ;;
  *) die "DISABLE_UDN_ARP_NDP_FLOOD must be \"true\" or unset, got '${DISABLE_UDN_ARP_NDP_FLOOD}'" ;;
esac

readonly CONFIGMAP_NAME=ovn-kubernetes-config-overrides
readonly MANIFEST_NAME=manifest_ovn-kubernetes-noflood-config-overrides.yaml

if [[ -z "${SHARED_DIR:-}" ]]; then
  die "SHARED_DIR is not set"
fi
if [[ ! -d "${SHARED_DIR}" || ! -w "${SHARED_DIR}" ]]; then
  die "SHARED_DIR ${SHARED_DIR} is not a writable directory"
fi

readonly TARGET="${SHARED_DIR}/${MANIFEST_NAME}"

desired_manifest() {
  cat <<MANIFEST
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: openshift-network-operator
data:
  disable-udn-arp-ndp-flood: "true"
MANIFEST
}

# Bootstrap creates each object once and skips existing ones, so a second
# producer of this ConfigMap would silently win or lose; refuse it instead.
# Detection is by a "name: <ConfigMap name>" line in any other manifest_* file
# (an optional trailing comment is tolerated); it fails closed, also for a
# same-named object of another kind or namespace.
# An unmatched glob expands to the literal pattern, so the -e test also
# filters out the "no other manifest" case.
for other in "${SHARED_DIR}"/manifest_*.yaml "${SHARED_DIR}"/manifest_*.yml; do
  [[ -e "${other}" && "${other}" != "${TARGET}" ]] || continue
  if grep -qE "^[[:space:]]*name:[[:space:]]*[\"']?${CONFIGMAP_NAME}[\"']?[[:space:]]*(#.*)?$" "${other}"; then
    die "$(basename "${other}") already declares ${CONFIGMAP_NAME}; consolidate its keys into one producer"
  fi
done

if [[ -e "${TARGET}" || -L "${TARGET}" ]]; then
  if [[ -f "${TARGET}" && ! -L "${TARGET}" ]] && cmp -s <(desired_manifest) "${TARGET}"; then
    echo "${MANIFEST_NAME} already present with the desired content"
  else
    die "${MANIFEST_NAME} already exists with different content; refusing to replace it"
  fi
else
  # Write through a hidden temporary file in the same directory and rename,
  # so a partial manifest is never visible to the collector.
  tmp=$(mktemp "${SHARED_DIR}/.${MANIFEST_NAME}.XXXXXX")
  desired_manifest > "${tmp}"
  mv "${tmp}" "${TARGET}"
  echo "wrote ${MANIFEST_NAME}"
fi

# The manifest holds no credentials; keep a copy for diagnostics.
if [[ -n "${ARTIFACT_DIR:-}" && -d "${ARTIFACT_DIR}" ]]; then
  cp "${TARGET}" "${ARTIFACT_DIR}/${MANIFEST_NAME}"
fi
