#!/bin/bash

set -xeuo pipefail

# This script automates pulling the FCOS container image and building the QEMU image.

# Git repository to clone
REPO_URL="https://github.com/trusted-execution-clusters/investigations.git"
REPO_DIR="investigations"

# Image to pull
SOURCE_IMAGE="quay.io/trusted-execution-clusters/fedora-coreos:42.20250705.3.0"
TARGET_IMAGE="quay.io/trusted-execution-clusters/fcos"
# --- Prerequisite Setup ---
echo "--- Updating system and installing build dependencies ---"
sudo dnf update -y
sudo dnf install -y \
    git \
    just \
    podman \
    skopeo \
    osbuild \
    osbuild-tools \
    osbuild-ostree \
    jq \
    xfsprogs \
    e2fsprogs \
    dosfstools \
    genisoimage \
    squashfs-tools \
    erofs-utils \
    syslinux-nonlinux

# Set SELinux to permissive mode, as required by custom-coreos-disk-images.sh
echo "--- Setting SELinux to permissive mode (temporarily and permanently) ---"
sudo setenforce 0 || true # Use || true to prevent script exit if it fails
sudo sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# --- Main script ---

echo "--- Cloning repository ---"
git clone "${REPO_URL}"
cd "${REPO_DIR}"

echo "--- Pulling FCOS container image ---"
sudo podman pull "${SOURCE_IMAGE}"

echo "--- Tagging image for build scripts ---"
sudo podman tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}"

# Navigate to the directory containing the build logic
cd coreos

# Define image paths
QEMU_IMAGE_NAME="fcos-qemu.x86_64.qcow2"
LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"
FINAL_IMAGE_PATH="${LIBVIRT_IMAGE_DIR}/${QEMU_IMAGE_NAME}"

# Ensure libvirt image directory exists
sudo mkdir -p "${LIBVIRT_IMAGE_DIR}"

# Check for existing image in the final destination
if [ -f "${FINAL_IMAGE_PATH}" ]; then
    echo "--- Existing QEMU image found at ${FINAL_IMAGE_PATH}, skipping build. ---"
else
    echo "--- Creating OCI archive ---"
    just oci-archive

    echo "--- Building QEMU image ---"
    just osbuild-qemu

    echo "--- Moving built image to ${LIBVIRT_IMAGE_DIR} ---"
    # The image is built in the current directory (investigations/coreos)
    sudo mv "${QEMU_IMAGE_NAME}" "${LIBVIRT_IMAGE_DIR}/"
    echo "--- Build and move complete! The new image is at ${FINAL_IMAGE_PATH} ---"
fi
