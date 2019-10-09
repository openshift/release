{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ipi-deprovision',
        rules: [
          {
            alert: 'ipi-deprovision-failures',
            expr: |||
              rate(prowjob_state_transitions{job_name="periodic-ipi-deprovision",state="failure"}[30m]) > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'ipi-deprovision has failures. Check on <https://grafana-prow-monitoring.svc.ci.openshift.org/d/%s/dptp-dashboard?orgId=1&fullscreen&panelId=2|grafana> and <https://prow.svc.ci.openshift.org/?type=periodic&job=periodic-ipi-deprovision|deck>' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          }
        ],
      },
      // TODO(hongkliu): The above ipi-deprovision-failures is an instance of the following
      // Try to combine when the following is verified to be working (same for the grafana panels)
      // The challenging part is the job_name label in the Deck URL
      {
        name: 'plank-infra',
        rules: [
          {
            alert: 'plank-job-with-infra-role-failures',
            expr: |||
              sum(rate(prowjob_state_transitions{job="plank",job_name!~"rehearse.*",state="failure"}[5m])) by (job_name) * on (job_name) group_left prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"} > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'plank jobs {{ $labels.job_name }} with infra role has failures. Check on <https://grafana-prow-monitoring.svc.ci.openshift.org/d/%s/dptp-dashboard?orgId=1&fullscreen&panelId=3|grafana> and <https://prow.svc.ci.openshift.org/?job={{ $labels.job_name }}|deck>' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          }
        ],
      },
    ],
  },
}
