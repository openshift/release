# Rotate Service Account Tokens

The Kubernetes community considers [bound service account tokens](https://github.com/kubernetes/enhancements/tree/master/keps/sig-auth/1205-bound-service-account-tokens) as best practice although [non-expiring ones](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#manually-create-a-service-account-api-token) are still supported. 

## Prow Components and CI-Tools
Bound SA tokens are used for Prow components and ci-tools except the following cases in the next section.
Each SA's token is created by `prowjob/periodic-ci-secret-generator` and bound to the same object `secret/token-bound-object-{0|1}` in the same namespace.
To expire the tokens,

- Bind all tokens to the other secret in [the generator's configuration file](../../core-services/ci-secret-generator/_config.yaml), e.g., bind to `secret/token-bound-object-1` if `secret/token-bound-object-0` currently. Create a PR and Merge it.

- Trigger `prowjob/periodic-ci-secret-generator` to generator the tokens bound to the new secret.

> make job JOB=periodic-ci-secret-generator

- Delete the secret that the old tokens were previously bound to. It will expire the old tokens. Since the old [secret's manifests](../../clusters/build-clusters/common/assets/bound-object_secrets.yaml) is still in the release repo, it will be created with a new uid and to be prepared the next rotation.

```console
oc --context ${CLUSTER} delete secret -A -l ci.openshift.io/token-bound-object=$(TOKEN_BOUND_OBJECT_NAME_SUFFIX)  --dry-run=none --as system:admin
```

## Non-Expiring Tokens
We use non-expiring tokens [DPTP-3087](https://issues.redhat.com/browse/DPTP-3087) in the following cases:

- config-updater: Their kubeconfigs are used to manage manifests on all clusters, including the secrets of kubeconfigs for other service accounts. We break the checken-and-egg issue this way.
- The kubeconfigs that are used by the `cronjobs` on the `psi` clusters to communicate with the clusters in CI production. The secrets on `psi` are not managed by our tools because it is inside Red Hat Intranet.

The version of Non-Expiring Tokens is configured in [_token.yaml](../../hack/_token.yaml).
Before generating new tokens for those service accounts which use non-expiring tokens, we have to bump the token version there:

```console
# need to install yq https://github.com/kislyuk/yq
$ make increase-token-version
```

Then, populate the new version in other places:

> make refresh-token-version

Then create a pull request based on the changes and merge it.

### Generate New Tokens

#### Config-Updater
The tokens in [dptp/config-updater](https://vault.ci.openshift.org/ui/vault/secrets/kv/show/dptp/config-updater) have to be refreshed manually.
If it is for a cluster managed by us, we can get the kubeconfig by

> make CLUSTER=${CLUSTER} API_SERVER_URL=$API_SERVER_URL config-updater-kubeconfig

If the cluster is not managed by the test-platform team such as `vsphere` or `arm01`, we could use `oc extract secret/config-updater -n ci --to=- --keys sa.config-updater.${CLUSTER}.config` to get the new token or ask the owners of the cluster to provide the new token if `secret/config-updater` on `app.ci` is still valid.
Then the secret will be refreshed with the new token after the next run of `prowjob/periodic-ci-secret-bootstrap`.

In case `secret/config-updater` does not work, we have to fix the secret manually because `prowjob/periodic-ci-secret-bootstrap` depends on it.

```console
$ make secret-config-updater
```

#### Service Accounts Used On PSI
If the version is modified, the secrets on `psi` have to be refreshed manually with the new tokens with the steps below. 

```console
$ make -C ./clusters/psi apply_credentials
```

### Expire a Previous token

After merging of the pull request, we expire the token with a previous version on every cluster:

```console
$ make CLUSTER=${CLUSTER} EXPIRE_TOKEN_VERSION=1 DRY_RUN=none expire-token-version
```

_Note_ that we have to always use a new name for the secrets (e.g, [config-updater-token-version-n](../../clusters/build-clusters/common/prow/admin_config-updater_rbac.yaml)) that contain the non-expiring token because it would reactivate the expired token otherwise.
That is the reason we cannot bounce between two secrets like we do for the bound SA's tokens.
Instead, we increase the number in the secret's names each time.

On any cluster, we should keep only the latest version of those secrets.

```console
$ make list-token-secrets 
oc --context app.ci -n ci get secret -l ci.openshift.io/token-version --show-labels
NAME                                        TYPE                                  DATA   AGE   LABELS
config-updater-token-version-1              kubernetes.io/service-account-token   4      13d   ci.openshift.io/non-expiring-token=true,ci.openshift.io/token-version=version-1
sync-rover-groups-updater-token-version-1   kubernetes.io/service-account-token   4      13d   ci.openshift.io/non-expiring-token=true,ci.openshift.io/token-version=version-1
```
