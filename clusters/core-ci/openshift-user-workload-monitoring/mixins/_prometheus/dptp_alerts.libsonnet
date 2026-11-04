// Aggregate infrastructure alerts retain the catalog classification of the failing
// job. Keep these catalog families explicit; unknown jobs remain orange/ci_platform.
local cleanupJobPattern = '^(periodic-ipi-deprovision-gcp(-[23])?|periodic-ipi-deprovision-aws|periodic-ci-openshift-release-main-deprovision-deprovision-aws(-[2-5])?)$';
local cloudJobPattern = '^(periodic-hypershift-deprovision-aws-konflux-(prod|stg)-hosted-mgmt2?|periodic-ci-openshift-release-main-hypershift-4[.](19|20|21)-periodic-ci-openshift-hypershift-hosted)$';
local fleetJobPattern = '^(branch-ci-.+-build[0-9]+-apply|periodic-build[0-9]+-upgrade|periodic-(hosted-mgmt2?|core-ci)-upgrade|periodic-etcd-defragger|periodic-hosted-mgmt2?-hypershift-deployment)$';
local repoJobPattern = '^(periodic-prow-auto-config-brancher|periodic-branch-protector|periodic-branch-protector-openshift-org|periodic-org-sync|periodic-openshift-release-fast-forward|periodic-openshift-release-merge-blockers|periodic-openshift-release-private-org-sync)$';
// Cleanup/cloud reaper + sanity jobs that post per-run crier reports today but
// carry no `role: infra` label, so infrastructure-job-failures below cannot match
// them. Derived from the catalog patterns above (same ops classification) plus the
// qci registry pruner, so adding a job to a catalog pattern also extends coverage.
local stripAnchors(p) = std.substr(p, 2, std.length(p) - 4);
local deprovisionCleanupJobPattern = '^(' + stripAnchors(cleanupJobPattern) + '|' + stripAnchors(cloudJobPattern) + '|periodic-openshift-release-qci-pruner)$';
// Timestamp of a job's most recent terminal transition of the given state(s), per
// job_name, over `window`: timestamp(v) and (increase(v[10m])>0 or birth) yields the
// eval time at each increment, and max_over_time holds the latest within the window.
// The birth term (v>0 unless v offset 15m) catches a counter born at 1 on its first
// increment or re-created after a prow-controller-manager restart, which increase()
// alone would miss.
local lastTransition(states, pattern, window) =
  local sel = 'prowjob_state_transitions{job="prow-controller-manager",job_name=~"%(p)s",state=~"%(s)s"}' % { p: pattern, s: states };
  |||
    max by (job_name) (
      max_over_time(
        (
          timestamp(%(sel)s)
          and
          (increase(%(sel)s[10m]) > 0 or (%(sel)s > 0 unless %(sel)s offset 15m))
        )[%(w)s:5m]
      )
    )
  ||| % { sel: sel, w: window };
// Fires while a job's most recent terminal transition is a failure/error that a
// later success has not overtaken (or it has never succeeded) -- a timestamp
// comparison, NOT "a failure in the window and no success in the window", so a
// success followed by a later failure still fires and a failure followed by a later
// success resolves (addresses the window-contains ambiguity).
local latestRunFailed(pattern, window) =
  local fail = lastTransition('failure|error', pattern, window);
  local succ = lastTransition('success', pattern, window);
  '(\n' + fail + ')\nunless on (job_name)\n(\n(\n' + succ + ') >= on (job_name) (\n' + fail + ')\n)';
local infraJobAnnotations = {
  ops_color: '{{ if match %s $labels.job_name }}yellow{{ else }}orange{{ end }}' % std.manifestJson(cleanupJobPattern),
  ops_category: '{{ if match %s $labels.job_name }}repo_automation{{ else if match %s $labels.job_name }}cluster_fleet{{ else if match %s $labels.job_name }}cloud_cleanup{{ else }}ci_platform{{ end }}' % [
    std.manifestJson(repoJobPattern),
    std.manifestJson(fleetJobPattern),
    std.manifestJson(cleanupJobPattern + '|' + cloudJobPattern),
  ],
};

{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'plank-infra',
        rules: [
          {
            alert: 'ci-tools-postsubmit-failures',
            expr: |||
              (
                sum by (job_name) (
                  increase(
                    prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="failure"}[24h]
                  )
                )
                * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_metadata_target="e2e-oo-post"})
                > 0
              )
              unless on (job_name)
              (
                sum by (job_name) (
                  increase(
                    prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="success"}[12h]
                  )
                )
                * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_metadata_target="e2e-oo-post"})
                > 0
              )
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'ci-tools postsubmit {{ $labels.job_name }} has failures. Check <https://prow.ci.openshift.org/?job={{ $labels.job_name }}|deck>.',
            },
          },
          {
            alert: 'infrastructure-job-failures',
            expr: |||
              (
                sum by (job_name) (
                  increase(
                    prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*|periodic-prow-auto-sippy-config-generator",state="failure"}[13h]
                  )
                )
                * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"})
                > 0
              )
              unless on (job_name)
              (
                sum by (job_name) (
                  increase(
                    prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*|periodic-prow-auto-sippy-config-generator",state="success"}[7h]
                  )
                )
                * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"})
                > 0
              )
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: infraJobAnnotations.ops_color,
              ops_category: infraJobAnnotations.ops_category,
              message: 'Infrastructure CI job {{ $labels.job_name }} is failing. Investigate the symptoms, assess the urgency and take appropriate action (<https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/%s/dptp-dashboard?orgId=1&fullscreen&viewPanel=4|Grafana Dashboard> | <https://prow.ci.openshift.org/?job={{ $labels.job_name }}|Deck> | <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/infrastructure-jobs.md#{{ $labels.job_name}}|SOP>).' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          },
          {
            alert: 'plank-job-with-infra-internal-role-failures',
            expr: |||
              (
                sum by (job_name) (
                  increase(
                    prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="failure"}[13h]
                  )
                )
                * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra-internal"})
                > 0
              )
              unless on (job_name)
              (
                sum by (job_name) (
                  increase(
                    prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="success"}[7h]
                  )
                )
                * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra-internal"})
                > 0
              )
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: infraJobAnnotations.ops_color,
              ops_category: infraJobAnnotations.ops_category,
              message: 'plank jobs {{ $labels.job_name }} with infra-internal role has failures. Check on <https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job={{ $labels.job_name }}|deck-internal>. See <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/infrastructure-jobs.md#{{ $labels.job_name}}|SOP>.',
            },
          },
          {
            alert: 'infrastructure-cleanup-job-failures',
            // Cleanup/cloud reaper + sanity jobs (gcp/aws/konflux deprovision,
            // hypershift hosted sanity, qci pruner) are selected by name because they
            // carry no `role: infra` label; they share the ops_* classification of the
            // infra alerts above and route through slack-criticals to #ops-testplatform
            // with the ops tags. These replace the per-run crier reports removed from
            // the job definitions. Uses the latest-transition comparison (not
            // failure-in-window / success-in-window) so a success later overtaken by a
            // failure still fires and a recovered job resolves. 2d window covers these
            // jobs' <=daily cadence.
            expr: latestRunFailed(deprovisionCleanupJobPattern, '2d'),
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: infraJobAnnotations.ops_color,
              ops_category: infraJobAnnotations.ops_category,
              message: 'Cleanup/cloud CI job {{ $labels.job_name }} is failing and has not succeeded recently. Investigate via <https://prow.ci.openshift.org/?job={{ $labels.job_name }}|Deck> and follow the <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/infrastructure-jobs.md|infrastructure-jobs SOP>.',
            },
          },
          {
            alert: 'ci-tools-image-build-failures',
            // Only the POSTSUBMIT (branch-ci) ci-tools image builds: they run on
            // merge to main and promote the images, so a failure means the ci-tools
            // images on main are broken. The presubmit (pull-ci) image builds are
            // intentionally NOT alerted -- their failures reflect individual
            // in-progress PRs (and prowjob_state_transitions has no per-PR label, so
            // all PR runs collapse into one series), are already surfaced to the
            // author as a required PR check, and are not an ops signal. Latest-transition
            // comparison (an earlier success cannot mask a later failing build). 2d is
            // the longest lookback the ci-metrics evaluator is confirmed to serve (it
            // matches configmap_alerts' predict_linear[2d]); a broken postsubmit with no
            // rebuild for >2d ages out until the next merge re-evaluates it.
            expr: latestRunFailed('^branch-ci-openshift-ci-tools(-standalone)?-main-images$', '2d'),
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'The ci-tools image postsubmit {{ $labels.job_name }} is failing on merge to main and has not succeeded since, so the ci-tools images on main may be stale. Check <https://prow.ci.openshift.org/?job={{ $labels.job_name }}|Deck>.',
            },
          },
        ],
      },
      {
        name: 'quay-io-image-mirroring',
        rules: [
          {
            alert: 'quay-io-image-mirroring-failures',
            expr: |||
              max_over_time(
                (sum(rate(quay_io_ci_images_distributor_image_mirroring_duration_seconds_count{state="failure"}[10m])))[15m:1m]
              ) > 0.5
              and
              sum(rate(quay_io_ci_images_distributor_image_mirroring_duration_seconds_count{state="failure"}[10m])) > 0.2
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Many mirroring tasks to quay.io have failed in the last 10 minutes. Please check errors in the pod logs to figure out the cause: <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/misc.md#quay-io-image-mirroring-failures|SOP>.',
              runbook_url: 'https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/misc.md#quay-io-image-mirroring-failures',
            },
          },
        ],
      },
      {
        name: 'cluster-client-creation-failure',
        rules: [
          {
            alert: 'component-failed-to-construct-a-client',
            expr: 'kubernetes_failed_client_creations > 0',
            'for': '5m',
            'keep_firing_for': '15m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Component {{ $labels.service }} failed to construct a client. Search for "failed to construct {manager,client} for cluster <<clustername>>" in the beginning of the pod log. If the cluster unavailability was transient, a restart of the pod will fix the issue.',
            },
          },
        ],
      },
      {
        name: 'ci-operator-infra-error',
        rules: [
          {
            alert: 'high-ci-operator-infra-error-rate',
            expr: |||
              (
                max_over_time(
                  (sum(rate(ci_operator_error_rate{job_name!~"rehearse.*",state="failed",reason!~".*cloning_source",reason!~".*executing_template",reason!~".*executing_multi_stage_test",reason!~".*building_image_from_source",reason!~".*building_.*_image",reason!="executing_graph:interrupted"}[30m])) by (reason))[15m:1m]
                ) > 0.02
                and
                sum(rate(ci_operator_error_rate{job_name!~"rehearse.*",state="failed",reason!~".*cloning_source",reason!~".*executing_template",reason!~".*executing_multi_stage_test",reason!~".*building_image_from_source",reason!~".*building_.*_image",reason!="executing_graph:interrupted"}[30m])) by (reason) > 0.01
              )
              and on (reason)
              (
                max_over_time(
                  (count by (reason) (
                    sum by (reason, job_name) (
                      rate(ci_operator_error_rate{job_name!~"rehearse.*",state="failed",reason!~".*cloning_source",reason!~".*executing_template",reason!~".*executing_multi_stage_test",reason!~".*building_image_from_source",reason!~".*building_.*_image",reason!="executing_graph:interrupted"}[30m])
                    ) > 0
                  ))[15m:1m]
                ) >= 3
                and
                count by (reason) (
                  sum by (reason, job_name) (
                    rate(ci_operator_error_rate{job_name!~"rehearse.*",state="failed",reason!~".*cloning_source",reason!~".*executing_template",reason!~".*executing_multi_stage_test",reason!~".*building_image_from_source",reason!~".*building_.*_image",reason!="executing_graph:interrupted"}[30m])
                  ) > 0
                ) >= 2
              )
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'An excessive amount of CI Operator executions are failing with `{{ $labels.reason }}` across multiple jobs, which indicates an infrastructure issue. See <https://search.dptools.openshift.org/?search=Reporting+job+state.*with+reason.*{{ $labels.reason }}&maxAge=6h&context=1&type=build-log&name=&excludeName=&maxMatches=5&maxBytes=20971520&groupBy=job|CI search> and follow <https://github.com/openshift/release/blob/main/docs/dptp-triage-sop/high-ci-operator-infra-error-rate.md|SOP>.',
              runbook_url: 'https://github.com/openshift/release/blob/main/docs/dptp-triage-sop/high-ci-operator-infra-error-rate.md',
            },
          }
        ],
      },
      {
        name: 'ci-operator-error',
        rules: [
          {
            alert: 'high-ci-operator-error-rate',
            expr: |||
              max_over_time(
                (sum(rate(ci_operator_error_rate{state="failed"}[30m])) by (reason))[15m:1m]
              ) > 0.08
              and
              sum(rate(ci_operator_error_rate{state="failed"}[30m])) by (reason) > 0.04
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'yellow',
              ops_category: 'ci_platform',
              message: 'An excessive amount of CI Operator executions are failing with `{{ $labels.reason }}`, which does not necessarily point to an infrastructure issue but is happening at an excessive rate and should be investigated. See <https://search.dptools.openshift.org/?search=Reporting+job+state.*with+reason.*{{ $labels.reason }}&maxAge=6h&context=1&type=build-log&name=&excludeName=&maxMatches=5&maxBytes=20971520&groupBy=job|CI search> and follow <https://github.com/openshift/release/blob/main/docs/dptp-triage-sop/high-ci-operator-error-rate.md|SOP>.',
            },
          }
        ],
      },
      {
        name: 'jobs-failing-with-lease-acquire-timeout',
        rules: [
          {
            alert: 'jobs-failing-with-lease-acquire-timeout',
            expr: |||
             label_replace((sum(increase(ci_operator_error_rate{state="failed",reason=~"executing_graph:step_failed:utilizing_lease:acquiring_lease:.*"}[30m])) by (reason)), "provider", "$1", "reason", "executing_graph:step_failed:utilizing_lease:acquiring_lease:(.*)-quota-slice") > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Jobs on provider {{ $labels.provider }} fail because they were unable to acquire a lease.',
            },
          }
        ],
      },
      {
        name: 'http-probe',
        rules: [
          {
            alert: 'SSLCertExpiringSoon',
            expr: |||
              probe_ssl_earliest_cert_expiry{job="blackbox"} - time() < 86400 * 28
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'The SSL certificates for instance {{ $labels.instance }} are expiring in 28 days.',
            },
          },
          {
            alert: 'ProbeFailing',
            expr: |||
              up{job="blackbox"} == 0 or probe_success{job="blackbox"} == 0
            |||,
            'for': '1m',
            'keep_firing_for': '3m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Blackbox probe is failing for service {{ $labels.instance }} for the past minute. Please check the service and follow <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/blackbox-probe-service-failing.md|SOP>.',
            },
          },
          {
            alert: 'ProbeFailing-Lenient',
            expr: |||
              up{job="blackbox-lenient"} == 0 or probe_success{job="blackbox-lenient"} == 0
            |||,
            'for': '5m',
            'keep_firing_for': '3m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Blackbox probe is failing for service {{ $labels.instance }} for the past five minutes. Please check the service and follow <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/blackbox-probe-service-failing.md|SOP>.',
            },
          },
        ],
      },
      {
        name: 'openshift-priv-image-building-jobs-failing',
        rules: [
          {
            alert: 'openshift-priv-image-building-jobs-failing',
            expr: |||
              (
                sum by (job_tail) (
                  label_replace(
                    rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"branch-ci-openshift-priv-.*-images",org="openshift-priv",state="success"}[12h]),
                    "job_tail", "$1", "job_name", "branch-ci-openshift-priv-(.*-images)"
                  )
                )
                /
                sum by (job_tail) (
                  label_replace(
                    rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"branch-ci-openshift-priv-.*-images",org="openshift-priv",state=~"success|failure|aborted"}[12h]),
                    "job_tail", "$1", "job_name", "branch-ci-openshift-priv-(.*-images)"
                  )
                )
              ) < 0.90
              and on (job_tail)
              (
                sum by (job_tail) (
                  label_replace(
                    rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"branch-ci-openshift-.*-images",org="openshift",state="success"}[12h]),
                    "job_tail", "$1", "job_name", "branch-ci-openshift-(.*-images)"
                  )
                )
                /
                sum by (job_tail) (
                  label_replace(
                    rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"branch-ci-openshift-.*-images",org="openshift",state=~"success|failure|aborted"}[12h]),
                    "job_tail", "$1", "job_name", "branch-ci-openshift-(.*-images)"
                  )
                )
              ) >= 0.90
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'repo_automation',
              message: 'The priv image-building job branch-ci-openshift-priv-{{ $labels.job_tail }} is failing while the corresponding public job branch-ci-openshift-{{ $labels.job_tail }} remains healthy. See priv <https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=branch-ci-openshift-priv-{{ $labels.job_tail }}|deck-internal> and public <https://prow.ci.openshift.org/?job=branch-ci-openshift-{{ $labels.job_tail }}|deck>. See <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/openshift-priv-image-building-jobs.md|SOP>.',
            },
          }
        ],
      },
      {
        name: 'pod-scaler-admission-resource-warning',
        rules: [
          {
            alert: 'pod-scaler-admission-resource-warning',
            expr: |||
             sum by (workload_name, workload_type, determined_amount, configured_amount, resource_type) (increase(pod_scaler_admission_high_determined_resource{workload_type!~"undefined|build"}[5m])) > 0
            |||,
            'for': '1m',
            'keep_firing_for': '10m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: 'Workload {{ $labels.workload_name }} ({{ $labels.workload_type }}) used 10x more than configured amount of {{ $labels.resource_type }} (actual: {{ $labels.determined_amount }}, configured: {{ $labels.configured_amount }}. See <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/pod-scaler-admission.md|SOP>.',
            },
          }
        ],
      },
      {
        name: 'openshift-mirroring-failures',
        rules: [
          {
            alert: 'openshift-mirroring-failures',
            expr: |||
              sum by (job_name) (
                rate(
                  prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="success"}[6h]
                )
              )
              * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="image-mirroring",label_ci_openshift_io_area="openshift"}) == 0
            |||,
            'for': '1m',
            'keep_firing_for': '2h',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'OpenShift image mirroring jobs have had no successful run in the last 6 hours. The primary recovery target is to restore at least one successful run after repeated failures. Check <https://prow.ci.openshift.org/?job=periodic-image-mirroring-openshift|overview> and follow <https://github.com/openshift/release/blob/main/docs/dptp-triage-sop/openshift-mirroring-failures.md|SOP>.',
            },
          }
        ],
      },
    ],
  },
}
