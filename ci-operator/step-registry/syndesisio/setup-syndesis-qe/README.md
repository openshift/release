# syndesisio-setup-syndesis-qe-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)

## Purpose

To create an htp user named 'admin' with cluster admin privileges on target cluster and verify able to login with user.

## Process

This script uses oc to login to target cluster as kubeadmin and provision a user named 'admin' with cluster privledges. It then verifies it is then able to login with this user.

## Requirements

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `KUBECONFIG`
  - **Definition**: Path and name of kubeconfig file of cluster.
  - **If left empty**: This step will fail

### Custom Images

- `htpasswd-cli`
    - [Image](cli)
    - The custom image for this step uses the `cli` image as its base that has been updated and httpd-tools installed

