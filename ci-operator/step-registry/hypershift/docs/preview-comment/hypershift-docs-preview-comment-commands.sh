#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

PREVIEW_URL=$(cat "${SHARED_DIR}/preview-url")

# Create the artifact with the preview link
REPORT="${ARTIFACT_DIR}/custom-link-tools.html"
cat > "${REPORT}" << EOF
<html>
<head>
  <title>Documentation Preview</title>
  <meta name="description" content="Link to the HyperShift documentation preview deployed to Cloudflare Pages.">
  <link rel="stylesheet" type="text/css" href="/static/style.css">
  <link rel="stylesheet" type="text/css" href="/static/extensions/style.css">
  <link href="https://fonts.googleapis.com/css?family=Roboto:400,700" rel="stylesheet">
  <link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.indigo-pink.min.css">
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    a {
        display: inline-block;
        padding: 10px 30px;
        margin: 20px;
        border: 2px solid #4E9AF1;
        border-radius: 1em;
        text-decoration: none;
        color: #FFFFFF !important;
        text-align: center;
        transition: all 0.2s;
        background-color: #4E9AF1;
        font-size: 18px;
    }
    a:hover {
        border-color: #FFFFFF;
    }
    .info {
        margin: 20px;
        color: #666;
        font-family: 'Roboto', sans-serif;
    }
  </style>
</head>
<body>
  <div class="info">
    <p>Your documentation changes have been deployed to Cloudflare Pages.</p>
  </div>
  <a target="_blank" href="${PREVIEW_URL}" title="View the documentation preview deployed to Cloudflare Pages">View Documentation Preview</a>
</body>
</html>
EOF

echo "Documentation preview available at: ${PREVIEW_URL}"
echo "Preview link added to job artifacts (custom-link-tools.html)"
