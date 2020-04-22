# openshift-image-registry

## Enable route

[Expose the registry using the default-route](https://docs.openshift.com/container-platform/4.2/registry/securing-exposing-registry.html#registry-exposing-secure-registry-manually_securing-exposing-registry):

```bash
$ oc --as system:admin --context build01 patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

```

TODO: add the configmap and the RBAC for `config-updater`.

Pull image:

```bash
$ podman pull default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com/ci/ci-operator:latest --tls-verify=false

```

## Scale up

Edit the image registry operator config to [scale up](https://docs.openshift.com/container-platform/4.3/registry/configuring-registry-operator.html#registry-operator-configuration-resource-overview_configuring-registry-operator):

```
$ oc --context build01 patch configs.imageregistry.operator.openshift.io/cluster -n openshift-image-registry -p '{"spec":{"replicas":3}}'
```

