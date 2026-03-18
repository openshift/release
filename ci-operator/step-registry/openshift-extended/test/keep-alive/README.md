# Keep Cluster Alive for 12 Hours

Simple step to keep a cluster running for debugging.

## Usage

Trigger in PR:
```
/test debug-gcp-4.22-gcp-ipi-debug
```

## Customize Image

Edit `ci-operator/config/openshift/release/openshift-release-main__debug-gcp-4.22.yaml`:

```yaml
env:
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: registry.ci.openshift.org/ocp/release:4.22.0-0.nightly-2026-03-17-195154
```

Available images: https://amd64.ocp.releases.ci.openshift.org/

## Destroy Early

```bash
oc create configmap stop-preserving -n default
```
