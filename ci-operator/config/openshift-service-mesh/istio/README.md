# Istio CI Jobs

This folder contains CI configuration for the [openshift-service-mesh/istio](https://github.com/openshift-service-mesh/istio) repository.

## Job Types

- **Periodic Jobs**: `sync-upstream-istio-master` - Automatically syncs upstream Istio changes
- **Pre-submit Jobs**: `lint`, `gencheck`, `unit` - Code quality and testing
- **Integration Tests**: Various test suites for pilot, telemetry, security, ambient, and helm
- **Sail Operator Tests**: Same integration tests using Sail operator as installer

## Complete Documentation

📖 **For comprehensive documentation covering all OpenShift Service Mesh CI jobs, see:**
**[OpenShift Service Mesh CI Documentation](../sail-operator/README.md)**

This includes:
- Complete job inventory across all repositories
- Usage patterns and manual triggering instructions
- Technical deep-dive and troubleshooting guidance
- Performance testing documentation
- Team maintenance procedures