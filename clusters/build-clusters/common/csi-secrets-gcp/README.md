These manifests deploy the [**Secrets Store CSI driver**](https://secrets-store-csi-driver.sigs.k8s.io/) 
and the [**Google Secret Manager Provider for Secret Store CSI Driver**](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp)
in order to utilize the GCP Secret Manager.

## Changes to upstream manifests
The Secrets Store CSI driver was deployed using the default upstream manifests as described [here](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation#alternatively-deployment-using-yamls).
However, the following changes needed to be done to the [upstream manifest](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/7218875135b87ca930b9bcb97231b1ede4e93e1a/deploy/provider-gcp-plugin.yaml) 
of the Google Secret Manager Provider, in order for it to run properly on our clusters:
1. Deleted the `spec.template.spec.initContainers` stanza:
```yaml
initContainers:
- name: chown-provider-mount
  image: busybox
  command:
  - chown
  - "1000:1000"
  - /etc/kubernetes/secrets-store-csi-providers
  volumeMounts:
  - mountPath: "/etc/kubernetes/secrets-store-csi-providers"
    name: providervol
```

2. Because of how the SCCs of our clusters are set up, the `spec.template.spec.containers.securityContext` stanza had to be changed from:
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop:
    - ALL
```
to:
```yaml
securityContext:
  privileged: true
```

3. The credentials for the GCP Service Account are mounted as a Volume in `spec.template.spec.volumes`. 
   It's contents are accessible to the pod through the env var `GOOGLE_APPLICATION_CREDENTIALS`.
