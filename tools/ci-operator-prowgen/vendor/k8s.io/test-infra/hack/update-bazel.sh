#!/usr/bin/env bash
# Copyright 2016 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

TESTINFRA_ROOT=$(git rev-parse --show-toplevel)
# https://github.com/kubernetes/test-infra/issues/5699#issuecomment-348350792
cd ${TESTINFRA_ROOT}
TMP_GOPATH=$(mktemp -d)

OUTPUT_GOBIN="${TESTINFRA_ROOT}/_output/bin"
GOBIN="${OUTPUT_GOBIN}" go install ./vendor/github.com/bazelbuild/bazel-gazelle/cmd/gazelle
GOBIN="${OUTPUT_GOBIN}" go install ./vendor/github.com/kubernetes/repo-infra/kazel

touch "${TESTINFRA_ROOT}/vendor/BUILD.bazel"

"${OUTPUT_GOBIN}/gazelle" fix \
  -external=vendored \
  -mode=fix

"${OUTPUT_GOBIN}/kazel"
