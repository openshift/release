#!/bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh

mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"


cat <<'EOF' > "${HOME}"/suite.txt
"[k8s.io] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart exec hook properly [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart http hook properly [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Lifecycle Hook when create a pod with lifecycle hook should execute prestop exec hook properly [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Lifecycle Hook when create a pod with lifecycle hook should execute prestop http hook properly [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test on terminated container should report termination message [LinuxOnly] as empty when pod succeeds and TerminationMessagePolicy FallbackToLogsOnError is set [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test on terminated container should report termination message [LinuxOnly] from file when pod succeeds and TerminationMessagePolicy FallbackToLogsOnError is set [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test on terminated container should report termination message [LinuxOnly] from log output if TerminationMessagePolicy FallbackToLogsOnError is set [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test on terminated container should report termination message [LinuxOnly] if TerminationMessagePath is set as non-root user and at a non-default path [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test on terminated container should report termination message [LinuxOnly] if TerminationMessagePath is set [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test when running a container with a new image should be able to pull from private registry with secret [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test when running a container with a new image should be able to pull image [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test when running a container with a new image should not be able to pull from private registry without secret [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test when running a container with a new image should not be able to pull image from invalid registry [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Container Runtime blackbox test when starting a container that exits should run with the expected status [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Docker Containers should be able to override the image's default arguments (docker cmd) [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Docker Containers should be able to override the image's default command and arguments [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Docker Containers should be able to override the image's default command (docker entrypoint) [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Docker Containers should use the image defaults if command and args are blank [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] [Feature:Example] [k8s.io] Downward API should create a pod that prints his name and namespace [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [Feature:Example] [k8s.io] Liveness liveness pods should be automatically restarted [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [Feature:Example] [k8s.io] Secret should create a pod that reads a secret [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] InitContainer [NodeConformance] should invoke init containers on a RestartAlways pod [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] InitContainer [NodeConformance] should invoke init containers on a RestartNever pod [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] InitContainer [NodeConformance] should not start app containers and fail the pod if init containers fail on a RestartNever pod [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] InitContainer [NodeConformance] should not start app containers if init containers fail on a RestartAlways pod [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] KubeletManagedEtcHosts should test kubelet managed /etc/hosts file [LinuxOnly] [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Kubelet when scheduling a busybox command in a pod should print the output to logs [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Kubelet when scheduling a busybox command that always fails in a pod should be possible to delete [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Kubelet when scheduling a busybox command that always fails in a pod should have an terminated reason [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Kubelet when scheduling a busybox Pod with hostAliases should write entries to /etc/hosts [LinuxOnly] [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Kubelet when scheduling a read only busybox container should not write to root filesystem [LinuxOnly] [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Lease lease API should be available [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] NodeLease when the NodeLease feature is enabled should have OwnerReferences set [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] NodeLease when the NodeLease feature is enabled the kubelet should create and update a lease in the kube-node-lease namespace [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] NodeLease when the NodeLease feature is enabled the kubelet should report node status infrequently [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Pods should allow activeDeadlineSeconds to be updated [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should be submitted and removed [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should be updated [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should contain environment variables for services [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should delete a collection of pods [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should get a host IP [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should run through the lifecycle of Pods and PodStatus [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should support pod readiness gates [NodeFeature:PodReadinessGate] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Pods should support remote command execution over websockets [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Pods should support retrieving logs from the container over websockets [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] PrivilegedPod [NodeConformance] should enable privileged commands [LinuxOnly] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should be restarted by liveness probe after startup probe enables it [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should be restarted startup probe fails [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should be restarted with a docker exec liveness probe with timeout  [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should be restarted with a exec \"cat /tmp/health\" liveness probe [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container should be restarted with a /healthz http liveness probe [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container should be restarted with a local redirect http liveness probe [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should have monotonically increasing restart count [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container should not be ready until startupProbe succeeds [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should not be ready with a docker exec readiness probe timeout  [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should *not* be restarted by liveness probe because startup probe delays it [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should *not* be restarted with a exec \"cat /tmp/health\" liveness probe [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container should *not* be restarted with a /healthz http liveness probe [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container should *not* be restarted with a non-local redirect http liveness probe [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Probing container should *not* be restarted with a tcp:8080 liveness probe [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container with readiness probe should not be ready before initial delay and never restart [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Probing container with readiness probe that fails should never be ready and never restart [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Security Context When creating a container with runAsNonRoot should not run with an explicit root user ID [LinuxOnly] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a container with runAsNonRoot should not run without a specified user ID [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a container with runAsNonRoot should run with an explicit non-root user ID [LinuxOnly] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a container with runAsNonRoot should run with an image specified user ID [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a container with runAsUser should run the container with uid 0 [LinuxOnly] [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a container with runAsUser should run the container with uid 65534 [LinuxOnly] [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Security Context When creating a pod with privileged should run the container as privileged when true [LinuxOnly] [NodeFeature:HostAccess] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a pod with privileged should run the container as unprivileged when false [LinuxOnly] [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Security Context When creating a pod with readOnlyRootFilesystem should run the container with readonly rootfs when readOnlyRootFilesystem=true [LinuxOnly] [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context When creating a pod with readOnlyRootFilesystem should run the container with writable rootfs when readOnlyRootFilesystem=false [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Security Context when creating containers with AllowPrivilegeEscalation should allow privilege escalation when not explicitly set and uid != 0 [LinuxOnly] [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context when creating containers with AllowPrivilegeEscalation should allow privilege escalation when true [LinuxOnly] [NodeConformance] [sig-node] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Security Context when creating containers with AllowPrivilegeEscalation should not allow privilege escalation when false [LinuxOnly] [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] [sig-node] Events should be sent by kubelets and the scheduler about pods scheduling and running  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] [sig-node] kubelet [k8s.io] [sig-node] Clean up pods on node kubelet should be able to delete 10 pods per node in 1m0s. [Serial] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[k8s.io] [sig-node] Mount propagation should propagate mounts to the host [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] NoExecuteTaintManager Multiple Pods [Serial] only evicts pods without tolerations from tainted nodes [Suite:openshift/conformance/serial] [Suite:k8s]"
"[k8s.io] [sig-node] NoExecuteTaintManager Single Pod [Serial] doesn't evict pod with tolerations from tainted nodes [Suite:openshift/conformance/serial] [Suite:k8s]"
"[k8s.io] [sig-node] NoExecuteTaintManager Single Pod [Serial] eventually evict pod with finite tolerations from tainted nodes [Suite:openshift/conformance/serial] [Suite:k8s]"
"[k8s.io] [sig-node] NoExecuteTaintManager Single Pod [Serial] evicts pods from tainted nodes [Suite:openshift/conformance/serial] [Suite:k8s]"
"[k8s.io] [sig-node] Pods Extended [k8s.io] Delete Grace Period should be submitted and removed [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Pods Extended [k8s.io] Pod Container Status should never report success for a pending container [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Pods Extended [k8s.io] Pods Set QOS Class should be set on Pods with matching resource requests and limits for memory and cpu [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] [sig-node] PreStop graceful pod terminated should wait until preStop hook completes the process [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] PreStop should call prestop when killing a pod  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support container.SecurityContext.RunAsUser And container.SecurityContext.RunAsGroup [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support container.SecurityContext.RunAsUser [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support pod.Spec.SecurityContext.RunAsUser And pod.Spec.SecurityContext.RunAsGroup [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support pod.Spec.SecurityContext.RunAsUser [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support pod.Spec.SecurityContext.SupplementalGroups [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support seccomp default which is unconfined [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support seccomp runtime/default [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support seccomp unconfined on the container [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] [sig-node] Security Context should support seccomp unconfined on the pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[k8s.io] Variable Expansion should allow composing env vars into new env vars [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Variable Expansion should allow substituting values in a container's args [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[k8s.io] Variable Expansion should allow substituting values in a container's command [NodeConformance] [Conformance] [sig-node] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] ConfigMap should be consumable via environment variable [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] ConfigMap should be consumable via the environment [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] ConfigMap should fail to create ConfigMap with empty key [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] ConfigMap should run through a ConfigMap lifecycle [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] ConfigMap should update ConfigMap successfully [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Downward API should provide container's limits.cpu/memory and requests.cpu/memory as env vars [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] Downward API should provide default limits.cpu/memory from node allocatable [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] Downward API should provide host IP and pod IP as an env var if pod uses host network [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Downward API should provide host IP as an env var [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] Downward API should provide pod name, namespace and IP address as env vars [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] Downward API should provide pod UID as env vars [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node][Late] should not have pod creation failures due to systemd timeouts [Suite:openshift/conformance/parallel]"
"[sig-node] PodTemplates should delete a collection of pod templates [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] PodTemplates should run the lifecycle of PodTemplates [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] RuntimeClass  should support RuntimeClasses API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

