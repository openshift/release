#!/bin/bash

oc create namespace numaresources-operator
operator-sdk run bundle -n numaresources-operator --security-context-config restricted "$OO_BUNDLE_OLD"
oc wait --for condition=Available -n numaresources-operator deployment numaresources-controller-manager