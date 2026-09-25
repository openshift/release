#!/bin/bash
export CLEANUP=true
USE_OLM=true ./hack/deploy-and-e2e.sh
USE_OLM=false ./hack/deploy-and-e2e.sh