# Telco 5G Infrastructure

## Generating an Image Pull Credential

First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/topology/all-namespaces/graph). Then, run:

```sh
oc get secrets --namespace cnf-ci -o json | jq '.items[] | select(.type=="kubernetes.io/dockercfg") | select(.metadata.annotations["kubernetes.io/service-account.name"]=="image-puller") | .data[".dockercfg"]' --raw-output | base64 --decode | jq
```
