{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ci-chat-bot-down',
        rules: [
          {
            alert: 'ciChatBotDown',
            expr: 'kube_deployment_status_replicas_unavailable{namespace="ci", deployment=~"ci-chat-bot"} >= 1',
            'for': '5m',
            labels: {
              severity: 'critical',
              team: 'crt',
            },
            annotations: {
              message: '{{ $labels.deployment }} has been down for 5 minutes.'
            },
          }
        ],
      },
      {
        name: 'ci-chat-bot-errors',
        rules: [
          {
            alert: 'ciChatBotError',
            expr: 'rate(cluster_bot_error_rate[5m]) > 0',
            labels: {
              severity: 'critical',
              team: 'crt',
            },
            annotations: {
              message: 'Cluster Bot has reported an error.'
            },
          }
        ],
      },
    ],
  },
}
