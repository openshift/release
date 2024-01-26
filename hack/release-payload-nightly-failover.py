#!/usr/bin/env python3
# Failover from nightly to CI payloads

import json
import sys

def apply_changes(input_file_name, target_file_name):
    with open(input_file_name, 'r') as file:
        data = json.load(file)

    with open(target_file_name, 'r') as file:
        ci_data = json.load(file)

    new_verify = {}
    for key, value in data.get('verify', {}).items():
        new_key = f"nightly-failover-{key}"
        if key in ci_data['verify']:
            print(f"Skipping '{new_key}' as it conflicts with existing key without prefix.")
            continue

        new_value = value
        if 'upgradeFromRelease' in value and value['upgradeFromRelease'].get('candidate', {}).get('stream') == 'nightly':
            new_value['upgradeFromRelease']['candidate']['stream'] = 'ci'
        new_verify[new_key] = new_value

    ci_data['verify'].update(new_verify)

    with open(target_file_name, 'w') as file:
        json.dump(ci_data, file, indent=2)
        file.write('\n')

def undo_changes(target_file_name):
    with open(target_file_name, 'r') as file:
        ci_data = json.load(file)

    ci_data['verify'] = {k: v for k, v in ci_data['verify'].items() if not k.startswith('nightly-failover-')}

    with open(target_file_name, 'w') as file:
        json.dump(ci_data, file, indent=2)
        file.write('\n')  # Adding a newline at the end of the file

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

