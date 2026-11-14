# Interop Test Registry

This directory contains **true interop tests** that test interaction between 2 or more Layered Products.

## Directory Structure

Pattern: `step-registry/interop/<mainOperator>/<testFunctionalGroup1>[/.../<testFunctionalGroupN>]/<targetOperators>/<testName>`

```
step-registry/interop/
 |- <mainOperator>/
     |- <testFunctionalGroup1>/
        /                                   \
        |.                                  |
        | .                                 |
        |  .                                |
        \    |- <testFunctionalGroupN>/     /
                 |- <targetOperators>/
                     |- <testName>/
```

### Components:

- **`<mainOperator>`**: The subject operator being tested (ACM, Quay, etc.)
- **`<testFunctionalGroupN>`**: Functional area (policy-set, security-scan, deployment, smoke, etc.)
  - Can have multiple nested levels for grouping if needed
- **`<targetOperators>`**: The target operators this test interacts with
  - Use descriptive names: `opp-bundle` for the full OpenShift Plus bundle
  - Or explicit names like `ACS`, `ACS+ODF` for specific combinations
- **`<testName>`**: Concise name describing the test action
  - Avoid `-` in test names (CI Operator uses `-` to join path segments into the step name)
  - Use `_` to separate words, `__` to separate functional components
  - Pattern: `stub_component_1[__...[__stub_component_N]]`
  - Example: `deployment` = deploys and verifies the resource
  - Example: `app_deployment` = deploys application
  - Example: `registry` = tests registry functionality

## Pod Name Length Considerations

⚠️ **CRITICAL**: The full step name becomes the Kubernetes Pod Name.

- When pod names exceed K8s limits, they are hashed/truncated
- Hashed names are harder to identify in logs and debugging
- **Avoid repetition and useless information** in naming

### Best Practices:
- Keep step names concise and DNS-1123 compliant
- Don't repeat information already in the path
- Use single underscores `_` to separate words in test names
- Example: `ACM/policy-set/opp-bundle/deployment` ✅
- Not: `ACM/policies/opp-bundle/policyset_deploy_compliance` ❌ (redundant, too long)

## Examples

### ACM Policy Set Deployment for OpenShift Plus Bundle
```
interop/ACM/policy-set/opp-bundle/deployment/
```
- **Main operator**: ACM
- **Functional group**: policy-set
- **Target operators**: opp-bundle (OpenShift Plus: ACM, ACS, ODF, Quay)
- **Test name**: deployment
- **Step name**: `interop-ACM-policy-set-opp-bundle-deployment`
- **What it tests**: ACM deploys policy-set to OpenShift Plus bundle and verifies successful deployment

### ACM Security Scanning of Container Images with ACS
```
interop/ACM/security-scan/ctr_img/ACS/app_deployment/
```
- **Main operator**: ACM
- **Functional group**: security-scan/ctr_img (container image security scanning)
- **Target operator**: ACS (Advanced Cluster Security)
- **Test name**: app_deployment
- **Step name**: `interop-ACM-security-scan-ctr_img-ACS-app_deployment`
- **What it tests**: ACM deploys application, ACS performs security scan on container images

### Quay Registry Smoke Test with ACS and ODF
```
interop/Quay/smoke/ACS+ODF/registry/
```
- **Main operator**: Quay
- **Functional group**: smoke
- **Target operators**: ACS+ODF (ACS security + ODF storage)
- **Test name**: registry
- **Step name**: `interop-Quay-smoke-ACS+ODF-registry`
- **What it tests**: Smoke test of Quay registry functionality (push/pull images, ODF storage integration, ACS security scanning)
