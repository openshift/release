# rh-openjdk-test-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)

## Purpose

Setup to run with any uid

## Process

This script uses oc to login to target cluster as kubeadmin and provision default sa with anyuid.

## Requirements

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `KUBECONFIG`
  - **Definition**: Path and name of kubeconfig file of cluster.
  - **If left empty**: This step will fail

### Custom Images

- `cli`
    - [Image](cli)
    - The custom image for this step uses the `cli` image as its base 

