#!/bin/sh
# Validate the generated user-workload-monitoring Prometheus alert rules with
# promtool unit tests.
#
# `promtool test rules` needs a native Prometheus rules file (top-level
# `groups:`), but the committed file is a PrometheusRule CR. Since `spec:` is the
# last top-level key, everything after it, dedented two spaces, is a valid rules
# file. We render that, then run every *_test.yaml in the tests directory.
#
# Usage: hack/validate-prometheus-rules.sh [base_dir]   (base_dir defaults to .)
# Requires: promtool on PATH (run inside a Prometheus image, or `make
# validate-prometheus-rules`).
set -eu

base_dir="${1:-.}"
rule_crd="${base_dir}/clusters/core-ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml"
tests_dir="${base_dir}/hack/prometheus-rules-tests"

[ -f "${rule_crd}" ] || { echo "rule file not found: ${rule_crd}" >&2; exit 1; }
[ -d "${tests_dir}" ] || { echo "tests dir not found: ${tests_dir}" >&2; exit 1; }

# Render bare Prometheus rules from the PrometheusRule CR.
sed -n '/^spec:/,$p' "${rule_crd}" | sed '1d' | sed 's/^  //' > "${tests_dir}/.rendered-rules.yaml"

cd "${tests_dir}"
trap 'rm -f .rendered-rules.yaml' EXIT

promtool check rules .rendered-rules.yaml
promtool test rules ./*_test.yaml
