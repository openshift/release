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

## Set up applyConfig against the cluster

Create the namespace:

> oc apply -f clusters/build-clusters/vsphere/ci/ci_ns.yaml

Create the SA for the `appyconfig` job:

> oc apply -f clusters/build-clusters/vsphere/ci/admin_config-updater_rbac.yaml

Note that this will promote `system:serviceaccount:ci:config-updater` to `cluster-admin`.

Create kubeconfig for `system:serviceaccount:ci:config-updater`:

```
context=vsphere
sa=config-updater
config="sa.${sa}.${context}.config"
oc sa create-kubeconfig -n ci "${sa}" > "${config}"
sed -i "s/${sa}/${context}/g" "${config}"
```

Contact a member of DPTP to send the `kubeconfig` file with encryption. Then DPTP will set up the `applyconfig` (presubmit for dry-run and postsubmit) jobs for the cluster.

After the [service accounts](./build-clusters/vsphere1/ci) are created by `applyconfig`, DPTP will
* create the `kubeconfig`s for other SAs with [hack/generate-bw-items.sh](https://github.com/openshift/release/blob/be736831f1926b3b7cfa197aab209c87aec0687a/clusters/build-clusters/02_cluster/hack/generate-bw-items.sh#L35).
* include those files in [`secret/build-farm-credentials`](https://github.com/openshift/release/blob/79e657752f6fae3367fcd70ed260bccf98e8a32c/core-services/ci-secret-bootstrap/_config.yaml#L1009-L1011).
* use the `kubeconfig`s in Prow components.

## Run a test on the cluster
TODO
### container based tests

### e2e tests