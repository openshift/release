# CI-Clusters

This folder includes the resources for installation and configuration of [CI-cluster](URL_TBD).

* [build-clusters](./build-clusters)
    * [01_cluster](./build-clusters/01_cluster): build cluster hosted on AWS managed by DPTP-team.
    * [02_cluster](./build-clusters/02_cluster): build cluster hosted on GCP managed by DPTP-team.
    * [vsphere](./build-clusters/vsphere): build cluster hosted on vSphere managed by SPLAT-team.
    * [arm01](./build-clusters/arm01): build cluster hosted on AWS managed by the ARMOCP-team.

## Best practice for applyConfig

* All the openshift/k8s assets are static and checked into the repo except sensitive information, e.g., github token. [`applyConfig`](https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig) will resolve secrets by auto-populating environment variables for templates.

    We use [bitwarden](https://bitwarden.com/) to store sensitive information. Running bash script _locally_, e.g., [populate-secrets-from-bitwarden.sh](../ci-operator/populate-secrets-from-bitwarden.sh) will create secrets in the cluster the current `oc-cli` logs into. All openshift/k8s assets can then use secrets for referring the sensitive information.


* A pre-processing step will be automated and the output of that will be static files that can be checked in. For the case of referring a piece of sensitive information, such as,

    ```yaml
    apiVersion: v1
    kind: Something
    spec:
      field: <credentials>
    ...
    ```

    Put it into an [openshift-template](https://docs.openshift.com/container-platform/4.2/openshift_images/using-templates.html):

    ```yaml
    apiVersion: v1
    kind: Template
    objects:
    - apiVersion: v1
      kind: Something
      spec:
        field: ${credentials}
    ...
    parameters:
    - description: credentials
      name: credentials
    ```

    Then `applyConfig` will use the environment variable `${credentials}` for its value when _processing_ the template (TODO: on it after this doc is accepted) if `${credentials}` is a non-empty string.

    A known restriction is that we should avoid naming a parameter in the template with a common environment variable such as `${HOME}`.
