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
- **`<testFunctionalGroupN>`**: Functional area (policies, securities, deployment, etc.)
  - Can have multiple nested levels for grouping if needed
- **`<targetOperators>`**: The target operators this test interacts with (opp-operators, ACS, ACS+ODF, etc.)
- **`<testName>`**: The specific test step name

## Pod Name Length Considerations

⚠️ **CRITICAL**: The full step name becomes the Kubernetes Pod Name.

- When pod names exceed K8s limits, they are hashed/truncated
- Hashed names are harder to identify in logs and debugging
- **Avoid repetition and useless information** in naming

### Best Practices:
- Keep step names concise
- Don't repeat information already in the path
- Example: `ACM/policies/opp-operators/openshift-plus` ✅
- Not: `ACM/policies/opp-operators/acm-policies-openshift-plus` ❌ (redundant "acm-policies")

## Examples

### ACM Policy Tests for OPP Bundle
```
interop/ACM/policies/opp-operators/openshift-plus/
```
- **Main operator**: ACM
- **Functional group**: policies
- **Target operators**: opp-operators (Quay+ODF+ACS bundle)
- **Test name**: openshift-plus
- **What it tests**: ACM deploys and manages policies for the OPP bundle operators

### ACM Secured Application with ACS
```
interop/ACM/securities/ACS/opp-app/
```
- **Main operator**: ACM
- **Functional group**: securities
- **Target operator**: ACS (Advanced Cluster Security)
- **Test name**: opp-app
- **What it tests**: ACM deploys a secured application with ACS security scanning

### Quay Security Integration
```
interop/Quay/securities/ACS+ODF/smoke/
```
- **Main operator**: Quay
- **Functional group**: securities
- **Target operators**: ACS+ODF (security scanning + storage)
- **Test name**: smoke
- **What it tests**: Quay registry with ACS security scanning and ODF storage
