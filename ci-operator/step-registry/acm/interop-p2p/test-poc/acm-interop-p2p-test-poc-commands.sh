#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Export environment variables
#=====================

#=====================
# Configuration variables
#=====================

#=====================

# Sleep 7h (25200s) - step timeout is 8h, leaving 1h buffer
sleep 25200