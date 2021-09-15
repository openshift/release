#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

token=$(set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 40)

echo "Adding SUPER_USERS to Quay configuration..." >&2
config_secret="$(oc -n quay get secret --sort-by='{.metadata.creationTimestamp}' -o name | grep ^secret/quay-quay-config-secret- | tail -n1)"
config_yaml_base64="$(
    (
        oc -n quay get "$config_secret" -o 'go-template={{index .data "config.yaml" | base64decode}}'
        echo 'SUPER_USERS: ["admin"]'
    ) | base64 | tr -d '\n'
)"
oc -n quay patch "$config_secret" --type=merge -p '{"data":{"config.yaml":"'$config_yaml_base64'"}}'

echo "Waiting for Postgres to become ready..." >&2
for _ in {1..30}; do
    ready=$(oc -n quay get pods -l quay-component=postgres -o go-template='{{$x := ""}}{{range .items}}{{$status := "False"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$status = .status}}{{end}}{{end}}{{if or (eq $x "") (eq $status "False")}}{{$x = $status}}{{end}}{{end}}{{or $x "False"}}')
    if [ "$ready" = "True" ]; then
	break
    fi
    sleep 10
done

echo "Waiting for Quay to become ready..." >&2
for _ in {1..30}; do
    ready=$(oc -n quay get pods -l quay-component=quay-app -o go-template='{{$x := ""}}{{range .items}}{{$status := "False"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$status = .status}}{{end}}{{end}}{{if or (eq $x "") (eq $status "False")}}{{$x = $status}}{{end}}{{end}}{{or $x "False"}}')
    if [ "$ready" = "True" ]; then
	break
    fi
    sleep 10
done

echo "Creating OAuth application and token..." >&2
quay_app_pod=$(oc -n quay get pods -l quay-component=quay-app -o name | head -n1)

oc -n quay rsh "$quay_app_pod" python <<EOF
from app import app
from data import model
from data.database import configure

if hasattr(model.oauth, 'create_user_access_token'):
    create_user_access_token = model.oauth.create_user_access_token
else:
    create_user_access_token = model.oauth.create_access_token_for_testing

scope="org:admin repo:admin repo:create repo:read repo:write super:user user:admin user:read"

configure(app.config)

admin_user = model.user.create_user("admin", "p@ssw0rd", "admin@localhost.local", auto_verify=True)
operator_org = model.organization.create_organization("quay-bridge-operator", "quay-bridge-operator@localhost.local", admin_user)
operator_app = model.oauth.create_application(operator_org.id, "quay-bridge-operator", "", "")
create_user_access_token(admin_user, operator_app.client_id, scope, access_token="$token")
EOF

echo "Deleting Quay pods with old configuration..." >&2
oc delete pods -n quay -l quay-component=quay-app

echo "Waiting for Quay to become ready..." >&2
for _ in {1..60}; do
    ready=$(oc -n quay get pods -l quay-component=quay-app -o go-template='{{$x := ""}}{{range .items}}{{range .status.conditions}}{{if eq .type "Ready"}}{{if or (eq $x "") (eq .status "False")}}{{$x = .status}}{{end}}{{end}}{{end}}{{end}}{{or $x "False"}}')
    if [ "$ready" = "True" ]; then
        printf "%s" "$token" >"$SHARED_DIR/quay-access-token"
        echo "Quay is running" >&2
        exit 0
    fi
    sleep 10
done

echo "Timed out waiting for Quay to become ready" >&2
exit 1
