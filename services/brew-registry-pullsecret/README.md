# CVP brew-registry-pullsecret

## Getting the brew-registry pull secret

First, log in to [the cluster](https://api.ci.openshift.org/console/catalog). Then, run:


```sh
oc get secrets --namespace brew-registry-pullsecret -o json | jq '.items[] | select(.type=="kubernetes.io/dockercfg") | .data[".dockercfg"]' --raw-output | base64 --decode
```
