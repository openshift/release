{
  alertmanagerReceivers+:: [
    {
      name: 'slack-%s' % receiver_name,
      slack_configs: [
        {
          channel: '%s' % $._config.alertManagerReceivers[receiver_name].channel,
          api_url: '${SLACK_API_URL}',
          icon_url: 'https://user-images.githubusercontent.com/4013349/205364674-3fea6300-88ed-4a90-bc53-4ae5f65b16b0.png',
          text: '{{ .CommonAnnotations.message }}',
          link_names: true,
        },
      ],
    }
    for receiver_name in std.objectFields($._config.alertManagerReceivers)
  ],
}
