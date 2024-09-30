# Multirch cluster pool

This folder contains the manifests for Multirch cluster pool created by Hive. [Hive](https://github.com/openshift/hive) is used as ClusterPool API to manage clusters for CI tests.

## Pool Template for Multiarch

[AWS - us-east-1](install-config-aws-us-east-1_secret.yaml) is used for [E2E Tests](https://github.com/openshift/multiarch-tuning-operator).

## How to use Multiarch Cluster Pool in your tests?

Add the claim to your configuration following example:

```yaml
- as: multiarch-e2e
  cluster_claim:
    architecture: multiarch
    cloud: aws
    owner: multiarch-ci
    product: ocp
    # time to wait for a cluster from the pool
    timeout: 1h0m0s
    version: "4.17"
    .
    .
    .
```

As a final step run the following commands to update the jobs based on your new pool config:

```bash
# Sanitize the config file of your job
make ci-operator-config

# Create jobs based on current config
make jobs
```

## Accessing Cluster Installation logs

In order to debug [cluster installation](https://docs.ci.openshift.org/docs/how-tos/cluster-claim/#troubleshooting-cluster-pools) logs, login to hive cluster from the [list](https://docs.ci.openshift.org/docs/getting-started/useful-links/#clusters).
