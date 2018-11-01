# OKD CI Infrastructure Secrets

This document overviews the secrets that are available and the means by which
they should be deployed to the cluster.

## Secrets Listing

The following secrets exist in the `ci` Namespace and are used by the infra. If
a job is being written that should mount one of these, a CI administrator should
vet that interaction for correctness.

### Aggregate IaaS Secrets for use in Cluster Tests

A set of secrets exists that contain aggregated information for ease of mounting
into tests that are interacting with an IaaS hosted by a cloud. The following
secrets currently exist:


#### `cluster-secrets-aws`

|       Key        | Description |
| ---------------- | ----------- |
| `.awscred`       | Credentials for the AWS EC2 API. See the [upstream credentials doc](https://docs.aws.amazon.com/cli/latest/userguide/cli-multiple-profiles.html). |
| `pull-secret`    | Credentials for pulling tectonic images from Quay.  In future will be the credentials used for pulling openshift origin images from a protected repo. |
| `ssh-privatekey` | Private half of the SSH key, for connecting to AWS EC2 VMs. |
| `ssh-publickey`  | Public half of the SSH key, for connecting to AWS EC2 VMs. |

#### `cluster-secrets-gcp`

|        Key        | Description |
| ----------------- | ----------- |
| `gce.json`        | Credentials for the GCE API. See the [upstream credentials doc](https://cloud.google.com/docs/authentication/production). |
| `ops-mirror.pem`  | Credentials for pulling dependent RPMs necessary to install OpenShift. |
| `ssh-privatekey`  | Private half of the SSH key, for connecting to GCE VMs. |
| `ssh-publickey`   | Public half of the SSH key, for connecting to GCE VMs. |
| `telemeter-token` | Token to push telemetry data on CI clusters. |

#### `cluster-secrets-azure-file`

|       Key        | Description |
| ---------------- | ----------- |
| `secret`         | Credentials for the Azure API. See the [upstream credentials doc](https://docs.microsoft.com/en-us/rest/api/apimanagement/apimanagementrest/azure-api-management-rest-api-authentication). |
| `certs.yaml`     | TODO: @kargakis fill this in |
| `ssh-privatekey` | Private half of the SSH key, for connecting to Azure VMs. |

### GCE ServiceAccount Credentials

The following serviceaccounts have their credentials stored in secrets on the
cluster:

 - `aos-pubsub-subscriber`
 - `aos-serviceaccount`
 - `ci-vm-operator`
 - `gcs-publisher`
 - `jenkins-ci-provisioner`

For each serviceaccount, a secret named `gce-sa-credentials-${sa_name}` holds
the following fields:

|        Key         | Description |
| ------------------ | ----------- |
| `credentials.json` | Credentials for the GCE API. See the [upstream credentials doc](https://cloud.google.com/docs/authentication/production). |
| `ssh-privatekey`   | [OPTIONAL] Private half of the SSH key, for connecting to GCE VMs. |
| `ssh-publickey`    | [OPTIONAL] Public half of the SSH key, for connecting to GCE VMs. |

### GitHub Credentials

#### User Credentials

The following GitHub users have their credentials stored in secrets on the
cluster:

 - @openshift-bot
 - @openshift-build-robot
 - @openshift-cherrypick-robot
 - @openshift-ci-robot
 - @openshift-merge-robot
 - @openshift-publish-robot

For each user, a secret named `github-credentials-${username}` holds the
following fields:

|       Key        | Description |
| ---------------- | ----------- |
| `oauth`          | OAuth2 token for the GitHub API. See the [upstream credentials doc](https://developer.github.com/v3/#oauth2-token-sent-in-a-header). |
| `ssh-privatekey` | [OPTIONAL] Private half of the SSH key, for cloning over SSH. |

#### Miscellaneous GitHub Secrets

 - The `github-app-credentials` secret holds the client configuration for the Deck OAuth application in the `config.json` key.
 - The `github-webhook-credentials` secret holds the HMAC encryption secret for GitHub webhook delivery to `hook` in the `hmac` key.
 - The `github-deploymentconfig-trigger` secret holds the unique URL prefix for `DeploymentConfig` triggers from GitHub in the `WebHookSecretKey` key.

### Container Image Registry Credentials

The following registries have their credentials stored in secrets on the cluster:

 - docker.io
 - quay.io

For each, a `registry-pull-credentials-${registry_url}` secret holds the pull
credentials in the `config.json` key and a `registry-push-credentials-${registry_url}`
secret holds push credentials also in a `config.json` key.

### Jenkins Credentials

The following Jenkins masters have their credentials stored in secrets on the
cluster:

 - openshift-ci-robot@ci.dev.openshift.redhat.com
 - openshift-ci-robot@ci.openshift.redhat.com
 - katabuilder@kata-jenkins-ci.westus2.cloudapp.azure.com

For each master, the `jenkins-credentials-${master_url}` secret holds the
password for the Jenkins user in the `password` key. For the `ci.dev` master,
a client cert, key and CA cert are also present for client authentication.

## Secret Regeneration

In order to regenerate the secrets in the case of an emergency, a CI admin can
recreate all of the above secrets by running:

```
$ BW_SESSION="$( bw login username@company.com password --raw )" ci-operator/populate-secrets-from-bitwarden.sh
```

This requires the appropriate access in BitWarden and will create a new session
that can be closed with:

```
$ bw logout
```

## Secret Drift Detection

Before using the above script to write new secrets to the infrastructure's
namespace, check that the secrets you are about to populate match those that
are currently in use. This should always be the case unless someone has edited
secrets manually and not committed the changes to the script or to BitWarden.

To check for drift, use `oc get --export` and `diff`:

```
$ oc get secrets --selector=ci.openshift.io/managed=true --export -o yaml -n ci > prod.yaml
$ oc get secrets --selector=ci.openshift.io/managed=true --export -o yaml -n $TEST_NS > proposed.yaml
$ diff prod.yaml proposed.yaml
```