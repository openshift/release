# OCS Infrastructure

## Generating an Service Account Credential

First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/topology/all-namespaces/graph). Then, run:


```sh
oc service-account get-token metrics-viewer --namespace managed-services
```
