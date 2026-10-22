#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf os image stream command ************"

# OSSTREAM is the single user-facing stream selector: rhcos-conf-osstream consumes it for the
# MachineConfigPools, and this step translates it into the OS_IMAGE_STREAM variable that
# dev-scripts writes to install-config.yaml as osImageStream.
if [[ -z "${OSSTREAM:-}" ]]; then
  echo "OSSTREAM is not set, leaving the install-config osImageStream unset"
  exit 0
fi

case "${OSSTREAM}" in
  rhel-9|rhel-10) ;;
  *)
    echo "ERROR: unsupported OSSTREAM '${OSSTREAM}', supported values are rhel-9 and rhel-10"
    exit 1
    ;;
esac

# install-config osImageStream is protected by the OSStreams feature gate, which openshift/api
# only enables by default from 4.23 on. Writing the field on an older payload makes the
# installer reject install-config, so gate on the release that is actually installed. For an
# upgrade job that is the initial release, never the upgrade target.
if [[ -z "${OSSTREAM_INITIAL_RELEASE_IMAGE:-}" ]]; then
  echo "ERROR: OSSTREAM=${OSSTREAM} was requested but the initial release image is not available,"
  echo "ERROR: so osImageStream support cannot be determined. Refusing to guess."
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR:-}/pull-secret" ]]; then
  echo "ERROR: OSSTREAM=${OSSTREAM} was requested but the pull secret is missing,"
  echo "ERROR: so the initial release version cannot be read. Refusing to guess."
  exit 1
fi

# The release image lives in the build farm registry, whose credentials are not part of the
# cluster profile pull secret, so merge them into a copy the same way the other steps that read
# a release image do.
pull_secret=/tmp/pull-secret
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${pull_secret}"
if ! oc registry login --to "${pull_secret}"; then
  rm -f "${pull_secret}"
  echo "ERROR: OSSTREAM=${OSSTREAM} was requested but logging in to the registry failed,"
  echo "ERROR: so the initial release version cannot be read. Refusing to guess."
  exit 1
fi

initial_version="$(oc adm release info --registry-config "${pull_secret}" \
    "${OSSTREAM_INITIAL_RELEASE_IMAGE}" --output=jsonpath='{.metadata.version}')" || initial_version=""
rm -f "${pull_secret}"

if [[ -z "${initial_version}" ]]; then
  echo "ERROR: OSSTREAM=${OSSTREAM} was requested but reading the initial release version failed."
  exit 1
fi

# Accept only a complete release version, so that an unexpected or truncated metadata value can
# never be read as a supported release. The grammar is major.minor.patch with the optional
# prerelease and build identifiers OpenShift actually publishes, for example 4.23.0,
# 4.23.0-ec.2, 4.23.0-rc.1, 4.23.0-0.nightly-2026-10-20-000000 and 4.23.0-0.ci-2026-10-20-000000.
# Each identifier must be non-empty, so trailing separators and empty suffixes are rejected, and
# no character class admits whitespace, so an embedded space or newline is rejected too.
identifier='[0-9A-Za-z-]+'
version_re="^([0-9]+)\.([0-9]+)\.([0-9]+)(-${identifier}(\.${identifier})*)?(\+${identifier}(\.${identifier})*)?$"

if [[ "${initial_version}" =~ [[:space:]] || ! "${initial_version}" =~ ${version_re} ]]; then
  echo "ERROR: OSSTREAM=${OSSTREAM} was requested but the initial release version"
  echo "ERROR: '${initial_version}' is not a complete release version. Refusing to guess."
  exit 1
fi
# Base 10 is explicit so that a zero-padded component is never read as octal.
major=$(( 10#${BASH_REMATCH[1]} ))
minor=$(( 10#${BASH_REMATCH[2]} ))

if (( major < 4 || ( major == 4 && minor < 23 ) )); then
  echo "Initial release ${initial_version} does not enable the OSStreams feature gate by default,"
  echo "so the install-config osImageStream is left unset; OSSTREAM=${OSSTREAM} still applies to"
  echo "the MachineConfigPools."
  exit 0
fi

echo "Initial release ${initial_version} supports osImageStream, installing from ${OSSTREAM}"
echo "export OS_IMAGE_STREAM=${OSSTREAM}" >> "${SHARED_DIR}/dev-scripts-additional-config"
