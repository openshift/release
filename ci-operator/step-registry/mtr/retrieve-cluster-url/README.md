# mtr-retrieve-cluster-url-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [~~Variables~~](#variables)
  - [~~Credentials~~](#credentials)

## Purpose

To retrieve the cluster URL of the target test cluster and write it to a file in the `SHARED_DIR` for use in a later step. This URL will be used to execute the MTR interop tests.

## Process

This is a very simple script. It uses `oc` to retrieve the console host of the target test cluster. After retrieving the URL, it removes a portion of the URL returned, then writes the result to a file named `cluster_url` in the `SHARED_DIR`.

## Requirements

### Infrastructure

- A provisioned test cluster to target.

### ~~Variables~~

### ~~Credentials~~
