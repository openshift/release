#!/bin/bash

# This uses oc from the step image
# In a "real" test job, inject correct oc binary with cli:latest
oc --insecure-skip-tls-verify get nodes -o wide
