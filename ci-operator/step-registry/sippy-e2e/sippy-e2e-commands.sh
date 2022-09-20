#!/bin/bash

# We want to keep the e2e testing scripts in the source repo for developers to use.
# Just launch the script from the source repo.

echo "Working in $PWD"

ls

ls -la $GCS_SA_JSON_PATH

make e2e
