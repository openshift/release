# OpenShift Observability Cluster Pool

This folder contains the manifests for OpenShift Observability cluster pools created by Hive. [Hive](https://github.com/openshift/hive) is used as ClusterPool API to manage clusters for CI tests.

## How to create a new Cluster Pool for your observability team?
Docs: https://docs.ci.openshift.org/docs/how-tos/cluster-claim/#create-a-manifest-for-your-cluster-pool

> Note:  The logging team has already implemented their pools and added installer credentials, meaning new teams can skip the steps: `Prepare Your Cloud Platform Credentials` and `Create a Directory...`

The cluster pools all live under the openshift-observability directory in hive config:  
https://github.com/openshift/release/tree/master/clusters/hosted-mgmt/hive/pools/openshift-observability

**1. Add a new ClusterPool manifest to the directory:** 

> Note:  
`spec.imageSetRef`: A reference to an existing ClusterImageSet in the cluster that determines the exact version of clusters created in the pool.
'ClusterImageSets' are cluster-scoped resources and their manifests are present in [clusters/hosted-mgmt/hive/pools](https://github.com/openshift/release/tree/master/clusters/hosted-mgmt/hive/pools) directory and are regularly bumped to most recent released OCP versions.
The value will be updated automatically if `version_*` labels are set.

Example ClusterPool manifest:
```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterPool
metadata:
  labels:
    architecture: amd64   # set according to the imageRef used
    cloud: aws    # set according to the imageRef used
    owner: obs-myteamname  # create your team name and add it here, ex: obs-logging
    product: ocp    # set according to the imageRef used
    region: us-east-1   # match install-config file
    version: "4.15"   # set according to the imageRef used
    version_lower: "4.15.0-0" # lower bound for automatically updated imageset
    version_upper: "4.16.0-0" # upper bound for automatically updated imageset
  name: obs-myteamname-ocp-4-15-amd64-aws-us-east-1   # must be unique and should describe your labels above
  namespace: openshift-observability-cluster-pool   # use this value 
spec:
  baseDomain: devobscluster.devcluster.openshift.com    # use this new base domain for all clusters, should match install-config
  hibernationConfig:
    resumeTimeout: 20m0s
  imageSetRef:
    name: ocp-release-4.15.12-x86-64-for-4.15.0-0-to-4.16.0-0  # will be automatically updated if `version_*` labels are set
  installAttemptsLimit: 1
  installConfigSecretTemplateRef:
    name: install-config-aws-us-east-1  # ref install-config file located in this directory
  labels:
    tp.openshift.io/owner: obs-teamname  # match team name above?
  platform:
    aws:
      credentialsSecretRef:
        name: aws-installer-credentials  # already configured in this namespace, use `aws-installer-credentials`
      region: us-east-1   # should match your label from above and match the region from the install config
  pullSecretRef:
    name: pull-secret   # set to `pull-secret`
  skipMachinePools: true
  size: 1     # the number of clusters that Hive should keep provisioned and waiting for use.
  maxSize: 10     # the maximum number of clusters that can exist at the same time.
```

**2. Create any necessary install-config file** or use an existing
https://docs.ci.openshift.org/docs/how-tos/cluster-claim/#create-a-manifest-for-your-install-config-template-secret

**3. Submit a PR to openshift/release**

Submit a PR to openshift/release with all your new manifests. After the PR merges, the manifests are committed to the cluster and Hive starts installing clusters for your pool.


## How to use Cluster Pool in your tests?

**1. Add the claim to your test configuration** at: https://github.com/openshift/release/tree/master/ci-operator/config  

The labels values will match default labels in our pool config:
`architecture`, `cloud`, `product`,`version`, and `owner`
> Notice the custom label `region` is matched by adding `labels.region`

Example job config:
```yaml
- as: example-e2e
  cluster_claim:
    architecture: amd64
    cloud: aws
    labels:
      region: us-east-1
    owner: obs-myteamname
    product: ocp
    timeout: 1h0m0s
    version: "4.15"
  steps:
      test:
      ...
      workflow: generic-claim # expose images, gather logs (https://steps.ci.openshift.org/workflow/generic-claim)  
...
```

**2. Update the jobs based on your new config**
As a final step before committing, run the following commands to update the jobs based on your new pool config:

```bash
# Sanitize the config file of your job
make ci-operator-config

# Create jobs based on current config
make jobs
```
**3. Submit a PR to openshift/release**

Submit a PR to openshift/release with all your new manifests. After the PR merges, the manifests are committed to the cluster and Hive starts installing clusters for your pool.


## Checking Status of Existing Cluster Pools
A table is provided here for checking status of pools:    https://docs.ci.openshift.org/docs/how-tos/cluster-claim/#existing-cluster-pools


## Accessing Cluster Installation logs

In order to debug [cluster installation](https://docs.ci.openshift.org/docs/how-tos/cluster-claim/#troubleshooting-cluster-pools) logs, login to hive cluster from the [list](https://docs.ci.openshift.org/docs/getting-started/useful-links/#clusters)

## OpenShift CI / Prow Support

OpenShift CI is handled by the Dev Productivity Test Platform team (DPTP).

[#forum-ocp-testplatform](https://redhat-internal.slack.com/archives/CBN38N3MW) Slack channel
