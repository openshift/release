#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

TMP_DIR="$(mktemp -d /tmp/ovs-doca-osimage.XXXXXX)"
RHSM_CREDS_DIR="/var/run/rhsm-creds"

# Set to true only once an activation-key registration actually succeeds, so that the trap
# does not try to unregister a system that was never registered.
REGISTERED=false

cleanup() {
  if [[ "${REGISTERED}" == "true" ]]; then
    # Hand the entitlement back; CI pods are short-lived but subscriptions are not.
    subscription-manager unregister > /dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

PULL_SECRET="${TMP_DIR}/pull-secret"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${PULL_SECRET}"
oc registry login --to "${PULL_SECRET}"

echo "Resolving the CoreOS layering base from the release payload..."
BASE_IMAGE=""
for tag in ${OVS_DOCA_BASE_IMAGE_TAGS}; do
  if BASE_IMAGE="$(oc adm release info --registry-config "${PULL_SECRET}" "${RELEASE_IMAGE_LATEST}" --image-for="${tag}" 2>/dev/null)"; then
    echo "Using payload tag '${tag}'"
    break
  fi
  BASE_IMAGE=""
done
if [[ -z "${BASE_IMAGE}" ]]; then
  echo "ERROR: none of the tags '${OVS_DOCA_BASE_IMAGE_TAGS}' exist in the release payload."
  echo "Available CoreOS tags:"
  oc adm release info --registry-config "${PULL_SECRET}" "${RELEASE_IMAGE_LATEST}" -o json \
    | jq -r '.references.spec.tags[].name' | grep -i coreos || true
  exit 1
fi
echo "Base image: ${BASE_IMAGE}"

# Collect the entitlement material so it can be bind-mounted into the build. Bind mounts are
# not committed to image layers, so the certificates never leave this pod.
ENT_DIR="${TMP_DIR}/entitlement"
CA_DIR="${TMP_DIR}/rhsm-ca"
mkdir -p "${ENT_DIR}" "${CA_DIR}"
chmod 0700 "${ENT_DIR}"

# Two ways to obtain entitlement, in order of preference:
#
#   1. A pre-issued entitlement certificate pair mounted straight from the secret collection.
#      This needs no subscription-manager binary, no root in the step pod, and no registration
#      round-trip, so it is both faster and far less brittle. The trade-off is that entitlement
#      certificates expire and have to be rotated in GSM.
#   2. Registering with an activation key and harvesting the certificate that RHSM issues.
#      More self-maintaining, but it requires subscription-manager in the step image and write
#      access to /etc/pki/entitlement, and it leaves a registered system behind if the pod is
#      killed before the EXIT trap runs.
if compgen -G "${RHSM_CREDS_DIR}/entitlement*.pem" > /dev/null; then
  echo "Using the pre-issued entitlement certificate from ${RHSM_CREDS_DIR}"
  cp "${RHSM_CREDS_DIR}"/entitlement*.pem "${ENT_DIR}/"
  if [[ -f "${RHSM_CREDS_DIR}/redhat-uep.pem" ]]; then
    cp "${RHSM_CREDS_DIR}/redhat-uep.pem" "${CA_DIR}/"
  elif [[ -f /etc/rhsm/ca/redhat-uep.pem ]]; then
    cp /etc/rhsm/ca/redhat-uep.pem "${CA_DIR}/"
  else
    echo "ERROR: no redhat-uep.pem CA certificate available."
    echo "Add it to the ovs-doca/rhsm-activation-key secret alongside the entitlement certificate."
    exit 1
  fi
else
  if ! command -v subscription-manager > /dev/null; then
    echo "ERROR: no entitlement certificate was mounted at ${RHSM_CREDS_DIR}/entitlement*.pem"
    echo "and subscription-manager is not present in this image, so the activation key cannot"
    echo "be redeemed. Add entitlement.pem + entitlement-key.pem to the ovs-doca/rhsm-activation-key"
    echo "secret, or use a step image that ships subscription-manager."
    exit 1
  fi

  echo "Registering with Red Hat Subscription Management using the activation key..."
  # Disable tracing due to activation key handling
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  for attempt in 1 2 3; do
    if subscription-manager register \
        --org="$(cat "${RHSM_CREDS_DIR}/subscription-manager-org")" \
        --activationkey="$(cat "${RHSM_CREDS_DIR}/subscription-manager-act-key")" > /dev/null 2>&1; then
      REGISTERED=true
      break
    fi
    set +x
    echo "Registration attempt #${attempt} failed"
    subscription-manager unregister > /dev/null 2>&1 || true
    sleep 10
  done
  ${WAS_TRACING} && set -x

  if [[ "${REGISTERED}" != "true" ]]; then
    echo "ERROR: could not register with Red Hat Subscription Management after 3 attempts."
    echo "Re-run with the subscription-manager output enabled locally to diagnose; it is"
    echo "suppressed here because its command line carries the activation key."
    exit 1
  fi
  echo "Registered."

  cp /etc/pki/entitlement/*.pem "${ENT_DIR}/"
  cp /etc/rhsm/ca/redhat-uep.pem "${CA_DIR}/"
fi

ENT_CERT_PATH="$(find "${ENT_DIR}" -name '*.pem' ! -name '*-key.pem' | head -1)"
if [[ -z "${ENT_CERT_PATH}" ]]; then
  echo "ERROR: no entitlement certificate found after registration."
  exit 1
fi
ENT_CERT="$(basename "${ENT_CERT_PATH}")"
ENT_KEY="${ENT_CERT%.pem}-key.pem"
if [[ ! -f "${ENT_DIR}/${ENT_KEY}" ]]; then
  echo "ERROR: entitlement key ${ENT_KEY} not found alongside ${ENT_CERT}."
  exit 1
fi

# Build a repo file for the entitled content. RHCOS ships no redhat.repo, and the one
# subscription-manager generates here targets this pod's RHEL version rather than the
# RHEL 10 base we are layering onto, so the repos are written explicitly.
#
# The URL shape and the repository names below were taken from the redhat.repo that
# subscription-manager generates for an entitled RHEL 10 aarch64 system:
#
#   https://cdn.redhat.com/content/dist/rhel10/<releasever>/aarch64/<component>/os
#
# The DOCA packages live in the 'supplementary' component, not in a DOCA-specific
# channel and not in fast-datapath.
REPO_FILE="${TMP_DIR}/ovs-doca.repo"
: > "${REPO_FILE}"
for component in ${OVS_DOCA_REPO_COMPONENTS}; do
  cat >> "${REPO_FILE}" <<EOF
[ovs-doca-${component}]
name=Red Hat Enterprise Linux ${OVS_DOCA_RELEASEVER} aarch64 - ${component}
baseurl=https://${OVS_DOCA_CDN_HOST}/content/dist/rhel10/${OVS_DOCA_RELEASEVER}/aarch64/${component}/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
sslverify=1
sslcacert=/etc/rhsm/ca/redhat-uep.pem
sslclientcert=/etc/pki/entitlement/${ENT_CERT}
sslclientkey=/etc/pki/entitlement/${ENT_KEY}

EOF
done
echo "Repository configuration (credentials are supplied by certificate, not by URL):"
cat "${REPO_FILE}"

CONTAINERFILE="${TMP_DIR}/Containerfile"
cat > "${CONTAINERFILE}" <<EOF
FROM ${BASE_IMAGE}

LABEL maintainer="rh-ecosystem-edge" quay.expires-after=${OVS_DOCA_IMAGE_EXPIRATION}

COPY ovs-doca.repo /etc/yum.repos.d/ovs-doca.repo
EOF

if [[ -n "${OVS_DOCA_REMOVE_PACKAGES}" ]]; then
  # The stock openvswitch packages conflict with the DOCA-provided stack and must be removed
  # before the install transaction. '|| true' keeps the build working against a base image
  # that happens not to ship them.
  cat >> "${CONTAINERFILE}" <<EOF
RUN dnf -y remove ${OVS_DOCA_REMOVE_PACKAGES} || true
EOF
fi

cat >> "${CONTAINERFILE}" <<EOF
RUN dnf -y install ${OVS_DOCA_PACKAGES}
RUN rm -f /etc/yum.repos.d/ovs-doca.repo \\
 && dnf clean all \\
 && rm -rf /var/cache/dnf /var/cache/yum
RUN ostree container commit
EOF

echo "Containerfile:"
cat "${CONTAINERFILE}"

IMAGE_TAG="ovs-doca-${NAMESPACE}"
IMAGE_REF="${OVS_DOCA_IMAGE_REPO}:${IMAGE_TAG}"

echo "Building layered CoreOS image ${IMAGE_REF} ..."
podman build \
  --authfile "${PULL_SECRET}" \
  --volume "${ENT_DIR}:/etc/pki/entitlement:ro" \
  --volume "${CA_DIR}:/etc/rhsm/ca:ro" \
  --tag "${IMAGE_REF}" \
  --file "${CONTAINERFILE}" \
  "${TMP_DIR}"

# Disable tracing due to registry credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_AUTH="${TMP_DIR}/quay-auth.json"
printf '{"auths":{"quay.io":{"auth":"%s"}}}' "$(tr -d '\n' < /var/run/quay-push/auth)" > "${QUAY_AUTH}"
chmod 0600 "${QUAY_AUTH}"
${WAS_TRACING} && set -x

echo "Pushing ${IMAGE_REF} ..."
DIGEST_FILE="${TMP_DIR}/digest"
podman push --authfile "${QUAY_AUTH}" --digestfile "${DIGEST_FILE}" "${IMAGE_REF}"

IMAGE_WITH_DIGEST="${OVS_DOCA_IMAGE_REPO}@$(cat "${DIGEST_FILE}")"
echo "Layered image published: ${IMAGE_WITH_DIGEST}"

# Stage the pivot as an install manifest. ipi-install picks up ${SHARED_DIR}/manifest_*.yaml
# and feeds it to the installer, so nodes in the pool boot straight onto the layered image
# instead of being reconfigured once the cluster is already up.
MC_MANIFEST="${SHARED_DIR}/manifest_ovs-doca-${OVS_DOCA_MCP}-osimage.yaml"
cat > "${MC_MANIFEST}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 98-ovs-doca-${OVS_DOCA_MCP}-osimage
  labels:
    machineconfiguration.openshift.io/role: ${OVS_DOCA_MCP}
spec:
  osImageURL: "${IMAGE_WITH_DIGEST}"
EOF
echo "Wrote ${MC_MANIFEST}:"
cat "${MC_MANIFEST}"

echo "${IMAGE_WITH_DIGEST}" > "${SHARED_DIR}/ovs-doca-osimage-reference"
echo "${OVS_DOCA_MCP}" > "${SHARED_DIR}/ovs-doca-mcp"
echo "${OVS_DOCA_PACKAGES}" > "${SHARED_DIR}/ovs-doca-packages"
