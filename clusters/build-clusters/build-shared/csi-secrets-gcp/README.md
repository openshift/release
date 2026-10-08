These manifests deploy the [**Secrets Store CSI driver**](https://secrets-store-csi-driver.sigs.k8s.io/)
and the [**Google Secret Manager Provider for Secret Store CSI Driver**](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp)
in order to utilize the GCP Secret Manager.

## Secrets Store CSI Driver

The driver is managed by the Red Hat [Secrets Store CSI Driver Operator](https://docs.openshift.com/container-platform/latest/storage/container_storage_interface/persistent-storage-csi-secrets-store.html),
installed via OLM (`secrets-store-csi-driver-operator.yaml`). The operator handles the driver
DaemonSet, CRDs, RBAC, and CSIDriver resource in the `openshift-cluster-csi-drivers` namespace.

The Subscription uses `channel: stable` with `installPlanApproval: Automatic`, so OLM
picks the correct CSV for each cluster's OCP version and applies updates automatically.
This avoids per-cluster overrides since our clusters often have different OCP
minor versions.

### Changes to GCP Provider
The upstream GCP provider image only supports amd64 and arm64. We build a multi-arch
manifest list that adds s390x and ppc64le using `hack/build-gcp-provider-multiarch.sh`,
and publish it to `quay.io/openshift/ci-public`.

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
   Its contents are accessible to the pod through the env var `GOOGLE_APPLICATION_CREDENTIALS`.