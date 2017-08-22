#!/bin/bash

secret=$( mktemp )
cat <<EOF >secret
{
    "$( oc get route gubernator -o "jsonpath={.spec.host}" )": {
        "session": "$( openssl rand -base64 16 )",
        "github_client": {
            "id": "${GUBERNATOR_CLIENT_ID}",
            "secret": "${GUBERNATOR_CLIENT_SECRET}"
        }
    }
}
EOF

oc create secret generic gubernator-config --from-file "secrets.json=${secret}" --dry-run -o yaml | oc apply -f -

rm "${secret}"