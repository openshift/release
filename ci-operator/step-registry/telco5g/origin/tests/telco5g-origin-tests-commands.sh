#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck disable=SC1091
source "$SHARED_DIR/main.env"

# Set go version
if [[ "$T5CI_VERSION" == "4.12" ]] || [[ "$T5CI_VERSION" == "4.13" ]]; then
    source $HOME/golang-1.19
elif [[ "$T5CI_VERSION" == "4.14" ]] || [[ "$T5CI_VERSION" == "4.15" ]]; then
    source $HOME/golang-1.20
elif [[ "$T5CI_VERSION" == "4.16" ]]; then
    source $HOME/golang-1.21.11
else
    source $HOME/golang-1.22.4
fi

export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn metallb multinetworkpolicy}" # next: ovs_qos
export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export CNF_BRANCH="${CNF_BRANCH:-master}"

# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/baremetalds/e2e/test/baremetalds-e2e-test-commands.sh
export TEST_PROVIDER='{"type":"baremetal"}'

echo "************ telco5g origin tests commands ************"
# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp "$SSH_PKEY_PATH" "$SSH_PKEY"
chmod 600 "$SSH_PKEY"

if [[ "$T5CI_VERSION" == "4.22" ]]; then
    export CNF_BRANCH="master"
else
    export CNF_BRANCH="release-${T5CI_VERSION}"
fi

cnf_dir=$(mktemp -d -t cnf-XXXXX)
cd "$cnf_dir" || exit 1

echo "running on branch ${CNF_BRANCH}"
git clone -b "${CNF_BRANCH}" "${CNF_REPO}" cnf-features-deploy
cd cnf-features-deploy
if [[ "$T5CI_VERSION" != "4.11" ]] && [[ "$T5CI_VERSION" != "4.12" ]] && [[ "$T5CI_VERSION" != "4.13" ]] && [[ "$T5CI_VERSION" != "4.14" ]]; then
    echo "Updating all submodules for >=4.15 versions"
    # git version 1.8 doesn't work well with forked repositories, requires a specific branch to be set
    sed -i "s@https://github.com/openshift/metallb-operator.git@https://github.com/openshift/metallb-operator.git\n        branch = main@" .gitmodules
    git submodule update --init --force --recursive
    git submodule foreach --recursive 'echo $path `git config --get remote.origin.url` `git rev-parse HEAD`' | grep -v Entering > ${ARTIFACT_DIR}/hashes.txt || true
fi
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

FEATURES_ENVIRONMENT="ci" make feature-deploy-on-ci 2>&1 | tee "${SHARED_DIR}/cnf-tests-run.log"

cd

# Wait until number of nodes matches number of machines
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
for i in $(seq 30); do
    nodes="$(oc get nodes --no-headers | wc -l)"
    machines="$(oc get machines -A --no-headers | wc -l)"
    [ "$machines" -le "$nodes" ] && break
    sleep 30
done

[ "$machines" -le "$nodes" ]

# Wait for nodes to be ready
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait nodes --all --for=condition=Ready=true --timeout=10m

# Waiting for clusteroperators to finish progressing
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m

# Pull secrets might be required to extract url to container image of OpenShift's conformance test suite
oc get secret pull-secret -n openshift-config -o jsonpath="{.data['\.dockerconfigjson']}" \
    | base64 --decode > pull-secret.txt

# Pull secrets are required to pull container image for openshift-tests
oc get secret pull-secret -n openshift-config -o yaml | grep -v '^\s*namespace:\s' | oc apply -f -

# Extract url to container image of OpenShift's conformance test suite aka openshift-tests
T5_JOB_TESTS_IMAGE=$(oc adm release info --registry-config pull-secret.txt --image-for=tests "$T5_JOB_RELEASE_IMAGE")

# Launch a pod from the openshift-tests image and let it idle
# while we copy the openshift-tests binary out of the container
oc run telco5g-tests-extractor --restart=Never --image "$T5_JOB_TESTS_IMAGE" --command=true \
    --overrides='{ "spec": { "template": { "spec": { "imagePullSecrets": [{"name": "pull-secret"}] } } } }' \
    -- sleep 3600

oc wait pod/telco5g-tests-extractor --for=condition=Ready --timeout=15m

# Extract openshift-tests binary from container
# shellcheck disable=SC2034
for i in $(seq 10); do # retry because copy is flaky
    if oc cp telco5g-tests-extractor:/usr/bin/openshift-tests openshift-tests; then
        break
    else
        rm -f openshift-tests # remove incompletely transferred files
        sleep 5
    fi
done
[ -e "openshift-tests" ]

oc delete pods telco5g-tests-extractor

chmod a+x openshift-tests

# Determine list of tests
case "$T5CI_VERSION" in
  4.12)
    TESTS_LIST=$(cat <<EOF
"[sig-apps] Deployment RecreateDeployment should delete old pods and create new ones [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-devex][Feature:Templates] templateinstance creation with invalid object reports error should report a failure on creation [apigroup:template.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] volumes should store data [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Dynamic PV (default fs)(allowExpansion)] volume-expand Verify if offline PVC expansion works [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Pre-provisioned PV (ext4)] volumes should store data [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-arch] [Conformance] sysctl pod should not start for sysctl not on whitelist kernel.msgmax [Suite:openshift/conformance/parallel/minimal]"
"[sig-cli] Kubectl client Simple pod should support exec using resource/name [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD preserving unknown fields at the schema root [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] ConfigMap updates should be reflected in volume [NodeConformance] [Conformance] [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Pods should function for intra-pod communication: http [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] Projected configMap should be consumable from pods in volume as non-root with defaultMode and fsGroup set [LinuxOnly] [NodeFeature:FSGroup] [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (OnRootMismatch)[LinuxOnly], pod created with an initial fsgroup, volume contents ownership changed via chgrp in first pod, new pod with same fsgroup skips ownership changes to the volume contents [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Probing container should not be ready with an exec readiness probe timeout [MinimumKubeletVersion:1.20] [NodeConformance] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI mock volume CSIServiceAccountToken token should not be plumbed down when csiServiceAccountTokenEnabled=false [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Probing container should be restarted by liveness probe after startup probe enables it [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: local][LocalVolumeType: blockfs] [Testpattern: Pre-provisioned PV (default fs)] subPath should support existing single file [LinuxOnly] [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] A node shouldn't be able to create another node [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: local][LocalVolumeType: dir] [Testpattern: Pre-provisioned PV (default fs)] subPath should support existing single file [LinuxOnly] [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] oc label pod [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:RoleBindingRestrictions] RoleBindingRestrictions should be functional Create a rolebinding when subject is not already bound and is not permitted by any RBR should fail [apigroup:authorization.openshift.io] [Suite:openshift/conformance/parallel]"
EOF
    )
    ;;
  4.13)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] Secrets should be consumable from pods in volume with defaultMode set [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (ext4)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context When creating a pod with privileged should run the container as unprivileged when false [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] Projected configMap should be consumable from pods in volume with mappings [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, new pod fsgroup applied to volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Deployment deployment should delete old replica sets [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] templates different namespaces [apigroup:user.openshift.io][apigroup:project.openshift.io][apigroup:template.openshift.io][apigroup:authorization.openshift.io][Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-devex][Feature:Templates] templateinstance readiness test should report failed soon after an annotated objects has failed [apigroup:template.openshift.io][apigroup:build.openshift.io] [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage][Late] Metrics should report short mount times [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Pre-provisioned PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] Ephemeralstorage When pod refers to non-existent ephemeral storage should allow deletion of pod with invalid volume : secret [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] EmptyDir volumes should support (non-root,0777,tmpfs) [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should unconditionally reject operations on fail closed webhook [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] Projected downwardAPI should set mode on item file [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc rsh specific flags should work well when access to a remote shell [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage] CSI mock volume CSIStorageCapacity CSIStorageCapacity used, no capacity [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Pre-provisioned PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should respect internalTrafficPolicy=Local Pod (hostNetwork: true) to Pod [Feature:ServiceInternalTrafficPolicy] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-ci] [Early] prow job name should match cluster version [apigroup:config.openshift.io] [Suite:openshift/conformance/parallel]"
EOF
    )
    ;;
  4.14)
    TESTS_LIST=$(cat <<EOF
"[sig-etcd] etcd record the start revision of the etcd-operator [Early] [Suite:openshift/conformance/parallel]"
"[sig-node] Security Context should support pod.Spec.SecurityContext.RunAsUser [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Pre-provisioned PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, volume contents ownership changed via chgrp in first pod, new pod with different fsgroup applied to the volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Pre-provisioned PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Dynamic PV (ext4)] volumes should store data [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support expansion of pvcs created for ephemeral pvcs [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Dynamic PV (block volmode)] volume-expand should not allow expansion of pvcs without AllowVolumeExpansion property [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Pre-provisioned PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Pre-provisioned PV (block volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Update Demo should create and stop a replication controller  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Pre-provisioned PV (ext4)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Netpol NetworkPolicy between server and client should ensure an IP overlapping both IPBlock.CIDR and IPBlock.Except is allowed [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should create read/write inline ephemeral volume [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Dynamic PV (default fs)(allowExpansion)] volume-expand should resize volume when PVC is edited while pod is using it [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Dynamic PV (immediate binding)] topology should provision a volume and schedule a pod with AllowedTopologies [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (block volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: aws] [Testpattern: Dynamic PV (immediate binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Skipped:NoOptionalCapabilities] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (block volmode)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.15)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] Projected secret should be consumable in multiple volumes in a pod [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should work after the service has been recreated [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of same group and version but different kinds [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] CSI Mock volume storage capacity CSIStorageCapacity CSIStorageCapacity disabled [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should manage the lifecycle of a ResourceQuota [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Inline-volume (ext4)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] patching/updating a validating webhook should work [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] Secrets should be consumable in multiple volumes in a pod [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] PersistentVolumes NFS when invoking the Recycle reclaim policy should test that a PV becomes Available and is clean after the PVC is deleted. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (cpu, memory quota set) against a pod with same priority class. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] PersistentVolumes-local  Pod with node different from PV's NodeAffinity should fail scheduling due to different NodeAffinity [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should find a service from listing all namespaces [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceValidationRules [Privileged:ClusterAdmin] MUST fail create of a custom resource definition that contains a x-kubernetes-validations rule that refers to a property that do not exist [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Downward API should provide host IP as an env var [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] Ephemeralstorage When pod refers to non-existent ephemeral storage should allow deletion of pod with invalid volume : projected [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] PersistentVolumes-local  [Volume type: tmpfs] Two pods mounting a local volume at the same time should be able to write from pod1 and read from pod2 [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] StatefulSet Basic StatefulSet functionality [StatefulSetBasic] should list, patch and delete a collection of StatefulSets [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: hostPathSymlink] [Testpattern: Inline-volume (default fs)] subPath should support existing single file [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] Secrets should be immutable if `immutable` field is set [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: no PDB => should allow an eviction [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.16)
    TESTS_LIST=$(cat <<EOF
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a replication controller. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Discovery should validate PreferredVersion for each APIGroup [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should support cascading deletion of custom resources [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context When creating a container with runAsNonRoot should not run without a specified user ID [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] PrivilegedPod [NodeConformance] should enable privileged commands [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should delete successful finished jobs with limit of one successful job [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Pods should support retrieving logs from the container over websockets [NodeConformance] [Conformance] [Skipped:Proxy] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Services should function for pod-Service: http [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on localhost that expects a client request should support a client that connects, sends NO DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] StatefulSet Basic StatefulSet functionality [StatefulSetBasic] should have a working scale subresource [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should support exec through kubectl proxy [Skipped:Proxy] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] StatefulSet Non-retain StatefulSetPersistentVolumeClaimPolicy should delete PVCs with a WhenDeleted policy [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 should proxy logs on node using proxy subresource  [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] ReplicationController should test the lifecycle of a ReplicationController [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should resolve DNS of partial qualified names for services [LinuxOnly] [Conformance] [Skipped:Proxy] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should delete pods created by rc when not orphaning [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should fallback to local terminating endpoints when there are no ready endpoints with internalTrafficPolicy=Local [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should be able to deny pod and configmap creation [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] DisruptionController should observe that the PodDisruptionBudget status is not updated for unmanaged pods [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Pods should function for node-pod communication: http [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOF
    )
    ;;
  4.17)
    TESTS_LIST=$(cat <<EOF
"[sig-cluster-lifecycle][Feature:Machines][Early] Managed cluster should have same number of Machines and Nodes [apigroup:machine.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-network] Internal connectivity for TCP and UDP on ports 9000-9999 is allowed [Serial:Self] [Suite:openshift/conformance/parallel]"
"[sig-network] Networking Granular Checks: Services should function for endpoint-Service: http [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (OnRootMismatch)[LinuxOnly], pod created with an initial fsgroup, volume contents ownership changed via chgrp in first pod, new pod with different fsgroup applied to the volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should serve endpoints on same port and different protocol for internal traffic on Type LoadBalancer  [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-imageregistry][Feature:ImageLookup] Image policy should perform lookup when the object has the resolve-names annotation [apigroup:image.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-cli] oc annotate pod [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Netpol NetworkPolicy between server and client should enforce ingress policy allowing any port traffic to a server on a specific protocol [Feature:NetworkPolicy] [Feature:UDP] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-devex][Feature:Templates] templateinstance cross-namespace test should create and delete objects across namespaces [apigroup:user.openshift.io][apigroup:template.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-network] Services should complete a service status lifecycle [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Dynamic PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cluster-lifecycle] CSRs from machines that are not recognized by the cloud provider are not approved [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:LDAP] LDAP should start an OpenLDAP test server [apigroup:user.openshift.io][apigroup:security.openshift.io][apigroup:authorization.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-cli] oc debug deployment configs from a build [apigroup:image.openshift.io][apigroup:apps.openshift.io] [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, volume contents ownership changed via chgrp in first pod, new pod with same fsgroup applied to the volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] templates different namespaces [apigroup:user.openshift.io][apigroup:project.openshift.io][apigroup:template.openshift.io][apigroup:authorization.openshift.io][Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] subPath should be able to unmount after the subpath directory is deleted [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth][Feature:OAuthServer] OAuth server has the correct token and certificate fallback semantics [apigroup:user.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-node] Security Context should support container.SecurityContext.RunAsUser [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.18)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directories when readOnly specified in the volumeSource [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl version should check is all data is printed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc debug dissect deployment config debug [apigroup:apps.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Ingress API should support creating Ingress API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support readOnly directory specified in the volumeMount [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 A set of valid responses are returned for both pod and service Proxy [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should create read-only inline ephemeral volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, new pod fsgroup applied to volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context should support seccomp unconfined on the pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart http hook properly [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf,application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directory [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.19)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directories when readOnly specified in the volumeSource [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl version should check is all data is printed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc debug dissect deployment config debug [apigroup:apps.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Ingress API should support creating Ingress API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support readOnly directory specified in the volumeMount [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 A set of valid responses are returned for both pod and service Proxy [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should create read-only inline ephemeral volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, new pod fsgroup applied to volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context should support seccomp unconfined on the pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart http hook properly [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf,application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directory [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.20)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directories when readOnly specified in the volumeSource [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl version should check is all data is printed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc debug dissect deployment config debug [apigroup:apps.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Ingress API should support creating Ingress API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support readOnly directory specified in the volumeMount [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 A set of valid responses are returned for both pod and service Proxy [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should create read-only inline ephemeral volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, new pod fsgroup applied to volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context should support seccomp unconfined on the pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart http hook properly [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf,application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directory [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.21)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directories when readOnly specified in the volumeSource [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl version should check is all data is printed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc debug dissect deployment config debug [apigroup:apps.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Ingress API should support creating Ingress API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support readOnly directory specified in the volumeMount [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 A set of valid responses are returned for both pod and service Proxy [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should create read-only inline ephemeral volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, new pod fsgroup applied to volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context should support seccomp unconfined on the pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart http hook properly [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf,application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directory [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  4.22)
    TESTS_LIST=$(cat <<EOF
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directories when readOnly specified in the volumeSource [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl version should check is all data is printed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc debug dissect deployment config debug [apigroup:apps.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: azure-file] [Testpattern: Dynamic PV (default fs)] subPath should support non-existent path [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Ingress API should support creating Ingress API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support readOnly directory specified in the volumeMount [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 A set of valid responses are returned for both pod and service Proxy [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Generic Ephemeral-volume (default fs) (late-binding)] ephemeral should create read-only inline ephemeral volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] fsgroupchangepolicy (Always)[LinuxOnly], pod created with an initial fsgroup, new pod fsgroup applied to volume contents [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Security Context should support seccomp unconfined on the pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Dynamic PV (delayed binding)] topology should fail to schedule a pod which has topologies that conflict with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Container Lifecycle Hook when create a pod with lifecycle hook should execute poststart http hook properly [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf,application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (default fs)] subPath should support existing directory [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
    )
    ;;
  *)
    echo "Error: Unsupported T5CI_VERSION."
    exit 1
    ;;
esac

echo "$TESTS_LIST" > "$ARTIFACT_DIR/tests-run.txt"
TEST_FILE=tests-run.txt
echo "TESTS_LIST written to $ARTIFACT_DIR/tests-run.txt"

IFS=- read -r CLUSTER_NAME _ <<< "$(cat "${SHARED_DIR}/cluster_name")"

cat << EOF > run-openshift-tests.yml
---
- name: Run OpenShift's conformance test suite
  hosts: hypervisor
  gather_facts: false
  any_errors_fatal: true

  tasks:
  - name: Copy OpenShift's conformance test suite through hypervisor to installer, run it and retrieve results
    block:
    - name: Create script on hypervisor to run openshift-tests binary on installer
      ansible.builtin.copy:
        content: |
          #!/bin/bash

          set -o nounset
          set -o errexit
          set -o pipefail

          export KUBECONFIG=/root/ocp/auth/kubeconfig

          openshift-tests run "${TEST_SUITE}" \\
            --provider '${TEST_PROVIDER}' \\
            -o e2e.log --junit-dir junit --file /root/tests.txt \\
            > openshift-tests.log
        dest: '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh'
        mode: 0755

    - name: Copy script from hypervisor to artifacts directory
      ansible.builtin.fetch:
        src: '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh'
        dest: '${ARTIFACT_DIR}/run-openshift-tests.sh'
        flat: true

    - name: Copy openshift-tests binary to hypervisor
      ansible.builtin.copy:
        src: '${PWD}/openshift-tests'
        dest: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests'

    - name: Copy list of tests to hypervisor
      ansible.builtin.copy:
        src: '${ARTIFACT_DIR}/${TEST_FILE}'
        dest: '/tmp/kcli_${CLUSTER_NAME}_${TEST_FILE}'

    - name: Copy script to run openshift-tests binary to installer
      ansible.builtin.shell:
        cmd: |
          kcli scp '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh' \\
            'root@${CLUSTER_NAME}-installer:/usr/local/bin/run-openshift-tests.sh' \\
          && kcli ssh 'root@${CLUSTER_NAME}-installer' 'chmod a+x /usr/local/bin/run-openshift-tests.sh'

    - name: Copy openshift-tests binary to installer
      ansible.builtin.shell:
        cmd: |
          kcli scp '/tmp/kcli_${CLUSTER_NAME}_openshift-tests' \\
            'root@${CLUSTER_NAME}-installer:/usr/local/bin/openshift-tests' \\
          && kcli ssh 'root@${CLUSTER_NAME}-installer' 'chmod a+x /usr/local/bin/openshift-tests'

    - name: Copy list of tests to installer
      ansible.builtin.shell:
        cmd: |
          kcli scp '/tmp/kcli_${CLUSTER_NAME}_${TEST_FILE}' \\
            'root@${CLUSTER_NAME}-installer:/root/tests.txt' \\

    - name: Test kubeconfig on installer
      ansible.builtin.shell:
        cmd: |
          kcli ssh 'root@${CLUSTER_NAME}-installer' "sh -c 'export KUBECONFIG=/root/ocp/auth/kubeconfig && oc get nodes'"

    - name: Run script for openshift-tests binary on installer
      ansible.builtin.shell:
        cmd: |
          kcli ssh 'root@${CLUSTER_NAME}-installer' "run-openshift-tests.sh || true"

    - name: Compress results from openshift-tests binary on installer
      ansible.builtin.shell:
        cmd: |
          kcli ssh 'root@${CLUSTER_NAME}-installer' \\
            "tar -czf openshift-tests.tar.gz e2e.log junit/ openshift-tests.log || { rm -f openshift-tests.tar.gz; exit 1; }"

    - name: Copy results from installer to hypervisor
      ansible.builtin.shell:
        cmd: |
          kcli scp 'root@${CLUSTER_NAME}-installer:/root/openshift-tests.tar.gz' \\
            '/tmp/kcli_${CLUSTER_NAME}_openshift-tests.tar.gz'

    - name: Copy results from hypervisor to artifacts directory
      ansible.builtin.fetch:
        src: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests.tar.gz'
        dest: '${ARTIFACT_DIR}/openshift-tests.tar.gz'
        flat: true

    always:
    - name: Remove script to run openshift-tests binary from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh'
        state: absent
      ignore_errors: true

    - name: Remove openshift-tests binary from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests'
        state: absent
      ignore_errors: true

    - name: Remove list of tests from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_${TEST_FILE}'
        state: absent
      ignore_errors: true

    - name: Remove openshift-tests results from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests.tar.gz'
        state: absent
      ignore_errors: true
EOF

# Run OpenShift's conformance test suite
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i "$SHARED_DIR/inventory" run-openshift-tests.yml -vv

cd "$ARTIFACT_DIR"
tar -xf openshift-tests.tar.gz
rm openshift-tests.tar.gz

cd junit/
for f in test-failures-summary_*.json; do
    if [ -e "$f" ]; then
        ln -s "$f" test-failures-summary.json
        break
    fi
done
