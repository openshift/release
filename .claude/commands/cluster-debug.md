---
name: cluster-debug
description: Help debug OpenShift CI clusters, access cluster information, and troubleshoot cluster issues
parameters:
  - name: action
    description: Action to perform - "info", "access", "pods", "nodes", "operators", "logs", "events", "etcd", "upgrade", "clusterpool", or "help" (default: help)
    required: false
  - name: cluster_name
    description: Name of the cluster (e.g., "app.ci", "build01", "build02", "vsphere02")
    required: false
  - name: namespace
    description: Optional namespace to focus on (e.g., "ci", "ocp", "openshift-prow")
    required: false
---
⚠️ **IMPORTANT**: Cluster debugging is infrastructure-related and requires admin access. Only authorized administrators should perform cluster debugging operations.

You are helping users debug OpenShift CI clusters and access cluster information.

## Context

OpenShift CI uses multiple clusters:
- **app.ci**: Main CI control plane (runs Prow components)
- **build01-11**: AWS build clusters for job execution
- **build02, build04, build08**: GCP build clusters
- **vsphere02**: vSphere build cluster
- **core-ci, hosted-mgmt**: Other specialized clusters

Cluster API endpoint patterns:
- **AWS clusters**: `https://api.<cluster-name>.ci.devcluster.openshift.com:6443` (e.g., build01, build03, build05-07, build09-11)
- **GCP clusters**: `https://api.<cluster-name>.gcp.ci.openshift.org:6443` (e.g., build02, build04, build08)
- **app.ci**: `https://api.ci.l2s4.p1.openshiftapps.com:6443`
- **vSphere**: `https://api.build02.vmc.ci.openshift.org:6443`

## Your Task

Based on the user's request: action="{{action}}"{{#if cluster_name}}, cluster="{{cluster_name}}"{{/if}}{{#if namespace}}, namespace="{{namespace}}"{{/if}}

1. **Provide guidance** based on the action:

   **info** - Get cluster information:
   - Cluster API endpoint
   - Cluster capabilities and features
   - Cluster status and health
   - Namespace information
   - Access methods

   **access** - Help access a cluster:
   - How to get kubeconfig
   - Authentication methods
   - Context switching
   - RBAC requirements

   **pods** - Debug pod issues:
   - List pods in namespace
   - Pod status and conditions
   - Pod logs access
   - Pod events
   - Resource usage

   **nodes** - Debug node issues:
   - Node status and conditions
   - Node resources
   - Node labels and taints
   - Machine information

   **operators** - Check cluster operators:
   - ClusterOperator status
   - Operator health
   - Operator logs
   - Degraded conditions

   **logs** - Access logs:
   - Pod logs
   - Operator logs
   - Node logs
   - Event logs

   **events** - Check cluster events:
   - Recent events
   - Event filtering
   - Warning/error events

   **etcd** - Debug etcd issues:
   - etcd pod status and health
   - etcd endpoint status
   - etcd database size and fragmentation
   - etcd compaction and defragmentation
   - etcd member communication issues

   **upgrade** - Monitor cluster upgrades:
   - Check upgrade status with `oc adm upgrade status`
   - Verify upgrade prerequisites
   - Monitor upgrade progress
   - Check upgrade history

   **clusterpool** - Debug cluster pools (hosted-mgmt cluster):
   - List cluster pools
   - Check cluster pool status
   - Check cluster claims
   - Check cluster deployments
   - Debug blocked deprovisioning
   - Find pool owners and configuration

   **help** - General help:
   - Available clusters
   - Common debugging tasks
   - Useful commands

2. **Common Cluster Information**:

   **app.ci**:
   - Endpoint: `https://api.ci.l2s4.p1.openshiftapps.com:6443`
   - Purpose: Main CI control plane
   - Namespaces: `ci`, `openshift-prow`, `openshift-monitoring`

   **build01** (AWS):
   - Endpoint: `https://api.build01.ci.devcluster.openshift.com:6443`
   - Capabilities: arm64, gpu, build-tmpfs, highperf, rce, sshd-bastion
   - Namespaces: `ci`, `ocp`

   **build02** (GCP):
   - Endpoint: `https://api.build02.gcp.ci.openshift.org:6443`
   - Capabilities: gpu, kvm, nested-podman
   
   **build04** (GCP):
   - Endpoint: `https://api.build04.gcp.ci.openshift.org:6443`
   - Capabilities: gpu, kvm, rce
   
   **build08** (GCP):
   - Endpoint: `https://api.build08.gcp.ci.openshift.org:6443`
   - Capabilities: gpu, kvm

   **hosted-mgmt**:
   - Purpose: Manages cluster pools via Hive
   - Namespaces: Various cluster pool namespaces (e.g., `ci-cluster-pool`, `openshift-observability-cluster-pool`)
   - Resources: ClusterPool, ClusterClaim, ClusterDeployment

3. **Key Commands**:

   **Cluster Access**:
   ```bash
   # List available contexts
   oc config get-contexts
   
   # Switch to cluster
   oc config use-context <cluster-name>
   
   # Get cluster info
   oc cluster-info
   ```

   **Pod Debugging**:
   ```bash
   # List pods
   oc get pods -n <namespace>
   
   # Pod details
   oc describe pod <pod-name> -n <namespace>
   
   # Pod logs
   oc logs <pod-name> -n <namespace>
   oc logs <pod-name> -n <namespace> --previous  # Previous container
   ```

   **Node Debugging**:
   ```bash
   # List nodes
   oc get nodes
   
   # Node details
   oc describe node <node-name>
   
   # Node resources
   oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory
   ```

   **Operator Debugging**:
   ```bash
   # Cluster operators
   oc get clusteroperators
   
   # Operator details
   oc get clusteroperator <operator-name> -o yaml
   
   # Operator conditions
   oc get clusteroperator <operator-name> -o jsonpath='{.status.conditions}'
   ```

   **Events**:
   ```bash
   # Recent events
   oc get events -n <namespace> --sort-by='.lastTimestamp'
   
   # Warning/error events
   oc get events -n <namespace> --field-selector type=Warning
   ```

   **etcd Debugging**:
   ```bash
   # Check etcd pods
   oc get pods -n openshift-etcd
   
   # Check etcd endpoint status
   oc -n openshift-etcd exec etcd-<master-node> -- etcdctl endpoint status --write-out=table
   
   # Check etcd health
   oc -n openshift-etcd exec etcd-<master-node> -- etcdctl endpoint health --cluster
   
   # Check etcd database size and fragmentation
   oc -n openshift-etcd exec etcd-<master-node> -- sh -c 'unset ETCDCTL_ENDPOINTS && etcdctl endpoint status --write-out=table'
   
   # Get etcd revision for compaction
   oc -n openshift-etcd exec etcd-<master-node> -- sh -c 'unset ETCDCTL_ENDPOINTS && etcdctl endpoint status --write-out fields' | grep Revision
   
   # Compact etcd (requires revision number)
   oc -n openshift-etcd exec etcd-<master-node> -- sh -c 'unset ETCDCTL_ENDPOINTS && etcdctl compact <revision>'
   
   # Defragment etcd (run after compaction)
   oc -n openshift-etcd exec etcd-<master-node> -- sh -c 'unset ETCDCTL_ENDPOINTS && etcdctl defrag --command-timeout 120s'
   
   # Check etcd member communication (from master node via SSH)
   # Requires SSH access to master node
   sudo -i
   ETCD=$(crictl ps --label io.kubernetes.container.name=etcd --quiet)
   crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
   ```

   **Upgrade Monitoring**:
   ```bash
   # Prerequisites: Must be cluster-admin
   oc auth can-i '*' '*' --all-namespaces
   
   # Check upgrade status (requires cluster-admin)
   oc adm upgrade status
   
   # Check upgrade history
   oc adm upgrade history
   
   # Check cluster version
   oc get clusterversion version
   
   # Check cluster version details
   oc get clusterversion version -o yaml
   
   # Check available updates
   oc adm upgrade --help
   ```

   **Cluster Pool Debugging (hosted-mgmt)**:
   ```bash
   # Switch to hosted-mgmt context
   oc config use-context hosted-mgmt
   
   # List all cluster pools
   oc get clusterpool -A
   
   # Get cluster pool details
   oc get clusterpool <pool-name> -n <namespace> -o yaml
   
   # Check cluster pool status
   oc get clusterpool <pool-name> -n <namespace> -o jsonpath='{.status}'
   
   # List cluster claims
   oc get clusterclaim -A
   
   # Get cluster claim details
   oc get clusterclaim <claim-name> -n <namespace> -o yaml
   
   # Check which pool a claim belongs to
   oc get clusterclaim <claim-name> -n <namespace> -o jsonpath='{.spec.clusterPoolName}'
   
   # List cluster deployments
   oc get clusterdeployment -A
   
   # Get cluster deployment details
   oc get clusterdeployment <deployment-name> -n <namespace> -o yaml
   
   # Find pool reference for a cluster deployment
   oc get clusterdeployment <deployment-name> -n <namespace> -o jsonpath='{.spec.clusterPoolRef}'
   
   # Check cluster deployment conditions
   oc get clusterdeployment <deployment-name> -n <namespace> -o jsonpath='{.status.conditions}'
   
   # Find job that claimed a cluster (from claim labels)
   oc get clusterclaim <claim-name> -n <namespace> --show-labels
   
   # Check for zombie cluster pools (not in config)
   # Compare configured pools with existing pools
   find clusters/hosted-mgmt/hive/pools -name '*.yaml' | xargs grep 'kind: ClusterPool'
   oc --context hosted-mgmt get clusterpool -A
   ```

4. **Common Debugging Scenarios**:

   **Job Pod Stuck**:
   - Check pod status: `oc get pod <pod-name> -n ci`
   - Check events: `oc get events -n ci --field-selector involvedObject.name=<pod-name>`
   - Check node: `oc describe node <node-name>`
   - Check logs: `oc logs <pod-name> -n ci`

   **Cluster Operator Degraded**:
   - Check operator: `oc get clusteroperator <operator-name>`
   - Check operator logs: `oc logs -n openshift-<operator> -l app=<operator>`
   - Check related resources

   **Node Not Ready**:
   - Check node: `oc describe node <node-name>`
   - Check node conditions: `oc get node <node-name> -o jsonpath='{.status.conditions}'`
   - Check machine: `oc get machines -n openshift-machine-api`

   **etcd Slowness/Issues**:
   - Check alerts: etcdMemberCommunicationSlow, etcdMembersDown, etcdNoLeader
   - Check etcd pod status: `oc get pods -n openshift-etcd`
   - Check etcd health: `oc -n openshift-etcd exec etcd-<node> -- etcdctl endpoint health --cluster`
   - Check database size: `oc -n openshift-etcd exec etcd-<node> -- etcdctl endpoint status --write-out=table`
   - If fragmented: Compact and defragment (see etcd debugging commands)
   - Note: May require SSH access to master nodes if API is unresponsive

   **Upgrade Issues**:
   - Verify prerequisites: `oc auth can-i '*' '*' --all-namespaces` (must return yes)
   - Check upgrade status: `oc adm upgrade status`
   - Check cluster operators: `oc get clusteroperators`
   - Check cluster version: `oc get clusterversion version`
   - Review upgrade history: `oc adm upgrade history`

   **Cluster Pool Issues (hosted-mgmt)**:
   - **Blocked Deprovision**: Check cluster deployment pool reference: `oc --context hosted-mgmt get clusterdeployment -n <ns> <name> -o jsonpath='{.spec.clusterPoolRef}'`
   - Find pool owners: Check `clusters/hosted-mgmt/hive/pools/` directory for pool configuration
   - Check claim status: `oc --context hosted-mgmt get clusterclaim -n <namespace> <claim-name>`
   - Check deployment status: `oc --context hosted-mgmt get clusterdeployment -n <namespace> <deployment-name>`
   - Find claiming job: `oc --context hosted-mgmt get clusterclaim <claim-name> -n <namespace> --show-labels | grep prow.k8s.io/job`
   - Common causes: Installer bugs (collect deprovision logs), cloud platform issues, test steps not cleaning up resources

5. **Cluster-Specific Information**:

   **Build Clusters**:
   - Primary namespaces: `ci`, `ocp`
   - Used for job execution
   - Check pod scheduling: `oc get pods -n ci -o wide`

   **app.ci**:
   - Prow components: `openshift-prow` namespace
   - CI services: `ci` namespace
   - Monitoring: `openshift-monitoring` namespace

   **hosted-mgmt**:
   - Cluster pools: Managed via Hive in `clusters/hosted-mgmt/hive/pools/`
   - Pool namespaces: Various (e.g., `ci-cluster-pool`, `openshift-observability-cluster-pool`)
   - Resources: ClusterPool, ClusterClaim, ClusterDeployment
   - Configuration: Pool manifests in `clusters/hosted-mgmt/hive/pools/<team>/`

## Important

- ⚠️ **Admin Access Required**: Cluster debugging is infrastructure-related and requires admin privileges. Only authorized administrators should perform these operations.
- **RBAC**: Ensure you have appropriate permissions before accessing clusters
- **Security**: Be careful when accessing production CI clusters
- **Documentation**: Refer to cluster-specific documentation in `clusters/` directory

## Example Output

**AWS Cluster (build01)**:
```
**Cluster**: build01 (AWS)
**Endpoint**: https://api.build01.ci.devcluster.openshift.com:6443
**Capabilities**: arm64, gpu, build-tmpfs, highperf, rce, sshd-bastion
```

**GCP Cluster (build02)**:
```
**Cluster**: build02 (GCP)
**Endpoint**: https://api.build02.gcp.ci.openshift.org:6443
**Capabilities**: gpu, kvm, nested-podman
```

**Cluster Pool Debugging (hosted-mgmt)**:
```
**Cluster**: hosted-mgmt
**Check Pool Status**:
oc --context hosted-mgmt get clusterpool -A
oc --context hosted-mgmt get clusterpool <pool-name> -n <namespace> -o yaml

**Check Claims**:
oc --context hosted-mgmt get clusterclaim -A
oc --context hosted-mgmt get clusterclaim <claim-name> -n <namespace> --show-labels

**Check Deployments**:
oc --context hosted-mgmt get clusterdeployment -A
oc --context hosted-mgmt get clusterdeployment <name> -n <namespace> -o jsonpath='{.spec.clusterPoolRef}'
```
```

Now help the user with: "{{action}}"{{#if cluster_name}} for cluster "{{cluster_name}}"{{/if}}{{#if namespace}} in namespace "{{namespace}}"{{/if}}

