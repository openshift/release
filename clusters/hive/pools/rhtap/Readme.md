# RHTAP cluster pools

This folder contains the manifests for RHTAP cluster pools created by Hive. [Hive](https://github.com/openshift/hive) is used as ClusterPool API to manage clusters for CI tests.

## Pools Templates for RHTAP

In RHTAP we have two different templates which install Openshift in different AWS regions:

* [Higher Tests Load - us-east-2](rhtap-aws-us-east-2.yaml): Mostly used for [Infra Deployments](https://github.com/redhat-appstudio/infra-deployments) and [E2E Tests](https://github.com/redhat-appstudio/e2e-tests) repos where we the tests load have a big impact.
* [Normal Tests Load - us-west-2](rhtap-aws-us-west-2.yaml): Recommended for RHTAP components like Application Service, SPI... etc due a lowest load impact of tests.

## How to use RHTAP Cluster Pools in your tests?

Once you select the pool template based on your component needs, it is time to add the claim to your config job.

In case you choose the template with **Higher Tests Load - us-west-2** add the claim to your configuration following [infra-deployments config](/ci-operator/config/redhat-appstudio/infra-deployments/redhat-appstudio-infra-deployments-main.yaml) example:

```yaml
- as: appstudio-e2e-tests
  cluster_claim:
    architecture: amd64
    cloud: aws
    labels:
      region: us-east-2
    owner: rhtap
    product: ocp
    # time to wait for a cluster from the pool
    timeout: 1h0m0s
    version: "4.12"
    .
    .
    .
```

In case you choose the template with **Normal Tests Load - us-west-2** add the claim to your configuration following [application service config](/ci-operator/config/redhat-appstudio/application-service/redhat-appstudio-application-service-main.yaml) example:

```yaml
- as: application-service-e2e
  cluster_claim:
    architecture: amd64
    cloud: aws
    labels:
      region: us-west-2
    owner: rhtap
    product: ocp
    # time to wait for a cluster from the pool
    timeout: 1h0m0s
    version: "4.12"
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

In case your team members need to debug [cluster installation](https://docs.ci.openshift.org/docs/how-tos/cluster-claim/#troubleshooting-cluster-pools) logs ask RHTAP QE team in slack to add you to **rhtap-cluster-pool** rover group. Once you get access to the group, login to hive cluster from the [list](https://docs.ci.openshift.org/docs/getting-started/useful-links/#clusters).
