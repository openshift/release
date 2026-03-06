#!/bin/bash
set -euo pipefail

RESOURCE_AGENT_SOURCE="${RESOURCE_AGENT_SOURCE:-RHCOS}"
RESOURCE_AGENTS_REPO="${RESOURCE_AGENTS_REPO:-https://github.com/ClusterLabs/resource-agents}"
RESOURCE_AGENTS_REF="${RESOURCE_AGENTS_REF:-main}"

if [[ "${RESOURCE_AGENT_SOURCE}" == "RHCOS" ]]; then
  # Report installed resource-agents version on first healthy schedulable node. Must not fail.
  NODE=$(oc get nodes -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status=="True")].metadata.name}' | tr ' ' '\n' | head -1)
  if [[ -z "${NODE}" ]]; then
    echo "No ready node found; skipping version report."
    exit 0
  fi
  if ! oc debug "node/${NODE}" -- chroot /host rpm -q resource-agents 2>/dev/null; then
    echo "Could not get resource-agents version (timeout or error); skipping."
  fi
  exit 0
fi

if [[ "${RESOURCE_AGENT_SOURCE}" != "REPO" ]]; then
  echo "RESOURCE_AGENT_SOURCE must be RHCOS or REPO, got: ${RESOURCE_AGENT_SOURCE}"
  exit 1
fi

# REPO path: build resource-agents RPM, custom RHCOS image, apply MachineConfig.
# Must run after cluster deployment (workflow-specific). Release image and version from clusterversion.
RELEASE_IMAGE=$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || true)
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [[ -z "${RELEASE_IMAGE}" ]] || [[ -z "${OCP_VERSION}" ]]; then
  echo "Could not get release image or version from cluster (clusterversion version)."
  exit 1
fi

PULL_SECRET="${PULL_SECRET:-}"
if [[ -z "${PULL_SECRET}" ]] && [[ -n "${CLUSTER_PROFILE_DIR:-}" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"
fi
if [[ -z "${PULL_SECRET}" ]] || [[ ! -f "${PULL_SECRET}" ]]; then
  echo "Pull secret file required (set PULL_SECRET or use CLUSTER_PROFILE_DIR/pull-secret)."
  exit 1
fi
OCP_MINOR=$(echo "${OCP_VERSION}" | cut -d. -f2)
if [[ -z "${OCP_MINOR}" ]] || ! [[ "${OCP_MINOR}" =~ ^[0-9]+$ ]]; then
  OCP_MINOR=0
fi
if [[ "${OCP_MINOR}" -le 22 ]]; then
  STREAM=9
else
  STREAM=10
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

BUILD_DIR="/tmp/resource-agents-build"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Enable CRB and EPEL when available (needed for CentOS Stream; no-op or harmless on RHEL).
dnf config-manager --set-enabled crb 2>/dev/null || true
dnf install -y epel-release 2>/dev/null || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${STREAM}.noarch.rpm" 2>/dev/null || true

# Install build deps. Include libxslt, systemd, which (required by resource-agents rpmbuild).
# On Stream 10 libqb-devel may be missing from EPEL; build libqb from source and install a stub RPM so rpmbuild's BuildRequires is satisfied.
DEPS="git autoconf automake docbook-style-xsl glib2-devel make rpm-build perl python3-devel libnet-devel python3-pyroute2 libxslt systemd which"
if ! dnf install -y ${DEPS} libqb-devel; then
  echo "libqb-devel not in repos (e.g. Stream 10); building libqb from source."
  dnf install -y ${DEPS} libqb libtool libxml2-devel check 2>/dev/null || true
  LIBQB_BUILD="/tmp/libqb-build"
  rm -rf "${LIBQB_BUILD}"
  git clone --depth 1 https://github.com/ClusterLabs/libqb "${LIBQB_BUILD}"
  (cd "${LIBQB_BUILD}" && autoreconf -fi && ./configure --prefix=/usr && make -j"$(nproc)" && make install)
  # Install a stub libqb-devel RPM so resource-agents' make rpm (BuildRequires: libqb-devel) succeeds.
  mkdir -p /tmp/libqb-devel-stub
  cat > /tmp/libqb-devel-stub/libqb-devel.spec << 'STUBSPEC'
Name: libqb-devel
Version: 0
Release: 1
Summary: Stub to satisfy BuildRequires when libqb built from source
License: LGPL-2.1
%description
Stub package; libqb was built and installed from source.
%files
%ghost /usr/lib64/libqb.so
STUBSPEC
  (cd /tmp/libqb-devel-stub && rpmbuild -bb --define "_sourcedir /tmp/libqb-devel-stub" --define "_rpmdir /tmp" libqb-devel.spec 2>/dev/null) || true
  STUB_RPM=$(find /tmp -name "libqb-devel-0-1.*.rpm" 2>/dev/null | head -1)
  if [[ -n "${STUB_RPM}" ]] && [[ -f "${STUB_RPM}" ]]; then
    rpm -i "${STUB_RPM}" 2>/dev/null || true
  fi
  rm -rf "${LIBQB_BUILD}" /tmp/libqb-devel-stub
  dnf install -y ${DEPS} 2>/dev/null || true
fi

git clone --depth 1 "${RESOURCE_AGENTS_REPO}" "${BUILD_DIR}"
git -C "${BUILD_DIR}" fetch origin "${RESOURCE_AGENTS_REF}"
git -C "${BUILD_DIR}" checkout FETCH_HEAD
RPM_VERSION=$(git -C "${BUILD_DIR}" rev-parse --short HEAD 2>/dev/null || echo "0")
cd "${BUILD_DIR}"
autoreconf --install --force
./configure
make rpm VERSION="${RPM_VERSION}"
RPM_PATH=$(find . -name 'resource-agents-*.rpm' ! -name '*debug*' ! -name '*.src.rpm' | head -1)
if [[ -z "${RPM_PATH}" ]]; then
  echo "No resource-agents RPM found after build."
  exit 1
fi
RPM_FILENAME=$(basename "${RPM_PATH}")
cp "${RPM_PATH}" /tmp/

# libqb (from default repos or job-provided path)
LIBQB_RPM="/tmp/libqb.rpm"
if [[ -n "${LIBQB_RPM_PATH:-}" ]] && [[ -f "${LIBQB_RPM_PATH}" ]]; then
  cp "${LIBQB_RPM_PATH}" "${LIBQB_RPM}"
else
  dnf download -y --destdir /tmp libqb 2>/dev/null || true
  LIBQB_FILE=$(ls /tmp/libqb-*.rpm 2>/dev/null | head -1)
  if [[ -z "${LIBQB_FILE}" ]] || [[ ! -f "${LIBQB_FILE}" ]]; then
    echo "Could not download libqb; set LIBQB_RPM_PATH or enable repo with libqb."
    exit 1
  fi
  cp "${LIBQB_FILE}" "${LIBQB_RPM}"
fi

# Base images from payload
OCP_BASE_OS="${OCP_BASE_OS:-rhel-coreos}"
if [[ "${STREAM}" -eq 10 ]]; then
  OCP_BASE_OS="rhel-coreos-10"
fi
OS_REF=$(oc adm release info "${RELEASE_IMAGE}" --registry-config "${PULL_SECRET}" --image-for="${OCP_BASE_OS}")
EXTENSIONS_REF=$(oc adm release info "${RELEASE_IMAGE}" --registry-config "${PULL_SECRET}" --image-for="${OCP_BASE_OS}-extensions")

# Unique tag per job so multiple jobs can push/pull concurrently. Delete step uses this to remove our image and runs 24h cleanup.
IMAGE_TAG="ts-$(date -u +%s)"
echo "${IMAGE_TAG}" > "${SHARED_DIR}/custom-rhcos-image-tag"

# Build custom RHCOS image
DOCKERFILE_DIR="/tmp/custom-rhcos-build"
rm -rf "${DOCKERFILE_DIR}"
mkdir -p "${DOCKERFILE_DIR}"
cp /tmp/"${RPM_FILENAME}" "${DOCKERFILE_DIR}/"
cp "${LIBQB_RPM}" "${DOCKERFILE_DIR}/libqb.rpm"
cat > "${DOCKERFILE_DIR}/Dockerfile" << EOF
FROM ${OS_REF}
COPY ${RPM_FILENAME} /${RPM_FILENAME}
COPY libqb.rpm /libqb.rpm
RUN rpm-ostree -C override replace /libqb.rpm /${RPM_FILENAME} && rm -f /${RPM_FILENAME} /libqb.rpm
EOF
CUSTOM_OS_IMAGE="${CUSTOM_OS_MIRROR_REGISTRY}/${CUSTOM_OS_IMAGE_REPO}:${IMAGE_TAG}"
podman build --authfile "${PULL_SECRET}" -t "${CUSTOM_OS_IMAGE}" -f "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}"
podman push --authfile "${PUSH_AUTHFILE}" --digestfile /tmp/custom-os-digest.txt "${CUSTOM_OS_IMAGE}"
CUSTOM_OS_DIGEST=$(cat /tmp/custom-os-digest.txt)
CUSTOM_OS_REF="${CUSTOM_OS_IMAGE%@*}@${CUSTOM_OS_DIGEST}"

# Extensions image to mirror (same tag for correlation)
CUSTOM_EXTENSIONS_IMAGE="${CUSTOM_OS_MIRROR_REGISTRY}/${CUSTOM_OS_EXTENSIONS_REPO:-${CUSTOM_OS_IMAGE_REPO}-extensions}:${IMAGE_TAG}"
podman pull --authfile "${PULL_SECRET}" "${EXTENSIONS_REF}"
podman tag "${EXTENSIONS_REF}" "${CUSTOM_EXTENSIONS_IMAGE}"
podman push --authfile "${PUSH_AUTHFILE}" --digestfile /tmp/custom-extensions-digest.txt "${CUSTOM_EXTENSIONS_IMAGE}"
CUSTOM_EXTENSIONS_DIGEST=$(cat /tmp/custom-extensions-digest.txt)
CUSTOM_EXTENSIONS_REF="${CUSTOM_EXTENSIONS_IMAGE%@*}@${CUSTOM_EXTENSIONS_DIGEST}"

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

# Wait for rollout; fail if it does not complete so cluster is cleaned up
echo "Waiting for master MachineConfigPool to complete rollout..."
if ! oc wait machineconfigpool/master --for=condition=Updated --timeout=30m 2>/dev/null; then
  echo "MachineConfig rollout did not complete; failing so cluster is cleaned up."
  exit 1
fi
echo "Rollout complete."
