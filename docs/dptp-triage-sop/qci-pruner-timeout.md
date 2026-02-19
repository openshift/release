QCI Pruner Job Timeout
======================

The `periodic-openshift-release-qci-pruner` job is responsible for pruning old tags from the `quay.io/openshift/ci` repository. The job runs daily and has a 12-hour timeout. When the job fails with a timeout error, it indicates that the pruner script is taking longer than expected to process all tags.

Error Indicators
----------------

The job failure will appear in the **#ops-testplatform** Slack channel with a message like:

```text
Job periodic-openshift-release-qci-pruner failed.
```

The job logs will show:

```text
"level":"error","msg":"Process did not finish before 12h0m0s timeout","severity":"error"
```

Background
----------

The pruner script (`hack/qci_registry_pruner.py`) performs the following operations:

1. **Tag Pruning**: Iterates through all tags in `quay.io/openshift/ci` and deletes tags matching the pattern `YYYYMMDDHHMMSS_prune_*` that are older than the TTL (default 5 days)
2. **Release Payload Preservation**: Manages preservation tags for release payload component images to prevent premature garbage collection
3. **Tag Listing**: Uses Quay.io V2 API with keyset-based pagination to fetch tags (recently optimized with WIP V2 API, but still slow due to large tag count)

The script processes tags in batches of 100 and uses concurrent deletion (up to 100 simultaneous requests) to improve performance. However, with a large number of tags in the repository, the iteration process can still take a very long time.

Troubleshooting Steps
---------------------

Check Job Status and Logs
--------------------------

1. Navigate to the Prow job dashboard for `periodic-openshift-release-qci-pruner`
2. Review the latest job run logs to identify:

   - How many tags were processed before timeout
   - Any specific errors or warnings
   - The last tag processed (if available)

Assess Tag Count
----------------

The pruner logs will show progress like:

```text
%d tags have been checked
```

If the job is timing out, it likely means there are too many tags to process within 12 hours. The script processes tags sequentially during the listing phase, which is the bottleneck.

Determine if Manual Intervention is Needed
------------------------------------------

If the job has been failing for multiple days:

- The backlog of tags to prune will continue to grow
- Manual intervention may be required to catch up
- Consider running the script locally for an extended period (3-4 days) to process the backlog

Running the Pruner Script Locally
----------------------------------

When the job is consistently timing out or there's a significant backlog, you may need to run the pruner script locally for several days to catch up.

Prerequisites
-------------

1. **Python 3** (3.12+ recommended)
2. **OpenShift CLI (`oc`)** - Required for release payload processing
3. **Quay.io OAuth Token** - Required for API access (obtain from secret `qci-pruner-credentials` in the `ci` namespace on `app.ci` cluster)
4. **Docker config JSON** (optional) - For v2 token authentication

Running the Script
------------------

Dry Run (Recommended First Step)
---------------------------------

Run without `--confirm` to see what would be pruned without making changes:

```bash
cd /path/to/release
./hack/qci_registry_pruner.py --ttl-days 5
```

This will:

- List all tags that would be pruned
- Show release payloads that would be preserved
- Not make any actual changes

Production Run
--------------

Once you've verified the dry run output, run with `--confirm`:

```bash
cd /path/to/release
./hack/qci_registry_pruner.py --confirm --ttl-days 5
```

Extended Run for Backlog
------------------------

If there's a significant backlog, you may need to run the script continuously for 3-4 days:

```bash
# Run in a screen or tmux session to keep it running
screen -S qci-pruner
# or
tmux new -s qci-pruner

# Run the script
cd /path/to/release
while true; do
    ./hack/qci_registry_pruner.py --confirm --ttl-days 5
    echo "Run completed at $(date). Sleeping for 1 hour before next run..."
    sleep 3600  # Wait 1 hour between runs
done
```

**Note**: The script will process tags incrementally. Each run will continue from where it left off (the script processes all tags each run, but only deletes those matching the criteria). Running it multiple times will gradually reduce the backlog.

Script Options
--------------

- `--confirm`: Actually delete tags (required for production runs)
- `--ttl-days N`: Only prune tags older than N days (default: 5, use `-1` for all prunable tags)
- `--token TOKEN`: Quay OAuth token (alternative to `QUAY_OAUTH_TOKEN` env var)

Monitoring Local Runs
---------------------

The script provides detailed logging:

```text
<timestamp> - INFO - <number> tags have been checked
<timestamp> - INFO - Successfully deleted <tag>
<timestamp> - INFO - Duration: <time>
<timestamp> - INFO - Total tags scanned: <count>
<timestamp> - INFO - Tags targeted for pruning: <count>
<timestamp> - INFO - Tags successfully pruned: <count>
```

Monitor the output to:

- Track progress (tags checked count)
- Identify any errors
- Verify tags are being deleted successfully
- Estimate time remaining

Long-term Solutions
-------------------

1. **Increase Job Timeout**: Consider increasing the timeout in `ci-operator/jobs/infra-periodics.yaml` if the repository continues to grow
2. **Optimize Tag Listing**: The script was recently optimized with WIP V2 API, but further optimizations may be needed
3. **Reduce TTL**: Consider reducing the default TTL (currently 5 days) if appropriate
4. **Parallel Processing**: The deletion is already parallelized, but tag listing is sequential - consider parallelizing tag fetching if Quay API supports it
5. **Incremental Processing**: Consider implementing checkpoint/resume functionality to avoid reprocessing all tags on each run

Related Files
-------------

- Script: `hack/qci_registry_pruner.py`
- Job Configuration: `ci-operator/jobs/infra-periodics.yaml`
- Image Build Config: `clusters/app.ci/supplemental-ci-images/qci-pruner.yaml`

Additional Notes
----------------

- The script uses retry logic (5 retries with 1-minute delays) for tag fetching failures
- Tag deletion uses a ThreadPoolExecutor with up to 100 concurrent workers
- The script processes release payload preservation tags in addition to prune tags
- Each run processes all tags in the repository (no incremental state tracking)
