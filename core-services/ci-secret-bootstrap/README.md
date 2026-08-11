ci-secret-bootstrap
===================

The [ci-secret-bootstrap](https://github.com/openshift/ci-tools/tree/main/cmd/ci-secret-bootstrap) tool
populates secrets onto our ci-clusters based on the items saved in Vault.
This directory contains [the config file](./_config.yaml) to run the tool.

The defined target `ci-secret-bootstrap` in [Makefile](../../Makefile) runs the tool as a container.

Be aware that the Makefile makes assumptions about how your contexts are set up and
that it will fail, should any of the contexts which are used as cluster in its config file not be present.

Service account `kubeconfig`s
-----------------------------

Following the deprecation and removal of `ServiceAccount` token `Secret`s in
Kubernetes 1.24, `kubeconfig` files are now generated in two parts.  See the
[`ci-secret-generator` documentation][ci_secret_generator] for details.

[ci_secret_generator]: ../ci-secret-generator/README.md#service-account-kubeconfig

Config Reference
----------------

```yaml
cluster_groups:
  group1:
  - build01
  - build02
  group2:
  - app.ci
secret_configs:
- from:
    anyname:
      field: foobar.pem # key name inside folder
      item: foobar # folder name inside vault
    foobar:
      field: cloud.json # key name inside folder
      item: aws # folder name inside vault
  to:
  - cluster_groups:
    - group1
    name: mirror.openshift.com # secret name inside cluster
    namespace: ocp # namespace where the secret will be
- from:
    .dockerconfigjson: # any name
      dockerconfigJSON: # special item type with specific fields
      - auth_field: push-token # value used for authentication
        email_field: email@example.com # optional when email is needed for auth
        item: quay.io/dptp # folder name inside vault
        registry_url: quay.io # registry URL, not present on vault
  to:
  - cluster: app.ci
    name: registry-secret
    namespace: ci
    type: kubernetes.io/dockerconfigjson
```
