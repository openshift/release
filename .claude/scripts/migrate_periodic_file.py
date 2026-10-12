#!/usr/bin/env python3
"""
Migrate a periodic configuration file from one release version to another.

This script transforms version references, regenerates cron schedules, and creates
a new periodic file for the target release.

Usage:
    python3 migrate_periodic_file.py <source_file> <from_version> <to_version>

Example:
    python3 migrate_periodic_file.py \
        openshift-csi-operator-release-4.20__periodics.yaml \
        4.20 \
        4.21
"""

import sys
import re
import random
from pathlib import Path


def migrate_periodic_file(source_path, from_version, to_version):
    """
    Migrate a periodic file from one version to another.

    Args:
        source_path: Path to source periodic file
        from_version: Source version (e.g., "4.20")
        to_version: Target version (e.g., "4.21")

    Returns:
        Path to created target file
    """
    source_path = Path(source_path)

    if not source_path.exists():
        raise FileNotFoundError(f"Source file not found: {source_path}")

    # Read source file
    with open(source_path, 'r') as f:
        content = f.read()

    # Parse versions
    from_major, from_minor = from_version.split('.')
    to_major, to_minor = to_version.split('.')

    # Calculate previous version (for golang tags)
    prev_major = from_major
    prev_minor = str(int(from_minor) - 1)
    prev_version = f"{prev_major}.{prev_minor}"

    # Transform version references
    transforms = [
        # Direct version strings
        (f'name: "{from_version}"', f'name: "{to_version}"'),
        (f"tag: \"{from_version}\"", f"tag: \"{to_version}\""),
        (f'version: "{from_version}"', f'version: "{to_version}"'),

        # Underscored versions in image keys (with underscores: ocp_4_21_)
        (f'ocp_{from_version.replace(".", "_")}_', f'ocp_{to_version.replace(".", "_")}_'),
        (f'ocp_{prev_version.replace(".", "_")}_', f'ocp_{from_version.replace(".", "_")}_'),

        # Period versions in image keys (with periods: ocp_4.21_)
        (f'ocp_{from_version}_', f'ocp_{to_version}_'),
        (f'ocp_{prev_version}_', f'ocp_{from_version}_'),

        # Registry paths (ocp/4.21: -> ocp/4.22:)
        (f'ocp/{from_version}:', f'ocp/{to_version}:'),
        (f'ocp/{prev_version}:', f'ocp/{from_version}:'),

        # Builder tags
        (f'openshift-{from_version}', f'openshift-{to_version}'),
        (f'openshift-{prev_version}', f'openshift-{from_version}'),

        # Branch metadata
        (f'branch: release-{from_version}', f'branch: release-{to_version}'),
    ]

    for old, new in transforms:
        content = content.replace(old, new)

    # Regenerate cron schedules
    content = regenerate_cron_schedules(content)

    # Construct target filename
    target_path = source_path.parent / source_path.name.replace(
        f'release-{from_version}__periodics.yaml',
        f'release-{to_version}__periodics.yaml'
    )

    # Write target file
    with open(target_path, 'w') as f:
        f.write(content)

    return target_path


def regenerate_cron_schedules(content):
    """
    Regenerate randomized cron schedules to avoid thundering herd.

    Args:
        content: File content with cron schedules

    Returns:
        Content with regenerated cron schedules
    """
    lines = content.split('\n')
    cron_count = 0

    # Use consistent seed for reproducibility within a run
    random.seed(42)

    for i, line in enumerate(lines):
        if "cron:" in line:
            # Extract the cron expression
            match = re.search(r"cron:\s*['\"]?(.+?)['\"]?$", line.strip())
            if match:
                original_cron = match.group(1)

                # Generate new randomized cron based on frequency
                new_cron = randomize_cron(original_cron, cron_count)

                # Replace the cron schedule, preserving indentation
                indent = len(line) - len(line.lstrip())
                lines[i] = ' ' * indent + f"cron: '{new_cron}'"

                cron_count += 1

    return '\n'.join(lines)


def randomize_cron(original_cron, seed_offset=0):
    """
    Generate a randomized cron schedule based on the original frequency.

    Args:
        original_cron: Original cron expression
        seed_offset: Offset for random seed to ensure different values

    Returns:
        New randomized cron expression
    """
    # Adjust random seed for this specific cron
    random.seed(42 + seed_offset)

    # Handle special cron syntax
    if original_cron == '@daily':
        # Daily at random time (avoid midnight)
        hour = random.randint(1, 23)
        minute = random.randint(0, 59)
        return f'{minute} {hour} * * *'

    elif original_cron == '@weekly':
        # Weekly on random day and time
        hour = random.randint(1, 23)
        minute = random.randint(0, 59)
        day_of_week = random.randint(0, 6)
        return f'{minute} {hour} * * {day_of_week}'

    elif original_cron == '@monthly':
        # Monthly on random day and time
        hour = random.randint(1, 23)
        minute = random.randint(0, 59)
        day = random.randint(1, 28)  # Safe for all months
        return f'{minute} {hour} {day} * *'

    else:
        # Parse standard cron format: minute hour day month day-of-week
        parts = original_cron.split()
        if len(parts) == 5:
            minute, hour, day, month, day_of_week = parts

            # Generate new random minute and hour
            new_minute = random.randint(0, 59)
            new_hour = random.randint(1, 23)  # Avoid midnight

            # Preserve the scheduling pattern
            return f'{new_minute} {new_hour} {day} {month} {day_of_week}'

        # If we can't parse it, return original
        return original_cron


def main():
    if len(sys.argv) != 4:
        print("Usage: python3 migrate_periodic_file.py <source_file> <from_version> <to_version>")
        print("Example: python3 migrate_periodic_file.py file.yaml 4.20 4.21")
        sys.exit(1)

    source_file = sys.argv[1]
    from_version = sys.argv[2].replace('release-', '')
    to_version = sys.argv[3].replace('release-', '')

    try:
        target_file = migrate_periodic_file(source_file, from_version, to_version)
        print(f"✓ Migrated: {source_file}")
        print(f"  Created: {target_file}")
    except Exception as e:
        print(f"✗ Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
