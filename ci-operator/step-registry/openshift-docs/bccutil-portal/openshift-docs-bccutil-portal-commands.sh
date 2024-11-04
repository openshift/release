#!/bin/bash

# set -o nounset
# set -o errexit
# set -o pipefail
set -o verbose

# Clone the PR under test
git init ~/openshift-docs-src
cd ~/openshift-docs-src || exit
git remote add origin https://github.com/openshift/openshift-docs
git fetch origin pull/${PULL_NUMBER}/head:${PULL_NUMBER}
git checkout ${PULL_NUMBER}

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/get-updated-distros.sh > scripts/get-updated-distros.sh
curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/get-updated-portal-books.sh > scripts/get-updated-portal-books.sh

chmod +x ./scripts/get-updated-distros.sh
chmod +x ./scripts/get-updated-portal-books.sh

NETLIFY_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-netlify-secret/NETLIFY_AUTH_TOKEN)

export NETLIFY_AUTH_TOKEN

COMMIT_ID=$(git log -n 1 --pretty=format:"%H")
PULL_NUMBER="$(curl -s "https://api.github.com/search/issues?q=$COMMIT_ID" | jq '.items[0].number')"

IFS=' ' read -r -a DISTROS <<< "${DISTROS}"

PREVIEW_URL="https://${PULL_NUMBER}--${PREVIEW_SITE}.netlify.app"

for DISTRO in "${DISTROS[@]}"; do

    case "${DISTRO}" in
        "openshift-enterprise"|"openshift-acs"|"openshift-pipelines"|"openshift-serverless"|"openshift-gitops"|"openshift-builds"|"openshift-service-mesh"|"openshift-opp"|"openshift-rhde"|"openshift-lightspeed")
            TOPICMAP="_topic_maps/_topic_map.yml"
            ;;
        "openshift-rosa")
            TOPICMAP="_topic_maps/_topic_map_rosa.yml"
            ;;
        "openshift-rosa-hcp")
            TOPICMAP="_topic_maps/_topic_map_rosa_hcp.yml"
            ;;
        "openshift-dedicated")
            TOPICMAP="_topic_maps/_topic_map_osd.yml"
            ;;
        "microshift")
            TOPICMAP="_topic_maps/_topic_map_ms.yml"
            ;;
    esac

    # For legacy ccutil build image, need to run with Python3.11     env
    ./scripts/get-updated-distros.sh | while read -r FILENAME; do
        if [ "${FILENAME}" == "${TOPICMAP}" ]; then
            echo -e "\e[91mBuilding openshift-docs with ${DISTRO} distro...\e[0m"
            python3.11 "${BUILD}" --distro "${DISTRO}" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
        elif [ "${FILENAME}" == "_distro_map.yml" ]; then
            python3.11 "${BUILD}" --distro "openshift-enterprise" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
        fi
    done
done

if [ -d "drupal-build" ]; then
    python3.11 makeBuild.py

    mkdir bccutil-portal

    # Calculate the portal preview URLs
    scripts/get-updated-portal-books.sh | while read -r FILENAME; do
        # Log the calculated URL to UPDATED_PAGES
        echo "$FILENAME" | cut -d'/' -f3- | sed 's/\master.adoc$/html-single\/index.html/' | sed "s|^|$PREVIEW_URL/|" | tr '\n' ' ' >> "${SHARED_DIR}/UPDATED_PAGES"
    done

    # Copy only the updated book folders from drupal-build/
    scripts/get-updated-portal-books.sh | while read -r FILENAME; do
        FOLDER_PATH=$(dirname "${FILENAME}")

        if [[ "$FOLDER_PATH" == "." ]]; then
            continue
        fi

        cp -r ${FOLDER_PATH} bccutil-portal
    done
fi

# Build only the updated assemblies
find bccutil-portal -type d -exec sh -c '
  for FOLDER in "$@"; do
    if [ -f "$FOLDER/master.adoc" ]; then
      cd "$FOLDER"

      ccutil compile --lang=en-US --format html-single

    fi
  done
' sh {} +

# Deploy with netlify
mkdir bccutil-netlify

find bccutil-portal -type d -exec sh -c '
  for FOLDER in "$@"; do
    if [ -d $FOLDER/build/tmp/en-US/html-single ]; then
      TARGET_DIR="$(basename $FOLDER)"
      mkdir bccutil-netlify/${TARGET_DIR}
      cp -r $FOLDER/build/tmp/en-US/html-single bccutil-netlify/${TARGET_DIR}
    fi
  done
' sh {} +

netlify deploy --site "${PREVIEW_SITE}" --auth "${NETLIFY_AUTH_TOKEN}" --alias "${PULL_NUMBER}" --dir="bccutil-netlify"
