#!/bin/bash
set -euo pipefail

echo "Installing AWS Neuron Operator and dependencies"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

DEVICECONFIG_SAMPLE="/tmp/deviceconfig-sample.yaml"
REPO="awslabs/operator-for-ai-chips-on-aws"

echo "Fetching deviceconfig-sample.yaml from latest ${REPO} release..."
DOWNLOAD_URL=$(curl -sfL --connect-timeout 10 --max-time 30 --retry 3 --retry-connrefused --retry-delay 5 \
    "https://api.github.com/repos/${REPO}/releases/latest" \
    | python3 -c "import json,sys; assets=json.load(sys.stdin).get('assets',[]); print(next(a['browser_download_url'] for a in assets if a['name']=='deviceconfig-sample.yaml'))")

curl -sfL --connect-timeout 10 --max-time 30 --retry 3 --retry-connrefused --retry-delay 5 \
    "${DOWNLOAD_URL}" -o "${DEVICECONFIG_SAMPLE}"
echo "Downloaded deviceconfig-sample.yaml"

python3 -c "
import shlex, os, sys, re

spec = {}
with open('${DEVICECONFIG_SAMPLE}') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('---'):
            continue
        m = re.match(r'^(\w+):\s+(.+)$', line)
        if m:
            spec[m.group(1)] = m.group(2).strip('\"')

drivers_image = spec.get('driversImage', '')
in_cluster_build = not bool(drivers_image)

if drivers_image and ':' in drivers_image:
    driver_version = drivers_image.rsplit(':', 1)[-1]
else:
    driver_version = spec.get('driverVersion', '')

mapping = {
    'ECO_HWACCEL_NEURON_DRIVERS_IMAGE': drivers_image,
    'ECO_HWACCEL_NEURON_DRIVER_VERSION': driver_version,
    'ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE': spec.get('devicePluginImage', ''),
    'ECO_HWACCEL_NEURON_SCHEDULER_IMAGE': spec.get('customSchedulerImage', ''),
    'ECO_HWACCEL_NEURON_SCHEDULER_EXTENSION_IMAGE': spec.get('schedulerExtensionImage', ''),
    'ECO_HWACCEL_NEURON_NODE_METRICS_IMAGE': spec.get('nodeMetricsImage', ''),
}

optional_when_in_cluster = {
    'ECO_HWACCEL_NEURON_DRIVERS_IMAGE',
}

image_re = re.compile(r'^[a-zA-Z0-9._/:-]+(@sha256:[0-9a-fA-F]{64})?$')

env_path = os.path.join(os.environ['SHARED_DIR'], 'neuron-deviceconfig.env')
with open(env_path, 'w') as ef:
    for key, value in mapping.items():
        existing = os.environ.get(key, '')
        final = existing if existing else value
        if not final:
            if in_cluster_build and key in optional_when_in_cluster:
                ef.write(f'export {key}=\n')
                print(f'  {key}= (empty, in-cluster build mode)')
                continue
            print(f'ERROR: {key} resolved to empty', file=sys.stderr)
            sys.exit(1)
        if not image_re.match(final):
            print(f'ERROR: {key} contains unexpected characters: {final!r}', file=sys.stderr)
            sys.exit(1)
        ef.write(f'export {key}={shlex.quote(final)}\n')
        print(f'  {key}={final}')
    icb = 'true' if in_cluster_build else 'false'
    ef.write(f'export ECO_HWACCEL_NEURON_IN_CLUSTER_BUILD={icb}\n')
    print(f'  ECO_HWACCEL_NEURON_IN_CLUSTER_BUILD={icb}')
"
echo "DeviceConfig values resolved (written to SHARED_DIR/neuron-deviceconfig.env)"

source "${SHARED_DIR}/neuron-deviceconfig.env"

make cluster-operators
