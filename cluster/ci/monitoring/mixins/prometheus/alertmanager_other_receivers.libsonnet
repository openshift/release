{
  alertmanagerReceivers+:: [
    {
      name: 'slack-%s' % receiver_name,
      slack_configs: [
        {
          channel: '%s' % $._config.alertManagerReceivers[receiver_name].channel,
          api_url: '{{ api_url }}',
          icon_url: 'https://avatars3.githubusercontent.com/u/3380462',
          text: '{{ template "custom_slack_text" . }}',
          link_names: true,
        },
      ],
    }
    for receiver_name in std.objectFields($._config.alertManagerReceivers)
  ],
}
