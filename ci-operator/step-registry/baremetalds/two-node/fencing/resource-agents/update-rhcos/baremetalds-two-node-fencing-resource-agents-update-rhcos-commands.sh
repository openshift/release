#!/bin/bash

set -euo pipefail

RESOURCE_AGENT_SOURCE="${RESOURCE_AGENT_SOURCE:-RHCOS}"
RESOURCE_AGENTS_REPO="${RESOURCE_AGENTS_REPO:-https://github.com/ClusterLabs/resource-agents}"
RESOURCE_AGENTS_REF="${RESOURCE_AGENTS_REF:-main}"

# Retry wrapper for oc debug commands. Debug containers on baremetal nodes
# are notoriously slow to start (image pull + scheduling). Retries with a
# generous timeout avoid transient failures.
oc_debug_with_retry() {
 local node="$1" ; shift
 local retries=5
 local timeout="90s"
 # ci-operator sets the kubeconfig context namespace to its ephemeral build
 # namespace (ci-op-*). That namespace only exists on the build cluster, not
 # on the test cluster. oc debug validates the context namespace before
 # honouring --namespace, so reset it to avoid "namespace not found" errors.
 oc config set-context --current --namespace=default 2>/dev/null || true
 for attempt in $(seq 1 "${retries}"); do
  echo "oc debug attempt ${attempt}/${retries} on node/${node} (timeout ${timeout})..."
  if [[ "${attempt}" -eq "${retries}" ]]; then
   # Show stderr on the last attempt for diagnostics
   if oc debug --namespace=default --request-timeout="${timeout}" "node/${node}" -- "$@"; then
    return 0
   fi
  else
   if oc debug --namespace=default --request-timeout="${timeout}" "node/${node}" -- "$@" 2>/dev/null; then
    return 0
   fi
  fi
  echo "Attempt ${attempt} failed."
  if [[ "${attempt}" -lt "${retries}" ]]; then
   sleep 5
  fi
 done
 return 1
}

if [[ "${RESOURCE_AGENT_SOURCE}" == "RHCOS" ]]; then
 # Report installed resource-agents version on first healthy schedulable node. Must not fail.
 NODE=$(oc get nodes --no-headers | awk 'tolower($2) == "ready" {print $1; exit}')
 if [[ -z "${NODE}" ]]; then
  echo "No ready node found; skipping version report."
  exit 0
 fi
 if ! oc_debug_with_retry "${NODE}" chroot /host rpm -q resource-agents; then
  echo "Could not get resource-agents version after retries; skipping."
 fi
 exit 0
fi

if [[ "${RESOURCE_AGENT_SOURCE}" != "REPO" ]]; then
 echo "RESOURCE_AGENT_SOURCE must be RHCOS or REPO, got: ${RESOURCE_AGENT_SOURCE}"
 exit 1
fi

# REPO path: build resource-agents RPM from source, create custom RHCOS image via
# multi-stage Dockerfile, push to mirror registry, apply MachineConfig, wait for rollout.
# Must run after cluster deployment. Release image and version from clusterversion.
RELEASE_IMAGE=$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || true)
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [[ -z "${RELEASE_IMAGE}" ]] || [[ -z "${OCP_VERSION}" ]]; then
 echo "Could not get release image or version from cluster (clusterversion version)."
 exit 1
fi

# Disable tracing due to credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

PULL_SECRET="${PULL_SECRET:-}"
if [[ -z "${PULL_SECRET}" ]] && [[ -n "${CLUSTER_PROFILE_DIR:-}" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
 PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"
fi
if [[ -z "${PULL_SECRET}" ]] || [[ ! -f "${PULL_SECRET}" ]]; then
 echo "Pull secret file required (set PULL_SECRET or use CLUSTER_PROFILE_DIR/pull-secret)."
 exit 1
fi
OCP_MAJOR=$(echo "${OCP_VERSION}" | cut -d. -f1)
OCP_MINOR=$(echo "${OCP_VERSION}" | cut -d. -f2)
if [[ -z "${OCP_MAJOR}" ]] || ! [[ "${OCP_MAJOR}" =~ ^[0-9]+$ ]]; then
 OCP_MAJOR=4
fi
if [[ -z "${OCP_MINOR}" ]] || ! [[ "${OCP_MINOR}" =~ ^[0-9]+$ ]]; then
 OCP_MINOR=0
fi
if [[ "${OCP_MAJOR}" -ge 5 ]] || [[ "${OCP_MINOR}" -gt 22 ]]; then
 STREAM=10
else
 STREAM=9
fi

if [[ -z "${CUSTOM_OS_MIRROR_REGISTRY:-}" ]] || [[ -z "${CUSTOM_OS_IMAGE_REPO:-}" ]]; then
 echo "CUSTOM_OS_MIRROR_REGISTRY and CUSTOM_OS_IMAGE_REPO must be set for REPO source."
 exit 1
fi

# Use profile Quay push secret for podman push if present (equinix-edge-enablement: quay-custom-rhcos-secret).
PUSH_AUTHFILE="${PULL_SECRET}"
if [[ -n "${CLUSTER_PROFILE_DIR:-}" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/quay-custom-rhcos-secret" ]]; then
 PUSH_AUTHFILE="${CLUSTER_PROFILE_DIR}/quay-custom-rhcos-secret"
fi

$WAS_TRACING && set -x

# Base images from payload
OCP_BASE_OS="${OCP_BASE_OS:-rhel-coreos}"
if [[ "${STREAM}" -eq 10 ]]; then
 OCP_BASE_OS="rhel-coreos-10"
fi
OS_REF=$(oc adm release info "${RELEASE_IMAGE}" --registry-config "${PULL_SECRET}" --image-for="${OCP_BASE_OS}")
EXTENSIONS_REF=$(oc adm release info "${RELEASE_IMAGE}" --registry-config "${PULL_SECRET}" --image-for="${OCP_BASE_OS}-extensions")

# Build custom RHCOS image using a multi-stage Dockerfile.
# Stage 1 (builder): CentOS Stream matching the RHCOS stream; installs build deps,
#   builds resource-agents RPM from source, downloads the libqb runtime RPM.
#   On Stream 10 libqb-devel may be missing; the builder falls back to compiling
#   libqb from source and installing a stub RPM to satisfy rpmbuild BuildRequires.
# Stage 2: RHCOS base from the payload; overlays the built RPMs with rpm-ostree.
DOCKERFILE_DIR="/tmp/custom-rhcos-build"
rm -rf "${DOCKERFILE_DIR}"
mkdir -p "${DOCKERFILE_DIR}"

BUILDER_IMAGE="quay.io/centos/centos:stream${STREAM}"

cat > "${DOCKERFILE_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
ARG BUILDER_IMAGE
ARG OS_REF

FROM ${BUILDER_IMAGE} AS builder
ARG RESOURCE_AGENTS_REPO
ARG RESOURCE_AGENTS_REF
ARG STREAM

# Enable CRB and EPEL so libqb/libqb-devel resolve to the correct version.
RUN dnf config-manager --set-enabled crb 2>/dev/null || true && \
    ( dnf install -y epel-release 2>/dev/null || \
      dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${STREAM}.noarch.rpm" 2>/dev/null || true )

# Install build dependencies. On Stream 10, libqb-devel may be absent; build it from
# source and create a stub RPM so rpmbuild BuildRequires is satisfied.
RUN set -euo pipefail && \
    DEPS="git autoconf automake docbook-style-xsl glib2-devel make rpm-build perl python3-devel libnet-devel python3-pyroute2 libxslt systemd which" && \
    if dnf install -y ${DEPS} libqb-devel 2>/dev/null; then \
      echo "All build deps installed from repos."; \
    else \
      echo "libqb-devel not in repos (Stream 10); building from source." && \
      dnf install -y ${DEPS} libqb libtool libxml2-devel check 2>/dev/null || true && \
      git clone --depth 1 https://github.com/ClusterLabs/libqb /tmp/libqb-build && \
      cd /tmp/libqb-build && autoreconf -fi && ./configure --prefix=/usr && make -j"$(nproc)" && make install && \
      mkdir -p /tmp/libqb-stub && \
      printf '%s\n' \
        'Name: libqb-devel' 'Version: 0' 'Release: 1' \
        'Summary: Stub to satisfy BuildRequires when libqb built from source' \
        'License: LGPL-2.1' '%description' 'Stub.' \
        '%files' '%ghost /usr/lib64/libqb.so' \
        > /tmp/libqb-stub/libqb-devel.spec && \
      ( rpmbuild -bb --define "_sourcedir /tmp/libqb-stub" --define "_rpmdir /tmp" \
        /tmp/libqb-stub/libqb-devel.spec 2>/dev/null && \
        rpm -i "$(find /tmp -name 'libqb-devel-0-1.*.rpm' | head -1)" 2>/dev/null ) || true && \
      rm -rf /tmp/libqb-build /tmp/libqb-stub && \
      dnf install -y ${DEPS} 2>/dev/null || true; \
    fi

# Clone and build resource-agents RPM.
# On Stream 10, the ldirectord sub-package has an init script path mismatch
# (/etc/init.d vs /etc/rc.d) causing rpmbuild to fail with "unpackaged files".
# We suppress that error globally but then verify the resource-agents RPM
# contains the OCF heartbeat agents the cluster actually needs.
RUN set -euo pipefail && \
    echo "%_unpackaged_files_terminate_build 0" > /etc/rpm/macros.ra-build && \
    git clone --depth 1 "${RESOURCE_AGENTS_REPO}" /tmp/ra-build && \
    cd /tmp/ra-build && \
    git fetch origin "${RESOURCE_AGENTS_REF}" && \
    git checkout FETCH_HEAD && \
    RPM_VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo "0") && \
    autoreconf --install --force && \
    ./configure && \
    make rpm VERSION="${RPM_VERSION}" && \
    mkdir -p /output && \
    find . -name 'resource-agents-*.rpm' ! -name '*debug*' ! -name '*.src.rpm' \
      -exec cp {} /output/ \;
# Verify the resource-agents RPM contains the OCF heartbeat agents the cluster needs.
RUN RPM_FILE=$(ls /output/resource-agents-*.rpm | head -1) && \
    echo "Verifying resource-agents RPM contents..." && \
    rpm -qlp "${RPM_FILE}" | grep -c 'ocf/resource.d/heartbeat' && \
    echo "RPM verified: $(basename ${RPM_FILE})"

# Download libqb runtime RPM for the RHCOS overlay.
RUN dnf download -y --arch x86_64 --destdir /output libqb 2>/dev/null && \
    ls /output/libqb-*.rpm >/dev/null 2>&1 || \
    { echo "ERROR: Could not download libqb RPM."; exit 1; }

# --- Final stage: overlay RPMs onto RHCOS ---
FROM ${OS_REF}
LABEL quay.expires-after=24h
COPY --from=builder /output/*.rpm /tmp/rpms/
RUN rpm-ostree -C override replace /tmp/rpms/*.rpm && rm -rf /tmp/rpms
DOCKERFILE_EOF

# Unique tag per job so multiple jobs can push/pull concurrently.
# Tags auto-expire after 24h via the quay.expires-after image label.
IMAGE_TAG="ts-$(date -u +%s)"

CUSTOM_OS_IMAGE="${CUSTOM_OS_MIRROR_REGISTRY}/${CUSTOM_OS_IMAGE_REPO}:${IMAGE_TAG}"

podman build --authfile "${PULL_SECRET}" \
 --build-arg BUILDER_IMAGE="${BUILDER_IMAGE}" \
 --build-arg OS_REF="${OS_REF}" \
 --build-arg RESOURCE_AGENTS_REPO="${RESOURCE_AGENTS_REPO}" \
 --build-arg RESOURCE_AGENTS_REF="${RESOURCE_AGENTS_REF}" \
 --build-arg STREAM="${STREAM}" \
 -t "${CUSTOM_OS_IMAGE}" \
 -f "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}"

podman push --authfile "${PUSH_AUTHFILE}" --digestfile /tmp/custom-os-digest.txt "${CUSTOM_OS_IMAGE}"
CUSTOM_OS_DIGEST=$(cat /tmp/custom-os-digest.txt)
CUSTOM_OS_REF="${CUSTOM_OS_IMAGE%:*}@${CUSTOM_OS_DIGEST}"

# Extensions image to mirror (same tag for correlation).
# Add quay.expires-after label so Quay auto-expires the tag.
CUSTOM_EXTENSIONS_IMAGE="${CUSTOM_OS_MIRROR_REGISTRY}/${CUSTOM_OS_EXTENSIONS_REPO:-${CUSTOM_OS_IMAGE_REPO}-extensions}:${IMAGE_TAG}"
podman pull --authfile "${PULL_SECRET}" "${EXTENSIONS_REF}"
podman commit --change 'LABEL quay.expires-after=24h' "$(podman create "${EXTENSIONS_REF}")" "${CUSTOM_EXTENSIONS_IMAGE}"
podman push --authfile "${PUSH_AUTHFILE}" --digestfile /tmp/custom-extensions-digest.txt "${CUSTOM_EXTENSIONS_IMAGE}"
CUSTOM_EXTENSIONS_DIGEST=$(cat /tmp/custom-extensions-digest.txt)
CUSTOM_EXTENSIONS_REF="${CUSTOM_EXTENSIONS_IMAGE%:*}@${CUSTOM_EXTENSIONS_DIGEST}"

# MachineConfig: quote image refs so special characters in refs cannot break YAML.
MC_NAME="${CUSTOM_OS_MC_NAME:-99-master-custom-rhcos}"
cat << EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
 labels:
  machineconfiguration.openshift.io/role: master
 name: ${MC_NAME}
spec:
 osImageURL: "${CUSTOM_OS_REF}"
 baseOSExtensionsContainerImage: "${CUSTOM_EXTENSIONS_REF}"
EOF

# Wait for MCO to start processing the new MachineConfig before waiting for
# completion. Without this gate the MCP may still show Updated=True from its
# prior state (MCO hasn't reconciled yet), causing the Updated wait to succeed
# immediately and the actual rolling reboot to happen during the next CI step.
echo "Waiting for MCO to begin processing the new MachineConfig..."
if ! oc wait machineconfigpool/master --for=condition=Updating=True --timeout=7m; then
 echo "MCO did not start processing within 7m; failing so cluster is cleaned up."
 exit 1
fi
echo "MCO is processing. Waiting for master MachineConfigPool to complete rollout..."
if ! oc wait machineconfigpool/master --for=condition=Updated --timeout=40m; then
 echo "MachineConfig rollout did not complete; failing so cluster is cleaned up."
 exit 1
fi
echo "Rollout complete."

# After MCO rollout nodes have just rebooted. Wait for them to be Ready and
# schedulable before attempting oc debug, which needs to place a pod on a node.
echo "Waiting for nodes to be Ready after reboot..."
oc wait nodes --all --for=condition=Ready --timeout=5m || true

# Report the resource-agents version now running on a cluster node (Best-effort).
NODE=$(oc get nodes --no-headers | awk 'tolower($2) == "ready" {print $1; exit}') || true
if [[ -n "${NODE}" ]]; then
 oc_debug_with_retry "${NODE}" chroot /host rpm -q resource-agents || echo "Could not verify resource-agents version on node after retries."
else
 echo "No ready node found; skipping post-rollout version check."
fi
