# Slash Command Helper Scripts

This directory contains Python scripts used by slash commands in the `.claude/commands/` directory.

## Scripts

### migrate_periodic_file.py

Migrates a periodic configuration file from one OpenShift release version to another.

**Used by**: `/migrate-variant-periodics` slash command

**Features**:
- Transforms version references (base images, builder tags, registry paths, release names, branch metadata)
- Regenerates randomized cron schedules to avoid thundering herd
- Maintains existing interval schedules
- Preserves YAML structure and formatting

**Usage**:
```bash
python3 migrate_periodic_file.py <source_file> <from_version> <to_version>
```

**Example**:
```bash
python3 migrate_periodic_file.py \
    ci-operator/config/openshift/csi-operator/openshift-csi-operator-release-4.20__periodics.yaml \
    4.20 \
    4.21
```

**Transformations performed**:
- `ocp_4_20_*` → `ocp_4_21_*`
- `openshift-4.20` → `openshift-4.21`
- `name: "4.20"` → `name: "4.21"`
- `branch: release-4.20` → `branch: release-4.21`
- Cron schedules randomized with new times

**Output**: Creates new file with `-release-{to_version}__periodics.yaml` suffix in same directory

## Development

When adding new scripts:
1. Place in this directory
2. Make executable: `chmod +x script.py`
3. Add shebang: `#!/usr/bin/env python3`
4. Document usage in this README
5. Reference from slash command in `.claude/commands/`
