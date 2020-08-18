#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e conf command ************"

# List of include cases

read -d '#' INCL << EOF
[sig-api-machinery] Watchers should be able to start watching from a specific resource version
[sig-api-machinery] Watchers should observe an object deletion if it stops meeting the requirements of the selector
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of different groups
[k8s.io] Probing container with readiness probe that fails should never be ready and never restart
[sig-apps] ReplicationController should surface a failure condition on a common issue like exceeded quota
[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] should include custom resource definition resources in discovery documents
[sig-node] ConfigMap should fail to create ConfigMap with empty key
[sig-apps] ReplicationController should release no longer matching pods
[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a pod.
[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] Simple CustomResourceDefinition creating/deleting custom resource definition objects works 
[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] custom resource defaulting for requests and from storage works
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] updates the published spec when one version gets renamed
[k8s.io] Kubelet when scheduling a busybox command that always fails in a pod should be possible to delete
[sig-api-machinery] Secrets should patch a secret 
[sig-auth] ServiceAccounts should allow opting out of API token automount 
[sig-network] Proxy version v1 should proxy logs on node with explicit kubelet port using proxy subresource 
[sig-cli] Kubectl client Kubectl api-versions should check if v1 is in available api versions 
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of same group but different versions
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD preserving unknown fields at the schema root
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] removes definition from spec when one version gets changed to not be served
[k8s.io] Lease lease API should be available
[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a secret.
[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a replication controller.
[sig-api-machinery] Secrets should fail to create secret due to empty secret key
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD without validation schema
[sig-cli] Kubectl client Kubectl version should check is all data is printed 
[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] Simple CustomResourceDefinition listing custom resource definition objects works
[sig-api-machinery] Garbage collector should delete RS created by deployment when not orphaning
[sig-api-machinery] Garbage collector should orphan pods created by rc if delete options say so
[sig-api-machinery] ResourceQuota should be able to update and delete ResourceQuota.
[sig-cli] Kubectl client Proxy server should support proxy with --port 0
[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a configMap.
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD with validation schema
[sig-network] Services should provide secure master service
[sig-api-machinery] Servers with support for Table transformation should return a 406 for a backend which does not implement metadata
[sig-api-machinery] Garbage collector should not be blocked by dependency circle
[sig-api-machinery] Watchers should receive events on concurrent watches in same order
[k8s.io] [sig-node] Pods Extended [k8s.io] Pods Set QOS Class should be set on Pods with matching resource requests and limits for memory and cpu 
[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a replica set.
[sig-api-machinery] CustomResourceDefinition Watch [Privileged:ClusterAdmin] CustomResourceDefinition Watch watch on custom resource definition objects
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for multiple CRDs of same group and version but different kinds
[sig-api-machinery] ResourceQuota should create a ResourceQuota and capture the life of a service.
[sig-api-machinery] Garbage collector should orphan RS created by deployment when deleteOptions.PropagationPolicy is Orphan 
[sig-network] Proxy version v1 should proxy logs on node using proxy subresource 
[sig-api-machinery] CustomResourceDefinition resources [Privileged:ClusterAdmin] Simple CustomResourceDefinition getting/updating/patching custom resource definition status sub-resource works 
[sig-api-machinery] Watchers should be able to restart watching from the last resource version observed by the previous watch
[sig-api-machinery] Garbage collector should delete pods created by rc when not orphaning
[sig-scheduling] LimitRange should create a LimitRange with defaults and ensure pod has those defaults applied.
[sig-api-machinery] Watchers should observe add, update, and delete watch notifications on configmaps
[sig-api-machinery] ResourceQuota should create a ResourceQuota and ensure its status is promptly calculated.
[sig-api-machinery] CustomResourcePublishOpenAPI [Privileged:ClusterAdmin] works for CRD preserving unknown fields in an embedded object
[sig-cli] Kubectl client Proxy server should support --unix-socket=/path 
[sig-network] Services should find a service from listing all namespaces
[sig-api-machinery] Garbage collector should keep the rc around until all its pods are deleted if the deleteOptions says so
[sig-api-machinery] ResourceQuota should verify ResourceQuota with best effort scope.
[sig-api-machinery] Garbage collector should not delete dependents that have both valid owner and owner that's waiting for dependents to be deleted
#
EOF

cat <(echo "$INCL") > "${SHARED_DIR}/test-list"

