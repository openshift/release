# docker-registry

This folder contains the files to build the [docker-registry](https://github.com/docker/distribution-library-image/tree/master) image.
We rebuild the image instead of reusing or importing the existing one because
- `htpasswd` is used to generate the file for the registry to enable the basic authentication based on a file that comes from a secret on the cluster.
- The pod needs to be restarted when the file is updated.
- It is easier to implement if both `htpasswd` and the registry run in the some container unlike [the example from the doc](https://docs.docker.com/registry/deploying/#native-basic-auth).


