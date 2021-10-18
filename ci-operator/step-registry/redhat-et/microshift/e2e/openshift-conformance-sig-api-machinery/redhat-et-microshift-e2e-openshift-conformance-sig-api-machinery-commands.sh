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
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] listing mutating webhooks should work [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] listing validating webhooks should work [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] patching/updating a mutating webhook should work [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] patching/updating a validating webhook should work [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should be able to deny attaching pod [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should be able to deny custom resource creation, update and deletion [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should be able to deny pod and configmap creation [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should deny crd creation [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should honor timeout [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should include webhook resources in discovery documents [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate configmap [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate custom resource [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate custom resource with different stored version [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate custom resource with pruning [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate pod and apply defaults after mutation [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should not be able to mutate or prevent deletion of webhook configuration objects [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should unconditionally reject operations on fail closed webhook [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Aggregator Should be able to support the 1.17 Sample API Server using the current Aggregator [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] API priority and fairness should ensure that requests can be classified by adding FlowSchema and PriorityLevelConfiguration [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/json,application/vnd.kubernetes.protobuf\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf,application/json\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] client-go should negotiate watch and report errors with accept \"application/vnd.kubernetes.protobuf\" [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] CustomResourceConversionWebhook [Privileged:ClusterAdmin] should be able to convert a non homogeneous list of CRs [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceConversionWebhook [Privileged:ClusterAdmin] should be able to convert from CR v1 to CR v2 [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] custom resource defaulting for requests and from storage works  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] should include custom resource definition resources in discovery documents [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] Simple CustomResourceDefinition creating/deleting custom resource definition objects works  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] Simple CustomResourceDefinition getting/updating/patching custom resource definition status sub-resource works  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] Simple CustomResourceDefinition listing custom resource definition objects works  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourceDefinition Watch [Privileged:ClusterAdmin] CustomResourceDefinition Watch watch on custom resource definition objects [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] removes definition from spec when one version gets changed to not be served [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] updates the published spec when one version gets renamed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD preserving unknown fields at the schema root [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD preserving unknown fields in an embedded object [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD without validation schema [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD with validation schema [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of different groups [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of same group and version but different kinds [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of same group but different versions [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Discovery Custom resource should have storage version hash [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Discovery should validate PreferredVersion for each APIGroup [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Events should delete a collection of events [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Events should ensure that an event can be fetched, patched, deleted, and listed [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery][Feature:APIServer][Late] API LBs follow /readyz of kube-apiserver and don't send request early [Suite:openshift/conformance/parallel]"
"[sig-api-machinery][Feature:APIServer][Late] API LBs follow /readyz of kube-apiserver and stop sending requests [Suite:openshift/conformance/parallel]"
"[sig-api-machinery][Feature:APIServer][Late] kube-apiserver terminates within graceful termination period [Suite:openshift/conformance/parallel]"
"[sig-api-machinery][Feature:APIServer][Late] kubelet terminates kube-apiserver gracefully [Suite:openshift/conformance/parallel]"
"[sig-api-machinery][Feature:ServerSideApply] Server-Side Apply should work for image.openshift.io/v1, Resource=images [Suite:openshift/conformance/parallel]"
"[sig-api-machinery][Feature:ServerSideApply] Server-Side Apply should work for template.openshift.io/v1, Resource=brokertemplateinstances [Suite:openshift/conformance/parallel]"
"[sig-api-machinery] Garbage collector should delete jobs and pods created by cronjob [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should delete pods created by rc when not orphaning [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should delete RS created by deployment when not orphaning [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should keep the rc around until all its pods are deleted if the deleteOptions says so [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should not be blocked by dependency circle [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should not delete dependents that have both valid owner and owner that's waiting for dependents to be deleted [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should orphan pods created by rc if deleteOptions.OrphanDependents is nil [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should orphan pods created by rc if delete options say so [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should orphan RS created by deployment when deleteOptions.PropagationPolicy is Orphan [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should support cascading deletion of custom resources [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Garbage collector should support orphan deletion of custom resources [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Generated clientset should create pods, set the deletionTimestamp and deletionGracePeriodSeconds of the pod [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Generated clientset should create v1beta1 cronJobs, delete cronJobs, watch cronJobs [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] health handlers should contain necessary checks [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Namespaces [Serial] should always delete fast (ALL of 100 namespaces in 150 seconds) [Feature:ComprehensiveNamespaceDraining] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-api-machinery] Namespaces [Serial] should delete fast enough (90 percent of 100 namespaces in 150 seconds) [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-api-machinery] Namespaces [Serial] should ensure that all pods are removed when a namespace is deleted [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-api-machinery] Namespaces [Serial] should ensure that all services are removed when a namespace is deleted [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-api-machinery] Namespaces [Serial] should patch a Namespace [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's multiple priority class scope (quota set to pod count: 2) against 2 pods with same priority classes. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (cpu, memory quota set) against a pod with same priority class. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (quota set to pod count: 1) against 2 pods with different priority class. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (quota set to pod count: 1) against 2 pods with same priority class. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (quota set to pod count: 1) against a pod with different priority class (ScopeSelectorOpExists). [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (quota set to pod count: 1) against a pod with different priority class (ScopeSelectorOpNotIn). [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:PodPriority] should verify ResourceQuota's priority class scope (quota set to pod count: 1) against a pod with same priority class. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:ScopeSelectors] should verify ResourceQuota with best effort scope using scope-selectors. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota [Feature:ScopeSelectors] should verify ResourceQuota with terminating scopes through scope selectors. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should be able to update and delete ResourceQuota. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a configMap. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a custom resource. [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a persistent volume claim. [sig-storage] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a persistent volume claim with a storage class. [sig-storage] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a pod. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a replica set. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a replication controller. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a secret. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a service. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should create a ResourceQuota and ensure its status is promptly calculated. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should verify ResourceQuota with best effort scope. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] ResourceQuota should verify ResourceQuota with terminating scopes. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Secrets should be consumable from pods in env vars [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Secrets should be consumable via the environment [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Secrets should fail to create secret due to empty secret key [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Secrets should patch a secret [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Server request timeout default timeout should be used if the specified timeout in the request URL is 0s [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Server request timeout the request should be served with a default timeout if the specified timeout in the request URL exceeds maximum allowed [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Servers with support for API chunking should return chunks of results for list calls [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Servers with support for Table transformation should return a 406 for a backend which does not implement metadata [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Servers with support for Table transformation should return chunks of table results for list calls [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Servers with support for Table transformation should return generic metadata details across all namespaces for nodes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] Servers with support for Table transformation should return pod details [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-api-machinery] server version should find the server version [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Watchers should be able to restart watching from the last resource version observed by the previous watch [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Watchers should be able to start watching from a specific resource version [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Watchers should observe add, update, and delete watch notifications on configmaps [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Watchers should observe an object deletion if it stops meeting the requirements of the selector [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-api-machinery] Watchers should receive events on concurrent watches in same order [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

