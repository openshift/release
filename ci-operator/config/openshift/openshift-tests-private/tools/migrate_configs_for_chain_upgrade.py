#!/usr/bin/env python3
"""
Create new CI configuration files with version bumps for release migration.

This script renames chain upgrade config files and updates their content:
- Renames files from release-{source} to release-{target}
- Updates tests-private-postupg.tag to target version
- Updates tests-private-preupg.tag to source version
- Updates target.candidate.version and arm64-target.candidate.version to target version
- Updates custom.candidate.version to source version
- Updates zz_generated_metadata.branch to release-{target}
- Updates zz_generated_metadata.variant version component

Features:
- Automatically validates existing files if rename fails due to file exists
- Reports which version fields are incorrect if validation fails
- Excludes automated-release-stable configs by default
- Supports dry-run mode for previewing changes

Example usage:
$ python ci-operator/config/openshift/openshift-tests-private/tools/migrate_configs_for_chain_upgrade.py -s "4.21" -t "4.22"
"""

import argparse
import glob
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)


def staged_files():
    """Staged all changes from git."""
    try:
        result = subprocess.run(
            ["git", "add", "."],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error stage files: {e}")
        sys.exit(1)

def get_staged_files():
    """Get list of staged files from git."""
    try:
        result = subprocess.run(
            ["git", "diff", "--staged", "--name-only"],
            capture_output=True,
            text=True,
            check=True
        )
        files = [f.strip() for f in result.stdout.strip().split('\n') if f.strip()]
        return files
    except subprocess.CalledProcessError as e:
        print(f"Error getting staged files: {e}")
        sys.exit(1)


def update_yaml_file(file_path, target_version, prior_version):
    """Update version fields in a YAML configuration file using YAML parser.

    Args:
        file_path: Path to the YAML file
        target_version: Target release version (e.g., "4.22")
        prior_version: Prior/source release version (e.g., "4.21")
    """
    try:
        # Load YAML file
        with open(file_path, 'r') as f:
            data = yaml.safe_load(f)

        if not data:
            return False

        modified = False

        # Update base_images.tests-private-postupg.tag
        if 'base_images' in data and 'tests-private-postupg' in data['base_images']:
            if 'tag' in data['base_images']['tests-private-postupg']:
                old_val = data['base_images']['tests-private-postupg']['tag']
                if old_val != target_version:
                    data['base_images']['tests-private-postupg']['tag'] = target_version
                    modified = True
                    print(f"  - Updated tests-private-postupg tag: {old_val} → {target_version}")

        # Update base_images.tests-private-preupg.tag
        if 'base_images' in data and 'tests-private-preupg' in data['base_images']:
            if 'tag' in data['base_images']['tests-private-preupg']:
                old_val = data['base_images']['tests-private-preupg']['tag']
                if old_val != prior_version:
                    data['base_images']['tests-private-preupg']['tag'] = prior_version
                    modified = True
                    print(f"  - Updated tests-private-preupg tag: {old_val} → {prior_version}")

        # Update releases section versions
        if 'releases' in data:
            # Update target.candidate.version
            if 'target' in data['releases']:
                if 'candidate' in data['releases']['target']:
                    if 'version' in data['releases']['target']['candidate']:
                        old_val = data['releases']['target']['candidate']['version']
                        if old_val != target_version:
                            data['releases']['target']['candidate']['version'] = target_version
                            modified = True
                            print(f"  - Updated target.candidate.version: {old_val} → {target_version}")
                if 'release' in data['releases']['target']:
                    if 'version' in data['releases']['target']['release']:
                        old_val = data['releases']['target']['release']['version']
                        if old_val != target_version:
                            data['releases']['target']['release']['version'] = target_version
                            modified = True
                            print(f"  - Updated target.release.version: {old_val} → {target_version}")

            # Update arm64-target.candidate.version
            if 'arm64-target' in data['releases']:
                if 'candidate' in data['releases']['arm64-target']:
                    if 'version' in data['releases']['arm64-target']['candidate']:
                        old_val = data['releases']['arm64-target']['candidate']['version']
                        if old_val != target_version:
                            data['releases']['arm64-target']['candidate']['version'] = target_version
                            modified = True
                            print(f"  - Updated arm64-target.candidate.version: {old_val} → {target_version}")
                if 'release' in data['releases']['arm64-target']:
                    if 'version' in data['releases']['arm64-target']['release']:
                        old_val = data['releases']['arm64-target']['release']['version']
                        if old_val != target_version:
                            data['releases']['arm64-target']['release']['version'] = target_version
                            modified = True
                            print(f"  - Updated arm64-target.release.version: {old_val} → {target_version}")

            # Update custom.candidate.version
            if 'custom' in data['releases']:
                if 'candidate' in data['releases']['custom']:
                    if 'version' in data['releases']['custom']['candidate']:
                        old_val = data['releases']['custom']['candidate']['version']
                        if old_val != prior_version:
                            data['releases']['custom']['candidate']['version'] = prior_version
                            modified = True
                            print(f"  - Updated custom.candidate.version: {old_val} → {prior_version}")

        # Update zz_generated_metadata.branch
        if 'zz_generated_metadata' in data:
            if 'branch' in data['zz_generated_metadata']:
                new_branch = f"release-{target_version}"
                old_val = data['zz_generated_metadata']['branch']
                if old_val != new_branch:
                    data['zz_generated_metadata']['branch'] = new_branch
                    modified = True
                    print(f"  - Updated zz_generated_metadata.branch: {old_val} → {new_branch}")

            # Update zz_generated_metadata.variant
            if 'variant' in data['zz_generated_metadata']:
                old_val = data['zz_generated_metadata']['variant']
                # Replace prior version with target version in variant
                # Pattern: amd64-nightly-4.21-upgrade-from-stable-4.xx -> amd64-nightly-4.22-upgrade-from-stable-4.xx
                pattern = rf'(\w+-)([a-z]+-){re.escape(prior_version)}(-upgrade-from-stable-\d\.\d+)'
                match = re.match(pattern, old_val)
                if match:
                    new_val = f"{match.group(1)}{match.group(2)}{target_version}{match.group(3)}"
                    if old_val != new_val:
                        data['zz_generated_metadata']['variant'] = new_val
                        modified = True
                        print(f"  - Updated zz_generated_metadata.variant: {old_val} → {new_val}")

        # Write back if modified
        if modified:
            with open(file_path, 'w') as f:
                yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
            return True

        return False

    except Exception as e:
        print(f"  Error processing file: {e}")
        import traceback
        traceback.print_exc()
        return False


def check_config_file_versions(file_path, target_version, source_version):
    """Check if a config file has correct version values.

    Args:
        file_path: Path to the YAML config file
        target_version: Expected target version (e.g., "4.22")
        source_version: Expected source version (e.g., "4.21")

    Returns:
        dict: Status with 'valid' (bool), 'issues' (list of strings), 'values' (dict)
    """
    try:
        with open(file_path, 'r') as f:
            data = yaml.safe_load(f)

        issues = []
        values = {}

        # Check base_images.tests-private-postupg.tag
        if 'base_images' in data and 'tests-private-postupg' in data['base_images']:
            if 'tag' in data['base_images']['tests-private-postupg']:
                actual = data['base_images']['tests-private-postupg']['tag']
                values['tests-private-postupg.tag'] = actual
                if actual != target_version:
                    issues.append(f"tests-private-postupg.tag is '{actual}', expected '{target_version}'")

        # Check base_images.tests-private-preupg.tag
        if 'base_images' in data and 'tests-private-preupg' in data['base_images']:
            if 'tag' in data['base_images']['tests-private-preupg']:
                actual = data['base_images']['tests-private-preupg']['tag']
                values['tests-private-preupg.tag'] = actual
                if actual != source_version:
                    issues.append(f"tests-private-preupg.tag is '{actual}', expected '{source_version}'")

        # Check releases.target.(candidate|release).version
        if 'releases' in data and 'target' in data['releases']:
            if 'candidate' in data['releases']['target'] and 'version' in data['releases']['target']['candidate']:
                actual = data['releases']['target']['candidate']['version']
                values['target.candidate.version'] = actual
                if actual != target_version:
                    issues.append(f"target.candidate.version is '{actual}', expected '{target_version}'")

            if 'release' in data['releases']['target'] and 'version' in data['releases']['target']['release']:
                actual = data['releases']['target']['release']['version']
                values['target.release.version'] = actual
                if actual != target_version:
                    issues.append(f"target.release.version is '{actual}', expected '{target_version}'")


        # Check releases.arm64-target.(candidate|release).version
        if 'releases' in data and 'arm64-target' in data['releases']:
            if 'candidate' in data['releases']['arm64-target'] and 'version' in data['releases']['arm64-target']['candidate']:
                actual = data['releases']['arm64-target']['candidate']['version']
                values['arm64-target.candidate.version'] = actual
                if actual != target_version:
                    issues.append(f"arm64-target.candidate.version is '{actual}', expected '{target_version}'")
            
            if 'release' in data['releases']['arm64-target'] and 'version' in data['releases']['arm64-target']['release']:
                actual = data['releases']['arm64-target']['release']['version']
                values['arm64-target.release.version'] = actual
                if actual != target_version:
                    issues.append(f"arm64-target.release.version is '{actual}', expected '{target_version}'")

        # Check releases.custom.candidate.version
        if 'releases' in data and 'custom' in data['releases']:
            if 'candidate' in data['releases']['custom'] and 'version' in data['releases']['custom']['candidate']:
                actual = data['releases']['custom']['candidate']['version']
                values['custom.candidate.version'] = actual
                if actual != source_version:
                    issues.append(f"custom.candidate.version is '{actual}', expected '{source_version}'")

        # Check zz_generated_metadata.branch
        if 'zz_generated_metadata' in data and 'branch' in data['zz_generated_metadata']:
            actual = data['zz_generated_metadata']['branch']
            expected = f"release-{target_version}"
            values['zz_generated_metadata.branch'] = actual
            if actual != expected:
                issues.append(f"zz_generated_metadata.branch is '{actual}', expected '{expected}'")

        # Check zz_generated_metadata.variant
        if 'zz_generated_metadata' in data and 'variant' in data['zz_generated_metadata']:
            actual = data['zz_generated_metadata']['variant']
            values['zz_generated_metadata.variant'] = actual
            # Check if variant contains target_version in the middle
            pattern = rf'\w+-[a-z]+-{re.escape(target_version)}-upgrade-from-stable-'
            if not re.search(pattern, actual):
                issues.append(f"zz_generated_metadata.variant '{actual}' doesn't contain target version '{target_version}'")

        return {
            'valid': len(issues) == 0,
            'issues': issues,
            'values': values
        }

    except Exception as e:
        return {
            'valid': False,
            'issues': [f"Error reading file: {str(e)}"],
            'values': {}
        }


def should_skip_file(filename, source_version):
    """Check if a file should be skipped based on various criteria.

    Skip files where:
    - Contains '__automated-release-stable-'
    - base_version == version (e.g., 4.21-upgrade-from-stable-4.21)
    - base_version == version - 1 minor (e.g., 4.21-upgrade-from-stable-4.20)

    Args:
        filename: Name of the config file
        source_version: Source version (e.g., "4.21")
    Returns:
        tuple: (should_skip: bool, reason: str or None)
    """
    # Check for automated-release-stable configs
    if '__automated-release-stable-' in filename:
        return (True, "automated-release-stable config (excluded by default)")

    # Extract base_version from filename
    # Pattern: *-upgrade-from-stable-{base_version}.yaml
    match = re.search(r'-upgrade-from-stable-([\d.]+)\.yaml$', filename)
    if not match:
        return (False, None)

    base_version = match.group(1)

    # Parse versions
    try:
        source_major, source_minor = map(int, source_version.split('.'))
        base_major, base_minor = map(int, base_version.split('.'))
    except (ValueError, AttributeError):
        return (False, None)

    # Check if base_version == source_version
    if base_major == source_major and base_minor == source_minor:
        return (True, f"base_version ({base_version}) equals source_version ({source_version})")

    # Check if base_version is one minor version earlier
    # e.g., source=4.21, base=4.20
    if base_major == source_major and base_minor == source_minor - 1:
        return (True, f"base_version ({base_version}) is one minor version earlier than source_version ({source_version})")

    return (False, None)

def get_chain_upgrade_configs(version, config_dir="ci-operator/config/openshift/openshift-tests-private", dry_run=False):
    
    
    skipped_files = []
        
    # Pattern to match chain upgrade config files
    # Format: {org}-{repo}-release-{version}__{variant}-{version}-upgrade-from-stable-{base_version}.yaml
    pattern = f"{config_dir}/*-release-{version}__*-{version}-upgrade-from-stable-*.yaml"

    matching_files = glob.glob(pattern)

    # Filter out files based on skip rules (automated configs, base_version rules, etc.)
    filtered_files = []
    for file_path in matching_files:
        filename = os.path.basename(file_path)
        should_skip, reason = should_skip_file(filename, version)
        if should_skip:
            skipped_files.append((filename, reason))
        else:
            filtered_files.append(file_path)
    
    return filtered_files, skipped_files
    

def rename_chain_upgrade_configs(source_version, target_version, config_dir="ci-operator/config/openshift/openshift-tests-private", dry_run=False):
    """Rename chain upgrade config files from source version to target version.

    Args:
        source_version: Source release version (e.g., "4.21")
        target_version: Target release version (e.g., "4.22")
        config_dir: Directory containing the config files
        dry_run: If True, only print what would be renamed without actually renaming

    Returns:
        List of tuples (old_path, new_path) for renamed files

    Skips files where:
        - base_version == source_version (e.g., 4.21-upgrade-from-stable-4.21)
        - base_version is one minor version earlier (e.g., 4.21-upgrade-from-stable-4.20)

    Example:
        Renames files like:
        openshift-openshift-tests-private-release-4.21__amd64-nightly-4.21-upgrade-from-stable-4.16.yaml
        to:
        openshift-openshift-tests-private-release-4.22__amd64-nightly-4.22-upgrade-from-stable-4.16.yaml
    """

    renamed_files = []
    filtered_files, skipped_files = get_chain_upgrade_configs(source_version)
    matching_files = filtered_files

    if skipped_files:
        print(f"\nSkipped {len(skipped_files)} file(s) based on filtering rules:")
        for filename, reason in skipped_files:
            print(f"  ⊘ {filename}")
            print(f"    Reason: {reason}")
        print()

    if not matching_files:
        print(f"No chain upgrade config files found to rename after filtering.")
        return renamed_files

    print(f"\nFound {len(matching_files)} chain upgrade config file(s) to rename:\n")

    for old_path in matching_files:
        old_filename = os.path.basename(old_path)

        # Replace release-{source_version} with release-{target_version}
        new_filename = old_filename.replace(f"-release-{source_version}__", f"-release-{target_version}__")

        # Replace {source_version}-upgrade with {target_version}-upgrade
        # Use regex to be more precise and avoid replacing the "from-stable-X.XX" part
        new_filename = re.sub(
            rf'__(.+?)-{re.escape(source_version)}-upgrade-from',
            rf'__\1-{target_version}-upgrade-from',
            new_filename
        )

        new_path = os.path.join(config_dir, new_filename)

        if old_path == new_path:
            print(f"⊘ {old_filename} (no change needed)")
            continue

        print(f"→ {old_filename}")
        print(f"  ⇒ {new_filename}")

        if not dry_run:
            try:
                # Use git mv to rename the file
                subprocess.run(
                    ["git", "mv", old_path, new_path],
                    capture_output=True,
                    text=True,
                    check=True
                )
                print(f"  ✓ Renamed successfully")
                renamed_files.append((old_path, new_path))
            except subprocess.CalledProcessError as e:
                error_msg = e.stderr.strip()
                print(f"  ✗ Error renaming: {error_msg}")

        else:
            print(f"  (dry run - not actually renamed)")
            renamed_files.append((old_path, new_path))

        print()

    return renamed_files


def main(target_version, prior_version):
    """Main function."""
    
    print("Fetching staged files...")
    staged_files = get_staged_files()

    if not staged_files:
        print("No staged files found.")
        return

    print(f"\nFound {len(staged_files)} staged file(s):\n")

    # Filter for YAML files in ci-operator/config
    yaml_files = [
        f for f in staged_files
        if f.endswith('.yaml') and f.startswith('ci-operator/config/')
    ]

    if not yaml_files:
        print("No YAML configuration files found in staged files.")
        return

    print(f"Processing {len(yaml_files)} YAML configuration file(s)...\n")

    updated_count = 0
    for file_path in yaml_files:
        if not Path(file_path).exists():
            print(f"⊘ {file_path} (file deleted)")
            continue

        print(f"→ {file_path}")
        if update_yaml_file(file_path, target_version, prior_version):
            updated_count += 1
        else:
            print(f"  - No changes needed")
        print()

    print(f"\nSummary: Updated {updated_count} of {len(yaml_files)} file(s).")

    if updated_count > 0:
        print("\nNote: Modified files are already staged. Review changes with 'git diff --staged'")



if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description='Rename chain upgrade config files from source version to target version.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry run (preview changes without renaming)
  %(prog)s --source 4.21 --target 4.22 --dry-run

  # Actually rename the files
  %(prog)s --source 4.21 --target 4.22

  # Specify custom config directory
  %(prog)s -s 4.21 -t 4.22 --config-dir /path/to/configs
        """
    )

    parser.add_argument(
        '-s', '--source',
        required=True,
        help='Source release version (e.g., "4.21")'
    )
    parser.add_argument(
        '-t', '--target',
        required=True,
        help='Target release version (e.g., "4.22")'
    )
    parser.add_argument(
        '--config-dir',
        default='ci-operator/config/openshift/openshift-tests-private',
        help='Directory containing config files (default: ci-operator/config/openshift/openshift-tests-private)'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be renamed without actually renaming'
    )
    parser.add_argument(
        '--include-automated',
        action='store_true',
        help='Include automated-release-stable configs in rename (default: excluded)'
    )

    args = parser.parse_args()

    print(f"Chain Upgrade Config Renamer")
    print(f"=" * 50)
    print(f"Source version: {args.source}")
    print(f"Target version: {args.target}")
    print(f"Config directory: {args.config_dir}")
    print(f"Mode: {'DRY RUN' if args.dry_run else 'RENAME'}")
    print(f"=" * 50)

    renamed = rename_chain_upgrade_configs(
        args.source,
        args.target,
        config_dir=args.config_dir,
        dry_run=args.dry_run
    )

    if renamed:
        print(f"\n{'Would rename' if args.dry_run else 'Renamed'} {len(renamed)} file(s):")
        for old_path, new_path in renamed:
            print(f"  {Path(old_path).name} → {Path(new_path).name}")

        if args.dry_run:
            print(f"\nRun without --dry-run to actually rename the files.")
    else:
        print(f"\nNo files were renamed.")
        
    staged_files()

    main(target_version=args.target, prior_version=args.source)
    
    staged_files()
    
    # Final check
    filtered_files, _ = get_chain_upgrade_configs(args.target)
    for new_path in filtered_files:
        # Check if error is due to destination file already exists
        if Path(new_path).exists():
            print(f"  ℹ Destination file exists, checking if it has correct content...")
            check_result = check_config_file_versions(new_path, args.target, args.source)

            if check_result['valid']:
                print(f"  ✓ Existing file has correct version values")
            else:
                print(f"  ⚠ Existing file has incorrect version values:")
                for issue in check_result['issues']:
                    print(f"    • {issue}")
                print(f"  → You may need to manually update or remove the file: {new_path}")
    
