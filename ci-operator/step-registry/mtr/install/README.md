# mtr-install-chain<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Variables](#variables)
  - [~~Credentials~~](#credentials)

## Purpose

The reason I have created this chain is to offer an easy and repeatable way to install the MTR operator on a cluster. The intent of this chain is to call it with all of the default values in the [varaibles](#variables) section, except for the `SUB_CHANNEL` value.


## Process

1. Executes the [`operatorhub-subscribe` ref](../../operatorhub/subscribe/operatorhub-subscribe-ref.yaml) with the provided variables.

## Requirements

### Infrastructure

- A provisioned test cluster to target.

### Variables

- `SUB_PACKAGE`
  - **Definition**: The package name of the optional operator to install.
  - **If left empty**: It will use 'mtr-operator' as the default value.
- `SUB_SOURCE`
  - **Definition**: The catalog source name.
  - **If left empty**: It will use 'redhat-operators' as the default value.
- `SUB_CHANNEL`
  - **Definition**: The channel from which to install the package.
  - **If left empty**: This chain will fail.
- `SUB_INSTALL_NAMESPACE`
  - **Definition**: The namespace into which the operator and catalog will be installed.
  - **If left empty**: It will use 'mtr' as the default value.
- `SUB_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target.
  - **If left empty**: It will use 'mtr' as the default value.

### ~~Credentials~~