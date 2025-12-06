These manifests deploy the [**Secrets Store CSI driver**](https://secrets-store-csi-driver.sigs.k8s.io/) 
and the [**Google Secret Manager Provider for Secret Store CSI Driver**](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp)
in order to utilize the GCP Secret Manager.

## Changes to upstream manifests
The following modifications needed to be made to the upstream manifests.

### Changes to Secrets Store CSI Driver
All manifests, except for `csidriver.yaml`, were deployed as described [here](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation#alternatively-deployment-using-yamls).
By default, volumes backed by Container Storage Interface (CSI) drivers can only be used
with a PersistentVolume and PersistentVolumeClaim object combination. To enable Pods to define inline volumes, 
the following label was added to the metadata section in `csidriver.yaml`, 
as explained in this [OpenShift documentation](https://docs.openshift.com/container-platform/4.17/storage/container_storage_interface/ephemeral-storage-csi-inline.html#overview-admission-plugin):
```yaml
  labels:
     security.openshift.io/csi-ephemeral-volume-profile: baseline
```
This configuration allows a Pod to mount CSI inline ephemeral volumes when 
the namespace in which the Pod is running is governed by a pod security standard (privileged/baseline/restricted) 
that is the same or higher than the one specified by the label.


### Changes to GCP Provider
The following changes needed to be done to the [upstream manifest](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/7218875135b87ca930b9bcb97231b1ede4e93e1a/deploy/provider-gcp-plugin.yaml) 
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

---
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

---
3. Modified the `spec.template.spec.tolerations` stanza from:
```yaml
   tolerations:
     - key: kubernetes.io/arch
       operator: Equal
       value: arm64
       effect: NoSchedule
```
to:
```yaml
   tolerations:
   - operator: Exists
```

---
4. The credentials for the GCP Service Account are mounted as a Volume in `spec.template.spec.volumes`. 
   It's contents are accessible to the pod through the env var `GOOGLE_APPLICATION_CREDENTIALS`.
