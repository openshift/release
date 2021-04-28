#!/bin/bash

echo "Deploying an operator in the bundle format"

# (todo): hardcoding this for now to test in CI; will fix
operator-sdk run bundle "quay.io/rashmigottipati/api-operator:1.0.1"