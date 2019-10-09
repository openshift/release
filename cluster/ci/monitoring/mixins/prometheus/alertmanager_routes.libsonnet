{
  alertmanagerRoutes+:: [
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
