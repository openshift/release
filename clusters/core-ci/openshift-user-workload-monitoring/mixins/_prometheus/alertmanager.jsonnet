local receivers = (import 'alertmanager.libsonnet').alertmanagerReceivers;
local routes = (import 'alertmanager.libsonnet').alertmanagerRoutes;

{
  global: {
    resolve_timeout: '5m',
  },
  route: {
    group_by: [
      'alertname',
      'job',
    ],
    group_wait: '30s',
    group_interval: '5m',
    // Safety net: cap re-notification of a still-firing alert at once per day
    // so any residual flapping/noise that slips past the per-rule hysteresis
    // cannot re-page frequently. Individual routes may override.
    repeat_interval: '24h',
    receiver: 'slack-warnings',
    routes: routes,
  },
  receivers: receivers,
  templates: [],
}
