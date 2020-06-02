{
  prometheusAlerts+:: {
    groups+: [
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
              severity: 'critical',
            },
            annotations: {
              message: 'plank jobs {{ $labels.job_name }} with infra role has failures. Check on <https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/%s/dptp-dashboard?orgId=1&fullscreen&panelId=3|grafana> and <https://prow.svc.ci.openshift.org/?job={{ $labels.job_name }}|deck>' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          }
        ],
      },
    ],
  },
}
