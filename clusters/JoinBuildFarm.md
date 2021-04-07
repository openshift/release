# Join Build Farm

To run test on an OpenShift cluster which is not managed by DPTP, the cluster has to join the CI build farm.

## Claim a folder 

Claim a folder in [README.md](../README.md), e.g.,

```
* [build-clusters](./build-clusters)
    ...
    * [vsphere](./build-clusters/vsphere): build cluster hosted on vSphere managed by SPLAT-team.
```

The folder `build-clusters/vsphere` then can be used to store the files related to the cluster.

Make a softlink to each folder.

```
$ cd build-clusters/vsphere
$ ln -s ../common common
$ ln -s ../common_except_app.ci common_except_app.ci
```

Create a pull request with the changes above.

## Set up applyConfig against the cluster

Create the namespaces:

> oc apply -f clusters/build-clusters/common/00_namespaces.yaml

Create the SA for the `appyconfig` job:

> oc apply -f clusters/build-clusters/common/prow/admin_config-updater_rbac.yaml

Note that this will promote `system:serviceaccount:ci:config-updater` to `cluster-admin`.

Create kubeconfig for `system:serviceaccount:ci:config-updater`:

```
context=vsphere
sa=config-updater
config="sa.${sa}.${context}.config"
oc sa create-kubeconfig -n ci "${sa}" > "${config}"
sed -i "s/${sa}/${context}/g" "${config}"
```

Contact a member of DPTP to send the `kubeconfig` file with encryption. Then DPTP will set up the `applyconfig` (presubmit for dry-run and postsubmit) jobs for the cluster. Note that the `yaml` files in the claimed folder will be applied automatically to the cluster: The presubmit is with the `dry-run` mode while the postsubmit is not, e.g, [pull-ci-openshift-release-master-vsphere-dry](https://github.com/openshift/release/blob/d3e0f9b333f74537376a8978d958b33b8b081733/ci-operator/jobs/openshift/release/openshift-release-master-presubmits.yaml#L778) and [branch-ci-openshift-release-master-vsphere-apply](https://github.com/openshift/release/blob/d3e0f9b333f74537376a8978d958b33b8b081733/ci-operator/jobs/openshift/release/openshift-release-master-postsubmits.yaml#L170).

After the [service accounts](./build-clusters/vsphere1/ci) are created by `applyconfig`, DPTP will
* Create the `kubeconfig`s for other SAs with [ci-secret-generator](https://github.com/openshift/release/blob/master/core-services/ci-secret-generator/_config.yaml). include those files in [`secret/build-farm-credentials`](https://github.com/openshift/release/blob/79e657752f6fae3367fcd70ed260bccf98e8a32c/core-services/ci-secret-bootstrap/_config.yaml#L1009-L1011).
* Add the new cluster context to 'cluster_groups' in [ci-secret-bootstrap/_config.yaml](https://github.com/openshift/release/blob/master/core-services/ci-secret-bootstrap/_config.yaml)
* Use the `kubeconfig`s in Prow components, including the [openshift-release-master-config-bootstrapper](https://github.com/openshift/release/blob/b2ee6d838506945347a620717f00205c40e80d9f/ci-operator/jobs/infra-periodics.yaml#L799) job.

## Run a test on the cluster

### container based tests

Create a pull request with a new rehearsal job with `cluster: vsphere`:

```yaml
  - agent: kubernetes
    always_run: true
    branches:
    - master
    cluster: vsphere
    context: ci/prow/join-cluster-job
    labels:
      pj-rehearse.openshift.io/can-be-rehearsed: "true"
    name: pull-ci-openshift-release-master-join-cluster-job
    rerun_command: /test join-cluster-job
    spec:
      containers:
      - image: docker.io/hello-world
        imagePullPolicy: Always
        name: ""
        resources:
          requests:
            cpu: 10m
    trigger: ((?m)^/test join-cluster-job,?(\s+|$))
```

Verify on [the Prow portal](https://prow.ci.openshift.org/?job=rehearse-*-join-cluster-job) if the rehearsal job is successfully running on the new cluster.

### OpenShift e2e tests

Cluster admin:

* [Expose the image-registry securely](https://docs.openshift.com/container-platform/4.5/registry/securing-exposing-registry.html).

DPTP:

* Update [cluster list](https://docs.ci.openshift.org/docs/getting-started/useful-links/#clusters) and [registry list](https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/#summary-of-available-registries) in the ci-docs site.