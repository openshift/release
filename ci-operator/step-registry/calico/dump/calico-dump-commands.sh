#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc get tigerastatus -o yaml
