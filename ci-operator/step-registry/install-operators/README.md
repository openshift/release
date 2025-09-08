# install-operators-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
  - [Defining `OPERATORS`](#defining-operators)
    - [Variable Definitions](#variable-definitions)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Variables](#variables)

## Purpose

This ref should be used to install one or more operators in a cluster.

## Process

This ref consumes a JSON blob from the [`OPERATORS` variable](#variables) and parses the JSON using the [`jq` command](https://stedolan.github.io/jq/). Using the parsed JSON, the script will iterate through the list of operators, the following happens for each operator:
1. Creates the `{install_namespace}`
   - If the namespace already exists, nothing happens.
2. Deploys a new operator group in the `{install_namespace}` with the value stored in `{operator_group}`. If a value for `{operator_group}` is not supplied, an operator group will not be used.
3. Creates an operator hub subscription in `{install_namespace}` using the `{name}`, `{channel}`, and `{source}` values provided.
4. Verifies the operator gets installed
   - Does a check every 30 seconds with 30 retries to verify the operator is installed

### Defining `OPERATORS`

The `OPERATORS` variable is a little different from other environment variables. This variable must be valid JSON to work. To define this variable correctly, please use these templates `env` blocks:

**Use with ONE operator:**
```yaml
env:
    OPERATORS: |
    [
        {"name": "", "source": "", "channel": "", "install_namespace": "", "target_namespaces": ""}
    ]
```

**Use with MULTIPLE operators:**
```yaml
env:
    OPERATORS: |
    [
        {"name": "", "source": "", "channel": "", "install_namespace": "", "target_namespaces": ""},
        {"name": "", "source": "", "channel": "", "install_namespace": "", "target_namespaces": ""}
    ]
```

**Use with global-operators group in the openshift-operators namespace:**
```yaml
env:
    OPERATORS: |
    [
        {"name": "<operator name>", "source": "<source>", "channel": "<channel>", "operator_group": "global-operators" "install_namespace": "openshift-operators", "target_namespaces": ""},
    ]
```

**Add subscription config:**
```yaml
env:
    OPERATORS: |
    [
        {"name": "<operator name>", "source": "<source>", "channel": "<channel>", "operator_group": "global-operators" "install_namespace": "openshift-operators", "target_namespaces": "", "config": "{\"env\": [{\"name\": \"FIPS_MODE\", \"value\": \"disabled\"}]}"},
    ]
```

#### Variable Definitions

- **`name`**: The package name of the optional operator to install. Example: `"mtr-operator"`.
- **`source`**: The catalog source name. Example: `"redhat-operators"`
- **`channel`**: The channel from which to install the package. This value can be set to `"!default"` if you'd like to always install from the default channel. Example: `"release-2.7"`.
- **`operator_group`**: (Optional) The operator group name. Example: `"global-operators"`
- **`install_namespace`**: The namespace into which the operator and catalog will be installed. Example: `"mtr-namespace"`.
- **`target_namespaces`**: A comma-separated list of namespaces the operator will target. If empty, all namespaces will be targeted. This value can be set to `"!install"` to use the `install_namespace` value. Example: `"mtr,ocm"`
- **`config`**: (Optional) SubscriptionConfig contains configuration specified for a subscription. Example: `{"env": [{"name": "FIPS_MODE", "value": "disabled"}]}`. More fields can be found in the CRD/subscriptions.operators.coreos.com.

## Requirements

### Infrastructure

- A provisioned test cluster to target.

### Variables

- `OPERATORS` 
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](#defining-operators) section of this document for more information.
  - **If left empty**: The script will fail.
