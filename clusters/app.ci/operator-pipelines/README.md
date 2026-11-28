# OCS Infrastructure

## Fetching a Service Account Token

A cluster admin creates a Secret of type `kubernetes.io/service-account-token` for the `operator-pipelines-trigger` Service Account. First, log in to [the cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/topology/all-namespaces/graph). Then, list the Secrets, and read the token from the one of that type:

```sh
oc --namespace operator-pipelines get secrets
oc --namespace operator-pipelines get secret <secret-name> -o jsonpath='{.data.token}' | base64 -d
```
