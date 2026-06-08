# Managed cluster Install via ACM

## What this step does ?

Assumes an ACM hub is already reachable

1. Creates a namespace same as clustername, reates ManagedClusterSet  in the same namepsace , and create ManagedClusterSetBinding for the namespace. For any cluster set created , namespace binding is required so that namespace is recongnised or discoverable by that clusterset.

2. It reads aws platform secrets from cluster profile and creates new secret on the ACM hub cluster and make discoverable for ACM by adding relevant labels. 

    oc label secret <secret-name> \
       cluster.open-cluster-management.io/type=aws \
       cluster.open-cluster-management.io/credentials="" \
       -n <namepsace>

3. reates a install-config and install config secret which is referenced by the ClusterDeployment

4. Creates ClusterDeployment resource to install a managed cluster

5. Creates ManagedCluster resource to make sure the cluster is registered in ACM as managed cluster

5. Wait for the ClusterDeployment state to be in Running status

6. Saves kubeconfig in location managed-cluster-kubeconfig file inside shared directory, so it can be used by other steps in the workflow
