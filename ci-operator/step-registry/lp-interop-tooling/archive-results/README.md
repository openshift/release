# lp-interop-tooling-archive-results-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [~~Infrastructure~~](#infrastructure)
  - [Variables](#variables)
  - [~~Credentials~~](#credentials)
  - [Other](#other)

## Purpose

This ref is to be used to archive results from layered-product interop tests. This ref allows us to archive results in a folder and with a filename that is predictable. Archiving with predictable locations and filenames is important for our reporting process. We need to be able to programmatically find results in the artifacts to report them properly.

## Process

This script takes the `$RESULTS_FILE` variable as an argument, the value of this variable should be the filename of the file you'd like to archive. The filename passed in the `$RESULTS_FILE` variable should exist in the **root** of the `$SHARED_DIR`.

## Requirements

### ~~Infrastructure~~

### Variables

- `RESULTS_FILE` 
  - **Definition**: The name of the file in the $SHARED_DIR that needs to be archived.
  - **If left empty**: The script will fail.

### ~~Credentials~~

### Other

- The `RESULTS_FILE` must exist in the **root** of the `$SHARED_DIR`.
