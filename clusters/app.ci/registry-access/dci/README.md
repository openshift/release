# DCI Infrastructure

## Generating an Image Pull Credential

First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/topology/all-namespaces/graph). Then, run:

```sh
oc --namespace dci registry login --service-account image-puller --registry-config=/tmp/config.json
```
