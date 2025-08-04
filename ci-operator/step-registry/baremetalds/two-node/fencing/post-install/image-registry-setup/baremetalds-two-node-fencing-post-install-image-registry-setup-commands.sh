#!/bin/bash

echo "baremetalds-two-node-fencing-post-install-image-registry-setup starting..."

# Check for image registry availability
for _ in {1..10}; do
  count=$(oc get configs.imageregistry.operator.openshift.io/cluster --no-headers | wc -l)
  echo "Image registry count: ${count}"
  if [[ ${count} -gt 0 ]]; then
    break
  fi
  sleep 30
done

# Check for imagestreams availability
for _ in {1..10}; do
  if ! oc get imagestreams --all-namespaces; then
    sleep 30
  else
    echo "$(date) - Imagestreams are available"
    break
  fi
done

# this works around a problem where tests fail because imagestreams aren't imported.  We see this happen for exec session.
echo "$(date) - waiting for non-samples imagesteams to import..."
count=0
while :
do
  non_imported_imagestreams=$(oc -n openshift get imagestreams -o go-template='{{range .items}}{{$namespace := .metadata.namespace}}{{$name := .metadata.name}}{{range .status.tags}}{{if not .items}}{{$namespace}}/{{$name}}:{{.tag}}{{"\n"}}{{end}}{{end}}{{end}}')
  if [ -z "${non_imported_imagestreams}" ]
  then
    break
  fi
  echo "The following image streams are yet to be imported (attempt #${count}):"
  echo "${non_imported_imagestreams}"

  count=$((count+1))
  if (( count > 30 )); then
    echo "Failed while waiting on imagestream import"
    exit 1
  fi

  sleep 60
done
echo "$(date) - all imagestreams are imported."