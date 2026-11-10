# dotnet-deploy-and-test-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other](#other)
- [Custom Image - `dotnet-runner`](#custom-image---dotnet-runner)

## Purpose

Use to execute `ansible-runner` [dotnet-deploy-and-test](https://github.com/sclorg/ansible-tests) using the provided arguments. All XML results will be combined into "$ARTIFACT_DIR/junit_rhscl-testing-results.xml".

## Process

1. Executes ansible-runner to deploy and test. 
2. Copies the XML file from the command in step 1 to `$ARTIFACT_DIR/junit-rhscl-testing-results.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - Should have a `dotnet` namespace/project:

### Environment Variables

- `DOTNET_VERSION`
  - **Definition**: Used to specify Dotnet versions to test (dotnet, dotnet_60 dotnet_70). This value will determine which version of .NET to run tests for.
  - **If left empty**: It will use 'dotnet' as the default value. Meaning tests will executed for all valid versions.
- `KUBECONFIG`
  - **Definition**: Path and name of kubeconfig file of cluster.
  - **If left empty**: This step will fail

### Other


## Custom Image - `dotnet-runner`

- `dotnet-runner`
  - [Dockerfile](https://github.com/sclorg/ansible-tests/blob/master/Dockerfile)
  - The custom image for this step uses the [`Ansible Automation Platform compatibility execution environment`](registry.redhat.io/ansible-automation-platform/ee-29-rhel8:latest) image as it's base. The image should have all of the required dependencies installed and the [scl/ansible-tests repository](https://github.com/sclorg/ansible-tests) copied into `/tmp/tests/ansible-tests`.

