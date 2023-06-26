#!/bin/bash

set -exuo pipefail

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

cat >> ${SHARED_DIR}/custom-links.txt << EOF
  <script>
  let kaas = document.createElement('a');
  kaas.href="https://kaas.dptools.openshift.org/?search="+document.referrer;
  kaas.title="KaaS is a service to spawn a fake API service that parses must-gather data. As a result, users can pass Prow CI URL to the service, fetch generated kubeconfig and use kubectl/oc/k9s/openshift-console to investigate the state of the cluster at the time must-gather was collected. Note, on Chromium-based browsers you'll need to fill-in the Prow URL manually. Security settings prevent getting the referrer automatically."
  kaas.innerHTML="KaaS";
  kaas.target="_blank";
  document.getElementById("debug-links").append(kaas);
  </script>
EOF

write_custom_links
