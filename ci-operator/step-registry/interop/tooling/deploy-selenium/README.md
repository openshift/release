# interop-tooling-deploy-selenium-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [Prepare](#prepare)
    - [Retrieve the console URL](#retrieve-the-console-url)
    - [Check if SELENIUM\_NAMESPACE is defined](#check-if-selenium_namespace-is-defined)
  - [Deploy](#deploy)
    - [Create the Namespace](#create-the-namespace)
    - [Deploy the Selenium Pod](#deploy-the-selenium-pod)
    - [Create a Service](#create-a-service)
    - [Create an Ingress](#create-an-ingress)
    - [Create a Network Policy](#create-a-network-policy)
  - [Verify](#verify)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)

## Purpose

To deploy a Selenium pod, along with the network infrastructure to use it from a different cluster, to the target test cluster. The container uses the [quay.io/redhatqe/selenium-standalone](https://quay.io/repository/redhatqe/selenium-standalone) image and allows us to use the container as a remote executor for Selenium tests.

## Process

This script can be separated into three parts: prepare, deploy, and verify.

### Prepare

#### Retrieve the console URL

Used to retrieve the console URL. We only use this during the [Verify](#verify) step of this script. It is used to build the URL to request the status of the pod.

#### Check if SELENIUM_NAMESPACE is defined
Used to verify that the `SELENIUM_NAMESPACE` environment variable is defined. If it is not defined, the default namespace of `selenium` will be used.

### Deploy

#### Create the Namespace

Create the Namespace defined in the `SELENIUM_NAMESPACE` variable. This command is idempotent, if the Namespace already exists, it will move on.

#### Deploy the Selenium Pod

Deploys the Selenium pod with the resources required to run this pod. It should pull a new image from Quay every time it is deployed, so the image will stay up to date.

#### Create a Service

Create the Selenium service that will route traffic from the Ingress (port 80) to the Selenium pod (port 4444). 

#### Create an Ingress

Creates an Ingress on the target test cluster to allow for traffic from outside of the cluster to reach the Selenium pod.

#### Create a Network Policy

Creates the Network Policy that allows Ingress to our Selenium pod from outside of the network.

### Verify

Waits about 2.5 minutes for the pod to finish starting, then checks the status of the pod and the network. It will print the output of this check, then write the address needed to use the pod as a remote executor to a file named `selenium-executor` in the `SHARED_DIR` for use in later stages of testing.

## Container Used

The container used to execute this step is the built-in `cli`image.

## Requirements

### Variables

- `SELENIUM_NAMESPACE`
  - **Definition**: The namespace that the Selenium pod and the supporting network infrastructure will be deployed in.
  - **If left empty**: The script will use the `selenium` namespace.
  - **Additional information**: If the requested namespace does not exist, it will be created.

### Infrastructure

- A provisioned test cluster to target.W