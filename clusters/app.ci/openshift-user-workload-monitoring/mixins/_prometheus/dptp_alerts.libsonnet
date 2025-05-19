{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'plank-infra',
        rules: [
          {
            alert: 'ci-tools-postsubmit-failures',
            expr: |||
              sum by (job_name) (
                rate(
                  prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="failure"}[5m]
                )
              )
              * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_metadata_target="e2e-oo-post"}) > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'ci-tools postsubmit {{ $labels.job_name }} has failures. Check <https://prow.ci.openshift.org/?job={{ $labels.job_name }}|deck>.',
            },
          },
          {
            alert: 'infrastructure-job-failures',
            expr: |||
              sum by (job_name) (
                rate(
                  prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="failure"}[5m]
                )
              )
              * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"}) > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Infrastructure CI job {{ $labels.job_name }} is failing. Investigate the symptoms, assess the urgency and take appropriate action (<https://grafana-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/%s/dptp-dashboard?orgId=1&fullscreen&viewPanel=4|Grafana Dashboard> | <https://prow.ci.openshift.org/?job={{ $labels.job_name }}|Deck> | <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/infrastructure-jobs.md#{{ $labels.job_name}}|SOP>).' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          },
          {
            alert: 'plank-job-with-infra-internal-role-failures',
            expr: |||
              sum by (job_name) (
                rate(
                  prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="failure"}[5m]
                )
              )
              * on (job_name) group_left max by (job_name) (prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra-internal"}) > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'plank jobs {{ $labels.job_name }} with infra-internal role has failures. Check on <https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job={{ $labels.job_name }}|deck-internal>. See <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/infrastructure-jobs.md#{{ $labels.job_name}}|SOP>.',
            },
          }
        ],
      },
      {
        name: 'quay-io-image-mirroring',
        rules: [
          {
            alert: 'quay-io-image-mirroring-failures',
            expr: 'sum(rate(quay_io_ci_images_distributor_image_mirroring_duration_seconds_count{state="failure"}[10m])) > 0.5',
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Many mirroring tasks to quay.io have been failed in the last minute. Please check errors in the pod logs to figure out the cause: <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/misc.md#quay-io-image-mirroring-failures|SOP>.',
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
            labels: {
              severity: 'critical',
            },
            annotations: {
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
              sum(rate(ci_operator_error_rate{job_name!~"rehearse.*",state="failed",reason!~".*cloning_source",reason!~".*executing_template",reason!~".*executing_multi_stage_test",reason!~".*building_image_from_source",reason!~".*building_.*_image",reason!="executing_graph:interrupted"}[30m])) by (reason) > 0.02
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'An excessive amount of CI Operator executions are failing with `{{ $labels.reason }}`, which is an infrastructure issue. See <https://search.dptools.openshift.org/?search=Reporting+job+state.*with+reason.*{{ $labels.reason }}&maxAge=6h&context=1&type=build-log&name=&excludeName=&maxMatches=5&maxBytes=20971520&groupBy=job|CI search>.',
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
              sum(rate(ci_operator_error_rate{state="failed"}[30m])) by (reason) > 0.07
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'An excessive amount of CI Operator executions are failing with `{{ $labels.reason }}`, which does not necessarily point to an infrastructure issue but is happening at an excessive rate and should be investigated. See <https://search.dptools.openshift.org/?search=Reporting+job+state.*with+reason.*{{ $labels.reason }}&maxAge=6h&context=1&type=build-log&name=&excludeName=&maxMatches=5&maxBytes=20971520&groupBy=job|CI search>.',
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
             label_replace((sum(increase(ci_operator_error_rate{state="failed",reason=~"executing_graph:step_failed:utilizing_lease:acquiring_lease:.*"}[15m])) by (reason)), "provider", "$1", "reason", "executing_graph:step_failed:utilizing_lease:acquiring_lease:(.*)-quota-slice") > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
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
              message: 'The SSL certificates for instance {{ $labels.instance }} are expiring in 28 days.',
            },
          },
          {
            alert: 'ProbeFailing',
            expr: |||
              up{job="blackbox"} == 0 or probe_success{job="blackbox"} == 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Probing the instance {{ $labels.instance }} has been failing for the past minute.',
            },
          },
          {
            alert: 'ProbeFailing-Lenient',
            expr: |||
              up{job="blackbox-lenient"} == 0 or probe_success{job="blackbox-lenient"} == 0
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Probing the instance {{ $labels.instance }} has been failing for the past five minutes.',
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
               sum(
                 rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"branch-ci-.*-images",org="openshift-priv",state="success"}[12h])
               )
               /
               sum(
                 rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"branch-ci-.*-images",org="openshift-priv",state=~"success|failure|aborted"}[12h])
               )
             )
             < 0.90
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'openshift-priv image-building jobs are failing at a high rate. Check on <https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=branch-ci-*-images|deck-internal>. See <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/openshift-priv-image-building-jobs.md|SOP>.',
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
                  prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="success"}[12h]
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
              message: 'OpenShift image mirroring jobs have failed. View failed jobs at the <https://prow.ci.openshift.org/?job=periodic-image-mirroring-openshift|overview>.',
            },
          }
        ],
      },
    ],
  },
}
