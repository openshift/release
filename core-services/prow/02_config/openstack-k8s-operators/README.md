# openstack-k8s-operators Prow/Tide Configuration

This directory contains Prow and Tide configuration for openstack-k8s-operators repositories.

## Tide Query Splitting Strategy

To work around GitHub API "Resource limits for this query exceeded" errors, we use an **exclusion label strategy** that creates 3 distinct Tide query patterns instead of 1 combined query.

### How It Works

1. **Per-repo configs** (`<repo>/_prowconfig.yaml`) each have a tide query with group-specific `missingLabels`:
   - **Group A (21 repos):** blocks `repo-group/core-operators` (its own identity)
   - **Group B (11 repos):** blocks `repo-group/tooling-ci` (its own identity)
   - **Group C (3 repos):** blocks `repo-group/lightspeed` (its own identity)

   **Pattern:** Each group blocks its own identity label - symmetric and easy to understand.

2. **Tide combines** repos with identical query patterns into separate GitHub searches:
   - 21 repos with pattern A → GitHub Query 1 (~1113 chars)
   - 11 repos with pattern B → GitHub Query 2 (~583 chars)
   - 3 repos with pattern C → GitHub Query 3 (~159 chars)

All 3 queries stay under GitHub's ~1930 character resource limit.

**Note:** There is NO org-level `_prowconfig.yaml`. All configuration is in per-repo files to avoid duplication.

### Query Groups

**Group A: OpenStack Operators & Infrastructure (21 repos)**
```
barbican-operator, cinder-operator, designate-operator, glance-operator,
heat-operator, horizon-operator, infra-operator, ironic-operator,
keystone-operator, manila-operator, mariadb-operator, neutron-operator,
nova-operator, octavia-operator, openstack-baremetal-operator, openstack-operator,
ovn-operator, swift-operator, telemetry-operator, test-operator, watcher-operator
```
- **Blocks:** `repo-group/core-operators`
- **Rationale:** All Go-based operator controllers

**Group B: Data Plane & CI Tooling (11 repos)**
```
ci-framework, data-plane-adoption, edpm-ansible, edpm-image-builder,
install_yamls, openstack-k8s-operators-ci, openstack-must-gather, repo-setup,
s2i-openstack-containers, sg-core, tcib
```
- **Blocks:** `repo-group/tooling-ci`
- **Rationale:** CI infrastructure, data plane deployment, and development utilities

**Group C: Lightspeed AI (3 repos)**
```
lightspeed-mcps, lightspeed-operator, lightspeed-rag-content
```
- **Blocks:** `repo-group/lightspeed`
- **Rationale:** Experimental AI features (tech preview)

### Excluded Repositories

**osp-director-operator**
- Has tide configuration but uses the OLD query pattern (no `needs-rebase`, no `repo-group` labels)
- Forms its own 4th single-repo query
- Reason: Deprecated director-based deployment, being phased out
- **To fully integrate:** Update its `_prowconfig.yaml` to match Group A pattern (add `needs-rebase` + `repo-group/core-operators` to missingLabels)

## Developer Workflow

**No changes required.** PRs merge with `/lgtm` + `/approve` as before.

The exclusion labels (`repo-group/*`) are **never applied to PRs** - they exist only in configuration to make Tide treat the queries as distinct.

## Adding a New Repository

1. Determine which group the repo belongs to:
   - **Operator controller?** → Group A
   - **CI/tooling/data-plane?** → Group B
   - **Lightspeed AI?** → Group C

2. Create `<new-repo>/_prowconfig.yaml` by copying from an existing repo in that group:
   ```bash
   # Example: adding a new operator (Group A)
   cp barbican-operator/_prowconfig.yaml new-operator/_prowconfig.yaml

   # Then edit to replace repo name in the repos: list
   ```

3. Ensure `missingLabels` matches the group pattern:
   - Group A: must block `repo-group/core-operators`
   - Group B: must block `repo-group/tooling-ci`
   - Group C: must block `repo-group/lightspeed`

4. Verify:
   ```bash
   make checkconfig
   ```

## Modifying Query Groups

If repos need to be moved between groups (e.g., promoting from experimental to stable):

1. Edit the repo's `_prowconfig.yaml`:
   - Update `missingLabels` to match the new group pattern
   - Group A: blocks `repo-group/core-operators`
   - Group B: blocks `repo-group/tooling-ci`
   - Group C: blocks `repo-group/lightspeed`

2. Verify the change:
   ```bash
   make checkconfig
   ```

## Troubleshooting

**"Resource limits exceeded" returns:**
- Check total repos per query - may need to split further
- Group A can hold ~36 repos max before approaching limit
- Group B can hold ~33 repos max
- Group C can hold ~58 repos max

**PR not merging despite labels:**
- Check PR doesn't have any `repo-group/*` labels (should never happen)
- Verify repo is in exactly one query in `_prowconfig.yaml`
- Check `/hold` or other blocking labels

**Per-repo file out of sync:**
- Per-repo `_prowconfig.yaml` files are the source of truth
- Run `make prow-config` to validate and determinize formatting
- Run `make checkconfig` to verify configuration correctness

## Architecture Notes

- **Exclusion labels are never registered** in `_plugins.yaml` - they exist only in `missingLabels`
- **No plugin consolidation** - per-repo `_pluginconfig.yaml` files preserve repo-specific approval workflows
- **merge_method overrides** live in per-repo files after determinize (ci-framework, edpm-ansible, nova-operator, watcher-operator)
- **Why not org-level `orgs:` query?** Prow validation requires org-level plugin consolidation, removing repo-specific customization (attempted in PR #82798, reverted)

## Related

- **Plan Document:** `tide-query-split-plan.md` (project root)
- **Workaround PR:** #86401 (osp-director-operator exclusion)
- **Failed attempt:** PR #82798 (org-level consolidation with plugin changes)
- **Implementation PR:** PR #TBD (this strategy)
