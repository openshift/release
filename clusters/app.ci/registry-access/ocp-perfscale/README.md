## Generating an Image Pull Credential
```sh
oc --namespace ocp-perfscale registry login --service-account image-puller --registry-config=/tmp/config
```
The created /tmp/config.json file can be then used as a standard .docker/config.json authentication file.

