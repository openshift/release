{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'prow',
        rules: [
          {
            alert: 'prow-pod-crashlooping',
            expr: 'increase(kube_pod_container_status_restarts_total{job="kube-state-metrics",namespace="ci"}[1h]) > 20',
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Pod {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container}}) is restarting {{ printf "%.2f" $value }} times over the last 1 hour.'
            },
          },
          {
            alert: 'ImagePullBackOff',
            expr: 'sum(sum_over_time(kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}[5m])) > 30',
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Many pods have been failing on pulling images. Please check the relevant events on the cluster.'
            },
          },
          {
            alert: 'prow-job-backlog-growing',
            expr: 'sum(rate(prowjob_state_transitions{state="triggered"}[5m])) - sum(rate(prowjob_state_transitions{state!="triggered"}[5m])) > 0',
            'for': '60m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The number of the triggered Prow jobs that have not yet been running has been increasing for the past hour.'
            },
          },
          {
            alert: 'Controller backlog is not being drained',
            expr: 'workqueue_depth{name=~"crier.*|plank"} > 100',
            'for': '20m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The backlog for {{ $labels.name }} is not getting drained. Check <https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/alertrules?alerting-rule-name=prow-job-backlog-growing|Prometheus>'
            },
          },
          {
            # We need this for a grafana variable, because grafana itself can only do extremely simplistic queries there
            record: 'github:identity_names',
            expr: 'count(label_replace(count(github_token_usage{token_hash =~ "openshift.*"}) by (token_hash), "login", "$1", "token_hash", "(.*)") or github_user_info{login=~"openshift-.*"}) by (login)'
          }
        ],
      },
    ],
  },
}
