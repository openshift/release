#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetalds assisted test command ************"

if [ "${TEST_TYPE:-list}" == "none" ]; then
    echo "No need to run tests"
    exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

collect_artifacts() {
    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT TERM

# Tests execution
set +e

if [ ${TEST_LIST} == "" ]; then 
    read -d '#' TEST_LIST << EOF
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
[sig-apps] CronJob [Top Level] [sig-apps] CronJob should delete failed finished jobs with limit of one job
[sig-apps] CronJob [Top Level] [sig-apps] CronJob should delete successful finished jobs with limit of one successful job
[sig-apps] CronJob [Top Level] [sig-apps] CronJob should not emit unexpected warnings
[sig-apps] CronJob [Top Level] [sig-apps] CronJob should remove from active list jobs that have been deleted
[sig-apps] CronJob [Top Level] [sig-apps] CronJob should replace jobs when ReplaceConcurrent
[sig-apps] CronJob [Top Level] [sig-apps] CronJob should schedule multiple jobs concurrently
[sig-apps] Deployment [Top Level] [sig-apps] Deployment RecreateDeployment should delete old pods and create new ones
[sig-apps] Deployment [Top Level] [sig-apps] Deployment RollingUpdateDeployment should delete old pods and create new ones
[sig-apps] Deployment [Top Level] [sig-apps] Deployment deployment reaping should cascade to its replica sets and pods
[sig-apps] Deployment [Top Level] [sig-apps] Deployment deployment should delete old replica sets
[sig-apps] Deployment [Top Level] [sig-apps] Deployment deployment should support proportional scaling
[sig-apps] Deployment [Top Level] [sig-apps] Deployment deployment should support rollover
[sig-apps] Deployment [Top Level] [sig-apps] Deployment iterative rollouts should eventually progress
[sig-apps] Deployment [Top Level] [sig-apps] Deployment should not disrupt a cloud load-balancer's connectivity during rollout
[sig-apps] Deployment [Top Level] [sig-apps] Deployment test Deployment ReplicaSet orphaning and adoption regarding controllerRef
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: enough pods, absolute => should allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: enough pods, replicaSet, percentage => should allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: maxUnavailable allow single eviction, percentage => should allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: maxUnavailable deny evictions, integer => should not allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: no PDB => should allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: too few pods, absolute => should not allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController evictions: too few pods, replicaSet, percentage => should not allow an eviction
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController should block an eviction until the PDB is updated to allow it
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController should create a PodDisruptionBudget
[sig-apps] DisruptionController [Top Level] [sig-apps] DisruptionController should update PodDisruptionBudget status
[sig-apps] Job [Top Level] [sig-apps] Job should adopt matching orphans and release non-matching pods
[sig-apps] Job [Top Level] [sig-apps] Job should delete a job
[sig-apps] Job [Top Level] [sig-apps] Job should fail to exceed backoffLimit
[sig-apps] Job [Top Level] [sig-apps] Job should fail when exceeds active deadline
[sig-apps] Job [Top Level] [sig-apps] Job should remove pods when job is deleted
[sig-apps] Job [Top Level] [sig-apps] Job should run a job to completion when tasks sometimes fail and are locally restarted
[sig-apps] Job [Top Level] [sig-apps] Job should run a job to completion when tasks succeed
[sig-apps] ReplicaSet [Top Level] [sig-apps] ReplicaSet should adopt matching pods on creation and release no longer matching pods
[sig-apps] ReplicaSet [Top Level] [sig-apps] ReplicaSet should serve a basic image on each replica with a private image
[sig-apps] ReplicaSet [Top Level] [sig-apps] ReplicaSet should serve a basic image on each replica with a public image
[sig-apps] ReplicaSet [Top Level] [sig-apps] ReplicaSet should surface a failure condition on a common issue like exceeded quota
[sig-apps] ReplicationController [Top Level] [sig-apps] ReplicationController should adopt matching pods on creation
[sig-apps] ReplicationController [Top Level] [sig-apps] ReplicationController should release no longer matching pods
[sig-apps] ReplicationController [Top Level] [sig-apps] ReplicationController should serve a basic image on each replica with a private image
[sig-apps] ReplicationController [Top Level] [sig-apps] ReplicationController should serve a basic image on each replica with a public image
[sig-apps] ReplicationController [Top Level] [sig-apps] ReplicationController should surface a failure condition on a common issue like exceeded quota
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] Should recreate evicted statefulset
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should adopt matching orphans and release non-matching pods
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should have a working scale subresource
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should implement legacy replacement when the update strategy is OnDelete
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should not deadlock when a pod's predecessor fails
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should perform canary updates and phased rolling updates of template modifications
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should perform rolling updates and roll backs of template modifications
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should perform rolling updates and roll backs of template modifications with PVCs
[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] [Top Level] [sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should provide basic identity
#
EOF
fi

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash -s "${OPENSHIFT_TESTS_IMAGE}" "${TEST_TYPE:-list}" "${TEST_SUITE:-:openshift/conformance/parallel}" "${TEST_LIST:-''}" "${TEST_PROVIDER:-baremetal}" "${TEST_SKIPS}" << "EOF"
    set -x

    openshift_tests_image="$1"
    test_type="$2"
    test_suite="$3"
    test_list="$4"
    test_provider="$5"
    test_skips="$6"

    function get_baremetal_test_list() {
        podman run --network host --rm -i \
            -e KUBECONFIG=/tmp/kubeconfig -v ${KUBECONFIG}:/tmp/kubeconfig $1 \
            openshift-tests run $2 \
            --dry-run \
            --provider "{\"type\": \"$3\"}"
    }

    function run_tests() {
        podman run --network host --rm -i -v /tmp:/tmp -e KUBECONFIG=/tmp/kubeconfig -v ${kubeconfig}:/tmp/kubeconfig $1 \
            openshift-tests run -o /tmp/artifacts/e2e_${name}.log --junit-dir /tmp/artifacts/reports --file $2
    }
    
    # prepending each printed line with a timestamp
    exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

    for kubeconfig in $(find ${KUBECONFIG} -type f); do
        export KUBECONFIG=${kubeconfig}
        name=$(basename ${kubeconfig})

        case $test_type in
            suite)
                test_list="$(get_baremetal_test_list $openshift_tests_image $test_suite $test_provider)"
                ;;
            list)
                ;;
            *)
                echo >&2 "Unsupported TEST_TYPE: $test_type"
                exit 1
                ;;
        esac

        echo "$test_list" | grep -v "${TEST_SKIPS}" > /tmp/test-list

        stderr=$( { run_tests $openshift_tests_image "/tmp/test-list"; } 2>&1 )
        exit_code=$?
        
        # TODO: remove this part once we fully handle the problem described at
        # https://issues.redhat.com/browse/MGMT-15555.
        # After 'openshift-tests' finishes validating the tests, it checks
        # the extra monitoring tests, so the following line only excludes those
        # kind of failures (rather than excluding all runs where the monitoring
        # tests have failed).
        if [[ "${stderr}" == *"failed due to a MonitorTest failure" ]]; then
            continue
        fi

        if [[ ${exit_code} -ne 0 ]]; then
            exit ${exit_code}
        fi
    done
EOF


exit_code=$?

set -e
echo "### Done! (${exit_code})"
exit $exit_code
