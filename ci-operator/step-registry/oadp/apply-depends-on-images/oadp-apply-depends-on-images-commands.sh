#!/bin/bash

# Applies whatever oadp-depends-on-build resolved to the operator already
# installed in this test cluster (OLMv0 Subscription.spec.config.env today).
# See oadp-depends-on-build-commands.sh for the full order-of-operations
# writeup (only the triggering PR needs Depends-On:, one-directional by
# default, live re-fetch on every run/retest).
#
# OLM VERSION SEAM: this step is deliberately the ONLY place that knows how
# to make a resolved image "take effect" -- oadp-depends-on-build itself
# only builds images and writes a plain repo-agnostic manifest, with no
# OLM-API knowledge at all. When operator-controller's ClusterExtension
# (OLMv1) eventually replaces the Subscription-based install this
# ecosystem uses today, only this step needs a new code path (see the
# OLM_API_VERSION=v1 branch below, not yet implemented) -- the resolver
# does not change.

set -o errexit
set -o nounset
set -o pipefail

if [[ ! -s "${SHARED_DIR}/depends-on-images.txt" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] No ${SHARED_DIR}/depends-on-images.txt (or empty) -- nothing to apply"
    exit 0
fi

case "${OLM_API_VERSION}" in
    v0)
        ;;
    v1)
        echo "OLM_API_VERSION=v1 (operator-controller ClusterExtension) is not implemented yet -- see openshift/oadp-operator#2389. Refusing to silently skip a requested override rather than pretend it applied." >&2
        exit 1
        ;;
    *)
        echo "Unknown OLM_API_VERSION '${OLM_API_VERSION}' -- expected 'v0' (implemented) or 'v1' (reserved, not yet implemented)" >&2
        exit 1
        ;;
esac

SUBS=$(oc get subscription -n "${OO_INSTALL_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}')
if [[ -z "${SUBS}" ]]; then
    echo "No Subscription found in namespace ${OO_INSTALL_NAMESPACE}" >&2
    exit 1
fi
if [[ "$(echo "${SUBS}" | wc -w)" -gt 1 ]]; then
    echo "Multiple Subscriptions found in ${OO_INSTALL_NAMESPACE}: ${SUBS}" >&2
    exit 1
fi
SUB="${SUBS}"
echo "Discovered Subscription: ${SUB}"

ALL_ENV_LINES=$(cat "${SHARED_DIR}/depends-on-images.txt")

# Subscription.spec.config.env is OLM's supported override mechanism: it
# wins over same-named CSV env vars and survives reconciliation. Built with
# printf, not jq -- the cli image doesn't ship it, and the patch shape is
# fixed/simple enough not to need it.
# NOTE: --type merge below REPLACES the whole spec.config.env array rather
# than merging by key -- same known limitation as the KDM set-related-image
# steps this mirrors. Safe only while the Subscription in this namespace has
# no pre-existing config.env entries this would clobber.
ENTRIES=()
while read -r ENV_NAME ENV_VALUE; do
    [[ -z "${ENV_NAME}" ]] && continue
    ENTRIES+=("{\"name\":\"${ENV_NAME}\",\"value\":\"${ENV_VALUE}\"}")
done <<< "${ALL_ENV_LINES}"
JOINED=$(IFS=,; echo "${ENTRIES[*]}")
PATCH=$(printf '{"spec":{"config":{"env":[%s]}}}' "${JOINED}")
oc patch subscription "${SUB}" -n "${OO_INSTALL_NAMESPACE}" --type merge -p "${PATCH}"

echo "Waiting for Deployment ${OO_MANAGER_DEPLOYMENT} to observe:"
echo "${ALL_ENV_LINES}"
for _ in $(seq 1 60); do
    ALL_OK=true
    while read -r ENV_NAME ENV_VALUE; do
        [[ -z "${ENV_NAME}" ]] && continue
        CURRENT=$(oc get deployment/"${OO_MANAGER_DEPLOYMENT}" -n "${OO_INSTALL_NAMESPACE}" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"manager\")].env[?(@.name==\"${ENV_NAME}\")].value}" 2>/dev/null || true)
        [[ "${CURRENT}" != "${ENV_VALUE}" ]] && ALL_OK=false
    done <<< "${ALL_ENV_LINES}"
    [[ "${ALL_OK}" == "true" ]] && break
    sleep 5
done
if [[ "${ALL_OK}" != "true" ]]; then
    echo "Timed out waiting for Deployment spec to reflect the Subscription.spec.config.env override" >&2
    oc get subscription "${SUB}" -n "${OO_INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/subscription-${SUB}.yaml" || true
    oc get csv -n "${OO_INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/csvs.yaml" || true
    oc get deployment -n "${OO_INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/deployments.yaml" || true
    exit 1
fi
oc rollout status deployment/"${OO_MANAGER_DEPLOYMENT}" -n "${OO_INSTALL_NAMESPACE}" --timeout=180s
