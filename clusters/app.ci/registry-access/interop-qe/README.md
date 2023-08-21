# Interop QE

[Document Guide to request service account](https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/#how-do-i-get-a-token-for-programmatic-access-to-the-central-ci-registry)

## Generating an Image Pull Credential

First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/). Then, run:

```sh
oc registry login --auth-basic $(oc get secrets -n interop-qe --sort-by=.metadata.creationTimestamp -o json | \
  jq '.items[] | select(.type=="kubernetes.io/dockercfg" and .metadata.annotations["kubernetes.io/service-account.name"]=="image-puller")' | \
  jq -r -s '.[-1] | .data.".dockercfg"' | base64 -d | jq -r '."registry.ci.openshift.org" as $e | $e.username + ":" + $e.password') \
  --registry-config=/tmp/config.json
```

The created /tmp/config.json file can be then used as a standard .docker/config.json authentication file.
