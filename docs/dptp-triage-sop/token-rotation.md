# Rotate Service Account Tokens

## Prow Components and CI-Tools
TODO

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

After merging of the pull request, we expire the token with a previous version

```console
$ make EXPIRE_TOKEN_VERSION=1 DRY_RUN=none expire-token-version
```