# openshift-image-registry

## Scale up

Edit the image registry operator config to [scale up](https://docs.openshift.com/container-platform/4.3/registry/configuring-registry-operator.html#registry-operator-configuration-resource-overview_configuring-registry-operator):

```
$ oc --context build01 patch configs.imageregistry.operator.openshift.io/cluster -n openshift-image-registry -p '{"spec":{"replicas":3}}'
```

