{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'plank-infra',
        rules: [
          {
            alert: 'plank-job-with-infra-role-failures',
            expr: |||
              sum(rate(prowjob_state_transitions{job="prow-controller-manager",job_name!~"rehearse.*",state="failure"}[5m])) by (job_name) * on (job_name) group_left prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"} > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'plank jobs {{ $labels.job_name }} with infra role has failures. Check on <https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/%s/dptp-dashboard?orgId=1&fullscreen&panelId=3|grafana> and <https://prow.svc.ci.openshift.org/?job={{ $labels.job_name }}|deck>' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          }
        ],
      },
      {
        name: 'ci-operator-infra-error',
        rules: [
          {
            alert: 'high-ci-operator-infra-error-rate',
            expr: |||
              sum(rate(ci_operator_error_rate{state="failed",reason!~".*cloning_source",reason!~".*executing_template",reason!~".*executing_multi_stage_test",reason!~".*building_image_from_source",reason!~".*building_.*_image",reason!="executing_graph:interrupted"}[30m])) by (reason) > 0.02
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'An excessive amount of CI Operator executions are failing with {{ $labels.reason }}, which is an infrastructure issue.',
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
              message: 'An excessive amount of CI Operator executions are failing with {{ $labels.reason }}, which does not necessarily point to an infrastructure issue but is happening at an excessive rate and should be investigated.',
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
              probe_ssl_earliest_cert_expiry{job="blackbox"} - time() < 86400 * 30
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The SSL certificates for instance {{ $labels.instance }} are expiring in 30 days.',
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
          }
        ],
      },
    ],
  },
}
