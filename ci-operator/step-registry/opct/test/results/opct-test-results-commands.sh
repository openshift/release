#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

# Retrieve after successful execution
show_msg "Retrieving Results..."
mkdir -p "${ARTIFACT_DIR}/certification-results"
${OPCT_EXEC} retrieve "${ARTIFACT_DIR}/certification-results"

# Run results summary (to log to file)
show_msg "running: ${OPCT_EXEC} results"
${OPCT_EXEC} results "${ARTIFACT_DIR}"/certification-results/*.tar.gz

show_msg "running: ${OPCT_EXEC} report --verbose"
${OPCT_EXEC} report --verbose "${ARTIFACT_DIR}"/certification-results/*.tar.gz --save-to /tmp/results

#
# Gather some cluster information and upload certification results
#
install_awscli

# shellcheck disable=SC2153 # OPCT_VERSION is defined on ${SHARED_DIR}/install-env
show_msg "Saving file on bucket [openshift-provider-certification] and path [${OBJECT_PATH}]"
echo "Meta: ${OBJECT_META}"
echo "URL: https://openshift-provider-certification.s3.us-west-2.amazonaws.com/index.html"

aws s3 cp --only-show-errors --metadata "${OBJECT_META}" \
  "${ARTIFACT_DIR}"/certification-results/*.tar.gz \
  "s3://openshift-provider-certification/${OBJECT_PATH}"

## EXPERIMENTAL
# https://github.com/openshift/release/pull/33211
aws s3 cp --only-show-errors "s3://openshift-provider-certification/bin/opct-linux-amd64-devel" /tmp/opct
chmod u+x /tmp/opct

/tmp/opct report --verbose "${ARTIFACT_DIR}"/certification-results/*.tar.gz --save-to /tmp/results

REPORT_FILE="/tmp/results/opct-report.html"
if [ -f "$REPORT_FILE" ]; then
  cp "$REPORT_FILE" "${ARTIFACT_DIR}/opct-report.html"
  cp -rf /tmp/results/failures-* "${ARTIFACT_DIR}"
fi
[ -f "/tmp/results/opct-filter.html" ] && cp "/tmp/results/opct-filter.html" "${ARTIFACT_DIR}/opct-filter.html"


function write_custom_links() {
  # Create custom-link-tools.html from custom-links.txt
  REPORT="${ARTIFACT_DIR}/custom-link-tools.html"
  cat >> ${REPORT} << EOF
  <html>
  <head>
    <title>Debug tools</title>
    <meta name="description" content="Contains links to OpenShift-specific tools like Loki log collection, PromeCIeus, etc.">
    <link rel="stylesheet" type="text/css" href="/static/style.css">
    <link rel="stylesheet" type="text/css" href="/static/extensions/style.css">
    <link href="https://fonts.googleapis.com/css?family=Roboto:400,700" rel="stylesheet">
    <link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.indigo-pink.min.css">
    <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
    <style>
      a {
          display: inline-block;
          padding: 5px 20px 5px 20px;
          margin: 10px;
          border: 2px solid #4E9AF1;
          border-radius: 1em;
          text-decoration: none;
          color: #FFFFFF !important;
          text-align: center;
          transition: all 0.2s;
          background-color: #4E9AF1
      }

      a:hover {
          border-color: #FFFFFF;
      }
    </style>
  </head>
  <body>
  <div id="debug-links">
EOF

  if [[ -f ${SHARED_DIR}/custom-links.txt ]]; then
    cat ${SHARED_DIR}/custom-links.txt >> ${REPORT}
  fi

  cat >> ${REPORT} << EOF
  </div>
  </body>
  </html>
EOF
}
# write_custom_links

# cat >> ${SHARED_DIR}/custom-links.txt << EOF
#   <script>
#   let kaas = document.createElement('a');
#   kaas.href="https://kaas.dptools.openshift.org/?search="+document.referrer;
#   kaas.title="KaaS is a service to spawn a fake API service that parses must-gather data. As a result, users can pass Prow CI URL to the service, fetch generated kubeconfig and use kubectl/oc/k9s/openshift-console to investigate the state of the cluster at the time must-gather was collected. Note, on Chromium-based browsers you'll need to fill-in the Prow URL manually. Security settings prevent getting the referrer automatically."
#   kaas.innerHTML="KaaS";
#   kaas.target="_blank";
#   document.getElementById("debug-links").append(kaas);
#   </script>
# EOF
