# OCP QE Infrastructure

[Document Guide to reqeust service account](https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/#how-do-i-get-a-token-for-programmatic-access-to-the-central-ci-registry)


## Generating an Image Pull Credential

First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/topology/all-namespaces/graph). Then, run:

```sh
oc get secrets --namespace ocp-qe -o json | jq '.items[] | select(.type=="kubernetes.io/dockercfg") | select(.metadata.annotations["kubernetes.io/service-account.name"]=="image-puller") | .data[".dockercfg"]' --raw-output | base64 --decode | jq
```
