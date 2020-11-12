# ci-secret-bootstrap

The [ci-secret-bootstrap](https://github.com/openshift/ci-tools/tree/master/cmd/ci-secret-bootstrap) tool
populates secrets onto our ci-clusters based on the items saved in Bitwarden.
This directory contains [the config file](./_config.yaml) to run the tool.

The defined target `ci-secret-bootstrap` in [Makefile](../../Makefile) runs the tool as a container.

Be aware that the Makefile makes assumptions about how your contexts are set up and
that it will fail, should any of the contexts which are used as cluster in its config file not be present:

# Custom Bitwarden items

Adding a new Bitwarden item to create a new secret or inject it in an existing one, requires few minor steps.
First, the user has to create the Bitwarden item and share it with the *OpenShift TestPlatform (CI)* collection,
following the official [documentation](https://bitwarden.com/help/article/share-to-a-collection/).

After the item has been created and shared, it can be used in the [configuration file](https://github.com/openshift/release/blob/master/core-services/ci-secret-bootstrap/_config.yaml).

Example:
```yaml
  - from:
      my_key: # the created secret will contain this key name
        bw_item: my_custom_bw_item
        attachment: my_attachment
        field: my_field
    to:
      - cluster_groups:
        - build_farm (see [here](https://github.com/openshift/release/blob/master/core-services/ci-secret-bootstrap/_config.yaml#L1-L12))
        namespace: my_namespace (use test-credentials to use the secret in a CI job)
        name: my_secret_name
```
