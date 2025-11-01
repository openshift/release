# Managed cluster Install via ACM

## What this step does ?

Assumes an ACM hub is already reachable

Creates a namespace same as clustername, reates ManagedClusterSet  in the same namepsace , and create ManagedClusterSetBinding for the namespace. For any cluster set created , namespace binding is required so that namespace is recongnised or discoverable by that clusterset.

It reads aws platform secrets from cluster profile and creates new secret on the ACM hub cluster and make discoverable for ACM by adding relevant labels. 

    oc label secret <secret-name> \
       cluster.open-cluster-management.io/type=aws \
       cluster.open-cluster-management.io/credentials="" \
       -n <namepsace>

Creates a install-config and install config secret which is referenced by the ClusterDeployment

Creates ClusterDeployment to install a managed cluster

    apiVersion: hive.openshift.io/v1
    kind: ClusterDeployment
    metadata:
    name: <cluster-name>
    namespace: <namespace> #same as cluster name
    labels:
        cloud: 'AWS'
        region: <aws-region>
        vendor: OpenShift
        cluster.open-cluster-management.io/clusterset: <managed-cluster-set>
    spec:
    baseDomain: <base-domain>
    clusterName: <cluster-name>
    controlPlaneConfig:
        servingCertificates: {}
    platform:
        aws:
            region: <aws-region>
            credentialsSecretRef:
                name: <aws-secret-name>
    pullSecretRef:
        name: pull-secret
    installAttemptsLimit: 1
    provisioning:
        installConfigSecretRef:
            name: <install-config-secret-name>
        releaseImage: <ocp-release-image>
        sshPrivateKeyRef:
            name: <ssh-private-key-secret-name>

Creates ManagedCluster resource to make sure the cluster is registered in ACM as managed cluster

    apiVersion: cluster.open-cluster-management.io/v1
    kind: ManagedCluster
    metadata:
    name: <cluster-name>
    labels:
        name: <cluster-name>
        cloud: Amazon
        region: <aws-region>
        vendor: OpenShift
        cluster.open-cluster-management.io/clusterset: <cluster-set>
    spec:
    hubAcceptsClient: true

Checks for cluster provison to show up, once detected it checks for cluster provisoining pod and stream logs from provisoinig pod.

Saves kubeconfig in location managed-cluster-kubeconfig file inside shared directory, so it can be used by other steps in the workflow
