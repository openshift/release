#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

scripts/check-asciidoctor-build.sh
