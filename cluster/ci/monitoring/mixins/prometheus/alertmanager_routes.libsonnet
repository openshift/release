{
  alertmanagerRoutes+:: [
    {
      receiver: 'slack-%s' % severity,
      continue: true,
      match: {
        severity: '%s' % severity,
      },
    }
    for severity in ['warning', 'critical']
  ] + [
    {
      receiver: 'slack-%s' % receiver_name,
      continue: true,
      match: {
        team: '%s' % $._config.alertManagerReceivers[receiver_name].team,
      },
    }
    for receiver_name in std.objectFields($._config.alertManagerReceivers)
  ],
}
