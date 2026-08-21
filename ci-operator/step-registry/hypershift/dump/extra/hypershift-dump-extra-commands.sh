#!/bin/bash
function queue() {
  local TARGET="${1}"
  shift
  local LIVE
  LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  if [[ -n "${FILTER:-}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
  else
    "${@}" >"${TARGET}" &
  fi
}

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Gathering artifacts ..."
mkdir -p ${ARTIFACT_DIR}/pods ${ARTIFACT_DIR}/nodes ${ARTIFACT_DIR}/metrics ${ARTIFACT_DIR}/bootstrap ${ARTIFACT_DIR}/network ${ARTIFACT_DIR}/oc_cmds

prometheus="$( oc --insecure-skip-tls-verify --request-timeout=20s get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus --ignore-not-found -o name )"
if [[ -n "${prometheus}" ]]; then
	echo "${prometheus}" | while read prompod; do
	  prompod=${prompod#"pod/"}
		FILE_NAME="${prompod}"
		# for backwards compatibility with promecious we keep the first files beginning with "prometheus"
		if [[ "$prompod" == *-0 ]]; then
			FILE_NAME="prometheus"
		fi

		echo "Snapshotting prometheus from ${prompod} as ${FILE_NAME} (may take 15s) ..."
		queue "${ARTIFACT_DIR}/metrics/${FILE_NAME}.tar.gz" oc --insecure-skip-tls-verify exec -n openshift-monitoring "${prompod}" -- tar cvzf - -C /prometheus .

		FILTER=gzip queue ${ARTIFACT_DIR}/metrics/${FILE_NAME}-target-metadata.json.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring "${prompod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/targets/metadata --data-urlencode 'match_target={instance!=\"\"}'"
		FILTER=gzip queue ${ARTIFACT_DIR}/metrics/${FILE_NAME}-config.json.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring "${prompod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/status/config"
		queue ${ARTIFACT_DIR}/metrics/${FILE_NAME}-tsdb-status.json oc --insecure-skip-tls-verify exec -n openshift-monitoring "${prompod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/status/tsdb"
		queue ${ARTIFACT_DIR}/metrics/${FILE_NAME}-runtimeinfo.json oc --insecure-skip-tls-verify exec -n openshift-monitoring "${prompod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/status/runtimeinfo"
		queue ${ARTIFACT_DIR}/metrics/${FILE_NAME}-targets.json oc --insecure-skip-tls-verify exec -n openshift-monitoring "${prompod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/targets"
	done

	cat >> ${SHARED_DIR}/custom-links.txt <<-EOF
	<script>
	let prom = document.createElement('a');
	prom.href="https://promecieus.dptools.openshift.org/?search="+document.referrer;
	prom.title="Creates a new prometheus deployment with data from this job run.";
	prom.innerHTML="PromeCIeus";
	prom.target="_blank";
	document.getElementById("wrapper").append(prom);
	</script>
	EOF
else
	echo "Unable to find a Prometheus pod to snapshot."
fi

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
EOF

if [[ -f ${SHARED_DIR}/custom-links.txt ]]; then
  cat ${SHARED_DIR}/custom-links.txt >> ${REPORT}
fi

cat >> ${REPORT} << EOF
</body>
</html>
EOF
