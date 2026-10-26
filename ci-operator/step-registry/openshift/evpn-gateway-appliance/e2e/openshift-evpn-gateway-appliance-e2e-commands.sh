#!/bin/bash
# Run the emulated EVPN e2e lane on the EC2 VM provisioned by the openshift-image-based-infra-aws-ec2
# chain. This runs in the CI image (ansible-test-runner), which bakes test/e2e/run_remote.sh at
# /src and carries skopeo + ssh. run_remote.sh installs nothing on the target and the ec2 chain
# provisions a bare VM, so we install the VM tools here, then run run_remote.sh in remote mode.
set -euo pipefail

# CI_IMAGE / FRR_IMAGE / NODE_EXPORTER_IMAGE / EE_BASE_IMAGE / APPLIANCE_BASE_IMAGE come from the
# ref env (public defaults, overridden by the base_images dependencies); passed through below.

# Target VM from the provisioning chain.
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
ssh_opts="-i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ConnectTimeout=30"
echo "e2e: target VM ${remote}"

# Install what load.sh/build.sh/run.sh need and enable the podman socket. Wait for sshd first
# (the ec2 chain waits for instance-status-ok, not sshd).
# shellcheck disable=SC2086  # ssh_opts is intentionally word-split
for _ in $(seq 1 30); do ssh ${ssh_opts} "${remote}" true 2>/dev/null && break; sleep 10; done
# shellcheck disable=SC2086
ssh ${ssh_opts} "${remote}" 'sudo dnf install -y podman skopeo make && sudo systemctl enable --now podman.socket'

# Run the baked run_remote.sh in remote mode, passing all its inputs explicitly.
exec env \
	SSH_REMOTE="${remote}" \
	SSH_OPTS="${ssh_opts}" \
	REGISTRY_AUTH_FILE=/var/run/registry-pull-credentials/.dockerconfigjson \
	CI_IMAGE="${CI_IMAGE}" \
	FRR_IMAGE="${FRR_IMAGE}" \
	NODE_EXPORTER_IMAGE="${NODE_EXPORTER_IMAGE}" \
	EE_BASE_IMAGE="${EE_BASE_IMAGE}" \
	APPLIANCE_BASE_IMAGE="${APPLIANCE_BASE_IMAGE}" \
	bash /src/test/e2e/run_remote.sh
