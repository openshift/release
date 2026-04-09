#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

clouds_to_env="
import os
import yaml
try:
    from shlex import quote
except ImportError:
    from pipes import quote


cloud = os.environ.get('OS_CLOUD')
if not cloud:
    print('OS_CLOUD isn\'t set. Export your cloud environment with OS_CLOUD.')
    exit(1)

config_file = os.environ.get('OS_CLIENT_CONFIG_FILE')
if not config_file:
    print('OS_CLIENT_CONFIG_FILE isn\'t set. Export the path to clouds.yaml with OS_CLIENT_CONFIG_FILE.')
    exit(1)

# https://docs.openstack.org/openstacksdk/latest/user/config/configuration.html
# The keys are all of the keys you'd expect from OS_* - except lower case and
# without the OS prefix. So, region name is set with region_name.
def parse_key(clouds_key, clouds_value):
    if clouds_key == 'auth':
        for k in clouds_value:
            parse_key(k, clouds_value[k])
    elif not clouds_key == 'regions':
        print('export OS_%s=%s' % (clouds_key.upper(), quote(str(clouds_value))))

with open(config_file) as f:
    data = yaml.safe_load(f)
    if not data.get('clouds', {}).get(cloud):
        print('Cloud %s doesn\'t exist in %s' % (cloud, config_file))
        exit(1)
    for k in data['clouds'][cloud]:
        parse_key(k, data['clouds'][cloud][k])
"

python -c "$clouds_to_env" > "${SHARED_DIR}/cinder_credentials.sh"
