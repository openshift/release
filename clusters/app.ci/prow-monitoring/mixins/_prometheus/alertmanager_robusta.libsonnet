{
  alertmanagerRoutes+:: [
    {
      receiver: 'robusta',
      match_re: {
        severity: 'info|warning|error|critical',
      },
      repeat_interval: '4h',
      continue: true,
    }
  ],
  alertmanagerReceivers+:: [
    {
      name: 'robusta',
      webhook_configs: [
        {
          url: 'http://robusta-runner.robusta.svc.cluster.local/api/alerts',
          send_resolved: true,
        },
      ],
    },
  ],
}
