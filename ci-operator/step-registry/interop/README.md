# Interop Test Registry

This directory contains **true interop tests** that test interaction between 2 or more Layered Products.

## Directory Structure

```
step-registry/interop/
  └── <mainOperator>/
      └── <testFunctionalGroup>/
          └── <targetOperators>/
              └── <testName>/
```

### Components:

- **`<mainOperator>`**: The subject operator being tested (ACM, Quay, etc.)
- **`<testFunctionalGroup>`**: Functional area (policies, securities, deployment, etc.)
  - Can have multiple nested levels for grouping if needed
- **`<targetOperators>`**: The target operators this test interacts with (OPP, ACS, ACS+ODF, etc.)
- **`<testName>`**: The specific test step name

## Pod Name Length Considerations

⚠️ **CRITICAL**: The full step name becomes the Kubernetes Pod Name.

- When pod names exceed K8s limits, they are hashed/truncated
- Hashed names are harder to identify in logs and debugging
- **Avoid repetition and useless information** in naming

### Best Practices:
- Keep step names concise
- Don't repeat information already in the path
- Example: `ACM/policies/OPP/acm-policies-openshift-plus` ✅
- Not: `ACM/policies/OPP/acm-policies-opp-openshift-plus` ❌ (redundant "opp")

## Examples

### ACM Policy Tests for OPP
```
interop/ACM/policies/OPP/acm-policies-openshift-plus/
```
- **Main operator**: ACM
- **Functional group**: policies
- **Target operators**: OPP (Quay+ODF+ACS bundle)
- **What it tests**: ACM deploys and manages policies for the OPP runtime

### Quay Security Integration
```
interop/Quay/securities/ACS+ODF/interop-tests-opp-quay-smoke/
```
- **Main operator**: Quay
- **Functional group**: securities
- **Target operators**: ACS+ODF (security scanning + storage)
- **What it tests**: Quay registry with ACS security scanning and ODF storage

## Distinction from `interop-tests/`

- **`interop/`**: Real interop tests (2+ operators)
- **`interop-tests/`**: Single-operator health monitoring (NOT interop)

Only tests that verify interaction between multiple products belong in `interop/`.
