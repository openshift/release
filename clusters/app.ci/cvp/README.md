# OCS Infrastructure

## Fetching a Service Acount Token

First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/topology/all-namespaces/graph). Then, run:


```sh
oc --namespace cvp serviceaccounts get-token triggerer
```
