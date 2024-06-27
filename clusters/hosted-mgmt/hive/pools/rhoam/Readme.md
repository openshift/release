# RHOAM cluster pool

This folder contains the manifests for RHOAM cluster pool created by Hive. [Hive](https://github.com/openshift/hive) is used as ClusterPool API to manage clusters for CI tests.

## Pool Template for RHOAM

[AWS - us-east-2](install-config-aws-us-east-2_secret.yaml) is used for [E2E Tests](https://github.com/integr8ly/integreatly-operator/tree/master/test/e2e).

## How to use RHOAM Cluster Pool in your tests?

Add the claim to your configuration following [e2e config](ci-operator/config/integr8ly/integreatly-operator/integr8ly-integreatly-operator-master.yaml) example:

```yaml
- as: rhoam-e2e
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: rhoam
    product: ocp
    # time to wait for a cluster from the pool
    timeout: 1h0m0s
    version: "4.14"
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
