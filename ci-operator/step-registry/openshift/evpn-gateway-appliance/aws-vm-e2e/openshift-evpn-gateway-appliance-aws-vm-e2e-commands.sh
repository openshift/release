#!/bin/bash
# Canary for the appliance PR's emulated EVPN e2e lane.
#
# Builds the CI image from the PR here (ci-operator builds ansible-test-runner from the repo's
# default branch, which lacks the lane, so we build it ourselves), then runs the PR's
# test/e2e/run_remote.sh in remote mode against the EC2 VM, passing that PR-built image as
# CI_IMAGE. FRR_IMAGE/NODE_EXPORTER_IMAGE/EE_BASE_IMAGE come from the ref's base_images
# dependencies; APPLIANCE_BASE_IMAGE from the ref env (public quay).
set -euo pipefail

readonly EVPN_APPLIANCE_REPO="${EVPN_APPLIANCE_REPO:-https://github.com/openshift/evpn-gateway-appliance}"
readonly EVPN_APPLIANCE_PR="${EVPN_APPLIANCE_PR:-22}"
# Appliance bootc base (not mirrored in the CI registry, so not a base_images dependency).
readonly APPLIANCE_BASE_IMAGE="${APPLIANCE_BASE_IMAGE:-quay.io/centos-bootc/centos-bootc:stream10}"

# Base-image pullspecs injected by the ref's dependencies; passed through on the call below.
: "${FRR_IMAGE:?injected by the metallb-frr dependency}"
: "${NODE_EXPORTER_IMAGE:?injected by the prometheus-node-exporter dependency}"
: "${EE_BASE_IMAGE:?injected by the centos-stream10 dependency}"

# Fetch the PR source.
slug="${EVPN_APPLIANCE_REPO#https://github.com/}"
sha="$(curl -fsSL -H 'Accept: application/vnd.github.sha' \
	"https://api.github.com/repos/${slug}/commits/refs/pull/${EVPN_APPLIANCE_PR}/head")"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "aws-vm-e2e: could not resolve PR head sha" >&2; exit 1; }
rm -rf /tmp/ega-src && mkdir -p /tmp/ega-src
curl -fsSL -L "${EVPN_APPLIANCE_REPO}/archive/${sha}.tar.gz" | tar -xz -C /tmp/ega-src --strip-components=1
cd /tmp/ega-src

# Build the CI image from the PR (run_remote exports it from local storage via CI_IMAGE).
echo "aws-vm-e2e: building CI image from PR ${EVPN_APPLIANCE_PR}"
podman build -t localhost/evpn-gateway-appliance-ci:local -f Dockerfile.ci .

# Target VM from the provisioning chain.
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
ssh_opts="-i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ConnectTimeout=30"
echo "aws-vm-e2e: target VM ${remote}"

# run_remote.sh installs nothing on the target ("provisioning handles tools"); the ec2 chain
# doesn't either, so install what load.sh/build.sh/run.sh need and enable the podman socket.
echo "aws-vm-e2e: provisioning tools on the VM"
# shellcheck disable=SC2086  # ssh_opts is intentionally word-split
ssh ${ssh_opts} "${remote}" 'sudo dnf install -y podman skopeo make && sudo systemctl enable --now podman.socket'

# Run the PR's run_remote.sh in remote mode, passing all its inputs explicitly.
exec env \
	SSH_REMOTE="${remote}" \
	SSH_OPTS="${ssh_opts}" \
	REGISTRY_AUTH_FILE=/var/run/registry-pull-credentials/.dockerconfigjson \
	CI_IMAGE=containers-storage:localhost/evpn-gateway-appliance-ci:local \
	FRR_IMAGE="${FRR_IMAGE}" \
	NODE_EXPORTER_IMAGE="${NODE_EXPORTER_IMAGE}" \
	EE_BASE_IMAGE="${EE_BASE_IMAGE}" \
	APPLIANCE_BASE_IMAGE="${APPLIANCE_BASE_IMAGE}" \
	bash test/e2e/run_remote.sh
