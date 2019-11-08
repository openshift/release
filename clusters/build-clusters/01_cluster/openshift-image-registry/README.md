# openshift-image-registry

## Configuration

Doc: [expose the registry using DefaultRoute](https://docs.openshift.com/container-platform/4.2/registry/securing-exposing-registry.html#registry-exposing-secure-registry-manually_securing-exposing-registry)

```bash
$ oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

```

TODO: add the configmap and the RBAC for `config-updater`.

Pull image:

```
# podman pull default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com/ci/ci-operator:latest --tls-verify=false

```
