#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail


# Namespace may or may not be created already, creating just in case.
oc create ns test-migration || true

# Patch the netnamespace to use multicast annotation
oc annotate netnamespace test-migration netnamespace.network.openshift.io/multicast-enabled=true