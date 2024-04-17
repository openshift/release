#!/usr/bin/env bash

set -Eeuo pipefail

# Expose credentials for the openstack client
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE

export OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

function populate_artifact_dir() {
	set +e
	echo "Copying log bundle..."
	cp log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
	echo "Removing REDACTED info from log..."
	sed '
		s/password: .*/password: REDACTED/;
		s/X-Auth-Token.*/X-Auth-Token REDACTED/;
		s/UserData:.*,/UserData: REDACTED,/;
		' ".openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"

	cp inventory.yaml "${ARTIFACT_DIR}/inventory.yaml"

	# Make install-config.yaml available for debugging purposes
	openshift-install create install-config
	python - 'install-config.yaml' <<-EOF > "${ARTIFACT_DIR}/install-config.yaml"
		import yaml;
		import sys
		data = yaml.safe_load(open(sys.argv[1]))
		data["pullSecret"] = "redacted"
		if "proxy" in data:
		    data["proxy"] = "redacted"
		print(yaml.dump(data))
		EOF
}

function prepare_next_steps() {
	#Save exit code for must-gather to generate junit
	echo "$?" > "${SHARED_DIR}/install-status.txt"
	set +e
	#Signal termination to approve_csrs in case it started
	touch 'install-complete'
	date +%s > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
	date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"
	echo "Setup phase finished, prepare env for next steps"
	populate_artifact_dir
	echo "Copying required artifacts to shared dir"
	#Copy the auth artifacts to shared dir for the next steps
	cp -t "${SHARED_DIR}" \
		"auth/kubeconfig" \
		"auth/kubeadmin-password" \
		"metadata.json"
}

cd "$(mktemp -d)"

trap 'prepare_next_steps' EXIT TERM

# Expose the UPI playbooks to the script
cp /var/lib/openshift-install/upi/*.yaml .

# Expose configuration files to the script
cp -t . \
	"${SHARED_DIR}/install-config.yaml" \
	"${SHARED_DIR}/inventory.yaml"

# Extract OS_CACERT from clouds.yaml because that's how the UPI script expects it.
OS_CACERT="$(yq -r ".clouds.${OS_CLOUD}.cacert" "$OS_CLIENT_CONFIG_FILE")"
if [ -n "$OS_CACERT" ] && [ "$OS_CACERT" != "null" ]; then
	export OS_CACERT
else
	unset OS_CACERT
fi

# The cluster name is used to give a unique name to the RHCOS image in Glance
CLUSTER_NAME="$(yq -r '.metadata.name' "${SHARED_DIR}/install-config.yaml")"
export CLUSTER_NAME

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/

date +%s > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

mkdir manifests

# Collect the additional manifests prepared in previous steps
while IFS= read -r -d '' item; do
	manifest="$( basename "${item}" )"
	cp "${item}" "manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)


# UPI_DOCS is the Markdown documentation for UPI. We read it and copy its scripts to UPI_SCRIPT
UPI_DOCS='/var/lib/openshift-install/docs/install_upi.md'
UPI_SCRIPT="${ARTIFACT_DIR}/upi-install.sh"

sed '
	# Add a bash shebang and appropriate flags at the beginning of the target script
	1i #!/usr/bin/env bash
	1i set -Eeuo pipefail
	1i

	# Only pick up labelled lines from the documentation file
	1,/e2e-openstack-upi: INCLUDE START/d
	/e2e-openstack-upi: INCLUDE END/,/e2e-openstack-upi: INCLUDE START/d
	/e2e-openstack-upi: INCLUDE END/,$d

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

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
${SHELL} "$UPI_SCRIPT"

approve_csrs() {
	export KUBECONFIG="$PWD/auth/kubeconfig"
	while [[ ! -f 'install-complete' ]]; do
		oc get csr -o jsonpath='{.items[*].metadata.name}' | xargs --no-run-if-empty oc adm certificate approve || true
		sleep 15
	done
}

approve_csrs &
openshift-install wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'

# Save console URL in `console.url` file so that ci-chat-bot could report success
echo "https://$(env KUBECONFIG=${PWD}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
