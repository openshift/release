# Proxy CI Jobs

This folder contains CI configuration for the [openshift-service-mesh/proxy](https://github.com/openshift-service-mesh/proxy) repository.

## Job Types

- **Pre-submit Jobs**:
  - `unit` - Unit tests for x86_64 architecture
  - `unit-arm` - Unit tests for ARM64 architecture
  - `envoy` - Extended Envoy-specific tests (optional)
- **Post-submit Jobs**:
  - `copy-artifacts-gcs` / `copy-artifacts-gcs-arm` - Upload build artifacts
  - `update-istio` - Automatically updates Istio repository with new proxy builds

## Complete Documentation

📖 **For comprehensive documentation covering all OpenShift Service Mesh CI jobs, see:**
**[OpenShift Service Mesh CI Documentation](../sail-operator/README.md)**

This includes:
- Complete job inventory across all repositories
- Usage patterns and manual triggering instructions
- Technical deep-dive and troubleshooting guidance
- Performance testing documentation
- Team maintenance procedures