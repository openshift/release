local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local row = grafana.row;
local statPanel = grafana.statPanel;
local barGaugePanel = grafana.barGaugePanel;
local text = grafana.text;
local prometheus = grafana.prometheus;

// Grafana only renders a row as collapsed if its member panels are *nested*
// inside the row panel's own `panels` array — a top-level panel sitting below
// a `collapsed: true` row is simply not drawn. grafonnet's addPanel only ever
// appends flat, so this post-processes the finished panel list: every row
// except the named one swallows the panels that follow it, until the next row.
//
// Nested panels keep their gridPos, which is what lets Grafana lay them back
// out correctly when the row is expanded.
local collapseRowsExcept(keepOpen, panels) =
  local n = std.length(panels);
  local isRow(i) = panels[i].type == 'row';
  // Index arithmetic rather than a fold over an accumulator object: folding
  // here means every step inherits from the previous accumulator and re-slices
  // the whole output list, and appending members with `panels+:` stacks one
  // object-inheritance level per member (26 of them under Controller Loops).
  // That is cheap to *write* and expensive to *evaluate* — some jsonnet
  // implementations do not share memoization across those copies and grind to
  // a halt. Slicing each row's members out directly is flat and linear-ish.
  local nextRowAfter(i) =
    local later = [j for j in std.range(i + 1, n - 1) if isRow(j)];
    if std.length(later) > 0 then later[0] else n;
  local rowOwning(i) =
    local earlier = [j for j in std.range(0, i - 1) if isRow(j)];
    if std.length(earlier) > 0 then earlier[std.length(earlier) - 1] else -1;
  local isCollapsedRow(j) = j >= 0 && isRow(j) && panels[j].title != keepOpen;
  local mapped = std.makeArray(n, function(i)
    if isRow(i) && panels[i].title != keepOpen then
      panels[i] {
        collapse: true,
        collapsed: true,
        panels: panels[i + 1:nextRowAfter(i)],
      }
    else panels[i]);
  // Members of a collapsed row now live inside it, so drop them from the top
  // level; members of the kept-open row stay where they are.
  [mapped[i] for i in std.range(0, n - 1) if isRow(i) || !isCollapsedRow(rowOwning(i))];

local dashboardConfig = {
        uid: 'd69a91f76d8110d3e72885ee5ce8038e',
    };

// grafonnet-lib (vendored here) predates the "timeseries" panel type, so
// there's no builder for it upstream. This mirrors the shape of the other
// panel builders in vendor/grafonnet (self.addTarget with auto refId).
local timeseriesPanel(
    title,
    description=null,
    unit='short',
    min=null,
    max=null,
    drawStyle='line',
    fillOpacity=if drawStyle == 'bars' then 100 else 15,
    stacking=null,
    spanNulls=false,
    legendCalcs=['mean', 'lastNotNull', 'max'],
  ) = {
    type: 'timeseries',
    title: title,
    [if description != null then 'description']: description,
    datasource: 'prometheus',
    fieldConfig: {
      defaults: {
        unit: unit,
        [if min != null then 'min']: min,
        [if max != null then 'max']: max,
        custom: {
          drawStyle: drawStyle,
          lineInterpolation: if drawStyle == 'line' then 'smooth' else 'linear',
          lineWidth: 2,
          fillOpacity: fillOpacity,
          gradientMode: if drawStyle == 'line' then 'opacity' else 'none',
          spanNulls: spanNulls,
          showPoints: 'never',
          pointSize: 5,
          stacking: if stacking != null then stacking else { mode: 'none', group: 'A' },
          axisPlacement: 'auto',
        },
      },
      overrides: [],
    },
    options: {
      legend: {
        displayMode: 'table',
        placement: 'right',
        calcs: legendCalcs,
      },
      tooltip: {
        mode: 'multi',
        sort: 'desc',
      },
    },
    targets: [],
    _nextTarget:: 0,
    addTarget(target):: self {
      local nextTarget = super._nextTarget,
      _nextTarget: nextTarget + 1,
      targets+: [target { refId: std.char(std.codepoint('A') + nextTarget) }],
    },
  };

// grafonnet-lib has no builder for the "status history" panel either: a grid
// of one row per series and one cell per time bucket, colored by value. It is
// the only stock panel that puts a *categorical* axis (here repo:branch)
// opposite time — Grafana's heatmap panel only does numeric y-buckets, so it
// cannot express "repo on the y axis".
local statusHistoryPanel(
    title,
    description=null,
  ) = {
    type: 'status-history',
    title: title,
    [if description != null then 'description']: description,
    datasource: 'prometheus',
    fieldConfig: {
      defaults: {
        unit: 'short',
        min: 0,
        decimals: 0,
        color: { mode: 'continuous-GrYlRd' },
        custom: {
          fillOpacity: 100,
          lineWidth: 1,
        },
      },
      overrides: [],
    },
    options: {
      // No legend: this panel type legends the distinct *values* in the data
      // (it shares state-timeline's legend), not the series, so it can neither
      // label the rows — the y axis already does — nor total them. Totals come
      // from the bar gauge to the left. `displayMode` is the pre-10 key,
      // `showLegend` the modern one.
      legend: { displayMode: 'hidden', showLegend: false, placement: 'bottom' },
      tooltip: { mode: 'single', sort: 'none' },
      showValue: 'auto',
      rowHeight: 0.9,
      colWidth: 0.9,
    },
    targets: [],
    _nextTarget:: 0,
    addTarget(target):: self {
      local nextTarget = super._nextTarget,
      _nextTarget: nextTarget + 1,
      targets+: [target { refId: std.char(std.codepoint('A') + nextTarget) }],
    },
  };

local completenessThresholds = [
  { color: 'red', value: null },
  { color: 'yellow', value: 0.8 },
  { color: 'green', value: 0.95 },
];

// Pairs "how many GitHub search query shards did this controller issue, and
// how many succeeded/partially-failed/errored" with the resulting pool
// completeness ratio, all as one set of stat boxes instead of scattering them
// across several single-value gauge/stat panels.
local queryCompletenessPanel(controller, title) =
  (statPanel.new(
      title,
      description='Most recent %s-controller query cycle: how many GitHub search query shards succeeded, came back partial, or errored, alongside the resulting pool completeness ratio.' % controller,
      datasource='prometheus',
      unit='short',
      reducerFunction='lastNotNull',
      graphMode='none',
      colorMode='background',
      orientation='horizontal',
  ) + {
    fieldConfig+: {
      defaults+: {
        thresholds: { mode: 'absolute', steps: [{ color: 'green', value: null }] },
      },
      overrides+: [
        {
          matcher: { id: 'byName', options: 'Partial shards' },
          properties: [
            { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: 'green', value: null }, { color: 'yellow', value: 1 }] } },
          ],
        },
        {
          matcher: { id: 'byName', options: 'Error shards' },
          properties: [
            { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: 'green', value: null }, { color: 'red', value: 1 }] } },
          ],
        },
        {
          matcher: { id: 'byName', options: 'Completeness' },
          properties: [
            { id: 'unit', value: 'percentunit' },
            { id: 'thresholds', value: { mode: 'absolute', steps: completenessThresholds } },
          ],
        },
      ],
    },
  })
  .addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s", result="success"})' % controller,
      legendFormat='Success shards',
      instant=true,
  )).addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s", result="partial"})' % controller,
      legendFormat='Partial shards',
      instant=true,
  )).addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s", result="error"})' % controller,
      legendFormat='Error shards',
      instant=true,
  )).addTarget(prometheus.target(
      'max(tide_pool_completeness_ratio{controller="%s"})' % controller,
      legendFormat='Completeness',
      instant=true,
  ));

// Companion to queryCompletenessPanel: the same query-shard-outcome counts,
// plotted over time instead of as a single instant. Completeness itself is
// omitted here — it's success / (success + partial + error), so it's already
// implied by these bars and is redundant to also plot; the exact ratio is on
// the Current panel next to this one.
local queryCompletenessHistoryPanel(controller, title) =
  (timeseriesPanel(
      title,
      description='History of %s-controller GitHub search query shard outcomes.' % controller,
      unit='short',
      min=0,
      drawStyle='bars',
      fillOpacity=100,
      stacking={ mode: 'normal', group: 'A' },
      legendCalcs=['last', 'max'],
  ) + {
    fieldConfig+: {
      overrides+: [
        { matcher: { id: 'byName', options: 'success' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'green' } }] },
        { matcher: { id: 'byName', options: 'partial' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'yellow' } }] },
        { matcher: { id: 'byName', options: 'error' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'red' } }] },
      ],
    },
    options+: {
      legend+: { sortBy: 'Last', sortDesc: true },
    },
  })
  .addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s"}) by (result)' % controller,
      legendFormat='{{result}}',
  ));

local queryDurationCurrentPanel(controller, title) =
  (statPanel.new(
      title,
      description='Most recent p50/p95/p99 duration of %s-controller GitHub search queries.' % controller,
      datasource='prometheus',
      unit='s',
      reducerFunction='lastNotNull',
      graphMode='none',
      colorMode='background',
      orientation='horizontal',
  ) + {
    fieldConfig+: {
      defaults+: {
        thresholds: { mode: 'absolute', steps: [{ color: 'green', value: null }, { color: 'yellow', value: 30 }, { color: 'red', value: 60 }] },
      },
    },
  })
  .addTarget(prometheus.target(
      'histogram_quantile(0.50, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le))' % controller,
      legendFormat='p50',
      instant=true,
  )).addTarget(prometheus.target(
      'histogram_quantile(0.95, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le))' % controller,
      legendFormat='p95',
      instant=true,
  )).addTarget(prometheus.target(
      'histogram_quantile(0.99, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le))' % controller,
      legendFormat='p99',
      instant=true,
  ));

// p50 as a solid line, plus a shaded p95-p99 band. Grafana timeseries has no
// native fill-between-two-series, so this is faked with stacking: an
// invisible p95 "base" series stacked with a visible (p99 - p95) "spread"
// series on top of it — the visible band's top edge lands exactly at p99 and
// its bottom edge at p95.
local queryDurationHistoryPanel(controller, title) =
  (timeseriesPanel(
      title,
      description='%s-controller query duration: p50 line with a shaded p95-p99 spread band.' % controller,
      unit='s',
      min=0,
      legendCalcs=['last', 'max'],
  ) + {
    fieldConfig+: {
      overrides+: [
        { matcher: { id: 'byName', options: 'p50' }, properties: [
          { id: 'color', value: { mode: 'fixed', fixedColor: 'blue' } },
          { id: 'custom.lineWidth', value: 2 },
          { id: 'custom.fillOpacity', value: 0 },
        ] },
        { matcher: { id: 'byName', options: 'p95 (band base)' }, properties: [
          { id: 'custom.stacking', value: { mode: 'normal', group: 'band' } },
          { id: 'custom.lineWidth', value: 0 },
          { id: 'custom.fillOpacity', value: 0 },
          { id: 'custom.hideFrom', value: { legend: true, tooltip: true, viz: false } },
        ] },
        { matcher: { id: 'byName', options: 'p95-p99 spread' }, properties: [
          { id: 'custom.stacking', value: { mode: 'normal', group: 'band' } },
          { id: 'color', value: { mode: 'fixed', fixedColor: 'orange' } },
          { id: 'custom.lineWidth', value: 0 },
          { id: 'custom.fillOpacity', value: 25 },
        ] },
      ],
    },
    options+: {
      legend+: { sortBy: 'Last', sortDesc: true },
    },
  })
  .addTarget(prometheus.target(
      'histogram_quantile(0.50, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le))' % controller,
      legendFormat='p50',
  )).addTarget(prometheus.target(
      'histogram_quantile(0.95, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le))' % controller,
      legendFormat='p95 (band base)',
  )).addTarget(prometheus.target(
      'histogram_quantile(0.99, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le)) - histogram_quantile(0.95, sum(rate(tide_query_duration_seconds_bucket{controller="%s"}[5m])) by (le))' % [controller, controller],
      legendFormat='p95-p99 spread',
  ));

// Experimental alternative to queryDurationHistoryPanel: same "% of queries
// per outcome bucket" idiom as prsReturnedHistoryPanel, using the duration
// histogram's own boundaries. Live data (summed across pod incarnations,
// 1h rate) showed most mass concentrated under 20s for both controllers, but
// with a real second mode for sync specifically: ~46% of sync queries land
// in 10-20s, not smoothly tailing off like status does. That bucket is kept
// distinct (rather than merged into a single "slow" bucket) so this cluster
// stays visible. Unlike the PRs-returned buckets, none of these is extreme
// enough (sub-1%) to need a log axis — plain 0-100% stacking works.
local queryDurationBucketHistoryPanel(controller, title) =
  local bucket(hi, lo=null) =
    if lo == null then
      'sum(increase(tide_query_duration_seconds_bucket{controller="%s", le="%s"}[5m]))' % [controller, hi]
    else
      '(sum(increase(tide_query_duration_seconds_bucket{controller="%s", le="%s"}[5m]))) - (sum(increase(tide_query_duration_seconds_bucket{controller="%s", le="%s"}[5m])))' % [controller, hi, controller, lo];
  local total = 'sum(increase(tide_query_duration_seconds_bucket{controller="%s", le="+Inf"}[5m]))' % controller;
  (timeseriesPanel(
      title,
      description='History of %s-controller GitHub search query durations, bucketed by the histogram\'s own boundaries, as a %% of queries in each trailing 5m window.' % controller,
      unit='percentunit',
      min=0,
      max=1,
      drawStyle='bars',
      fillOpacity=100,
      stacking={ mode: 'normal', group: 'A' },
      legendCalcs=['last', 'max'],
  ) + {
    fieldConfig+: {
      overrides+: [
        { matcher: { id: 'byName', options: '<1s' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'green' } }] },
        { matcher: { id: 'byName', options: '1-5s' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'blue' } }] },
        { matcher: { id: 'byName', options: '5-10s' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'yellow' } }] },
        { matcher: { id: 'byName', options: '10-20s' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'orange' } }] },
        { matcher: { id: 'byName', options: '20s+' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'red' } }] },
      ],
    },
    options+: {
      legend+: { sortBy: '', sortDesc: false },
    },
  })
  .addTarget(prometheus.target(
      '(%s) / (%s)' % [bucket('1'), total],
      legendFormat='<1s',
  )).addTarget(prometheus.target(
      '(%s) / (%s)' % [bucket('5', '1'), total],
      legendFormat='1-5s',
  )).addTarget(prometheus.target(
      '(%s) / (%s)' % [bucket('10', '5'), total],
      legendFormat='5-10s',
  )).addTarget(prometheus.target(
      '(%s) / (%s)' % [bucket('20', '10'), total],
      legendFormat='10-20s',
  )).addTarget(prometheus.target(
      '(%s) / (%s)' % [bucket('+Inf', '20'), total],
      legendFormat='20s+',
  ));

// Errors are rare (fractions of a percent of total query volume), so a raw
// errors/sec rate rounds to an unreadable, uniformly-tiny number. Dividing by
// total query volume (tide_query_duration_seconds_count, which counts every
// query regardless of outcome) turns it into a meaningful percentage instead.
// This can only be an aggregate per controller — the denominator has no
// org_shard label (see project-tide-query-volume-lacks-org-label memory).
local queryErrorRateCurrentPanel(controller, title) =
  (statPanel.new(
      title,
      description='Share of %s-controller GitHub search queries that errored in the last 5m, out of all queries (success + partial + error) in that window.' % controller,
      datasource='prometheus',
      unit='percentunit',
      reducerFunction='lastNotNull',
      graphMode='area',
      colorMode='background',
  ).addThresholds([
      { color: 'green', value: null },
      { color: 'yellow', value: 0.01 },
      { color: 'red', value: 0.05 },
  ]))
  .addTarget(prometheus.target(
      // tide_query_errors_total's series only exist once a controller has
      // errored at least once (lazy label creation), so a controller with a
      // clean history has literally zero matching time series — sum() over
      // that is an empty result, not a 0, and an empty numerator makes the
      // whole division empty too, which Grafana renders as "No data" instead
      // of the accurate "0%". `or vector(0)` supplies that missing 0.
      '((sum(rate(tide_query_errors_total{controller="%s"}[5m]))) or vector(0)) / sum(rate(tide_query_duration_seconds_count{controller="%s"}[5m]))' % [controller, controller],
  ));

// Same underlying data as queryErrorRateCurrentPanel, but for the top-level
// "Is Tide OK?" row: raw counts (errors, total queries) side by side instead
// of a single computed percentage, so it reads as "x errors out of y" rather
// than an abstract rate.
local queryErrorCountPanel(controller, title) =
  (statPanel.new(
      title,
      description='%s-controller query shard outcomes from the most recent cycle: errored/partial shards vs. total shards (same underlying data as the Queries: Current panel below). Background is green when clean, yellow if any shard came back partial, red if any errored.' % controller,
      datasource='prometheus',
      unit='short',
      reducerFunction='lastNotNull',
      graphMode='none',
      colorMode='background',
      orientation='horizontal',
  ) + {
    fieldConfig+: {
      defaults+: {
        decimals: 0,
        thresholds: { mode: 'absolute', steps: [{ color: 'green', value: null }] },
      },
      overrides+: [
        {
          matcher: { id: 'byName', options: 'Errors' },
          properties: [
            { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: 'green', value: null }, { color: 'red', value: 1 }] } },
          ],
        },
        {
          matcher: { id: 'byName', options: 'Partials' },
          properties: [
            { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: 'green', value: null }, { color: 'yellow', value: 1 }] } },
          ],
        },
      ],
    },
  })
  .addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s", result="error"})' % controller,
      legendFormat='Errors',
      instant=true,
  )).addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s", result="partial"})' % controller,
      legendFormat='Partials',
      instant=true,
  )).addTarget(prometheus.target(
      'sum(tide_sync_query_shards{controller="%s"})' % controller,
      legendFormat='Total',
      instant=true,
  ));

// Companion history: raw error counts (not rate) per org_shard/error_class,
// so a spike reads as "3 errors from stolostron" instead of "0.0008 ops".
// Tying the increase() window to display resolution ($__interval /
// $__rate_interval) breaks down here: Tide is scraped every 30s, but this
// Grafana datasource's configured scrape interval is 5s, so even
// $__rate_interval's safety margin can resolve smaller than the real scrape
// cadence once zoomed in — the window then often contains 0-1 real samples,
// which reads as gaps or "no data". A plain fixed 5m increase() window
// sidesteps this regardless of zoom (well above the real scrape interval, so
// always several real samples) without smearing each burst far past its
// actual duration the way a wider smoothing window would.
local queryErrorRateHistoryPanel(controller, title) =
  local counts = 'sum(increase(tide_query_errors_total{controller="%s"}[5m])) by (org_shard, error_class)' % controller;
  (timeseriesPanel(
      title,
      description='History of %s-controller GitHub search query error counts by org shard and error class, in trailing 5m windows. Zero-count points are omitted, so a shard/class only appears while it actually has errors.' % controller,
      unit='short',
      min=0,
      drawStyle='bars',
      fillOpacity=100,
      stacking={ mode: 'normal', group: 'A' },
      legendCalcs=['last', 'max'],
  ) + {
    // increase() extrapolates to estimate the counter's true delta across the
    // exact window boundaries, so it returns a fractional estimate even
    // though the real underlying error count is a whole number. Round the
    // display only; the query itself is correct as-is.
    fieldConfig+: {
      defaults+: { decimals: 0 },
      overrides+: [
        // The `or vector(0)` fallback below has no org_shard/error_class
        // labels, so its legend substitutes to the literal string ":" — hide
        // that pseudo-series entirely. It only exists so the panel always has
        // at least one data point (a clean window otherwise has zero matching
        // time series, which Grafana renders as "No data" instead of "0
        // errors"); at value 0 on a bar chart it's invisible anyway.
        { matcher: { id: 'byName', options: ':' }, properties: [
          { id: 'custom.hideFrom', value: { legend: true, tooltip: true, viz: true } },
        ] },
      ],
    },
    options+: {
      legend+: { sortBy: 'Last', sortDesc: true },
    },
  })
  .addTarget(prometheus.target(
      '(%s) > 0 or vector(0)' % counts,
      legendFormat='{{org_shard}}:{{error_class}}',
  ));

// Partial results are queries that came back with an incomplete GitHub search
// result set rather than an outright error — same "how bad is this, as a
// share of total query volume" framing as queryErrorRateCurrentPanel, just
// for the partial-result counter instead of the error counter.
local queryPartialRateCurrentPanel(controller, title) =
  (statPanel.new(
      title,
      description='Share of %s-controller GitHub search queries that came back partial in the last 5m, out of all queries (success + partial + error) in that window.' % controller,
      datasource='prometheus',
      unit='percentunit',
      reducerFunction='lastNotNull',
      graphMode='area',
      colorMode='background',
  ).addThresholds([
      { color: 'green', value: null },
      { color: 'yellow', value: 0.01 },
      { color: 'red', value: 0.05 },
  ]))
  .addTarget(prometheus.target(
      // See queryErrorRateCurrentPanel: the `or vector(0)` fallback keeps a
      // clean-history controller from dividing an empty numerator (empty, not
      // 0, since tide_query_partial_results_total has no series until the
      // first partial result ever happens) into "No data".
      '((sum(rate(tide_query_partial_results_total{controller="%s"}[5m]))) or vector(0)) / sum(rate(tide_query_duration_seconds_count{controller="%s"}[5m]))' % [controller, controller],
  ));

// Companion history to queryPartialRateCurrentPanel, same shape as
// queryErrorRateHistoryPanel: raw partial-result counts by org_shard in
// trailing 5m windows, zero-count points omitted.
local queryPartialRateHistoryPanel(controller, title) =
  local counts = 'sum(increase(tide_query_partial_results_total{controller="%s"}[5m])) by (org_shard)' % controller;
  (timeseriesPanel(
      title,
      description='History of %s-controller GitHub search partial-result counts by org shard, in trailing 5m windows. Zero-count points are omitted, so a shard only appears while it actually has partial results.' % controller,
      unit='short',
      min=0,
      drawStyle='bars',
      fillOpacity=100,
      stacking={ mode: 'normal', group: 'A' },
      legendCalcs=['last', 'max'],
  ) + {
    fieldConfig+: {
      defaults+: { decimals: 0 },
      overrides+: [
        // See queryErrorRateHistoryPanel: hides the always-present fallback
        // series that keeps a clean window from showing "No data". The
        // fallback carries an explicit org_shard="—" (rather than no label
        // at all) purely so it has a stable, matchable field name: a legend
        // format that renders to the empty string is not applied as the
        // field name, so Grafana would fall back to naming the field after
        // the raw PromQL and this override would never fire.
        { matcher: { id: 'byName', options: '—' }, properties: [
          { id: 'custom.hideFrom', value: { legend: true, tooltip: true, viz: true } },
        ] },
      ],
    },
    options+: {
      legend+: { sortBy: 'Last', sortDesc: true },
    },
  })
  .addTarget(prometheus.target(
      '(%s) > 0 or label_replace(vector(0), "org_shard", "—", "", "")' % counts,
      legendFormat='{{org_shard}}',
  ));

// PRs-returned-per-query turned out to be extremely skewed and coarsely
// bucketed (le boundaries: 0, 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500,
// +Inf) — live data showed 84% of sync queries and 29% of status queries
// return exactly 0 PRs, ~97%/95% return <=5, and well under 1% ever exceed
// 25. A percentile line is the wrong shape for this: p50 sits pinned at 0/1
// (flat, uninformative) while any percentile near the tail jumps discretely
// between bucket edges (0, 1, 5, 10, 25, ...), reading as noisy spikes on a
// linear axis. A stacked breakdown by outcome bucket shows the actual shape
// of the distribution instead, consistent with the outcome-bar style already
// used for query completeness/errors/partials in this section. Buckets are
// derived by subtracting adjacent cumulative histogram buckets (le="5" minus
// le="0" = count of queries returning 1-5 PRs, etc.). Expressed as a % of
// queries in the window rather than a raw count: a fixed 5m increase()
// window covers a variable number of sync/status loop cycles (currently ~2.7
// at sync's ~225s loop time), so the raw count doesn't line up with the
// single-cycle "Total" shown on the Queries: Current panel above and reads as
// implausibly large by comparison. The percentage is window-size-independent
// and is what this panel is actually trying to show anyway: the shape of the
// distribution, not a volume count.
// A dual right-axis kept the tail visible but at the cost of two independent
// scales on one chart, which reads as confusing rather than clarifying. Log
// scale solves the same "tiny value lost next to huge ones" problem on a
// single shared axis instead: it expands the low end (where 0.1% vs 1% is a
// meaningful difference) and compresses the high end (where 80% vs 90%
// barely matters), so all four buckets are legible together without
// splitting the chart's scale. That also rules out the 100%-stacked-bar
// layout (a log axis can't sensibly represent a running stack total), so
// these are now overlapping (unstacked) lines instead. Log scale cannot
// represent 0, so zero-value points are filtered out per bucket — consistent
// with how the error/partial history panels elsewhere already omit
// zero-count points rather than plotting them.
local prsReturnedHistoryPanel(controller, title) =
  local bucket(hi, lo=null) =
    if lo == null then
      'sum(increase(tide_query_prs_returned_bucket{controller="%s", le="%s"}[5m]))' % [controller, hi]
    else
      '(sum(increase(tide_query_prs_returned_bucket{controller="%s", le="%s"}[5m]))) - (sum(increase(tide_query_prs_returned_bucket{controller="%s", le="%s"}[5m])))' % [controller, hi, controller, lo];
  local total = 'sum(increase(tide_query_prs_returned_bucket{controller="%s", le="+Inf"}[5m]))' % controller;
  (timeseriesPanel(
      title,
      description='History of %s-controller GitHub search queries by how many PRs they returned, as a %% of queries in each trailing 5m window. Log-scaled so the rare 26+ PRs tail (usually well under 1%%) stays legible next to the dominant buckets; zero-value points are omitted since a log axis can\'t represent them.' % controller,
      unit='percentunit',
      drawStyle='line',
      fillOpacity=0,
      legendCalcs=['last', 'max'],
  ) + {
    fieldConfig+: {
      defaults+: {
        custom+: { scaleDistribution: { type: 'log', log: 10 } },
      },
      overrides+: [
        { matcher: { id: 'byName', options: '0 PRs' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'dark-blue' } }] },
        { matcher: { id: 'byName', options: '1-5 PRs' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'blue' } }] },
        { matcher: { id: 'byName', options: '6-25 PRs' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'orange' } }] },
        { matcher: { id: 'byName', options: '26+ PRs' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'red' } }] },
      ],
    },
    // Grafana's legend has no built-in "sort by bucket order" option (only
    // sort-by-calc-value), so the natural small-to-large bucket order is
    // achieved by adding targets in that exact order instead — the
    // legend/tooltip list follows query/target order when no sortBy is set.
    options+: {
      legend+: { sortBy: '', sortDesc: false },
    },
  })
  .addTarget(prometheus.target(
      '(%s) / (%s) > 0' % [bucket('0'), total],
      legendFormat='0 PRs',
  )).addTarget(prometheus.target(
      '(%s) / (%s) > 0' % [bucket('5', '0'), total],
      legendFormat='1-5 PRs',
  )).addTarget(prometheus.target(
      '(%s) / (%s) > 0' % [bucket('25', '5'), total],
      legendFormat='6-25 PRs',
  )).addTarget(prometheus.target(
      '(%s) / (%s) > 0' % [bucket('+Inf', '25'), total],
      legendFormat='26+ PRs',
  ));

// Tide lazily creates a merges_sum label combination on its first Observe()
// per pod lifetime, instead of pre-registering it at 0. increase()/rate() need
// a prior sample to measure a delta, so a repo's *first* merge after each Tide
// restart is invisible to plain increase() queries: the series jumps straight
// to its final value with no earlier "0" to diff against. This adds back that
// missing delta for any series that exists now but didn't exist at the start
// of the window (a "brand new" series).
//
// The amount to add back is the series' *first* scraped value, not its
// current one: increase() over a young series still measures from its first
// sample to its last (Prometheus extrapolates back at most half a scrape
// interval, never all the way to zero), so what it misses is exactly the
// jump from nothing to that first sample. For a monotonic counter that first
// value is min_over_time(merges_sum[window]). Crediting the current value
// instead would double-count everything the series has done since its first
// scrape.
// Plain vector `+` only keeps series present on BOTH sides (one-to-one
// matching), and the correction term is only ever nonempty for brand-new
// series — so without the `or` fallbacks below, every ordinary (non-buggy)
// series has no match on the right and gets silently dropped by the `+`,
// not just left uncorrected. Both fallbacks are needed, in this order:
// `or <correction>` recovers groups that exist *only* in the correction term
// (a brand-new series with a single sample in the window produces no
// increase() output at all, which is exactly the case this correction is
// for), and `or <plain increase>` recovers the ordinary groups that have no
// correction.
//
// The "brand new series" check itself must run at merges_sum's own full
// label granularity (org, repo, branch, plus Prometheus's own pod/instance
// labels) *before* any `by (byLabels)` grouping, not after: `unless` matches
// on complete label sets, so pre-aggregating with `by (byLabels)` first (e.g.
// `by (org)`, or `by ()` for a global total) collapses many distinct repos
// into one series before the existence check runs. If that org (or the
// global total) already had *any* merge before the window, the aggregated
// "before" series exists, `unless` finds a match, and the entire correction
// for every other repo in that group — including genuinely brand-new
// series — gets silently dropped. Verified live: right after a Tide restart,
// grouping `by (org)` this way undercounted a busy org's 3h merge count by
// more than half (13 vs the correct 32) versus computing the correction at
// full per-series granularity first and only summing `by (org)` afterward.
// mergesIncreasePinned: for instant queries, gates, or any "value as of now"
// use — pins the correction to the query's own evaluation instant.
local mergesIncreasePinned(window, byLabels) =
  local plain = 'sum(increase(merges_sum[%s])) by (%s)' % [window, byLabels];
  local newSinceWindow = 'sum(min_over_time(merges_sum[%s] @ end()) unless (merges_sum @ end() offset %s)) by (%s)' % [window, window, byLabels];
  '((%s) + (%s)) or (%s) or (%s)' % [plain, newSinceWindow, newSinceWindow, plain];
// mergesIncreaseTrend: for the per-point base expression of a range/trend
// panel — leaves timestamps unpinned so every plotted point gets its own
// correction, not just the panel's last point.
local mergesIncreaseTrend(window, byLabels) =
  local plain = 'sum(increase(merges_sum[%s])) by (%s)' % [window, byLabels];
  local newSinceWindow = 'sum(min_over_time(merges_sum[%s]) unless (merges_sum offset %s)) by (%s)' % [window, window, byLabels];
  '((%s) + (%s)) or (%s) or (%s)' % [plain, newSinceWindow, newSinceWindow, plain];
// Same idea as mergesIncreasePinned, but for the "same 1h window, 24h ago"
// comparison — the whole thing (plain increase, and the new-series check)
// has to shift by that same 24h, not just the increase() window, or the
// correction ends up checking "new since now" instead of "new since 24h
// ago". Verified live: the uncorrected version of this query returned 0,
// the corrected one returned 23 — Tide's restart cadence (several times a
// day) makes a 24-25h-old window very likely to straddle one.
local mergesIncreasePinnedSameHourYesterday =
  local plain = 'sum(increase(merges_sum[1h] offset 24h))';
  local newSinceWindow = 'sum(min_over_time(merges_sum[1h] @ end() offset 24h) unless (merges_sum @ end() offset 25h))';
  '((%s) + (%s)) or (%s) or (%s)' % [plain, newSinceWindow, newSinceWindow, plain];

// "Time since last merge, anywhere" has no direct metric — merges_sum only
// exposes its cumulative value, not when it last changed. This derives it:
// `changes(merges_sum[3m]) > 0` is true only in the brief window right after
// a real merge (long enough to span >=2 scrapes at Tide's 30s interval);
// ANDing that onto `timestamp(merges_sum)` yields the sample's real scrape
// time only during that brief window, and absent otherwise; `last_over_time`
// over a wide subquery then carries that timestamp forward so it reads
// continuously instead of just flashing for a few seconds. 3d is a
// performance/safety tradeoff, not a real limit — a 7d version of this same
// query took ~19s to evaluate vs ~3s for 3d; if Tide goes 3 real days without
// merging anything this panel goes blank, which is itself a loud signal.
//
// Same lazy-series-creation issue as mergesIncreasePinned/mergesIncreaseTrend
// applies here too, and this expression didn't originally have the fix: a
// repo's *first* merge after a Tide restart creates a brand-new merges_sum
// series with only one sample in the 3m window, so changes() can't see a
// delta and that merge is invisible to the check above. Right after a
// restart (or two, in quick succession) this makes the panel show a stale
// pre-restart timestamp — "time since last merge" that's actually "time
// since the last merge that happened to be a repo's *second-or-later* merge
// since its series was last (re)created" — even while merges are actively
// happening. The second `or` branch below catches a series that exists now
// but didn't 3m ago (i.e. just lazily created) and credits its current
// timestamp as a merge, same idea as the `unless`-based correction above.
local timeSinceLastMergeExpr =
  'time() - max(last_over_time((timestamp(merges_sum) and ((changes(merges_sum[3m]) > 0) or (merges_sum unless merges_sum offset 3m)))[3d:1m]))';

dashboard.new(
        'tide dashboard',
        time_from='now-2d',
        schemaVersion=40,
      )
.addPanel(
    row.new('Is Tide OK?'), gridPos={
    h: 1,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (statPanel.new(
        'Tide Process',
        description="Is the Tide process up and being scraped.",
        datasource='prometheus',
        unit='none',
        reducerFunction='lastNotNull',
        graphMode='none',
        colorMode='background',
    ).addThresholds([
        { color: 'red', value: null },
        { color: 'green', value: 1 },
    ]) + {
      fieldConfig+: {
        defaults+: {
          mappings: [
            { type: 'value', options: { '1': { text: 'UP' }, '0': { text: 'DOWN' } } },
          ],
        },
      },
    })
    .addTarget(prometheus.target(
        'up{job="tide"}',
        instant=true,
    )), gridPos={
    h: 6,
    w: 3,
    x: 0,
    y: 1,
  })
.addPanel(
    (statPanel.new(
        'Restarts (24h)',
        description="Container restarts of the Tide pod in the last 24h. Any value above 0 means the process crashed and was restarted, not a routine rollout to a new pod.",
        datasource='prometheus',
        unit='short',
        reducerFunction='lastNotNull',
        graphMode='none',
        colorMode='background',
    ).addThresholds([
        { color: 'green', value: null },
        { color: 'red', value: 1 },
    ]) + {
      // increase() extrapolates, so a single restart renders as e.g. 1.05
      // without this — a restart count with decimals just reads as broken.
      fieldConfig+: { defaults+: { decimals: 0 } },
    })
    .addTarget(prometheus.target(
        'sum(increase(kube_pod_container_status_restarts_total{job="kube-state-metrics", namespace="ci", container="tide"}[24h]))',
        instant=true,
    )), gridPos={
    h: 6,
    w: 3,
    x: 3,
    y: 1,
  })
.addPanel(
    (statPanel.new(
        'Pod Age',
        description="How long the current Tide pod has been running.",
        datasource='prometheus',
        unit='s',
        reducerFunction='lastNotNull',
        graphMode='none',
        colorMode='value',
    ))
    .addTarget(prometheus.target(
        'time() - process_start_time_seconds{job="tide"}',
        instant=true,
    )), gridPos={
    h: 6,
    w: 3,
    x: 6,
    y: 1,
  })
.addPanel(
    (statPanel.new(
        'Time Since Last Merge',
        description="Time since Tide last merged a PR, in any org. Derived from merges_sum (no direct metric for this); goes blank if Tide hasn't merged anything in over 3 days.",
        datasource='prometheus',
        unit='s',
        reducerFunction='lastNotNull',
        graphMode='none',
        colorMode='background',
    ).addThresholds([
        { color: 'green', value: null },
        { color: 'yellow', value: 3600 },
        { color: 'red', value: 14400 },
    ]))
    .addTarget(prometheus.target(
        timeSinceLastMergeExpr,
        instant=true,
    )), gridPos={
    h: 6,
    w: 3,
    x: 9,
    y: 1,
  })
.addPanel(
    queryErrorCountPanel('sync', 'Sync Query Errors'), gridPos={
    h: 6,
    w: 4,
    x: 12,
    y: 1,
  })
.addPanel(
    queryErrorCountPanel('status', 'Status Query Errors'), gridPos={
    h: 6,
    w: 4,
    x: 16,
    y: 1,
  })
.addPanel(
    (statPanel.new(
        'Merged: Last 1h vs. Same Hour Yesterday',
        description="Total PRs merged (any org) in the trailing 1h, compared to the same 1h-wide window 24h ago.",
        datasource='prometheus',
        unit='short',
        reducerFunction='lastNotNull',
        graphMode='none',
        colorMode='value',
        orientation='horizontal',
    ) + {
      fieldConfig+: {
        defaults+: { decimals: 0 },
      },
    })
    .addTarget(prometheus.target(
        mergesIncreasePinned('1h', ''),
        legendFormat='Last 1h',
        instant=true,
    )).addTarget(prometheus.target(
        mergesIncreasePinnedSameHourYesterday,
        legendFormat='Same hour yesterday',
        instant=true,
    )), gridPos={
    h: 6,
    w: 4,
    x: 20,
    y: 1,
  })
.addPanel(
    row.new('Are We Merging PRs?'), gridPos={
    h: 1,
    w: 24,
    x: 0,
    y: 7,
  })
.addPanel(
    (barGaugePanel.new(
        'PRs Merged by Org (last 3h)',
        description="PRs merged per org in the last 3 hours, sorted descending (batches count all their PRs). Orgs with zero merges in the window are omitted.",
        datasource='prometheus',
        unit='short',
        thresholds=[
          { color: 'green', value: null },
        ],
    ) + {
      // increase() extrapolates a fractional estimate of the counter's true
      // delta across the window boundaries; the real merge count is a whole
      // number, so round the display only.
      fieldConfig+: {
        defaults+: { decimals: 0 },
      },
      options: {
        reduceOptions: { values: false, calcs: ['lastNotNull'], fields: '' },
        orientation: 'horizontal',
        displayMode: 'gradient',
        valueMode: 'color',
      },
    })
    .addTarget(prometheus.target(
        'sort_desc((' + mergesIncreasePinned('3h', 'org') + ') > 0)',
        legendFormat='{{org}}',
        instant=true,
    )), gridPos={
    h: 9,
    w: 8,
    x: 0,
    y: 8,
  })
.addPanel(
    (timeseriesPanel(
        'PRs Merged by Org (3h sliding window)',
        description="Trend of the trailing-3h merged-PR count, restricted to orgs currently merging (same org set as the bar gauge to the left).",
        unit='short',
        min=0,
        legendCalcs=['last', 'max'],
    ) + {
      fieldConfig+: {
        defaults+: { decimals: 0 },
      },
      options+: {
        legend+: {
          sortBy: 'Last',
          sortDesc: true,
        },
      },
    })
    .addTarget(prometheus.target(
        '(' + mergesIncreaseTrend('3h', 'org') + ') and on(org) ((' + mergesIncreasePinned('3h', 'org') + ') > 0)',
        legendFormat='{{org}}',
    )), gridPos={
    h: 9,
    w: 8,
    x: 8,
    y: 8,
  })
.addPanel(
    (timeseriesPanel(
        'PRs Merged by Org (24h sliding window)',
        description="Trend of the trailing-24h merged-PR count, restricted to orgs currently merging.",
        unit='short',
        min=0,
        legendCalcs=['last', 'max'],
    ) + {
      fieldConfig+: {
        defaults+: { decimals: 0 },
      },
      options+: {
        legend+: {
          sortBy: 'Last',
          sortDesc: true,
        },
      },
    })
    .addTarget(prometheus.target(
        '(' + mergesIncreaseTrend('24h', 'org') + ') and on(org) ((' + mergesIncreasePinned('24h', 'org') + ') > 0)',
        legendFormat='{{org}}',
    )), gridPos={
    h: 9,
    w: 8,
    x: 16,
    y: 8,
  })
.addPanel(
    (barGaugePanel.new(
        'Nonzero Pool Sizes (current)',
        description="Tide pools that currently have at least one PR eligible for merge, by repo, sorted descending. Color reflects pool size: green is small, red is large.",
        datasource='prometheus',
        unit='short',
        thresholds=[
          { color: 'green', value: null },
        ],
    ) + {
      fieldConfig+: {
        defaults+: {
          color: { mode: 'continuous-GrYlRd' },
        },
      },
      options: {
        reduceOptions: { values: false, calcs: ['lastNotNull'], fields: '' },
        orientation: 'horizontal',
        displayMode: 'basic',
        valueMode: 'color',
      },
    })
    .addTarget(prometheus.target(
        'sort_desc((avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch)) > 0)',
        legendFormat='{{org}}/{{repo}}:{{branch}}',
        instant=true,
    )), gridPos={
    h: 9,
    w: 6,
    x: 0,
    y: 17,
  })
.addPanel(
    (timeseriesPanel(
        'Pool Sizes (current pools)',
        description="Trend of pool size, restricted to repos currently in a nonzero pool (same repo set as the bar gauge to the left) whose pool size exceeded 1 at some point in the visible window. Gaps are real: either the pool emptied or the data went stale (Tide never emits an explicit 0).",
        unit='short',
        min=0,
        legendCalcs=['last', 'max'],
    ) + {
      options+: {
        legend+: {
          sortBy: 'Last',
          sortDesc: true,
        },
      },
    })
    .addTarget(prometheus.target(
        '(avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch)) and on(org, repo, branch) (last_over_time((avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch))[1m:] @ end()) > 0) and on(org, repo, branch) (max_over_time((avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch))[$__range:1h] @ end()) > 1)',
        legendFormat='{{org}}/{{repo}}:{{branch}}',
    )), gridPos={
    h: 9,
    w: 12,
    x: 6,
    y: 17,
  })
.addPanel(
    (barGaugePanel.new(
        'Nonzero Pool, No Merges (sustained 4h)',
        description="Repos whose pool has stayed nonzero for the last 4h straight (no gaps longer than ~10m) but that had zero merges in the same 4h window. Sorted descending by current pool size.",
        datasource='prometheus',
        unit='short',
        thresholds=[
          { color: 'red', value: null },
        ],
    ) + {
      options: {
        reduceOptions: { values: false, calcs: ['lastNotNull'], fields: '' },
        orientation: 'horizontal',
        displayMode: 'gradient',
        valueMode: 'color',
      },
    })
    .addTarget(prometheus.target(
        'sort_desc((avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch)) and on(org, repo, branch) (count_over_time((avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch))[4h:5m]) >= 47) unless on(org, repo, branch) ((' + mergesIncreasePinned('4h', 'org, repo, branch') + ') > 0))',
        legendFormat='{{org}}/{{repo}}:{{branch}}',
        instant=true,
    )), gridPos={
    h: 9,
    w: 6,
    x: 18,
    y: 17,
  })
.addPanel(
    row.new('Which Repos Are Merging?'), gridPos={
    h: 1,
    w: 24,
    x: 0,
    y: 26,
  })
.addPanel(
    // Repo-level counterpart to the by-org bar gauge above, deliberately
    // built the same way (same thresholds/orientation/gradient) so the two
    // read as one family. The >5 floor keeps this to repos with real merge
    // volume — the long tail of repos that merged once or twice a day would
    // otherwise crowd out everything worth looking at.
    //
    // Sits beside the activity grid rather than above it because the grid
    // cannot render a per-row total itself: status-history shares its legend
    // with state-timeline, which legends the distinct *values* in the data
    // rather than the series, so legend calcs are ignored outright. This is
    // where the grid's totals come from. Note the two are not row-aligned —
    // this gauge is sorted by count, the grid's rows are alphabetical (its
    // row order is frame order, which Prometheus returns sorted by label).
    (barGaugePanel.new(
        'PRs Merged by Repo (last 24h)',
        description="PRs merged per repo in the last 24 hours, sorted descending (batches count all their PRs). Limited to repos with more than 5 merges in the window.",
        datasource='prometheus',
        unit='short',
        thresholds=[
          { color: 'green', value: null },
        ],
    ) + {
      // See "PRs Merged by Org": increase() estimates a fractional delta, so
      // round the display only.
      fieldConfig+: {
        defaults+: { decimals: 0 },
      },
      options: {
        reduceOptions: { values: false, calcs: ['lastNotNull'], fields: '' },
        orientation: 'horizontal',
        displayMode: 'gradient',
        valueMode: 'color',
      },
    })
    .addTarget(prometheus.target(
        'sort_desc((' + mergesIncreasePinned('24h', 'org, repo, branch') + ') > 5)',
        legendFormat='{{org}}/{{repo}}:{{branch}}',
        instant=true,
    )), gridPos={
    h: 14,
    w: 6,
    x: 0,
    y: 27,
  })
.addPanel(
    // Same data as the stacked columns above, laid out as a grid instead: one
    // row per repo:branch, one cell per 30m block, colored by how many merges
    // landed in it. Trades the stacked view's "total merges this hour" for a
    // per-repo rhythm that survives having many repos on screen — a stack of
    // 40+ segments turns into mush, 40 rows do not. Zero cells are filtered
    // out entirely so idle blocks stay blank rather than rendering as a
    // uniform floor of "0" tiles.
    (statusHistoryPanel(
        'Merge Activity Grid (30m blocks)',
        description="Merges per repo per 30-minute block. Each row is a repo:branch, each cell a 30m window, colored by merge count (blank means none). Same repo set as the panels above: more than 5 merges in the last 24h.",
    ))
    .addTarget(prometheus.target(
        '((' + mergesIncreaseTrend('30m', 'org, repo, branch') + ') and on(org, repo, branch) ((' + mergesIncreasePinned('24h', 'org, repo, branch') + ') > 5)) > 0',
        legendFormat='{{org}}/{{repo}}:{{branch}}',
        // See "Merges per Hour by Repo": without this the default
        // intervalFactor of 2 turns the requested 30m step into 1h blocks.
        intervalFactor=1,
        interval='30m',
    )), gridPos={
    h: 14,
    w: 18,
    x: 6,
    y: 27,
  })
.addPanel(
    row.new('Controller Loops'), gridPos={
    h: 1,
    w: 24,
    x: 0,
    y: 41,
  })
.addPanel(
    text.new(
        'Sync Controller',
        mode='markdown',
        content=|||
          <div style="background:#1f3b57;padding:6px 10px;border-radius:4px;margin:-8px -8px 8px -8px;">
          <b style="font-size:1.1em;">Sync Controller</b>
          </div>

          Searches Tide's configured merge-pool queries for mergeable PRs and merges or retests them. Query volume roughly tracks the number of configured queries — each configured query is essentially one GitHub search "bucket" — but there's internal batching/filtering per query, so it's not a strict 1:1.
        |||,
    ), gridPos={
    h: 4,
    w: 12,
    x: 0,
    y: 42,
  })
.addPanel(
    text.new(
        'Status Controller',
        mode='markdown',
        content=|||
          <div style="background:#1f4d3b;padding:6px 10px;border-radius:4px;margin:-8px -8px 8px -8px;">
          <b style="font-size:1.1em;">Status Controller</b>
          </div>

          Searches for PRs that may have recently become (or stopped being) mergeable, to keep each PR's GitHub status/labels/context up to date. Unlike sync, these searches are collapsed into org-wide queries rather than following the per-configured-query shape.
        |||,
    ), gridPos={
    h: 4,
    w: 12,
    x: 12,
    y: 42,
  })
.addPanel(
    (statPanel.new(
        'Sync Loop: Current',
        description="Duration of Tide's most recent sync-controller loop (fetch pools, evaluate mergeability, merge). Colored against the configured sync_period (2m45s = 165s): yellow at 80% of the period, red at or above it — red means loops are taking longer than the interval that's supposed to trigger the next one.",
        datasource='prometheus',
        unit='s',
        reducerFunction='lastNotNull',
        graphMode='area',
        colorMode='background',
    ).addThresholds([
        { color: 'green', value: null },
        { color: 'yellow', value: 132 },
        { color: 'red', value: 165 },
    ]))
    .addTarget(prometheus.target(
        'max(syncdur{job="tide"} and (changes(syncdur{job="tide"}[1h]) > 0))',
    )), gridPos={
    h: 9,
    w: 4,
    x: 0,
    y: 46,
  })
.addPanel(
    (timeseriesPanel(
        'Sync Loop: History',
        description="Trend of sync-controller loop duration. Dashed line marks the configured sync_period (2m45s) for comparison.",
        unit='s',
        min=0,
        legendCalcs=['last', 'max'],
    ) + {
      fieldConfig+: {
        defaults+: {
          custom+: { lineInterpolation: 'stepAfter' },
        },
        overrides+: [
          {
            matcher: { id: 'byName', options: 'sync_period (2m45s)' },
            properties: [
              { id: 'color', value: { mode: 'fixed', fixedColor: 'red' } },
              { id: 'custom.lineStyle', value: { fill: 'dash', dash: [10, 10] } },
              { id: 'custom.fillOpacity', value: 0 },
            ],
          },
        ],
      },
      options+: {
        legend+: { sortBy: 'Last', sortDesc: true },
      },
    })
    .addTarget(prometheus.target(
        'max(syncdur{job="tide"} and (changes(syncdur{job="tide"}[1h]) > 0))',
        legendFormat='sync loop duration',
    )).addTarget(prometheus.target(
        'vector(165)',
        legendFormat='sync_period (2m45s)',
    )), gridPos={
    h: 9,
    w: 8,
    x: 4,
    y: 46,
  })
.addPanel(
    (statPanel.new(
        'Status Loop: Current',
        description="Duration of Tide's most recent status-controller loop (updates GitHub statuses/labels for PRs in pools). Colored against the configured status_update_period (2m30s = 150s): yellow at 80% of the period, red at or above it — red means updates are falling behind their trigger cadence.",
        datasource='prometheus',
        unit='s',
        reducerFunction='lastNotNull',
        graphMode='area',
        colorMode='background',
    ).addThresholds([
        { color: 'green', value: null },
        { color: 'yellow', value: 120 },
        { color: 'red', value: 150 },
    ]))
    .addTarget(prometheus.target(
        'max(statusupdatedur{job="tide"} and (changes(statusupdatedur{job="tide"}[1h]) > 0))',
    )), gridPos={
    h: 9,
    w: 4,
    x: 12,
    y: 46,
  })
.addPanel(
    (timeseriesPanel(
        'Status Loop: History',
        description="Trend of status-controller loop duration. Dashed line marks the configured status_update_period (2m30s) for comparison.",
        unit='s',
        min=0,
        legendCalcs=['last', 'max'],
    ) + {
      fieldConfig+: {
        defaults+: {
          custom+: { lineInterpolation: 'stepAfter' },
        },
        overrides+: [
          {
            matcher: { id: 'byName', options: 'status_update_period (2m30s)' },
            properties: [
              { id: 'color', value: { mode: 'fixed', fixedColor: 'red' } },
              { id: 'custom.lineStyle', value: { fill: 'dash', dash: [10, 10] } },
              { id: 'custom.fillOpacity', value: 0 },
            ],
          },
        ],
      },
      options+: {
        legend+: { sortBy: 'Last', sortDesc: true },
      },
    })
    .addTarget(prometheus.target(
        'max(statusupdatedur{job="tide"} and (changes(statusupdatedur{job="tide"}[1h]) > 0))',
        legendFormat='status loop duration',
    )).addTarget(prometheus.target(
        'vector(150)',
        legendFormat='status_update_period (2m30s)',
    )), gridPos={
    h: 9,
    w: 8,
    x: 16,
    y: 46,
  })
.addPanel(
    queryCompletenessPanel('sync', 'Sync Queries: Current'), gridPos={
    h: 9,
    w: 4,
    x: 0,
    y: 55,
  })
.addPanel(
    queryCompletenessHistoryPanel('sync', 'Sync Queries: History'), gridPos={
    h: 9,
    w: 8,
    x: 4,
    y: 55,
  })
.addPanel(
    queryCompletenessPanel('status', 'Status Queries: Current'), gridPos={
    h: 9,
    w: 4,
    x: 12,
    y: 55,
  })
.addPanel(
    queryCompletenessHistoryPanel('status', 'Status Queries: History'), gridPos={
    h: 9,
    w: 8,
    x: 16,
    y: 55,
  })
.addPanel(
    queryErrorRateCurrentPanel('sync', 'Sync Error Rate (5m)'), gridPos={
    h: 5,
    w: 4,
    x: 0,
    y: 64,
  })
.addPanel(
    queryErrorRateHistoryPanel('sync', 'Sync Errors: History'), gridPos={
    h: 5,
    w: 8,
    x: 4,
    y: 64,
  })
.addPanel(
    queryErrorRateCurrentPanel('status', 'Status Error Rate (5m)'), gridPos={
    h: 5,
    w: 4,
    x: 12,
    y: 64,
  })
.addPanel(
    queryErrorRateHistoryPanel('status', 'Status Errors: History'), gridPos={
    h: 5,
    w: 8,
    x: 16,
    y: 64,
  })
.addPanel(
    queryPartialRateCurrentPanel('sync', 'Sync Partial Rate (5m)'), gridPos={
    h: 5,
    w: 4,
    x: 0,
    y: 69,
  })
.addPanel(
    queryPartialRateHistoryPanel('sync', 'Sync Partials: History'), gridPos={
    h: 5,
    w: 8,
    x: 4,
    y: 69,
  })
.addPanel(
    queryPartialRateCurrentPanel('status', 'Status Partial Rate (5m)'), gridPos={
    h: 5,
    w: 4,
    x: 12,
    y: 69,
  })
.addPanel(
    queryPartialRateHistoryPanel('status', 'Status Partials: History'), gridPos={
    h: 5,
    w: 8,
    x: 16,
    y: 69,
  })
.addPanel(
    queryDurationCurrentPanel('sync', 'Sync Query Duration: Current'), gridPos={
    h: 15,
    w: 4,
    x: 0,
    y: 74,
  })
.addPanel(
    queryDurationHistoryPanel('sync', 'Sync Query Duration: History'), gridPos={
    h: 9,
    w: 8,
    x: 4,
    y: 74,
  })
.addPanel(
    queryDurationBucketHistoryPanel('sync', 'Sync Query Duration Buckets (experimental)'), gridPos={
    h: 6,
    w: 8,
    x: 4,
    y: 83,
  })
.addPanel(
    queryDurationCurrentPanel('status', 'Status Query Duration: Current'), gridPos={
    h: 15,
    w: 4,
    x: 12,
    y: 74,
  })
.addPanel(
    queryDurationHistoryPanel('status', 'Status Query Duration: History'), gridPos={
    h: 9,
    w: 8,
    x: 16,
    y: 74,
  })
.addPanel(
    queryDurationBucketHistoryPanel('status', 'Status Query Duration Buckets (experimental)'), gridPos={
    h: 6,
    w: 8,
    x: 16,
    y: 83,
  })
.addPanel(
    prsReturnedHistoryPanel('sync', 'Sync PRs Returned per Query'), gridPos={
    h: 9,
    w: 12,
    x: 0,
    y: 89,
  })
.addPanel(
    prsReturnedHistoryPanel('status', 'Status PRs Returned per Query'), gridPos={
    h: 9,
    w: 12,
    x: 12,
    y: 89,
  })
.addPanel(
    row.new('How Much GitHub API Is Tide Using?'), gridPos={
    h: 1,
    w: 24,
    x: 0,
    y: 98,
  })
.addPanel(
    (timeseriesPanel(
        'GraphQL (v4) Request Rate by Org',
        description="Rate of Tide's own GraphQL (/graphql) requests through ghproxy, split by org. Org is extracted from ghproxy's token_hash label, which for GitHub App installation tokens is \"<app slug> - <org>\" (Tide authenticates as the openshift-merge-bot app, one installation token per org). Filtered to user_agent=\"tide\" because that same app/token is also used by a few other bots (pj-rehearse, auto-config-brancher, private-prow-configs-mirror) whose traffic would otherwise be mixed in. There's no metric for actual per-query GraphQL point cost, so this request rate is the closest available proxy for relative GraphQL load/cost per org.",
        unit='reqps',
        min=0,
        legendCalcs=['mean', 'last', 'max'],
    ) + {
      options+: {
        legend+: { sortBy: 'Last', sortDesc: true },
      },
    })
    .addTarget(prometheus.target(
        'label_replace(sum(rate(github_request_duration_count{token_hash=~"openshift-merge-bot - .*", user_agent="tide", path="/graphql"}[5m])) by (token_hash), "org", "$1", "token_hash", "openshift-merge-bot - (.*)")',
        legendFormat='{{org}}',
    )), gridPos={
    h: 12,
    w: 24,
    x: 0,
    y: 99,
  })
+ dashboardConfig
+ {
  panels: collapseRowsExcept('Is Tide OK?', super.panels),
}
