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
import yaml, shlex, os, sys, re

with open('${DEVICECONFIG_SAMPLE}') as f:
    dc = yaml.safe_load(f)

spec = dc.get('spec', {})

mapping = {
    'ECO_HWACCEL_NEURON_DRIVERS_IMAGE': spec.get('driversImage', ''),
    'ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE': spec.get('devicePluginImage', ''),
    'ECO_HWACCEL_NEURON_SCHEDULER_IMAGE': spec.get('customSchedulerImage', ''),
    'ECO_HWACCEL_NEURON_SCHEDULER_EXTENSION_IMAGE': spec.get('schedulerExtensionImage', ''),
    'ECO_HWACCEL_NEURON_NODE_METRICS_IMAGE': spec.get('nodeMetricsImage', ''),
}

drivers_image = spec.get('driversImage', '')
driver_version = drivers_image.rsplit(':', 1)[-1] if ':' in drivers_image else ''
mapping['ECO_HWACCEL_NEURON_DRIVER_VERSION'] = driver_version

image_re = re.compile(r'^[a-zA-Z0-9._/:-]+(@sha256:[0-9a-fA-F]{64})?$')

env_path = os.path.join(os.environ['SHARED_DIR'], 'neuron-deviceconfig.env')
with open(env_path, 'w') as ef:
    for key, value in mapping.items():
        existing = os.environ.get(key, '')
        final = existing if existing else value
        if not final:
            print(f'ERROR: {key} resolved to empty', file=sys.stderr)
            sys.exit(1)
        if not image_re.match(final):
            print(f'ERROR: {key} contains unexpected characters: {final!r}', file=sys.stderr)
            sys.exit(1)
        ef.write(f'export {key}={shlex.quote(final)}\n')
        print(f'  {key}={final}')
"
echo "DeviceConfig values resolved (written to SHARED_DIR/neuron-deviceconfig.env)"

source "${SHARED_DIR}/neuron-deviceconfig.env"

make cluster-operators
