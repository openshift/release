{
  alertmanagerRoutes+:: [
    {
      receiver: 'slack-ops-testplatform',
      group_by: ['alertname'],
      group_wait: '30s',
      group_interval: '4h',
      repeat_interval: '24h',
      match: {
        alertname: 'ArgoCDApplicationOutOfSync',
      },
    },
  ] + [
    {
      receiver: 'slack-%s' % receiver_name,
      match: {
        team: '%s' % $._config.alertManagerReceivers[receiver_name].team,
      },
    }
    for receiver_name in std.objectFields($._config.alertManagerReceivers)
  ] + [
    {
      receiver: 'slack-%ss' % severity,
      match: {
        severity: '%s' % severity,
      },
    }
    for severity in ['warning', 'critical']
  ],
}
