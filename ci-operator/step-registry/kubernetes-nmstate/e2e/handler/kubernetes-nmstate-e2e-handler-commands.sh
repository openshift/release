#!/bin/bash

export KUBECONFIG=${SHARED_DIR}/kubeconfig
make test-e2e-handler-ocp
