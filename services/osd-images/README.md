# OSD Images
this folder is to allow osd pull images from the release images with ease.

copied from the [interop-qe folder](../interop-qe/)

## Generating an Image Pull Credential

First, log in to [the cluster](https://api.ci.openshift.org/console/catalog). Then, run:


```sh
oc get secrets --namespace osd-images -o json | jq '.items[] | select(.type=="kubernetes.io/dockercfg") | select(.metadata.annotations["kubernetes.io/service-account.name"]=="image-puller") | .data[".dockercfg"]' --raw-output | base64 --decode | jq 'with_entries(select(.key == "registry.svc.ci.openshift.org"))'
```

# Adding yourself to the image-pullers
for the image puller you will need to:
1. access to the cluster (see link in previous section)
2. login to the cli with the login token
3. check your login username with `oc whoami` command

that is the user you should add to the image pullers list
