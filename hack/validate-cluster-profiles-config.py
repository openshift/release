#!/usr/bin/env python3
"""Validate cluster-profiles-config.yaml for duplicates and sorting."""

import argparse
import sys
import yaml


def validate_cluster_profiles_config(config_path, fix=False):  # pylint: disable=too-many-statements
    """Validate and optionally fix cluster-profiles-config.yaml."""
    errors = []
    warnings = []

    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        errors.append(f"YAML parsing error: {e}")
        return errors, warnings

    if not isinstance(data, list):
        errors.append("Root element must be a list")
        return errors, warnings

    # Track all profiles and their orgs
    consolidated_data = []

    for profile_entry in data:
        if not isinstance(profile_entry, dict) or 'profile' not in profile_entry:
            errors.append(f"Invalid profile entry: {profile_entry}")
            continue

        profile_name = profile_entry['profile']
        owners = profile_entry.get('owners', [])
        secret = profile_entry.get('secret')

        # Build consolidated owners list
        org_map = {}
        for owner in owners:
            if not isinstance(owner, dict) or 'org' not in owner:
                errors.append(f"Invalid owner entry in profile {profile_name}: {owner}")
                continue

            org_name = owner['org']
            # Handle both 'repo' and 'repos' keys
            repos = owner.get('repos', [])
            if not repos and 'repo' in owner:
                # Convert single 'repo' to list
                repo_val = owner['repo']
                repos = [repo_val] if isinstance(repo_val, str) else repo_val

            # Normalize repos to list
            if not isinstance(repos, list):
                repos = [repos] if repos else []

            # Check for duplicate orgs
            if org_name in org_map:
                if fix:
                    # Merge repos
                    existing_repos = set(org_map[org_name].get('repos', []))
                    new_repos = set(repos)
                    org_map[org_name]['repos'] = sorted(list(existing_repos | new_repos))
                    warnings.append(f"Profile {profile_name}: Merged duplicate org '{org_name}'")
                else:
                    errors.append(f"Profile {profile_name}: Duplicate org '{org_name}' found")
            else:
                org_map[org_name] = {
                    'org': org_name,
                    'repos': sorted(repos) if repos else []
                }

        # Sort orgs alphabetically
        sorted_orgs = sorted(org_map.values(), key=lambda x: x['org'].lower())

        # Build new profile entry
        new_entry = {'profile': profile_name}
        if secret:
            new_entry['secret'] = secret
        if sorted_orgs:
            new_entry['owners'] = []
            for org_entry in sorted_orgs:
                owner_dict = {'org': org_entry['org']}
                if org_entry['repos']:
                    owner_dict['repos'] = org_entry['repos']
                new_entry['owners'].append(owner_dict)

        consolidated_data.append(new_entry)

    if errors and not fix:
        return errors, warnings

    # If fixing, write back the consolidated data with proper formatting
    if fix:
        try:
            output_lines = []
            for profile_entry in consolidated_data:
                output_lines.append(f"- profile: {profile_entry['profile']}")
                if 'secret' in profile_entry:
                    output_lines.append(f"  secret: {profile_entry['secret']}")
                if 'owners' in profile_entry and profile_entry['owners']:
                    output_lines.append("  owners:")
                    for owner in profile_entry['owners']:
                        output_lines.append(f"    - org: {owner['org']}")
                        if 'repos' in owner and owner['repos']:
                            output_lines.append("      repos:")
                            for repo in owner['repos']:
                                output_lines.append(f"        - {repo}")
                output_lines.append("")

            with open(config_path, 'w', encoding='utf-8') as f:
                content = '\n'.join(output_lines)
                if not content.endswith('\n'):
                    content += '\n'
                f.write(content)
            print(f"Fixed {config_path}: Consolidated duplicates and sorted entries")
        except (IOError, OSError) as e:
            errors.append(f"Error writing fixed file: {e}")

    return errors, warnings


def main():
    parser = argparse.ArgumentParser(description='Validate cluster-profiles-config.yaml')
    parser.add_argument('config_file', help='Path to cluster-profiles-config.yaml')
    parser.add_argument('--fix', action='store_true',
                        help='Fix issues by consolidating duplicates and sorting')
    args = parser.parse_args()

    errors, warnings = validate_cluster_profiles_config(args.config_file, fix=args.fix)

    if warnings:
        for warning in warnings:
            print(f"WARNING: {warning}", file=sys.stderr)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

    if not args.fix:
        print("Validation passed: No issues found")
    else:
        print("File fixed successfully")


if __name__ == '__main__':
    main()
