# terraform-windows-provisioner CI Configuration

This directory contains CI operator configuration for building the [terraform-windows-provisioner](https://github.com/openshift/terraform-windows-provisioner) container image.

## Container Image

The built image is available at:
```
registry.ci.openshift.org/ci/terraform-windows-provisioner:latest
```

## What's in the Image

The container image is built from the upstream Dockerfile and includes:

- **Terraform 1.9.5** - Infrastructure provisioning tool
- **Provisioner Scripts** - `byoh.sh` and all platform-specific configs
- **Cloud CLIs** - AWS CLI, gcloud, Azure CLI for cloud operations
- **Dependencies** - oc, kubectl, jq, bash, git

## Usage in Step Registry

This image is used by the Windows BYOH provisioning steps:
- `ci-operator/step-registry/windows/byoh/provision/`
- `ci-operator/step-registry/windows/byoh/destroy/`

These steps use the pre-built image to provision and destroy Windows nodes across multiple cloud platforms (AWS, Azure, GCP, vSphere, Nutanix) without needing to clone the repository or download terraform on every job run.

## Image Build

The image is automatically built by CI when changes are merged to the `main` branch of the terraform-windows-provisioner repository.

Build configuration: `openshift-terraform-windows-provisioner-main.yaml`

## Related Documentation

- Upstream Repository: https://github.com/openshift/terraform-windows-provisioner
- Step Registry: `ci-operator/step-registry/windows/byoh/`
- WINC Epic: [WINC-1473](https://issues.redhat.com/browse/WINC-1473)
