#!/bin/bash
set -euo pipefail

echo "Installing AWS Neuron Operator and dependencies"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

DEVICECONFIG_SAMPLE="/tmp/deviceconfig-sample.yaml"
REPO="awslabs/operator-for-ai-chips-on-aws"

echo "Fetching deviceconfig-sample.yaml from latest ${REPO} release..."
DOWNLOAD_URL=$(curl -sfL "https://api.github.com/repos/${REPO}/releases/latest" \
    | python3 -c "import json,sys; assets=json.load(sys.stdin).get('assets',[]); print(next(a['browser_download_url'] for a in assets if a['name']=='deviceconfig-sample.yaml'))")

curl -sfL "${DOWNLOAD_URL}" -o "${DEVICECONFIG_SAMPLE}"
echo "Downloaded deviceconfig-sample.yaml"

eval "$(python3 -c "
import yaml, sys, os

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

for key, value in mapping.items():
    if not os.environ.get(key):
        print(f'export {key}=\"{value}\"')
")"

echo "DeviceConfig values resolved:"
echo "  DRIVERS_IMAGE=${ECO_HWACCEL_NEURON_DRIVERS_IMAGE}"
echo "  DRIVER_VERSION=${ECO_HWACCEL_NEURON_DRIVER_VERSION}"
echo "  DEVICE_PLUGIN_IMAGE=${ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE}"
echo "  SCHEDULER_IMAGE=${ECO_HWACCEL_NEURON_SCHEDULER_IMAGE}"
echo "  SCHEDULER_EXTENSION_IMAGE=${ECO_HWACCEL_NEURON_SCHEDULER_EXTENSION_IMAGE}"
echo "  NODE_METRICS_IMAGE=${ECO_HWACCEL_NEURON_NODE_METRICS_IMAGE}"

# Save values for downstream steps (test, kserve-test)
cat > "${SHARED_DIR}/neuron-deviceconfig.env" <<EOF
export ECO_HWACCEL_NEURON_DRIVERS_IMAGE="${ECO_HWACCEL_NEURON_DRIVERS_IMAGE}"
export ECO_HWACCEL_NEURON_DRIVER_VERSION="${ECO_HWACCEL_NEURON_DRIVER_VERSION}"
export ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE="${ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE}"
export ECO_HWACCEL_NEURON_SCHEDULER_IMAGE="${ECO_HWACCEL_NEURON_SCHEDULER_IMAGE}"
export ECO_HWACCEL_NEURON_SCHEDULER_EXTENSION_IMAGE="${ECO_HWACCEL_NEURON_SCHEDULER_EXTENSION_IMAGE}"
export ECO_HWACCEL_NEURON_NODE_METRICS_IMAGE="${ECO_HWACCEL_NEURON_NODE_METRICS_IMAGE}"
EOF

make cluster-operators
