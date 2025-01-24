# jboss-fuse-deploy-resources-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)
- [Custom Images](#custom-images)

## Purpose

To deploy secrets, configmaps, deployment-configs, persistent-volumes of Fuse On Openshift XpaaS-QE test-suite.

## Process

This script does the following to run Fuse On Openshift interop tests:
1. Create the project and set access policies.
2. Create persistent volumes to store results and shared properties between multiple executions (PODs) of the test-suite
3. Create configmaps to store test-suite settings for running
4. Create nginx server to expose dependencies as maven repo shared between PODs
5. Import xpaas-qe image

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `FUSE_RELEASE`
    - **Definition**: Fuse release or branch/tag used for selecting right image..
    - **If left empty**: latest tag will be set.

## Custom Images

- `xpaas-qe`
    - [Dockerfile](https://github.com/jboss-fuse/fuse-xpaas-qe-container/blob/main/Dockerfile)
      The custom image for this step is related to xpaas-qe test-suite installation and run. All the required dependencies are already included in the container.