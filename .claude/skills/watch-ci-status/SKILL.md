---
name: watch-ci-status
description: >-
  Watch a repo branch for a fresh postsubmit past a cutoff commit/time, or
  watch a PR's commit-status contexts (e.g. rehearsals) until they finish.
  Use instead of manual polling or sleep loops when a fix depends on a
  cross-repo postsubmit landing, or when tracking /pj-rehearse results.
---

# Watch CI Status

Two small scripts for a recurring pattern in this repo: a change here
(openshift/release) depends on a postsubmit from a *different* repo actually
running and succeeding before a rehearsal can mean anything, and rehearsals
themselves need to be watched to completion rather than polled by hand.

Grew out of openshift/release#83049/#83282 (KDM e2e migration depending on
oadp-operator's bundle-promotion postsubmit). Keep improving these in place
as new watch patterns come up in this project — don't fork one-off copies
into `/tmp` again.

## watch_postsubmit_refresh.sh

Watches one or more branches of an external repo for a commit newer than a
given cutoff (e.g. the merge time of the release PR that fixed the
promotion config), then reports the status contexts on that commit matching
a filter substring (default `images`, i.e. the postsubmit image-build/promote
job).

```bash
.claude/scripts/watch_postsubmit_refresh.sh \
  --repo openshift/oadp-operator \
  --after 2026-08-13T18:54:02Z \
  --branch oadp-dev --branch oadp-1.6 \
  --context-filter images
```

Run this via the `Monitor` tool (`persistent: true`) rather than blocking —
it loops forever by design so it can keep watching across multiple branches;
stop it with `TaskStop` once the postsubmit you were waiting for has been
seen and reported successful (or failed).

## watch_pr_status.sh

Watches a single commit's GitHub status contexts (rehearsals, presubmits,
postsubmits — whatever `--context-filter` matches) until every matching
context has left `pending`, printing each state transition as it happens.

```bash
.claude/scripts/watch_pr_status.sh \
  --repo openshift/release \
  --sha "$(git rev-parse HEAD)" \
  --context-filter rehearse
```

This one **exits** once all matching contexts are final (success/failure/error),
so it's safe to back a persistent `Monitor` and just let it end naturally —
no need to `TaskStop` it yourself.

## Notes

- Both scripts use `gh api ... --paginate` — PRs/commits with 30+ statuses
  silently truncate without it (bit us once in a local hook, see
  `require-rehearse-proof.sh`).
- Default poll interval is 60s (`--interval` to override) — keep it 60s+ to
  avoid hammering the GitHub API across a long-running Monitor.
- If you improve these (new filters, better state summaries, Slack/webhook
  output, etc.), edit them in place here rather than recreating ad hoc
  `/tmp` scripts next time — that's the whole point of parking them in a
  skill.
