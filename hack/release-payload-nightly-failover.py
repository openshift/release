#!/usr/bin/env python3
# Failover from nightly to CI payloads

import json
import sys


def apply_changes(source_file_name, destination_file_name):
    with open(source_file_name, 'r', encoding='utf-8') as file:
        data = json.load(file)

    with open(destination_file_name, 'r', encoding='utf-8') as file:
        ci_data = json.load(file)

    new_verify = {}
    for key, value in data.get('verify', {}).items():
        new_key = f"nightly-failover-{key}"
        if key in ci_data['verify']:
            print(
                f"Skipping '{new_key}' as it conflicts with existing key without prefix.")
            continue

        if 'upgradeFromRelease' in value and value['upgradeFromRelease'].get('candidate', {}).get('stream') == 'nightly':
            value['upgradeFromRelease']['candidate']['stream'] = 'ci'
        new_verify[new_key] = value

    ci_data['verify'].update(new_verify)

    with open(destination_file_name, 'w', encoding='utf-8') as file:
        json.dump(ci_data, file, indent=2)
        file.write('\n')

def undo_changes(destination_file_name):
    with open(destination_file_name, 'r', encoding='utf-8') as file:
        ci_data = json.load(file)

    ci_data['verify'] = {k: v for k, v in ci_data['verify'].items(
    ) if not k.startswith('nightly-failover-')}

    with open(destination_file_name, 'w', encoding='utf-8') as file:
        json.dump(ci_data, file, indent=2)
        file.write('\n')

def print_usage():
    print("Usage:")
    print("  To apply changes:\n\tpython script.py [nightly rc json] apply")
    print("  To undo changes:\n\tpython script.py [nightly rc json] undo")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print_usage()
    else:
        input_file_name = sys.argv[1]
        target_file_name = input_file_name.replace('.json', '-ci.json')
        action = sys.argv[2]

        if action == 'apply':
            apply_changes(input_file_name, target_file_name)
        elif action == 'undo':
            undo_changes(target_file_name)
        else:
            print("Invalid action. Use 'apply' or 'undo'.")
