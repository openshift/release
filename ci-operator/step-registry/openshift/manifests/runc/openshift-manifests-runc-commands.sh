#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat > "/tmp/50-runc" << EOF
[crio.runtime]
default_runtime = "runc"
[crio.runtime.runtimes.runc]
runtime_root = "/run/runc"
allowed_annotations = [
	"io.containers.trace-syscall",
	"io.kubernetes.cri-o.Devices",
	"io.kubernetes.cri-o.LinkLogs",
]
EOF

cat > "${SHARED_DIR}/manifest_mc-master-runc.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-runc
spec:
  config:
    ignition:
      version: 3.3.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,$(base64 -w0 </tmp/50-runc)
        filesystem: root
        mode: 0644
        path: /etc/crio/crio.conf.d/50-runc
EOF

sed 's/master/worker/g' "${SHARED_DIR}/manifest_mc-master-runc.yml" > "${SHARED_DIR}/manifest_mc-worker-runc.yml"

# Create the GCP CCM CredentialsRequest manifest
# This is required because in OpenShift 5.0, when custom MachineConfigs are added during installation,
# the cloud-controller-manager-operator does not properly create this CredentialsRequest from the release payload.
# Without this manifest, the gcp-ccm-cloud-credentials secret won't be created, causing the
# gcp-cloud-controller-manager deployment to fail with missing credentials.
cat > "${SHARED_DIR}/manifest_gcp-ccm-credreq.yml" << 'EOF'
apiVersion: cloudcredential.openshift.io/v1
kind: CredentialsRequest
metadata:
  annotations:
    capability.openshift.io/name: CloudCredential+CloudControllerManager
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
  name: openshift-gcp-ccm
  namespace: openshift-cloud-credential-operator
spec:
  providerSpec:
    apiVersion: cloudcredential.openshift.io/v1
    kind: GCPProviderSpec
    permissions:
    - compute.addresses.create
    - compute.addresses.delete
    - compute.addresses.get
    - compute.addresses.list
    - compute.firewalls.create
    - compute.firewalls.delete
    - compute.firewalls.get
    - compute.firewalls.update
    - compute.forwardingRules.create
    - compute.forwardingRules.delete
    - compute.forwardingRules.get
    - compute.healthChecks.create
    - compute.healthChecks.delete
    - compute.healthChecks.get
    - compute.healthChecks.update
    - compute.httpHealthChecks.create
    - compute.httpHealthChecks.delete
    - compute.httpHealthChecks.get
    - compute.httpHealthChecks.update
    - compute.instanceGroups.create
    - compute.instanceGroups.delete
    - compute.instanceGroups.get
    - compute.instanceGroups.update
    - compute.instances.get
    - compute.instances.use
    - compute.regionBackendServices.create
    - compute.regionBackendServices.delete
    - compute.regionBackendServices.get
    - compute.regionBackendServices.update
    - compute.targetPools.addInstance
    - compute.targetPools.create
    - compute.targetPools.delete
    - compute.targetPools.get
    - compute.targetPools.removeInstance
    - compute.zones.list
    skipServiceCheck: true
  secretRef:
    name: gcp-ccm-cloud-credentials
    namespace: openshift-cloud-controller-manager
  serviceAccountNames:
  - cloud-controller-manager
EOF
