# ROSA Gap Analysis Periodic CI Jobs

This directory contains the CI configuration for running automated gap analysis for ROSA (Red Hat OpenShift Service on AWS) between OpenShift versions.

## Files

- **openshift-online-rosa-gap-analysis-main.yaml** - CI operator configuration defining the periodic test job
- **OWNERS** - Approvers and reviewers for this configuration

## Jobs Defined

### Daily Jobs

| Job | Schedule | Description |
|-----|----------|-------------|
| `rosa-gap-analysis-nightly` | Daily 6 AM UTC | Runs comprehensive gap analysis comparing OpenShift versions |

## What This Job Does

The `rosa-gap-analysis-nightly` job:
1. Builds a container image from `./ci/Containerfile` in the rosa-gap-analysis repository
2. Runs the `./scripts/gap-all.sh` script inside the container
3. Generates gap analysis reports comparing OpenShift versions
4. Stores results in Prow artifacts for team review

## Configuration

The job is configured to skip when only documentation is changed:
- `^docs/` - Documentation directories
- `\.md$` - Markdown files
- `.gitignore`, `OWNERS`, `PROJECT`, `LICENSE` - Metadata files

To modify the job configuration:
1. Edit `openshift-online-rosa-gap-analysis-main.yaml`
2. Update the `commands`, `cron`, or `skip_if_only_changed` settings
3. Regenerate jobs: `make update` (in release repo root)
4. Create PR with changes

### Slack Notifications

Slack notifications can be configured in the generated periodics file (see step 4 in "Next Steps" below).

To add Slack notifications:
1. Run `make update` to generate the periodics file
2. Edit the generated file: `ci-operator/jobs/openshift-online/rosa-gap-analysis/openshift-online-rosa-gap-analysis-main-periodics.yaml`
3. Add `reporter_config.slack.channel` section to the job
4. Include in your PR

## Next Steps

### 1. Generate Periodic Jobs

From the release repository root:

```bash
cd /path/to/e2e/release

# Generate the periodic jobs from this config
make update

# This creates:
# ci-operator/jobs/openshift-online/rosa-gap-analysis/openshift-online-rosa-gap-analysis-main-periodics.yaml
```

### 2. Add Slack Configuration (Manual Step)

After running `make update`, manually edit the generated periodics file to add Slack notifications:

```bash
vim ci-operator/jobs/openshift-online/rosa-gap-analysis/openshift-online-rosa-gap-analysis-main-periodics.yaml
```

Add to the periodic job:

```yaml
  reporter_config:
    slack:
      channel: '#your-team-channel'  # Your Slack channel
      job_states_to_report:
      - failure
      - error
      report_template: ':warning: Gap Analysis failed: <{{.Status.URL}}|View logs>'
```

### 3. Validate Configuration

```bash
# Full validation and check
make update
make checkconfig
```

### 4. Create Pull Request

```bash
git checkout -b add-gap-ci

# Stage files
git add ci-operator/config/openshift-online/rosa-gap-analysis/
git add ci-operator/jobs/openshift-online/rosa-gap-analysis/

# Commit
git commit -m "Add periodic CI job for ROSA gap-analysis

This adds a nightly CI job to run gap analysis for ROSA
comparing OpenShift versions.

Job:
- rosa-gap-analysis-nightly: Daily at 6 AM UTC

Reports stored in Prow artifacts for team review.
"

# Push and create PR
git push origin add-gap-ci
```

### 5. PR Review

Tag reviewers:
```
/assign @reviewer-username
/cc @openshift/test-platform
```

Get approvals:
```
/lgtm
/approve
```

## Monitoring

### View Job Status

- **Prow Dashboard**: https://prow.ci.openshift.org/
- **Search**: `periodic-ci-openshift-online-rosa-gap-analysis`

### Access Artifacts

Reports are stored in GCS:

```
gs://test-platform-results/logs/
  periodic-ci-openshift-online-rosa-gap-analysis-main-rosa-gap-analysis-nightly/<build-id>/artifacts/
```

Download artifacts:

```bash
BUILD_ID=<latest-build-id-from-prow>

# Download gap analysis reports
gsutil -m cp -r gs://test-platform-results/logs/periodic-ci-openshift-online-rosa-gap-analysis-main-rosa-gap-analysis-nightly/${BUILD_ID}/artifacts/ .
```

## Troubleshooting

### Jobs Not Running

Check cron schedule at https://crontab.guru/

Manually trigger (requires admin permissions):

```yaml
# File: manual-trigger.yaml
apiVersion: prow.k8s.io/v1
kind: ProwJob
metadata:
  name: manual-gap-test
  namespace: ci
spec:
  job: periodic-ci-openshift-online-rosa-gap-analysis-main-rosa-gap-analysis-nightly
  type: periodic
```

Apply: `kubectl apply -f manual-trigger.yaml -n ci`

### Script Failures

1. Check Prow logs in job UI
2. Verify the `./scripts/gap-all.sh` script exists in the rosa-gap-analysis repository
3. Ensure the container image builds successfully from `./ci/Containerfile`
4. Check that required dependencies are available in the container

### Missing Artifacts

Artifacts are automatically collected from the container working directory. If artifacts are missing:
- Verify the script outputs to the correct location
- Check Prow job logs for script execution errors
- Ensure the container has write permissions to the artifact directory

## Maintenance

### Update the Script or Container

If you need to modify the gap analysis logic:

1. Update the script or Containerfile in the [rosa-gap-analysis repository](https://github.com/openshift-online/rosa-gap-analysis)
2. The CI job will automatically use the latest version from the `main` branch

### Change Schedule

```bash
# Edit cron field in openshift-online-rosa-gap-analysis-main.yaml
# Examples:
# "0 2 * * *"    - Daily at 2 AM UTC
# "0 2 * * 1-5"  - Weekdays at 2 AM UTC
# "0 2 * * 1"    - Monday at 2 AM UTC

# Regenerate jobs
cd /path/to/e2e/release
make update

# Create PR
git add ci-operator/
git commit -m "Update gap-analysis schedule"
```

### Modify Skip Patterns

```bash
# Edit skip_if_only_changed in openshift-online-rosa-gap-analysis-main.yaml
# Add or remove file patterns to control when the job runs

# Regenerate jobs
make update

# Create PR
git add ci-operator/
git commit -m "Update gap-analysis skip patterns"
```

## Support

- **CI/Prow questions**: `#forum-testplatform` on Slack
- **ROSA gap analysis questions**: Contact the ROSA team
- **PR reviews**: Tag `@openshift/test-platform`

## References

- [OpenShift CI Documentation](https://docs.ci.openshift.org/)
- [ci-operator Configuration](https://docs.ci.openshift.org/docs/architecture/ci-operator/)
- [Prow Job Documentation](https://docs.prow.k8s.io/docs/jobs/)
- [ROSA Gap Analysis Repository](https://github.com/openshift-online/rosa-gap-analysis)
