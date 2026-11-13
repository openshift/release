# Interop Test Registry

This directory contains **true interop tests** that test interaction between 2 or more Layered Products.

## Directory Structure

Pattern: `ci-operator/step-registry/interop/<main-operator>/<test-functional-group-1>[/.../<test-functional-group-n>]/<target-operators>/<test-name>`

Every path component, at every level, is a lowercase RFC 1123 label: lowercase
alphanumerics, with `-` as the only separator. No uppercase and no underscore
or plus characters anywhere in a path, doubled or not.

CI Operator joins the directory path with `/` replaced by `-` to form the step
name, and that step name becomes the pod name verbatim. Only characters valid in
a DNS-1123 subdomain (lowercase alphanumerics, `-`, `.`) survive, so `_` and `+`
fail at pod creation.

```
ci-operator/step-registry/interop/
 |- <main-operator>/
     |- <test-functional-group-1>/
        /                                   \
        |.                                  |
        | .                                 |
        |  .                                |
        \    |- <test-functional-group-n>/  /
                 |- <target-operators>/
                     |- <test-name>/
```

### Components:

- **`<main-operator>`**: The subject operator being tested (`acm`, `quay`, etc.)
- **`<test-functional-group-n>`**: Functional area (`policy-set`, `security-scan`, `ctr-img`, `smoke`, etc.)
  - Multi-word components are joined with `-`: `policy-set`, `opp-bundle`, `security-scan`, `ctr-img`, `app-deployment`
  - Can have multiple nested levels for grouping if needed
- **`<target-operators>`**: The target operators this test interacts with
  - Use descriptive names: `opp-bundle` for the full OpenShift Plus bundle
  - Or explicit names like `acs` for a single product, `acs-odf` for specific combinations
  - Combined target operators are joined with `-`
- **`<test-name>`**: Concise name describing the test action, words separated with `-`
  - Example: `deployment` = deploys and verifies the resource
  - Example: `app-deployment` = deploys application
  - Example: `registry` = tests registry functionality

## Pod Name Length Considerations

⚠️ **CRITICAL**: The full step name becomes the Kubernetes Pod Name.

- When pod names exceed K8s limits, they are hashed/truncated
- Hashed names are harder to identify in logs and debugging
- **Avoid repetition and useless information** in naming

### Best Practices:
- Keep step names concise and DNS-1123 compliant
- Don't repeat information already in the path
- Use `-` to separate words in test names
- Example: `acm/policy-set/opp-bundle/deployment` ✅
- Not: `acm/policies/opp-bundle/policyset-deploy-compliance` ❌ (redundant, too long)

## Examples

### ACM Policy Set Deployment for OpenShift Plus Bundle
```
interop/acm/policy-set/opp-bundle/deployment/
```
- **Main operator**: acm
- **Functional group**: policy-set
- **Target operators**: opp-bundle (OpenShift Plus: ACM, ACS, ODF, Quay)
- **Test name**: deployment
- **Step name**: `interop-acm-policy-set-opp-bundle-deployment`
- **What it tests**: ACM deploys policy-set to OpenShift Plus bundle and verifies successful deployment

### ACM Security Scanning of Container Images with ACS
```
interop/acm/security-scan/ctr-img/acs/app-deployment/
```
- **Main operator**: acm
- **Functional group**: security-scan/ctr-img (container image security scanning)
- **Target operator**: acs (Advanced Cluster Security)
- **Test name**: app-deployment
- **Step name**: `interop-acm-security-scan-ctr-img-acs-app-deployment`
- **What it tests**: ACM deploys application, ACS performs security scan on container images

### Quay Registry Smoke Test with ACS and ODF
```
interop/quay/smoke/acs-odf/registry/
```
- **Main operator**: quay
- **Functional group**: smoke
- **Target operators**: acs-odf (ACS security + ODF storage)
- **Test name**: registry
- **Step name**: `interop-quay-smoke-acs-odf-registry`
- **What it tests**: Smoke test of Quay registry functionality (push/pull images, ODF storage integration, ACS security scanning)
