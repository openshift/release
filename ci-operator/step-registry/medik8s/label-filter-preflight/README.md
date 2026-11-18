# medik8s-label-filter-preflight

Clusterless Ginkgo dry-run gate used by **stability:candidate** daily jobs.

## Behavior

1. Runs `scripts/test-runner.sh --dry-run` with `ECO_DRY_RUN=true` against
   `ECO_TEST_FEATURES` / `ECO_TEST_LABELS` from the job env (image: `src`).
2. If the label filter selects **zero** specs, the step **fails**.
3. A failing `pre` step causes OpenShift CI to **skip remaining pre/test steps**,
   including `ipi-aws-pre` / cluster install. `post` steps still run.

## Resource caveats (intentional)

| Avoided | Not avoided |
| --- | --- |
| AWS IPI cluster creation | Boskos / `cluster_profile` **lease** (acquired before any step) |

Empty candidate suites therefore leave the periodic **red** until at least one
matching `stability:candidate` spec exists. That is preferred over spending a
full cluster on a no-op run.

## Wiring

Override workflow `pre` (test-level `pre` replaces `ipi-aws` pre):

```yaml
pre:
- ref: medik8s-label-filter-preflight
- chain: ipi-aws-pre
```

## Related

- Label constant: `stability:candidate` in `openshift/rhwa-system-tests`
- Normal jobs must include `!stability:candidate` in `ECO_TEST_LABELS`
