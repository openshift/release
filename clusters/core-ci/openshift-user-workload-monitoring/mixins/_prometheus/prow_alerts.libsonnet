{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'prow',
        rules: [
          {
            alert: 'prow-pod-crashlooping',
            expr: |||
              increase(kube_pod_container_status_restarts_total{job="kube-state-metrics",namespace="ci",clusterName="core-ci"}[1h]) > 10
              and
              max_over_time(
                increase(kube_pod_container_status_restarts_total{job="kube-state-metrics",namespace="ci",clusterName="core-ci"}[1h])[30m:]
              ) > 20
            |||,
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Pod {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container}}) is restarting {{ printf "%.2f" $value }} times over the last 1 hour.'
            },
          },
          {
            alert: 'NonKubeContainerWaiting',
            expr: 'max by (namespace, pod, container) (kube_pod_container_status_waiting_reason{namespace!~"(openshift-.*|kube-.*|default)",job="kube-state-metrics",clusterName="core-ci"} > 0)',
            'for': '1h',
            'keep_firing_for': '15m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              summary: 'Pod container waiting longer than 1 hour',
	      description: 'pod/{{ $labels.pod }} in namespace {{ $labels.namespace }} on container {{ $labels.container }} has been in waiting state for longer than 1 hour. (reason: {{ with printf `kube_pod_container_status_waiting_reason{namespace="%s",pod="%s",container="%s"}` $labels.namespace $labels.pod $labels.container | query }}{{ . | first | label "reason" }}{{ end }}).',
            },
          },
          {
            alert: 'prow-job-backlog-growing',
            expr: 'sum(rate(prowjob_state_transitions{state="triggered"}[30m])) - sum(rate(prowjob_state_transitions{state!="triggered"}[30m])) > 0',
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'The number of triggered Prow jobs that have not yet started running has been growing (net positive) over the past 30 minutes.'
            },
          },
          {
            alert: 'Controller backlog is not being drained',
            expr: |||
              workqueue_depth{name=~"crier.*|plank"} > 80
              and
              max_over_time(workqueue_depth{name=~"crier.*|plank"}[20m:]) > 100
            |||,
            'for': '20m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'red',
              ops_category: 'ci_platform',
              message: 'The backlog for {{ $labels.name }} is not getting drained. Check <https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/alertrules?alerting-rule-name=prow-job-backlog-growing|Prometheus>'
            },
          },
          {
            alert: 'TriggeredButPendingJobs',
            expr: |||
              sum by (job_name) (increase(prowjob_state_transitions{state="triggered"}[15m]))
              - sum by (job_name) (increase(prowjob_state_transitions{state="pending"}[15m]))
              > 10
              and
              max_over_time(
                (
                  sum by (job_name) (increase(prowjob_state_transitions{state="triggered"}[15m]))
                  - sum by (job_name) (increase(prowjob_state_transitions{state="pending"}[15m]))
                )[20m:]
              ) > 20
            |||,
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'There are {{ $value }} jobs that have been triggered but are still pending, indicating potential scheduling or resource constraints. Investigate pending Prow jobs. Check <https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/alertrules?alerting-rule-name=TriggeredButPendingJobs|Prometheus>.',
            }
          },
          {
            alert: 'TriggeredProwJobsPileup',
            // Sustained-pileup detector: min_over_time fires only when the triggered
            // count stayed above the threshold for the WHOLE 5m (jobs genuinely not
            // draining), so a continuous pileup is one held firing. A max_over_time
            // peak-detector instead fired (and, with keep_firing_for, re-fired) on the
            // brief batch-scheduling bursts that drain within seconds -- the flapping
            // observed in ci-metrics (baseline ~60, p90 ~170; only sub-5m spikes cross 450).
            expr: 'min_over_time((sum(prowjobs{job="prow-controller-manager", state="triggered"}))[5m:]) > 450',
            'keep_firing_for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Triggered prowjobs have stayed above the configured threshold for the last 5 minutes (sustained pileup that is not draining; low={{ $value }}). Follow <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/prow-job-state-pileup.md#triggered-peak|SOP>.',
              runbook_url: 'https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/prow-job-state-pileup.md#triggered-peak',
            }
          },
          {
            alert: 'SchedulingProwJobsPileup',
            // Same sustained-pileup detector as TriggeredProwJobsPileup above
            // (min_over_time, not a max_over_time peak-detector) so transient
            // scheduling bursts do not fire/re-fire; only a queue that stays above
            // the threshold for a full 5m pages.
            expr: 'min_over_time((sum(prowjobs{job="prow-controller-manager", state="scheduling"}))[5m:]) > 300',
            'keep_firing_for': '10m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: 'Scheduling prowjobs have stayed above the configured threshold for the last 5 minutes (sustained pileup that is not draining; low={{ $value }}). Follow <https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/prow-job-state-pileup.md#scheduling-peak|SOP>.',
              runbook_url: 'https://github.com/openshift/release/blob/master/docs/dptp-triage-sop/prow-job-state-pileup.md#scheduling-peak',
            }
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
