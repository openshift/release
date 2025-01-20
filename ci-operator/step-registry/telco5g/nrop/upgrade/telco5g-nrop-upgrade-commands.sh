#!/bin/bash

operator-sdk run bundle-upgrade --timeout=10m --security-context-config restricted -n numaresources-operator "$OO_BUNDLE"
oc wait --for condition=Available -n numaresources-operator deployment numaresources-controller-manager