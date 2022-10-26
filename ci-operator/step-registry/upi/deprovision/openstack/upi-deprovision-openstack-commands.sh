#!/usr/bin/env bash

set -Eeuo pipefail

# Expose credentials for the openstack client
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

cd "$(mktemp -d)"

cp "${SHARED_DIR}/metadata.json" ./

# The cluster name is used to give a unique name to the RHCOS image in Glance
CLUSTER_NAME="$(yq -r '.metadata.name' "${SHARED_DIR}/install-config.yaml")"
export CLUSTER_NAME

# Expose the UPI playbooks to the script
cp /var/lib/openshift-install/upi/*.yaml .

# Expose configuration files to the script
cp \
	"${SHARED_DIR}/install-config.yaml" \
	"${SHARED_DIR}/inventory.yaml" \
	./


# UPI_DOCS is the Markdown documentation for UPI. We read it and copy its scripts to UPI_SCRIPT
UPI_DOCS='/var/lib/openshift-install/docs/install_upi.md'
UPI_SCRIPT="${ARTIFACT_DIR}/upi-deprovision.sh"

sed '
	# Add a bash shebang and appropriate flags at the beginning of the target script
	1i #!/usr/bin/env bash
	1i set -Eeuo pipefail
	1i

	# Only pick up labelled lines from the documentation file
	1,/e2e-openstack-upi(deprovision): INCLUDE START/d
	/e2e-openstack-upi(deprovision): INCLUDE END/,/e2e-openstack-upi(deprovision): INCLUDE START/d
	/e2e-openstack-upi(deprovision): INCLUDE END/,$d

	# shell commands can be used directly (minus the leading PS1)
	/^```sh/,/^```/ {
		/^```sh/d
		s/^$ //
		/^```/c
	}

	# python scripts are passed as heredocs to the python interpreter
	/^```python/,/^```/ {
		/^```python/cpython <<EOF
		/^```/cEOF\n
	}

	# when the markdown triple-backtick-tag ends in ".json", interpret it as
	# a path where to put that JSON file
	/^```.*\.json$/,/^```/ {
		s/^```\(.*\.json\)$/cat <<EOF > "\1"/
		/^```/cEOF\n
	}
	' "$UPI_DOCS" > "$UPI_SCRIPT"

if ! whoami &> /dev/null; then
	if [[ -w /etc/passwd ]]; then
		echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
	fi
fi

${SHELL} "$UPI_SCRIPT"
